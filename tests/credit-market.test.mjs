import {test,after} from 'node:test';import assert from 'node:assert/strict';import {randomUUID} from 'node:crypto';import {readdir} from 'node:fs/promises';import {createTitlesDatabase,asPlayer,uid} from './helpers/titlesDatabase.mjs';
const files=(await readdir(new URL('../supabase/migrations/',import.meta.url))).filter(f=>f.endsWith('.sql')&&!f.includes('010000_titles_identity')&&!f.includes('020000_titles_economy')).sort();const db=await createTitlesDatabase(undefined,files);after(()=>db.close());
const rpc=async(n,name,args=[])=>(await asPlayer(db,n,`SELECT ${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) r`,args)).rows[0].r;
const act=(n,action,values,op=randomUUID())=>rpc(n,'ct_credit_market_command',[op,action,values]);
const balance=async(n)=>(await db.query('SELECT balance FROM ct_wallets WHERE user_id=$1',[uid(n)])).rows[0].balance;
const diamonds=async(n)=>(await db.query('SELECT balance FROM ct_diamond_wallets WHERE user_id=$1',[uid(n)])).rows[0]?.balance??0;
await db.exec("INSERT INTO ct_demo_cards(user_id,tier_id) SELECT id,'basic' FROM ct_profiles; SELECT ct_post_diamond('"+uid(2)+"',1000,'admin_adjustment','credit-test-seed')");

