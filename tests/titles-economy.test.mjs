import {test,after} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {PGlite} from '@electric-sql/pglite';
import {createTitlesDatabase,asPlayer,uid} from './helpers/titlesDatabase.mjs';
const folder=await mkdtemp(join(tmpdir(),'titles-economy-'));
let db=await createTitlesDatabase(folder);
after(async()=>{await db.close();await rm(folder,{recursive:true,force:true});});
const claim=(id=randomUUID())=>asPlayer(db,1,'SELECT ct_claim_daily($1) result',[id]);
const snapshot=async n=>(await asPlayer(db,n,'SELECT ct_economy_snapshot() result')).rows[0].result;
test('daily is persisted once across retries and new operation IDs',async()=>{
 const id=randomUUID(),first=(await claim(id)).rows[0].result;
 assert.equal(first.amount,750);
 assert.deepEqual((await claim(id)).rows[0].result,first);
 assert.equal((await claim()).rows[0].result.already_claimed,true);
 const state=await snapshot(1);
 assert.equal(state.wallet.balance,5750);assert.equal(state.wallet.version,1);
 assert.equal(state.transactions.length,2);assert.equal(state.transactions[0].balance_after,5750);
 assert.equal(state.daily_claimed,true);
 assert.equal((await snapshot(2)).wallet.balance,5000);
});
test('burst of claims cannot duplicate rewards',async()=>{
 const results=await Promise.all(Array.from({length:8},()=>claim()));
 assert.equal(results.length,8);
 assert.equal((await snapshot(1)).wallet.balance,5750);
 assert.equal((await db.query('SELECT count(*)::int n FROM ct_daily_rewards')).rows[0].n,1);
});
test('client cannot mint, debit, overwrite journal, or call private helpers',async()=>{
 for(const sql of ["SELECT ct_post_credit(auth.uid(),100000,'hack','x')",'SELECT ct_lock_wallet()',
  'DELETE FROM ct_wallet_transactions','UPDATE ct_wallets SET balance=1','INSERT INTO ct_operations SELECT * FROM ct_operations',
  "SELECT ct_check_rate(auth.uid())","SELECT ct_replay(auth.uid(),gen_random_uuid(),'{}')"])
  await assert.rejects(asPlayer(db,1,sql),/permission denied/);
 assert.equal((await asPlayer(db,2,'SELECT * FROM ct_wallet_transactions')).rows.length,1);
});
test('internal journal failure rolls back wallet; negative balances and overflow fail',async()=>{
 const before=(await snapshot(1)).wallet;
 await assert.rejects(db.transaction(async tx=>{
  await tx.query('SELECT 1 FROM ct_wallets WHERE user_id=$1 FOR UPDATE',[uid(1)]);
  await tx.query("SELECT ct_post_credit($1,-100,'test','welcome:v1')",[uid(1)]);
 }),/unique/);
 assert.deepEqual((await snapshot(1)).wallet,before);
 await assert.rejects(db.query("SELECT ct_post_credit($1,-100000,'test','overdraw')",[uid(1)]),/Insufficient/);
 await assert.rejects(db.query("SELECT ct_post_credit($1,9000000000000,'test','overflow')",[uid(1)]),/Insufficient/);
});
test('operation payload mismatch and null operation IDs fail',async()=>{
 const id=randomUUID();await claim(id);
 await assert.rejects(db.query('SELECT ct_replay($1,$2,$3)',[uid(1),id,{kind:'other'}]),/different payload/);
 await assert.rejects(asPlayer(db,1,'SELECT ct_claim_daily(NULL)'),/Operation ID required/);
});
test('successful operation rate limit is enforced, replay remains available',async()=>{
 const id=randomUUID();await claim(id);
 await db.query('UPDATE ct_request_limits SET requests=30 WHERE user_id=$1',[uid(1)]);
 await assert.rejects(claim(),/Too many operations/);
 assert.equal((await claim(id)).rows[0].result.already_claimed,true);
});
test('committed balance and receipts survive database close/reopen',async()=>{
 const before=await snapshot(1);await db.close();db=new PGlite(folder);
 assert.deepEqual(await snapshot(1).then(({server_time,next_daily_at,...rest})=>rest),
 (({server_time,next_daily_at,...rest})=>rest)(before));
});
test('a physical local backup restores balances, idempotency receipts and role policies',async()=>{
 const before=await snapshot(1),archive=await db.dumpDataDir();
 const restored=new PGlite({loadDataDir:archive});
 try{
  const state=(await asPlayer(restored,1,'SELECT ct_economy_snapshot() result')).rows[0].result;
  assert.deepEqual(state.wallet,before.wallet);assert.deepEqual(state.transactions,before.transactions);
  await assert.rejects(asPlayer(restored,1,'UPDATE ct_wallets SET balance=9000'),/permission denied/);
  assert.equal((await restored.query('SELECT count(*)::int n FROM ct_operations')).rows[0].n,(await db.query('SELECT count(*)::int n FROM ct_operations')).rows[0].n);
 }finally{await restored.close();}
});
