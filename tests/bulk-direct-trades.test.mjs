import {test,after} from 'node:test';import assert from 'node:assert/strict';import {randomUUID} from 'node:crypto';import {readdir,readFile} from 'node:fs/promises';import ts from 'typescript';import {createTitlesDatabase,asPlayer,uid} from './helpers/titlesDatabase.mjs';
const files=(await readdir('supabase/migrations')).filter(f=>f.endsWith('.sql')&&!f.includes('010000_titles_identity')&&!f.includes('020000_titles_economy')).sort(),db=await createTitlesDatabase(undefined,files);after(()=>db.close());
await db.exec("INSERT INTO ct_demo_cards(user_id,tier_id) SELECT id,'basic' FROM ct_profiles");
const rpc=async(n,name,args)=>(await asPlayer(db,n,`SELECT ${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) r`,args)).rows[0].r;
const act=(n,a,v,op=randomUUID())=>rpc(n,'ct_trade_command',[op,a,v]);const workspace=(n,id)=>rpc(n,'ct_trade_workspace',[id]);const offer=(n,v,op=randomUUID())=>rpc(n,'ct_trade_bulk_offer',[op,v]);
let trade,group,offerValues,offerId;
test('workspace groups 500 actual chests into one compact stack with no asset-ID array',async()=>{
 for(let i=0;i<5;i++)await db.query("SELECT ct_grant_sealed($1,1::smallint,100)",[uid(1)]);await db.query("SELECT ct_post_diamond($1,200,'admin','bulk-test')",[uid(2)]);
 trade=(await act(1,'invite',{username:'Bob'})).trade_id;await act(2,'accept',{trade_id:trade,version:1});const w=await workspace(1,trade);group=w.groups.find(g=>g.kind==='chest');assert.equal(group.available,500);assert.equal(w.groups.length,1);assert.ok(!('assets' in w));assert.ok(JSON.stringify(w).length<2500);assert.equal(w.max_items,1000);
});
test('one grouped offer reserves 500 copies, replays once and is visible to the counterparty',async()=>{
 offerValues={trade_id:trade,version:2,diamonds:0,groups:[{key:group.key,quantity:500}]};offerId=randomUUID();const result=await offer(1,offerValues,offerId);assert.equal(result.version,3);assert.deepEqual(await offer(1,offerValues,offerId),result);const other=await workspace(2,trade);assert.equal(other.offers[0].quantity,500);assert.equal((await db.query('SELECT count(*)::integer n FROM ct_direct_assets WHERE trade_id=$1',[trade])).rows[0].n,500);
 const copy=(await db.query('SELECT asset_id FROM ct_direct_assets WHERE trade_id=$1 LIMIT 1',[trade])).rows[0].asset_id;await assert.rejects(rpc(1,'ct_market_command',[randomUUID(),'open_sealed',{asset_id:copy}]),/réserv|réserve|reserved/i);
});
test('no-op autosaves preserve confirmations while edits reset both and stale confirmations fail',async()=>{
 await act(1,'confirm',{trade_id:trade,version:3});const unchanged=await offer(1,{...offerValues,version:3});assert.equal(unchanged.version,3);assert.equal((await workspace(1,trade)).a_confirmed,true);
 await offer(2,{trade_id:trade,version:3,diamonds:100,groups:[]});const changed=await workspace(1,trade);assert.equal(changed.version,4);assert.equal(changed.a_confirmed,false);assert.equal(changed.b_confirmed,false);await assert.rejects(act(1,'confirm',{trade_id:trade,version:3}),/changé/);
});
test('invalid, duplicate, foreign, fractional or excessive quantities leave reservations unchanged',async()=>{
 for(const groups of [[{key:group.key,quantity:501}],[{key:group.key,quantity:1001}],[{key:group.key,quantity:1},{key:group.key,quantity:1}],[{key:'foreign',quantity:1}],[{key:group.key,quantity:1.5}]])await assert.rejects(offer(1,{trade_id:trade,version:4,diamonds:0,groups}));
 assert.equal((await workspace(1,trade)).version,4);assert.equal((await workspace(2,trade)).offers.find(g=>g.kind==='chest').quantity,500);
});
test('both confirmations atomically deliver every chest and diamonds and create receipts once',async()=>{
 await act(1,'confirm',{trade_id:trade,version:4});const op=randomUUID(),r=await act(2,'confirm',{trade_id:trade,version:4},op);assert.deepEqual(await act(2,'confirm',{trade_id:trade,version:4},op),r);assert.ok(r.order_id);
 const result=await workspace(1,trade);assert.equal(result.status,'completed');assert.equal(result.offers.find(g=>g.kind==='chest').quantity,500);assert.equal((await db.query('SELECT count(*)::integer n FROM ct_sealed_chests WHERE user_id=$1',[uid(2)])).rows[0].n,500);assert.equal((await rpc(1,'ct_diamond_balance',[])).balance,100);assert.equal((await rpc(2,'ct_diamond_balance',[])).balance,100);assert.equal((await db.query('SELECT count(*)::integer n FROM ct_direct_assets WHERE trade_id=$1',[trade])).rows[0].n,0);assert.equal((await db.query("SELECT count(*)::integer n FROM ct_orders WHERE source_key LIKE $1",['direct:'+trade+':%'])).rows[0].n,1);
 await assert.rejects(offer(1,offerValues));assert.deepEqual(await offer(1,offerValues,offerId),{ok:true,trade_id:trade,status:'open',version:3});
});
test('private inventory helpers remain inaccessible and outsiders cannot read a workspace',async()=>{
 await assert.rejects(rpc(2,'ct_trade_inventory_rows',[uid(1),trade]),/permission denied/);await assert.rejects(db.transaction(async tx=>{await tx.exec('SET LOCAL ROLE anon');return tx.query('SELECT ct_trade_workspace($1)',[trade]);}),/permission denied/);
 const third=randomUUID();await db.query('INSERT INTO auth.users VALUES($1,now())',[third]);await db.transaction(async tx=>{await tx.exec('SET LOCAL ROLE authenticated');await tx.query("SELECT set_config('request.jwt.claim.sub',$1,true)",[third]);await assert.rejects(tx.query('SELECT ct_trade_workspace($1)',[trade]),/introuvable/);});
});
test('inventory preserves stored chest characteristics, even for reserved copies and custom pools',async()=>{
 const titleRows=(await db.query('SELECT id FROM ct_titles ORDER BY id LIMIT 2')).rows;
 const ids=(await db.query("INSERT INTO ct_sealed_chests(user_id,chest_id,name,rarity,weights,title_ids,purchase_price) VALUES($1,1,'Snapshot',5,ARRAY[10000,0,0,0,0,0,0,0],$2,123),($1,1,'Snapshot',5,ARRAY[10000,0,0,0,0,0,0,0],$3,456) RETURNING id",[uid(1),[titleRows[0].id],[titleRows[1].id]])).rows.map(r=>r.id);
 const inv=await rpc(1,'ct_sealed_inventory',[]);const a=inv.find(c=>c.id===ids[0]),b=inv.find(c=>c.id===ids[1]);assert.deepEqual(a.weights,[10000,0,0,0,0,0,0,0]);assert.equal(a.purchase_price,123);assert.equal(b.purchase_price,456);assert.equal(a.custom_pool,true);assert.equal(a.pool_size,1);assert.notEqual(a.pool_key,b.pool_key);
 const id=(await act(1,'invite',{username:'Bob'})).trade_id;await act(2,'accept',{trade_id:id,version:1});await act(1,'offer',{trade_id:id,version:2,diamonds:0,items:[{kind:'chest',id:ids[0]}]});const reserved=(await rpc(1,'ct_sealed_inventory',[])).find(c=>c.id===ids[0]);assert.equal(reserved.reserved,true);assert.deepEqual(reserved.weights,a.weights);assert.equal(reserved.pool_key,a.pool_key);await act(1,'cancel',{trade_id:id});
});
const js=ts.transpileModule(await readFile('src/lib/tradeOffer.ts','utf8'),{compilerOptions:{module:ts.ModuleKind.ESNext}}).outputText;const {setTradeQuantity,fillTrade,tradeCount,tradeSignature}=await import('data:text/javascript;base64,'+Buffer.from(js).toString('base64'));
test('quantity controls add 500 in one action, support multiple title stacks, clamp stock and cap total',()=>{
 const chest={key:'chest',available:500},title={key:'title',available:600},other={key:'other',available:4};let d=setTradeQuantity({groups:{},diamonds:0},chest,500);assert.equal(d.groups.chest,500);d=fillTrade(d,[title,other]);assert.equal(tradeCount(d),1000);assert.equal(d.groups.title,500);d=setTradeQuantity(d,chest,0);assert.ok(!d.groups.chest);d=fillTrade(d,[other]);assert.equal(d.groups.other,4);assert.equal(tradeSignature({groups:{x:1,y:2},diamonds:4}),tradeSignature({groups:{y:2,x:1,z:0},diamonds:4}));assert.equal(setTradeQuantity(d,other,-3).groups.other,undefined);
});
