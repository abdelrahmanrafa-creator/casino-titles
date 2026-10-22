import test,{after} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readdir} from 'node:fs/promises';
import {createTitlesDatabase,asPlayer,uid} from './helpers/titlesDatabase.mjs';
const migrations=(await readdir(new URL('../supabase/migrations/',import.meta.url))).filter(f=>f.endsWith('.sql')&&!f.includes('010000_titles_identity')&&!f.includes('020000_titles_economy')).sort();
const db=await createTitlesDatabase(undefined,migrations);after(()=>db.close());
const rpc=async(n,name,args=[])=>(await asPlayer(db,n,`SELECT ${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) result`,args)).rows[0].result;
const act=(n,action,values={},op=randomUUID())=>rpc(n,'ct_trade_command',[op,action,values]);
const market=(n,action,values={},op=randomUUID())=>rpc(n,'ct_market_command',[op,action,values]);
const room=(n,id)=>rpc(n,'ct_trade_room',[id]);
await db.query('INSERT INTO ct_admins(user_id) VALUES($1)',[uid(1)]);
await db.query('INSERT INTO auth.users VALUES($1,now())',[uid(3)]);await rpc(3,'ct_initialize_profile',['Charlie']);
let sealed,trade,title;
test('chest-only quests grant sealed inventory once and preserve the credit economy',async()=>{
 const op=randomUUID(),before=(await db.query('SELECT balance FROM ct_wallets WHERE user_id=$1',[uid(1)])).rows[0].balance;
 const quests=await rpc(1,'ct_my_quests');assert.ok(quests.find(q=>q.id==='sealed-welcome').reward_chest_name);
 const r=await rpc(1,'ct_claim_quest',[op,'sealed-welcome']);assert.equal(r.sealed_chests.length,1);assert.deepEqual(await rpc(1,'ct_claim_quest',[op,'sealed-welcome']),r);await assert.rejects(rpc(1,'ct_claim_quest',[randomUUID(),'sealed-welcome']));
 sealed=r.sealed_chests[0].id;assert.equal((await rpc(1,'ct_sealed_inventory')).length,1);assert.equal((await db.query('SELECT balance FROM ct_wallets WHERE user_id=$1',[uid(1)])).rows[0].balance,before);
});
test('administrator can configure chest quests and promos, with once-only atomic delivery',async()=>{
 const chest=(await rpc(1,'ct_market_snapshot',['',null])).sealed_shop[0];
 await rpc(1,'ct_admin_save_quest',[randomUUID(),{id:'chest-test',name:'Test coffre',description:'Un cadeau scellé',kind:'profile',target:1,reward:0,active:true,reward_chest_id:chest.id,reward_chest_count:2},'Validation des coffres']);
 assert.equal((await rpc(2,'ct_claim_quest',[randomUUID(),'chest-test'])).sealed_chests.length,2);
 await rpc(1,'ct_admin_save_promo',[randomUUID(),{code:'CHESTTEST',name:'Cadeau coffre',credits:0,title_id:null,active:true,starts_at:new Date(Date.now()-60000).toISOString(),ends_at:new Date(Date.now()+86400000).toISOString(),max_uses:20,reward_chest_id:chest.id,reward_chest_count:2},'Validation des coffres']);
 const op=randomUUID(),r=await rpc(2,'ct_redeem_promo',[op,'chesttest']);assert.equal(r.sealed_chests.length,2);assert.deepEqual(await rpc(2,'ct_redeem_promo',[op,'CHESTTEST']),r);await assert.rejects(rpc(2,'ct_redeem_promo',[randomUUID(),'CHESTTEST']));
 await db.query('UPDATE ct_chest_types SET active=false WHERE id=$1',[chest.id]);await assert.rejects(rpc(3,'ct_redeem_promo',[randomUUID(),'CHESTTEST']),/indisponible/);assert.equal((await db.query('SELECT count(*)::int n FROM ct_promo_claims WHERE user_id=$1',[uid(3)])).rows[0].n,0);await db.query('UPDATE ct_chest_types SET active=true WHERE id=$1',[chest.id]);
});
test('invitations are private, accepted only by the target and bounded per pair',async()=>{
 const op=randomUUID(),r=await act(1,'invite',{username:'Bob'},op);trade=r.trade_id;assert.deepEqual(await act(1,'invite',{username:'Bob'},op),r);
 await assert.rejects(act(1,'invite',{username:'Bob'}),/déjà/);await assert.rejects(act(1,'invite',{username:'Alice'}),/indisponible/);assert.equal((await rpc(3,'ct_trade_inbox')).length,0);await assert.rejects(room(3,trade),/introuvable/);await assert.rejects(act(1,'accept',{trade_id:trade,version:1}),/impossible/);await act(2,'accept',{trade_id:trade,version:1});assert.equal((await room(1,trade)).status,'open');
});
test('offered items and diamonds are reserved against opening, market sales and overspending',async()=>{
 await rpc(1,'ct_admin_diamonds',[randomUUID(),'Alice',10,'Diamants de validation']);
 await act(1,'offer',{trade_id:trade,version:2,diamonds:8,items:[{kind:'chest',id:sealed}]});
 assert.equal((await rpc(1,'ct_sealed_inventory')).find(c=>c.id===sealed).reserved,true);await assert.rejects(market(1,'open_sealed',{asset_id:sealed}),/réservé/);await assert.rejects(market(1,'list',{asset_kind:'chest',asset_id:sealed,price:1}),/réservé/);
 title=(await db.query("INSERT INTO ct_player_titles(user_id,title_id,source) VALUES($1,'ct-1-001','test') RETURNING id",[uid(2)])).rows[0].id;
 const listing=(await market(2,'list',{asset_kind:'title',asset_id:title,price:3})).listing_id;await assert.rejects(market(1,'accept',{listing_id:listing}),/réservés/);await market(2,'cancel',{listing_id:listing});
 const other=(await act(1,'invite',{username:'Charlie'})).trade_id;await act(3,'accept',{trade_id:other,version:1});await assert.rejects(act(1,'offer',{trade_id:other,version:2,diamonds:3,items:[]}),/insuffisants/);await assert.rejects(act(1,'offer',{trade_id:other,version:2,diamonds:0,items:[{kind:'chest',id:sealed}]}),/réservé/);await act(1,'cancel',{trade_id:other});
});
test('any changed offer invalidates both confirmations, stale acceptance cannot transfer',async()=>{
 await act(2,'offer',{trade_id:trade,version:3,diamonds:0,items:[{kind:'title',id:title}]});await assert.rejects(rpc(2,'ct_equip_title',[title]),/réservé/);
 await act(1,'confirm',{trade_id:trade,version:4});assert.equal((await room(2,trade)).a_confirmed,true);
 await act(2,'offer',{trade_id:trade,version:4,diamonds:0,items:[{kind:'title',id:title}]});const r=await room(1,trade);assert.equal(r.a_confirmed,false);assert.equal(r.b_confirmed,false);await assert.rejects(act(1,'confirm',{trade_id:trade,version:4}),/changé/);assert.equal((await room(1,trade)).status,'open');
});
test('two confirmations transfer both offers exactly once and retain the receipt',async()=>{
 await act(1,'confirm',{trade_id:trade,version:5});const op=randomUUID(),r=await act(2,'confirm',{trade_id:trade,version:5},op);assert.equal(r.status,'completed');assert.deepEqual(await act(2,'confirm',{trade_id:trade,version:5},op),r);await assert.rejects(act(2,'confirm',{trade_id:trade,version:5}),/terminé/);
 const finished=await room(1,trade);assert.equal(finished.items.length,2);assert.equal((await db.query('SELECT user_id FROM ct_sealed_chests WHERE id=$1',[sealed])).rows[0].user_id,uid(2));assert.ok((await rpc(1,'ct_market_snapshot',['',null])).assets.some(i=>i.definition_id==='ct-1-001'));assert.equal((await rpc(1,'ct_diamond_balance')).balance,2);assert.equal((await rpc(2,'ct_diamond_balance')).balance,8);
 assert.equal((await db.query('SELECT count(*)::int n FROM ct_direct_assets')).rows[0].n,0);assert.equal((await db.query('SELECT ((SELECT sum(balance) FROM ct_diamond_wallets)-(SELECT sum(amount) FROM ct_diamond_ledger))::bigint n')).rows[0].n,0);
});
test('expiry and cancellation release reservations; paused market still permits cancellation',async()=>{
 const id=(await act(2,'invite',{username:'Alice'})).trade_id;await act(1,'accept',{trade_id:id,version:1});await act(2,'offer',{trade_id:id,version:2,diamonds:5,items:[{kind:'chest',id:sealed}]});await db.exec('UPDATE ct_market_settings SET market_enabled=false');await assert.rejects(act(2,'confirm',{trade_id:id,version:3}),/suspendus/);await act(1,'cancel',{trade_id:id});assert.equal((await rpc(2,'ct_sealed_inventory')).find(c=>c.id===sealed).reserved,false);await db.exec('UPDATE ct_market_settings SET market_enabled=true');
 const next=(await act(1,'invite',{username:'Bob'})).trade_id;await act(2,'accept',{trade_id:next,version:1});await act(2,'offer',{trade_id:next,version:2,diamonds:0,items:[{kind:'chest',id:sealed}]});await db.query("UPDATE ct_direct_trades SET expires_at=now()-interval '1 second' WHERE id=$1",[next]);await assert.rejects(act(1,'confirm',{trade_id:next,version:3}),/expiré/);assert.equal((await rpc(2,'ct_sealed_inventory')).find(c=>c.id===sealed).reserved,false);
});
test('private trade tables and helper functions cannot be called directly by players',async()=>{
 for(const table of ['ct_direct_trades','ct_direct_assets'])await assert.rejects(asPlayer(db,1,'SELECT * FROM '+table),/permission denied/);
 await assert.rejects(rpc(1,'ct_grant_sealed',[uid(1),1,1]),/permission denied/);await assert.rejects(rpc(1,'ct_direct_diamonds',[uid(1)]),/permission denied/);
});
test('changed balances cause an atomic failure before any asset or diamond leg is transferred',async()=>{
 const id=(await act(1,'invite',{username:'Bob'})).trade_id;await act(2,'accept',{trade_id:id,version:1});await act(2,'offer',{trade_id:id,version:2,diamonds:8,items:[]});await act(1,'confirm',{trade_id:id,version:3});await rpc(1,'ct_admin_diamonds',[randomUUID(),'Bob',-8,'Test retrait avant accord']);
 await assert.rejects(act(2,'confirm',{trade_id:id,version:3}),/plus disponibles/);const failed=await room(2,id);assert.equal(failed.status,'open');assert.equal(failed.b_confirmed,false);assert.equal((await rpc(1,'ct_diamond_balance')).balance,2);
 await rpc(1,'ct_admin_diamonds',[randomUUID(),'Bob',8,'Restauration de validation']);await act(2,'confirm',{trade_id:id,version:3});assert.equal((await rpc(1,'ct_diamond_balance')).balance,10);assert.equal((await rpc(2,'ct_diamond_balance')).balance,0);
 const e=await rpc(1,'ct_admin_economy',[30,null,'']);assert.equal(e.difference,0);assert.equal(e.ledger_difference,0);
});
