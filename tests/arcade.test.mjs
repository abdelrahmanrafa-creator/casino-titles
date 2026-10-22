import {test,after} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readdir} from 'node:fs/promises';
import {createTitlesDatabase,asPlayer,uid} from './helpers/titlesDatabase.mjs';
const migrations=(await readdir(new URL('../supabase/migrations/',import.meta.url))).filter(f=>f.endsWith('.sql')&&!f.includes('010000_titles_identity')&&!f.includes('020000_titles_economy')).sort();
const db=await createTitlesDatabase(undefined,migrations);after(()=>db.close());
const rpc=async(n,name,args=[])=>(await asPlayer(db,n,`SELECT ${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) result`,args)).rows[0].result;
const balance=async n=>(await db.query('SELECT balance FROM ct_wallets WHERE user_id=$1',[uid(n)])).rows[0].balance;
test('clicker credits exact server value once, caps burst and daily limit, refuses direct writes',async()=>{
 const before=await balance(1),op=randomUUID();const result=await rpc(1,'ct_clicker_action',[op,'click',20,0]);assert.equal(result.amount,20);assert.equal(await balance(1),before+20);assert.deepEqual(await rpc(1,'ct_clicker_action',[op,'click',20,0]),result);
 await assert.rejects(rpc(1,'ct_clicker_action',[randomUUID(),'click',21,0]),/20 clics/);await assert.rejects(rpc(1,'ct_clicker_action',[randomUUID(),'click',20,0]),/rapides/);
 await assert.rejects(asPlayer(db,1,'UPDATE ct_clickers SET level=10'),/permission denied/);
 await db.query('UPDATE ct_clickers SET day_clicks=5000,tokens=20 WHERE user_id=$1',[uid(1)]);await assert.rejects(rpc(1,'ct_clicker_action',[randomUUID(),'click',1,0]),/quotidienne/);
});
test('upgrade is paid atomically, changes future yield and rejects stale price/level',async()=>{
 const before=await balance(1),op=randomUUID(),result=await rpc(1,'ct_clicker_action',[op,'upgrade',0,0]);assert.equal(result.amount,-100);assert.equal(result.arcade.per_click,2);assert.equal(await balance(1),before-100);assert.deepEqual(await rpc(1,'ct_clicker_action',[op,'upgrade',0,0]),result);
 await assert.rejects(rpc(1,'ct_clicker_action',[randomUUID(),'upgrade',0,0]),/niveau/);await db.query('UPDATE ct_clickers SET day=day-1,tokens=20 WHERE user_id=$1',[uid(1)]);assert.equal((await rpc(1,'ct_clicker_action',[randomUUID(),'click',3,1])).amount,6);
 await db.query('UPDATE ct_wallets SET balance=0 WHERE user_id=$1',[uid(2)]);await assert.rejects(rpc(2,'ct_clicker_action',[randomUUID(),'upgrade',0,0]),/Insufficient/);assert.equal((await rpc(2,'ct_arcade_state')).level,0);
});
test('daily free gift and click milestones cannot be collected twice',async()=>{
 const op=randomUUID(),result=await rpc(1,'ct_free_reward',[op,'gift',0]);assert.ok(result.amount>=100&&result.amount<=500);assert.deepEqual(await rpc(1,'ct_free_reward',[op,'gift',0]),result);await assert.rejects(rpc(1,'ct_free_reward',[randomUUID(),'gift',0]),/duplicate key/);
 await assert.rejects(rpc(1,'ct_free_reward',[randomUUID(),'milestone',100]),/non atteint/);await db.query('UPDATE ct_clickers SET total_clicks=100 WHERE user_id=$1',[uid(1)]);assert.equal((await rpc(1,'ct_free_reward',[randomUUID(),'milestone',100])).amount,50);await assert.rejects(rpc(1,'ct_free_reward',[randomUUID(),'milestone',100]),/duplicate key/);
});
test('promo administration rejects players; reward, title and claim commit once under stock lock',async()=>{
 const values={code:'TEST-CERCLE',name:'Test du cercle',credits:450,title_id:'ct-2-001',active:true,starts_at:new Date(Date.now()-3600000).toISOString(),ends_at:new Date(Date.now()+3600000).toISOString(),max_uses:1};
 await assert.rejects(rpc(1,'ct_admin_save_promo',[randomUUID(),values,'Création de test']),/Administrator/);await db.query('INSERT INTO ct_admins(user_id) VALUES($1)',[uid(1)]);await rpc(1,'ct_admin_save_promo',[randomUUID(),values,'Création de test']);
 await assert.rejects(asPlayer(db,2,'SELECT * FROM ct_promos'),/permission denied/);const op=randomUUID(),result=await rpc(1,'ct_redeem_promo',[op,'  test-cercle ']);assert.equal(result.amount,450);assert.equal(result.title.id,'ct-2-001');assert.deepEqual(await rpc(1,'ct_redeem_promo',[op,'TEST-CERCLE']),result);
 await assert.rejects(rpc(2,'ct_redeem_promo',[randomUUID(),'TEST-CERCLE']),/épuisé/);assert.equal((await db.query('SELECT count(*)::int n FROM ct_promo_claims')).rows[0].n,1);
 const updated={...values,max_uses:5,version:1};await rpc(1,'ct_admin_save_promo',[randomUUID(),updated,'Extension de test']);await assert.rejects(rpc(1,'ct_redeem_promo',[randomUUID(),'TEST-CERCLE']),/déjà utilisé/);await assert.rejects(rpc(1,'ct_admin_save_promo',[randomUUID(),updated,'Écriture obsolète']),/modifié/);
 await db.query("UPDATE ct_promos SET ends_at=now()-interval '1 second',starts_at=now()-interval '2 days'");await assert.rejects(rpc(2,'ct_redeem_promo',[randomUUID(),'TEST-CERCLE']),/expiré/);
});
test('public title counts use unique active owners; people search exposes only public projections',async()=>{
 await db.query("INSERT INTO ct_player_titles(user_id,title_id,source) VALUES($1,'ct-2-001','test'),($2,'ct-2-001','test')",[uid(1),uid(2)]);
 let stats=await rpc(1,'ct_title_statistics');assert.equal(stats.find(t=>t.title_id==='ct-2-001').owners,2);
 await db.query("UPDATE ct_player_titles SET revoked_at=now() WHERE user_id=$1 AND title_id='ct-2-001'",[uid(2)]);stats=await rpc(1,'ct_title_statistics');assert.equal(stats.find(t=>t.title_id==='ct-2-001').owners,1);
 const username=(await db.query('SELECT username FROM ct_profiles WHERE id=$1',[uid(1)])).rows[0].username;const people=await rpc(2,'ct_find_players',[username]);assert.ok(people.some(p=>p.id===uid(1)));assert.deepEqual(Object.keys(people[0]).sort(),['avatar','equipped_title','id','is_bot','unique_titles','username']);assert.deepEqual(await rpc(1,'ct_find_players',['%']),[]);
 const collection=await rpc(2,'ct_public_collection',[uid(1)]);assert.equal(collection.find(t=>t.id==='ct-2-001').copies,2);assert.ok(!JSON.stringify(collection).includes('user_id'));
});
