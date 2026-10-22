import {test,after} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readdir} from 'node:fs/promises';
import {createTitlesDatabase,asPlayer,uid} from './helpers/titlesDatabase.mjs';
const migrations=(await readdir(new URL('../supabase/migrations/',import.meta.url))).filter(f=>f.endsWith('.sql')&&!f.includes('010000_titles_identity')&&!f.includes('020000_titles_economy')).sort();
const db=await createTitlesDatabase(undefined,migrations);
after(()=>db.close());
const code='test-only-admin-code-with-256bits-fixture',nextCode='test-only-next-secret-with-a-different-value';
await db.query("INSERT INTO ct_admin_security(id,salt,code_hash) VALUES(true,'fixture',encode(sha256(convert_to('fixture'||$1,'UTF8')),'hex'))",[code]);
const rpc=async(n,name,args=[],session=n)=>(await asPlayer(db,n,`SELECT ${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) result`,args,session)).rows[0].result;
const unlock=n=>rpc(n,'ct_admin_unlock',[code]);
const quote=async(n,id)=>(await rpc(n,'ct_shop_chests')).find(c=>c.id===id);
const saveOffer=(values,op=randomUUID())=>rpc(1,'ct_admin_save_offer',[op,values,'Campagne de test autorisée']);
const open=(n,q,op=randomUUID())=>rpc(n,'ct_open_chest',[op,q.id,q.version,q.current_price,q.offer_id]);
const dates={starts_at:new Date(Date.now()-3600000).toISOString(),ends_at:new Date(Date.now()+3600000).toISOString()};
test('admin remains locked; invalid attempts persist and five attempts cause a timed block',async()=>{
 assert.equal((await rpc(1,'ct_admin_access')).is_admin,false);
 assert.equal(await rpc(1,'ct_is_admin'),false);
 await assert.rejects(rpc(1,'ct_admin_dashboard'),/unlock required/);
 for(let i=0;i<5;i++)assert.equal((await rpc(1,'ct_admin_unlock',['wrong-code-long-enough-but-incorrect'])).ok,false);
 assert.equal((await db.query('SELECT failures FROM ct_admin_attempts WHERE user_id=$1',[uid(1)])).rows[0].failures,5);
 assert.equal((await unlock(1)).ok,false);
 await db.query('UPDATE ct_admin_attempts SET blocked_until=now()-interval \'1 second\',window_start=now()-interval \'11 minutes\' WHERE user_id=$1',[uid(1)]);
 assert.equal((await unlock(1)).ok,true);assert.equal(await rpc(1,'ct_is_admin'),true);
 assert.equal((await rpc(1,'ct_admin_access')).is_admin,true);
 assert.equal((await db.query('SELECT count(*)::int n FROM ct_admins')).rows[0].n,1);
});
test('account role grants access across sessions without code and expired unlocks do not restrict it',async()=>{
 assert.equal((await unlock(2)).ok,false);
 await rpc(1,'ct_admin_role',[randomUUID(),uid(2),true,'Accès délégué pour le test']);
 assert.equal((await rpc(2,'ct_admin_access')).is_admin,true);
 assert.equal((await unlock(2)).ok,true);
 assert.equal(await rpc(1,'ct_is_admin',[],99),true);
 assert.ok(await rpc(1,'ct_admin_overview',[''],99));
 await db.query('UPDATE ct_admin_sessions SET expires_at=now()-interval \'1 second\' WHERE user_id=$1',[uid(1)]);
 assert.ok(await rpc(1,'ct_admin_dashboard'));
 assert.equal((await rpc(1,'ct_admin_access')).is_admin,true);
 assert.equal((await unlock(1)).ok,true);
 await assert.rejects(asPlayer(db,1,'SELECT * FROM ct_admin_security'),/permission denied/);
});
test('active offer exposes a real base price, sale price and exact discount; only one stock item can sell',async()=>{
 const saved=await saveOffer({chest_id:1,name:'Éclair -50%',sale_price:250,...dates,active:true,stock_limit:1,per_player_limit:1});
 const a=await quote(1,1),b=await quote(2,1);assert.equal(a.base_price,500);assert.equal(a.current_price,250);assert.equal(a.discount_percent,50);assert.equal(a.offer_id,saved.offer_id);
 const op=randomUUID(),results=await Promise.allSettled([open(1,a,op),open(2,b)]);
 assert.equal(results.filter(r=>r.status==='fulfilled').length,1);
 const winner=results[0].status==='fulfilled'?1:2;
 const balance=(await db.query('SELECT sum(balance)::int n FROM ct_wallets')).rows[0].n;assert.equal(balance,9750);
 assert.equal((await db.query('SELECT stock_used FROM ct_chest_offers WHERE id=$1',[saved.offer_id])).rows[0].stock_used,1);
 const receipt=(await db.query('SELECT * FROM ct_chest_openings WHERE offer_id=$1',[saved.offer_id])).rows[0];assert.equal(receipt.base_price,500);assert.equal(receipt.price_paid,250);
 if(winner===1)assert.deepEqual(await open(1,a,op),results[0].value);
 assert.equal((await quote(2,1)).current_price,500);
});
test('future/expired promotions never advertise an active discount; no fake or zero-limit free offer',async()=>{
 const future={starts_at:new Date(Date.now()+3600000).toISOString(),ends_at:new Date(Date.now()+7200000).toISOString()};
 await saveOffer({chest_id:2,name:'Demain',sale_price:1000,...future,active:true,stock_limit:null,per_player_limit:null});
 assert.equal((await quote(1,2)).current_price,2000);
 await assert.rejects(saveOffer({chest_id:2,name:'Fausse réduction',sale_price:2100,...dates,active:true}),/lower than/);
 await assert.rejects(saveOffer({chest_id:2,name:'Gratuit sans limite',sale_price:0,...dates,active:true}),/check constraint/);
});
test('event chest creation validates exact probability tables and conserves stock',async()=>{
 const values={name:'Nébuleuse de test',price:1000,weights:[0,0,10000,0,0,0,0,0],active:true,rarity:8,description:'Un coffre événementiel limité.',category:'event',...dates,stock_limit:1,per_player_limit:1,title_pool:['ct-3-001'],allow_exclusive:true};
 const saved=await rpc(1,'ct_admin_save_chest',[randomUUID(),values,'Création du coffre événementiel']);
 assert.ok(saved.chest_id>8);const q=await quote(1,saved.chest_id);assert.equal(q.category,'event');assert.equal(q.rarity,8);
 const result=await open(1,q);assert.equal(result.title.id,'ct-3-001');assert.equal((await quote(2,saved.chest_id)).available,false);
 await assert.rejects(open(2,q),/indisponible/);
 await assert.rejects(rpc(1,'ct_admin_save_chest',[randomUUID(),{...values,name:'Impossible',weights:[9999,0,0,0,0,0,0,0]},'Validation des probabilités']),/exactly 100/);
});
test('free promotion is once per player, keeps a zero debit and awards a real title',async()=>{
 await saveOffer({chest_id:2,name:'Cadeau limité',sale_price:0,...dates,active:true,stock_limit:2,per_player_limit:1});
 const before=(await db.query('SELECT balance FROM ct_wallets WHERE user_id=$1',[uid(2)])).rows[0].balance;
 const result=await open(2,await quote(2,2));assert.equal(result.price_paid,0);assert.equal(result.balance,before);assert.ok(result.player_title_id);
 assert.equal((await quote(2,2)).current_price,2000);
});
test('game pause prevents new wagers, preserves replays and hides old bypass functions',async()=>{
 const op=randomUUID(),choice={side:'pile'};const first=await rpc(1,'ct_play_game',[op,'coinflip',20,choice]);
 await rpc(1,'ct_admin_game_control',[randomUUID(),'coinflip',false,20,1000000,'Pause temporaire de la table']);
 await assert.rejects(rpc(1,'ct_play_game',[randomUUID(),'coinflip',20,choice]),/paused/);
 assert.deepEqual(await rpc(1,'ct_play_game',[op,'coinflip',20,choice]),first);
 await assert.rejects(rpc(1,'ct_play_game_v1',[randomUUID(),'coinflip',20,choice]),/permission denied/);
 await rpc(1,'ct_admin_game_control',[randomUUID(),'coinflip',true,200,1000,'Nouvelles limites de mise']);
 await assert.rejects(rpc(1,'ct_play_game',[randomUUID(),'coinflip',20,choice]),/limits/);
});
test('admin missions retain once-only rewards; inactive missions cannot be claimed',async()=>{
 const values={id:'qa-mission',name:'Mission de test',description:'Profil créé',kind:'profile',target:1,reward:300,active:true};
 await rpc(1,'ct_admin_save_quest',[randomUUID(),values,'Création de mission de test']);
 const result=await rpc(2,'ct_claim_quest',[randomUUID(),values.id]);assert.equal(result.amount,300);
 await rpc(1,'ct_admin_save_quest',[randomUUID(),{...values,reward:500},'Mise à jour de récompense']);
 await assert.rejects(rpc(2,'ct_claim_quest',[randomUUID(),values.id]),/already claimed/);
 await rpc(1,'ct_admin_save_quest',[randomUUID(),{...values,active:false},'Désactivation de la mission']);
 await assert.rejects(rpc(1,'ct_claim_quest',[randomUUID(),values.id]),/inactive/);
});
test('audit pagination returns a searched projection without code material',async()=>{
 const rows=await rpc(1,'ct_admin_audit',[null,null,'save_offer']);assert.ok(rows.length>0);assert.ok(rows.every(a=>a.action==='save_offer'&&a.admin_name));
 assert.ok(!JSON.stringify(rows).includes(code));
});
test('secret rotation preserves account roles, old code fails, no plaintext reaches audit or receipts',async()=>{
 await rpc(1,'ct_admin_rotate_code',[randomUUID(),nextCode,'Rotation de sécurité du test']);
 assert.equal(await rpc(1,'ct_is_admin'),true);assert.equal(await rpc(2,'ct_is_admin'),true);
 assert.equal((await unlock(2)).ok,false);assert.equal((await rpc(2,'ct_admin_unlock',[nextCode])).ok,true);
 const logs=(await db.query('SELECT coalesce(jsonb_agg(to_jsonb(a))::text,\'\') text FROM ct_admin_audit_logs a')).rows[0].text;
 const receipts=(await db.query('SELECT coalesce(jsonb_agg(to_jsonb(o))::text,\'\') text FROM ct_operations o')).rows[0].text;
 assert.ok(!logs.includes(nextCode)&&!receipts.includes(nextCode));
 await rpc(1,'ct_admin_lock');assert.equal(await rpc(1,'ct_is_admin'),true);
 await rpc(1,'ct_admin_role',[randomUUID(),uid(2),false,'Révocation du rôle de test']);
 assert.equal((await rpc(2,'ct_admin_access')).unlocked,false);await assert.rejects(rpc(2,'ct_admin_dashboard'),/unlock required/);
 await db.query('INSERT INTO ct_suspensions(user_id,reason) VALUES($1,$2)',[uid(1),'Suspension pour test de sécurité']);
 assert.equal(await rpc(1,'ct_is_admin'),false);await assert.rejects(rpc(1,'ct_admin_dashboard'),/unlock required/);
});

