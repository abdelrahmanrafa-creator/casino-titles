import {test,after} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readdir,readFile} from 'node:fs/promises';
import {createTitlesDatabase,asPlayer,uid} from './helpers/titlesDatabase.mjs';
const migrations=(await readdir(new URL('../supabase/migrations/',import.meta.url))).filter(f=>f.endsWith('.sql')&&!f.includes('010000_titles_identity')&&!f.includes('020000_titles_economy')).sort();
const db=await createTitlesDatabase(undefined,migrations);after(()=>db.close());
const rpc=async(n,name,args=[])=>(await asPlayer(db,n,`SELECT ${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) result`,args)).rows[0].result;
await db.query('INSERT INTO ct_admins(user_id) VALUES($1)',[uid(1)]);
const economy=()=>rpc(1,'ct_admin_economy',[30,null,'']);
function balanced(e){assert.equal(e.difference,0);assert.equal(e.ledger_difference,0);assert.equal(e.unmirrored,0);assert.equal(e.total,100000000);assert.equal(e.treasury_available+e.reserved_tables+e.player_balances,e.initial_capital);}
test('welcome grants are countered by treasury and every credit is accounted for',async()=>{
 const e=await economy();balanced(e);assert.equal(e.treasury_gross,99990000);assert.equal(e.player_balances,10000);assert.equal(e.entries.filter(x=>x.reason==='welcome').length,2);assert.ok(e.entries.every(x=>x.amount===-5000));
 await db.query('INSERT INTO auth.users VALUES($1,now())',[uid(3)]);await rpc(3,'ct_initialize_profile',['Charlie']);const after=await economy();balanced(after);assert.equal(after.treasury_gross,e.treasury_gross-5000);assert.equal(after.player_balances,15000);
 await rpc(3,'ct_initialize_profile',['Charlie']);assert.equal((await economy()).treasury_gross,after.treasury_gross);
});
test('daily, chest purchase, upgrade and clicker transfer opposite amounts exactly once',async()=>{
 let before=await economy();const op=randomUUID(),claim=await rpc(2,'ct_claim_daily',[op]);let next=await economy();assert.equal(next.treasury_gross,before.treasury_gross-750);balanced(next);await rpc(2,'ct_claim_daily',[op]);assert.equal((await economy()).entries.length,next.entries.length);
 const chest=(await rpc(2,'ct_shop_chests')).find(x=>x.id===1);before=await economy();await rpc(2,'ct_open_chest',[randomUUID(),1,chest.version,chest.current_price,chest.offer_id]);next=await economy();assert.equal(next.treasury_gross,before.treasury_gross+chest.current_price);balanced(next);
 before=next;await rpc(2,'ct_clicker_action',[randomUUID(),'upgrade',0,0]);await rpc(2,'ct_clicker_action',[randomUUID(),'click',10,1]);next=await economy();assert.equal(next.treasury_gross,before.treasury_gross+100-20);balanced(next);
 const expensive=(await rpc(3,'ct_shop_chests')).find(x=>x.id===8),entries=next.entries.length;await assert.rejects(rpc(3,'ct_open_chest',[randomUUID(),8,expensive.version,expensive.current_price,expensive.offer_id]),/Insufficient/);assert.equal((await economy()).entries.length,entries);
});
test('table entries remain reserved liabilities rather than available house money',async()=>{
 const op=randomUUID(),state={phase:'waiting',host:uid(2),seats:[{id:uid(2),stack:500,committed:0}]},before=await economy();
 const created=(await db.query('SELECT ct_create_room($1,$2,$3,$4,$5,$6,$7,$8) result',[uid(2),op,{kind:'treasury-table'},'poker','TREASURYQA',true,500,state])).rows[0].result;
 let next=await economy();balanced(next);assert.equal(next.reserved_tables,500);assert.equal(next.treasury_gross,before.treasury_gross+500);assert.equal(next.treasury_available,before.treasury_available);
 await db.query('SELECT ct_commit_room($1,$2,$3,$4,$5,$6,$7)',[uid(2),randomUUID(),{kind:'treasury-refund'},created.room_id,created.version,{...state,seats:[],phase:'finished'},'leave']);next=await economy();balanced(next);assert.equal(next.reserved_tables,0);assert.equal(next.treasury_available,before.treasury_available);
});
test('a failed treasury counter-entry rolls back the wallet and its ledger in the same transaction',async()=>{
 const before=await economy();await db.exec("ALTER TABLE ct_treasury_entries ADD CONSTRAINT qa_reject_counter_entry CHECK(reason<>'qa_rejected_counter_entry')");
 try{await assert.rejects(db.query("SELECT ct_post_credit($1,50,'qa_rejected_counter_entry',$2)",[uid(2),randomUUID()]),/qa_reject_counter_entry/);const after=await economy();assert.equal(after.player_balances,before.player_balances);assert.equal(after.treasury_gross,before.treasury_gross);assert.equal(after.entries.length,before.entries.length);balanced(after);}finally{await db.exec('ALTER TABLE ct_treasury_entries DROP CONSTRAINT qa_reject_counter_entry');}
});
test('hiding a ranking applies to every metric and period, preserves profile and other preferences',async()=>{
 await rpc(2,'ct_save_preferences',[true]);await rpc(2,'ct_set_leaderboard_visibility',[true]);
 for(const metric of ['credits','wins','titles','chests','cosmic'])for(const period of ['all','week']){const rows=await rpc(1,'ct_rankings',[metric,period]);assert.ok(!rows.some(x=>x.id===uid(2)));assert.ok(rows.some(x=>x.id===uid(1)));}
 assert.equal((await rpc(1,'ct_public_profile',[uid(2)])).username,'Bob');assert.ok((await rpc(1,'ct_find_players',['Bob'])).some(x=>x.id===uid(2)));
 await rpc(2,'ct_save_preferences',[false]);assert.equal((await asPlayer(db,2,'SELECT * FROM ct_preferences')).rows[0].leaderboard_hidden,true);
 await rpc(2,'ct_set_leaderboard_visibility',[false]);assert.ok((await rpc(1,'ct_rankings',['credits','all'])).some(x=>x.id===uid(2)));balanced(await economy());
});
test('treasury is admin-only; reason filters and keyset pagination keep distinct rows',async()=>{
 await assert.rejects(rpc(2,'ct_admin_economy',[30,null,'']),/Administrator/);await assert.rejects(asPlayer(db,2,'SELECT * FROM ct_treasury_entries'),/permission denied/);await assert.rejects(asPlayer(db,2,"INSERT INTO ct_treasury_entries(user_id,amount,reason) VALUES(auth.uid(),999,'fraud')"),/permission denied/);
 await assert.rejects(asPlayer(db,2,'UPDATE ct_preferences SET leaderboard_hidden=true'),/permission denied/);
 const rows=(await rpc(1,'ct_admin_economy',[7,null,'welcome'])).entries;assert.ok(rows.length>=3);assert.ok(rows.every(e=>e.reason==='welcome'));const before=rows[0].id;const older=(await rpc(1,'ct_admin_economy',[7,before,'welcome'])).entries;assert.ok(older.every(e=>e.id<before));
});
test('payouts can make treasury negative without blocking settlement; conservation still holds',async()=>{
 await db.query("SELECT ct_post_credit($1,200000000,'payout','treasury-large-test')",[uid(1)]);const e=await economy();balanced(e);assert.ok(e.treasury_available<0);assert.equal(e.groups.find(x=>x.reason==='payout').distributed,200000000);
});
test('deleting an unused account returns its remaining balance and retains treasury history',async()=>{
 const before=await economy(),balance=(await db.query('SELECT balance FROM ct_wallets WHERE user_id=$1',[uid(3)])).rows[0].balance;
 await db.query('DELETE FROM auth.users WHERE id=$1',[uid(3)]);const after=await economy();balanced(after);assert.equal(after.treasury_gross,before.treasury_gross+balance);assert.ok(after.entries.some(e=>e.reason==='account_closed'&&e.amount===balance));assert.ok(after.entries.some(e=>e.reason==='welcome'&&e.user_id===uid(3)&&e.wallet_transaction_id===null));
});
test('installing treasury over existing history backfills once without changing player balances',async()=>{
 const legacy=await createTitlesDatabase(undefined,migrations.filter(f=>f<'20261022190000_treasury_privacy.sql'));try{
 await legacy.exec(await readFile(new URL('../supabase/migrations/20261022190000_treasury_privacy.sql',import.meta.url),'utf8'));await legacy.query('INSERT INTO ct_admins(user_id) VALUES($1)',[uid(1)]);
 const e=(await asPlayer(legacy,1,'SELECT ct_admin_economy() result')).rows[0].result;balanced(e);assert.equal(e.player_balances,10000);assert.equal(e.entries.length,2);assert.equal(e.treasury_gross,99990000);
 }finally{await legacy.close();}
});

