import {test,after} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readdir} from 'node:fs/promises';
import {createTitlesDatabase,asPlayer,uid} from './helpers/titlesDatabase.mjs';
const migrations=(await readdir(new URL('../supabase/migrations/',import.meta.url))).filter(f=>f.endsWith('.sql')&&!f.includes('010000_titles_identity')&&!f.includes('020000_titles_economy')).sort();
const db=await createTitlesDatabase(undefined,migrations);after(()=>db.close());
const rpc=async(n,name,args=[])=>(await asPlayer(db,n,`SELECT ${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) result`,args)).rows[0].result;
await db.query('INSERT INTO ct_admins(user_id) VALUES($1)',[uid(1)]);
const chest=(await rpc(1,'ct_shop_chests')).find(c=>c.id===1);
const config={names:['VesperQA','007','z7q'],rarity_counts:[0,1,0,0,1,0,0,1],balance_min:12000,balance_max:12000,titles_min:8,titles_max:8,top_titles:1,chests_min:4,chests_max:4,games_min:10,games_max:10,win_percent:60,bet:100,chest_id:chest.id,chest_price:chest.price,chest_version:chest.version,avatar:'🤖',hidden:false,title_pool:[]};
const create=(values,op=randomUUID())=>rpc(1,'ct_admin_create_bots',[op,values,'Création de bots pour recette']);
const economy=()=>rpc(1,'ct_admin_economy',[30,null,'']);
let batch;
test('bot generation requires admin and validates exact counts, usernames and zero Cosmic eligibility atomically',async()=>{
 await assert.rejects(rpc(2,'ct_admin_create_bots',[randomUUID(),config,'Tentative de création']),/Administrator/);
 for(const values of [{...config,rarity_counts:[0,1,0,0,1,0,0,0]},{...config,names:['x','y','z']},{...config,names:['same','SAME','other']},{...config,rarity_counts:[0,1,0,0,1,0,0,0,1]}])await assert.rejects(create(values));
 await assert.rejects(create({...config,title_pool:['ct-8-001']}),/catalogue/);assert.equal((await db.query('SELECT count(*)::int n FROM ct_bots')).rows[0].n,0);
});
test('a bot batch produces exact inventories, settled wins and chest records with counterbalanced credits',async()=>{
 const before=await economy(),op=randomUUID();batch=await create(config,op);assert.equal(batch.count,3);assert.deepEqual(await create(config,op),batch);
 const list=await rpc(1,'ct_admin_bots',['',0]);assert.equal(list.total,3);assert.equal(list.balances,36000);
 for(const b of list.bots){assert.equal(b.balance,12000);assert.equal(b.titles,8);assert.equal(b.chests,4);assert.equal(b.games,10);assert.equal(b.wins,6);const titles=(await db.query('SELECT t.rarity,count(*)::int copies FROM ct_player_titles i JOIN ct_titles t ON t.id=i.title_id WHERE i.user_id=$1 GROUP BY t.rarity',[b.id])).rows;assert.equal(Math.max(...titles.map(t=>t.rarity)),b.max_rarity);assert.equal(titles.reduce((n,t)=>n+t.copies,0),12);assert.ok(titles.every(t=>t.rarity<=7));assert.equal((await db.query('SELECT count(*)::int n FROM auth.users WHERE id=$1',[b.id])).rows[0].n,0);}
 assert.equal(list.bots.filter(b=>b.max_rarity===7).length,1);assert.equal((await db.query('SELECT count(*)::int n FROM ct_game_rounds WHERE NOT simulated')).rows[0].n,0);
 const after=await economy();assert.equal(after.treasury_gross,before.treasury_gross-36000);assert.equal(after.bot_balances,36000);assert.equal(after.difference,0);assert.equal(after.ledger_difference,0);assert.equal(after.unmirrored,0);
});
test('bot identities cannot earn credits, authenticate as humans, become admin, receive Cosmic or enter a real room',async()=>{
 const id=batch.bots[0].id;
 await assert.rejects(db.query("INSERT INTO ct_player_titles(user_id,title_id,source) VALUES($1,'ct-8-001','test')",[id]),/Cosmic/);
 await assert.rejects(rpc(1,'ct_admin_role',[randomUUID(),id,true,'Élévation interdite du bot']),/Bots cannot/);
 await assert.rejects(db.transaction(async tx=>{await tx.exec('SET LOCAL ROLE authenticated');await tx.query("SELECT set_config('request.jwt.claim.sub',$1,true)",[id]);return tx.query('SELECT ct_claim_daily($1)',[randomUUID()]);}),/frozen/);
 await assert.rejects(db.query('SELECT ct_create_room($1,$2,$3,$4,$5,$6,$7,$8)',[id,randomUUID(),{kind:'bot-table'},'poker','BOTROOMQA',true,500,{phase:'waiting',host:id,seats:[{id,stack:500,committed:0}]}]),/Bots cannot/);
 assert.equal((await db.query('SELECT count(*)::int n FROM ct_rooms')).rows[0].n,0);
 const before=(await economy()).treasury_gross;await assert.rejects(create(config),/déjà utilisé/);assert.equal((await economy()).treasury_gross,before);
});
test('public projections label bots, count their holders, and never disclose human wallet balances',async()=>{
 const id=batch.bots[0].id,p=await rpc(2,'ct_public_profile',[id]);assert.equal(p.is_bot,true);assert.equal(p.bot_balance,12000);assert.equal(p.chests,4);assert.equal(p.games,10);assert.equal(p.wins,6);
 const human=await rpc(2,'ct_public_profile',[uid(1)]);assert.equal(human.is_bot,false);assert.equal(human.bot_balance,null);
 assert.equal((await rpc(2,'ct_find_players',['VesperQA']))[0].is_bot,true);assert.ok((await rpc(2,'ct_rankings',['credits','all'])).some(p=>p.id===id&&p.is_bot));
 const titles=await rpc(2,'ct_public_collection',[id]),counts=await rpc(2,'ct_title_statistics');assert.ok(titles.length===8);for(const t of titles)assert.ok(counts.find(c=>c.title_id===t.id).bots>=1);
});
test('bot editing is versioned, balances stay double-entered, archive hides profiles and restoration preserves stats',async()=>{
 let b=(await rpc(1,'ct_admin_bots',['VesperQA',0])).bots[0],before=await economy();const op=randomUUID(),values={username:'VesperEditedQA',avatar:'🦊',balance:15000,expected_balance:b.balance,active:false,hidden:true,version:b.version};
 await rpc(1,'ct_admin_update_bot',[op,b.id,values,'Modification du bot de test']);await rpc(1,'ct_admin_update_bot',[op,b.id,values,'Modification du bot de test']);
 assert.equal((await economy()).treasury_gross,before.treasury_gross-3000);assert.equal(await rpc(2,'ct_public_profile',[b.id]),null);assert.deepEqual(await rpc(2,'ct_find_players',['VesperEditedQA']),[]);assert.ok(!(await rpc(2,'ct_rankings',['credits','all'])).some(p=>p.id===b.id));
 await assert.rejects(rpc(1,'ct_admin_update_bot',[randomUUID(),b.id,values,'Ancienne fiche du bot']),/modifié/);
 b=(await rpc(1,'ct_admin_bots',['VesperEditedQA',0])).bots[0];await rpc(1,'ct_admin_update_bot',[randomUUID(),b.id,{...values,active:true,hidden:false,version:b.version,expected_balance:b.balance},'Réactivation du bot de test']);const p=await rpc(2,'ct_public_profile',[b.id]);assert.equal(p.chests,4);assert.equal(p.bot_balance,15000);assert.equal(p.wins,6);assert.equal((await economy()).difference,0);
});
test('real profile creation, Auth cascade deletion and ranking privacy remain intact',async()=>{
 await db.query('INSERT INTO auth.users VALUES($1,now())',[uid(3)]);await rpc(3,'ct_initialize_profile',['HumanAfterBotsQA']);const p=(await db.query('SELECT auth_user_id,is_bot FROM ct_profiles WHERE id=$1',[uid(3)])).rows[0];assert.equal(p.auth_user_id,uid(3));assert.equal(p.is_bot,false);
 await rpc(3,'ct_set_leaderboard_visibility',[true]);assert.ok(!(await rpc(2,'ct_rankings',['credits','all'])).some(p=>p.id===uid(3)));await db.query('DELETE FROM auth.users WHERE id=$1',[uid(3)]);assert.equal((await db.query('SELECT count(*)::int n FROM ct_profiles WHERE id=$1',[uid(3)])).rows[0].n,0);assert.equal((await economy()).difference,0);
 await assert.rejects(asPlayer(db,2,'SELECT * FROM ct_bots'),/permission denied/);await assert.rejects(asPlayer(db,2,'UPDATE ct_profiles SET is_bot=true WHERE id=auth.uid()'),/permission denied/);
});
test('empty collections, zero balances and exact top-rarity pools generate valid frozen accounts',async()=>{
 const before=await economy();const empty=await create({...config,names:['EmptyBotQA'],rarity_counts:[1,0,0,0,0,0,0,0],balance_min:0,balance_max:0,games_min:0,games_max:0});const p=await rpc(2,'ct_public_profile',[empty.bots[0].id]);assert.equal(p.unique_titles,0);assert.equal(p.chests,0);assert.equal(p.games,0);assert.equal(p.bot_balance,0);
 const rare=await create({...config,names:['RareEdgeQA'],rarity_counts:[0,0,0,0,0,0,0,1],balance_min:0,balance_max:0,titles_min:1,titles_max:1,chests_min:3,chests_max:3,games_min:3,games_max:3,win_percent:100,title_pool:['ct-7-001']});const r=await rpc(2,'ct_public_profile',[rare.bots[0].id]);assert.equal(r.unique_titles,1);assert.equal(r.wins,3);assert.equal(r.bot_balance,0);assert.equal((await economy()).treasury_gross,before.treasury_gross);
 await assert.rejects(db.query("UPDATE ct_titles SET rarity=8 WHERE id='ct-7-001'"),/Cosmic/);assert.equal((await economy()).difference,0);
});
test('private projection helpers and bots configuration are not directly accessible to ordinary users',async()=>{
 await assert.rejects(rpc(2,'ct_admin_bots',['',0]),/Administrator/);await assert.rejects(rpc(2,'ct_rankings_before_bots',['credits','all']),/permission denied/);await assert.rejects(rpc(2,'ct_admin_economy_before_bots',[30,null,'']),/permission denied/);
 const b=(await rpc(1,'ct_admin_bots',['RareEdgeQA',0])).bots[0];await db.query("SELECT ct_post_credit($1,50,'bot_balance_adjustment',$2)",[b.id,randomUUID()]);await assert.rejects(rpc(1,'ct_admin_update_bot',[randomUUID(),b.id,{username:b.username,balance:20,expected_balance:0,version:b.version,active:true,hidden:false},'Modification obsolète du solde']),/modifié/);assert.equal((await economy()).difference,0);
});
