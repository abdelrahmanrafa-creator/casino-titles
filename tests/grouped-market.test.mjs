import {test,after} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readdir} from 'node:fs/promises';
import {createTitlesDatabase,asPlayer,uid} from './helpers/titlesDatabase.mjs';
const files=(await readdir(new URL('../supabase/migrations/',import.meta.url))).filter(f=>f.endsWith('.sql')&&!f.includes('010000_titles_identity')&&!f.includes('020000_titles_economy')).sort();
const db=await createTitlesDatabase(undefined,files);after(()=>db.close());
const rpc=async(n,name,args=[])=>(await asPlayer(db,n,`SELECT ${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) result`,args)).rows[0].result;
await db.exec("INSERT INTO ct_demo_cards(user_id,tier_id) SELECT id,'basic' FROM ct_profiles");
let assets,chest,group;
test('promotions and quantity savings stack sequentially with exact rounding and ledger allocation',async()=>{
 chest=(await rpc(2,'ct_shop_chests'))[0];await db.query('UPDATE ct_chest_types SET price=12000 WHERE id=$1',[chest.id]);
 const offer=(await db.query("INSERT INTO ct_chest_offers(chest_id,name,sale_price,starts_at,ends_at) VALUES($1,'Promotion dix pour cent',10800,now()-interval '1 minute',now()+interval '1 day') RETURNING id",[chest.id])).rows[0].id;
 const quote=await rpc(2,'ct_bulk_chest_quote',[chest.id,50]);assert.equal(quote.base_total,600000);assert.equal(quote.gross_total,540000);assert.equal(quote.total,523800);assert.equal(quote.discount_percent,3);
 await db.query("SELECT ct_post_credit($1,2000000,'admin_adjustment','group-funding')",[uid(2)]);
 const op=randomUUID(),args=[op,50,chest.id,quote.version,quote.unit_price,offer,quote.total];const result=await rpc(2,'ct_buy_chests',args);assert.deepEqual(await rpc(2,'ct_buy_chests',args),result);
 const paid=(await db.query('SELECT sum(purchase_price) total FROM ct_sealed_chests WHERE user_id=$1',[uid(2)])).rows[0].total;assert.equal(Number(paid),523800);
 await db.query('UPDATE ct_chest_offers SET active=false WHERE id=$1',[offer]);await db.query('UPDATE ct_chest_types SET price=500 WHERE id=$1',[chest.id]);chest=(await rpc(2,'ct_shop_chests')).find(c=>c.id===chest.id);
 const q=await rpc(2,'ct_bulk_chest_quote',[chest.id,100]);const buy=await rpc(2,'ct_buy_chests',[randomUUID(),100,chest.id,q.version,q.unit_price,null,q.total]);assets=[...result.sealed_ids,...buy.sealed_ids];
});
test('108 ordinary offers collapse into one seller/chest/price group beyond the old 50-listing page',async()=>{
 // Direct fixtures represent already-published matching listings without consuming per-action rate limits.
 await db.query("INSERT INTO ct_market_listings(seller_id,asset_kind,asset_id,name,rarity,definition_id,price) SELECT user_id,'chest',id,name,rarity,chest_id::text,80 FROM ct_sealed_chests WHERE id=ANY($1::uuid[])",[assets.slice(0,108)]);
 const groups=await rpc(1,'ct_market_chest_groups');assert.equal(groups.length,1);group=groups[0];assert.equal(group.stock,108);assert.equal(group.base_price,80);assert.equal(group.seller,'Bob');
 const q=await rpc(1,'ct_market_chest_group_quote',[group.group_key,100]);assert.equal(q.total,8000);assert.equal(q.parts.length,1);
 await db.query("SELECT ct_post_diamond($1,30000,'admin_adjustment','group-diamonds')",[uid(1)]);
 await assert.rejects(rpc(1,'ct_buy_market_chest_group',[randomUUID(),group.group_key,100,q.total-1,q.token]),/prix modifié/);
 assert.equal((await rpc(1,'ct_market_chest_groups'))[0].stock,108);
 const op=randomUUID(),args=[op,group.group_key,100,q.total,q.token];const bought=await rpc(1,'ct_buy_market_chest_group',args);assert.equal(bought.quantity,100);assert.deepEqual(await rpc(1,'ct_buy_market_chest_group',args),bought);
 assert.equal((await rpc(1,'ct_market_chest_groups'))[0].stock,8);assert.equal((await rpc(1,'ct_diamond_balance')).balance,22000);assert.equal((await rpc(2,'ct_diamond_balance')).balance,8000);
 assert.equal((await rpc(1,'ct_sealed_inventory')).length,100);assert.equal((await db.query('SELECT count(*) n FROM ct_market_trades')).rows[0].n,100);
});
test('ordinary and discounted stocks share one card, preserve seller tiers and transfer a mixed quantity atomically',async()=>{
 const created=await rpc(2,'ct_wholesale_command',[randomUUID(),'create',{asset_ids:assets.slice(108,128),price:80,tiers:[{min:10,price:75},{min:20,price:65}]}]);
 const groups=await rpc(1,'ct_market_chest_groups');assert.equal(groups.length,1);assert.equal(groups[0].stock,28);assert.equal(groups[0].has_tiers,true);
 const q=await rpc(1,'ct_market_chest_group_quote',[group.group_key,25]);assert.equal(q.total,20*65+5*80);assert.equal(q.parts.length,2);
 await assert.rejects(rpc(1,'ct_buy_market_chest_group',[randomUUID(),group.group_key,25,q.total,'wrong']),/prix modifié/);
 const op=randomUUID(),args=[op,group.group_key,25,q.total,q.token];await rpc(1,'ct_buy_market_chest_group',args);
 assert.equal((await rpc(1,'ct_market_chest_groups'))[0].stock,3);assert.equal((await rpc(1,'ct_sealed_inventory')).length,125);
 assert.equal((await db.query('SELECT remaining FROM ct_wholesale_offers WHERE id=$1',[created.id])).rows[0].remaining,0);
 await assert.rejects(rpc(1,'ct_buy_market_chest_group',[randomUUID(),group.group_key,25,q.total,q.token]),/Stock insuffisant/);
});
test('changed stock invalidates old quote; paused markets, suspension, access and balances are enforced',async()=>{
 const q=await rpc(1,'ct_market_chest_group_quote',[group.group_key,1]);await db.exec("UPDATE ct_market_listings SET status='cancelled' WHERE id=(SELECT min(id) FROM ct_market_listings WHERE status='active')");
 await assert.rejects(rpc(1,'ct_buy_market_chest_group',[randomUUID(),group.group_key,1,q.total,q.token]),/prix modifié/);
 const fresh=await rpc(1,'ct_market_chest_group_quote',[group.group_key,2]);await db.exec('UPDATE ct_market_settings SET wallets_frozen=true WHERE id');await assert.rejects(rpc(1,'ct_buy_market_chest_group',[randomUUID(),group.group_key,2,fresh.total,fresh.token]),/figé/);await db.exec('UPDATE ct_market_settings SET wallets_frozen=false WHERE id');
 await db.query('DELETE FROM ct_demo_cards WHERE user_id=$1',[uid(1)]);await assert.rejects(rpc(1,'ct_market_chest_groups'),/Carte active/);await db.query("INSERT INTO ct_demo_cards(user_id,tier_id) VALUES($1,'basic')",[uid(1)]);
 await db.query("UPDATE ct_diamond_wallets SET balance=0 WHERE user_id=$1",[uid(1)]);await assert.rejects(rpc(1,'ct_buy_market_chest_group',[randomUUID(),group.group_key,2,fresh.total,fresh.token]),/insuffisants/);assert.equal((await rpc(1,'ct_market_chest_groups'))[0].stock,2);
 await assert.rejects(rpc(2,'ct_buy_market_chest_group',[randomUUID(),group.group_key,2,fresh.total,fresh.token]),/propre stock/);
 await assert.rejects(asPlayer(db,1,'SELECT * FROM ct_market_chest_sources()'),/permission denied/);
});
test('barters, private offers and differing prices remain separate and cannot be bought through a grouped public quote',async()=>{
 await db.query("INSERT INTO ct_market_listings(seller_id,asset_kind,asset_id,name,rarity,definition_id,price,target_id) SELECT user_id,'chest',id,name,rarity,chest_id::text,80,$2 FROM ct_sealed_chests WHERE id=$1",[assets[128],uid(1)]);
 await db.query("INSERT INTO ct_market_listings(seller_id,asset_kind,asset_id,name,rarity,definition_id,price,wanted_kind,wanted_id) SELECT user_id,'chest',id,name,rarity,chest_id::text,80,'chest',chest_id::text FROM ct_sealed_chests WHERE id=$1",[assets[129]]);
 await db.query("INSERT INTO ct_market_listings(seller_id,asset_kind,asset_id,name,rarity,definition_id,price) SELECT user_id,'chest',id,name,rarity,chest_id::text,81 FROM ct_sealed_chests WHERE id=$1",[assets[130]]);
 const groups=await rpc(1,'ct_market_chest_groups');assert.equal(groups.length,2);assert.equal(groups.find(g=>g.base_price===80).stock,2);assert.equal(groups.find(g=>g.base_price===81).stock,1);
 assert.equal((await rpc(1,'ct_market_chest_groups',['Bob'])).length,2);assert.equal((await rpc(1,'ct_market_chest_groups',['Nobody'])).length,0);
});