test('listing reserves spendable credits; purchase transfers both currencies exactly once and preserves treasury capital',async()=>{
 const before=await balance(1),buyer=await balance(2),op=randomUUID();const offer=await act(1,'create',{amount:1200,price:17},op);assert.equal(await balance(1),before-1200);assert.deepEqual(await act(1,'create',{amount:1200,price:17},op),offer);assert.equal((await rpc(2,'ct_credit_market',['browse'])).offers.length,1);
 await assert.rejects(act(1,'buy',{id:offer.id,amount:1200,price:17}),/indisponible/);await assert.rejects(act(2,'buy',{id:offer.id,amount:1200,price:18}),/modifiée/);const buyOp=randomUUID(),b=await act(2,'buy',{id:offer.id,amount:1200,price:17},buyOp);assert.deepEqual(await act(2,'buy',{id:offer.id,amount:1200,price:17},buyOp),b);assert.equal(await balance(2),buyer+1200);assert.equal(await diamonds(1),17);assert.equal(await diamonds(2),983);await assert.rejects(act(2,'buy',{id:offer.id,amount:1200,price:17}),/indisponible/);await assert.rejects(act(1,'cancel',{id:offer.id}),/déjà conclue/);assert.equal((await rpc(2,'ct_credit_market',['history'])).offers[0].id,offer.id);
 const conservation=(await db.query('SELECT (SELECT initial_capital FROM ct_treasury)+(SELECT sum(amount) FROM ct_treasury_entries)+(SELECT sum(balance) FROM ct_wallets)-(SELECT initial_capital FROM ct_treasury) difference')).rows[0];assert.equal(Number(conservation.difference),0);
});
test('invalid values, insufficient credits and insufficient diamonds never lose funds or create an offer',async()=>{
 for(const v of [{amount:0,price:2},{amount:5,price:0},{amount:-1,price:1},{amount:1000000001,price:2},{amount:1,price:1000000001},{amount:null,price:2}])await assert.rejects(act(1,'create',v),/Choisissez/);
 await assert.rejects(act(1,'create',{amount:999999,price:1}),/Insufficient credits/);const offer=await act(1,'create',{amount:100,price:99999});const before=await balance(2);await assert.rejects(act(2,'buy',{id:offer.id,amount:100,price:99999}),/insuffisants/);assert.equal(await balance(2),before);assert.equal((await db.query('SELECT status FROM ct_credit_offers WHERE id=$1',[offer.id])).rows[0].status,'active');await act(1,'cancel',{id:offer.id});
});
test('cancellation refunds once even without a card or during a market freeze, including expired offers',async()=>{
 const before=await balance(1),o=await act(1,'create',{amount:300,price:5});await db.exec("UPDATE ct_market_settings SET wallets_frozen=true; UPDATE ct_demo_cards SET suspended=true WHERE user_id='"+uid(1)+"'; UPDATE ct_credit_offers SET expires_at=now()-interval '1 day' WHERE id="+o.id);
 await act(1,'cancel',{id:o.id});await act(1,'cancel',{id:o.id});assert.equal(await balance(1),before);await db.exec('UPDATE ct_market_settings SET wallets_frozen=false; UPDATE ct_demo_cards SET suspended=false');
});
test('private recipients, active cards, expiry and market freeze are enforced server-side',async()=>{
 await assert.rejects(act(1,'create',{amount:1,price:1,target_username:'missing'}),/Destinataire/);await assert.rejects(act(1,'create',{amount:1,price:1,target_username:'Alice'}),/Destinataire/);const o=await act(1,'create',{amount:100,price:2,target_username:'Bob'});const visible=await rpc(2,'ct_credit_market',['browse']);assert.ok(visible.offers.some(x=>x.id===o.id&&x.target==='Bob'));
 await db.exec('UPDATE ct_market_settings SET market_enabled=false');await assert.rejects(act(2,'buy',{id:o.id,amount:100,price:2}),/suspendu/);await db.exec('UPDATE ct_market_settings SET market_enabled=true');await db.exec("UPDATE ct_demo_cards SET suspended=true WHERE user_id='"+uid(1)+"'");await assert.rejects(act(2,'buy',{id:o.id,amount:100,price:2}),/indisponible/);await db.exec('UPDATE ct_demo_cards SET suspended=false');await db.query("UPDATE ct_credit_offers SET expires_at=now()-interval '1 day' WHERE id=$1",[o.id]);await assert.rejects(act(2,'buy',{id:o.id,amount:100,price:2}),/indisponible/);await act(1,'cancel',{id:o.id});
});
test('reserved credits remain refundable at the wallet cap and admin removal is audited with balanced escrow accounting',async()=>{
 await db.exec("INSERT INTO ct_admins(user_id) VALUES('"+uid(2)+"') ON CONFLICT DO NOTHING");const before=await balance(1),o=await act(1,'create',{amount:200,price:2});const economy=await rpc(2,'ct_admin_economy');assert.equal(economy.reserved_credit_market,200);assert.equal(economy.treasury_available+economy.reserved_tables+economy.reserved_credit_market+economy.player_balances,economy.initial_capital);assert.equal(economy.difference,0);assert.equal(economy.unmirrored,0);
 await assert.rejects(db.query('UPDATE ct_wallets SET balance=9000000000000 WHERE user_id=$1',[uid(1)]),/réservés compris/);await assert.rejects(act(2,'cancel',{id:o.id}),/Justification/);await act(2,'cancel',{id:o.id,reason:'Retrait de test justifié'});assert.equal(await balance(1),before);assert.equal((await db.query("SELECT count(*) n FROM ct_admin_audit_logs WHERE action='credit_market_cancel'")).rows[0].n,1);
});
test('two competing buyers cannot settle the same offer twice; payload reuse cannot alter a sale',async()=>{
 const o=await act(1,'create',{amount:20,price:1});const op=randomUUID();const results=await Promise.allSettled([act(2,'buy',{id:o.id,amount:20,price:1},op),act(2,'buy',{id:o.id,amount:20,price:1})]);assert.equal(results.filter(x=>x.status==='fulfilled').length,1);await assert.rejects(act(2,'buy',{id:o.id,amount:20,price:2},op),/reused/);
});
test('anonymous callers and direct table access are denied; nonadmins cannot inspect all offers',async()=>{
 await assert.rejects(db.transaction(async tx=>{await tx.exec('SET LOCAL ROLE anon');return tx.query('SELECT ct_credit_market()');}),/permission denied/);await assert.rejects(asPlayer(db,1,'SELECT * FROM ct_credit_offers'),/permission denied/);await assert.rejects(rpc(1,'ct_credit_market',['admin']),/Administrator required/);
});

