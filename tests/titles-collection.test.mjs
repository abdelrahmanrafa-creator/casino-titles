import {test,after} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {createTitlesDatabase,asPlayer,uid} from './helpers/titlesDatabase.mjs';
const db=await createTitlesDatabase(undefined,['20261022030000_titles_collection.sql','20261022031000_titles_catalog.sql','20261022040000_titles_chests.sql']);
after(()=>db.close());
const open=(id=randomUUID(),chest=1)=>asPlayer(db,1,'SELECT ct_open_chest($1,$2::smallint) result',[id,chest]);
test('catalog has exactly 320 unique names in the eight required counts',async()=>{
 const rows=(await db.query('SELECT rarity,count(*)::int n FROM ct_titles GROUP BY rarity ORDER BY rarity')).rows;
 assert.deepEqual(rows.map(r=>r.n),[70,60,50,45,35,25,20,15]);
 assert.equal((await db.query('SELECT count(DISTINCT name)::int n FROM ct_titles')).rows[0].n,320);
});
test('all eight weight tables total 100%; every possible roll has exact announced frequency',async()=>{
 const rows=(await db.query('SELECT * FROM ct_chest_types ORDER BY id')).rows;
 for(const row of rows){
  assert.equal(row.weights.reduce((a,b)=>a+b),10000);
  const counts=(await db.query('SELECT ct_rarity_for_roll($1,n) rarity,count(*)::int n FROM generate_series(0,9999) n GROUP BY 1 ORDER BY 1',[row.weights])).rows;
  const observed=Array(8).fill(0);for(const c of counts)observed[c.rarity-1]=c.n;
  assert.deepEqual(observed,row.weights);
 }
 await assert.rejects(db.query("UPDATE ct_chest_types SET weights=ARRAY[9999,0,0,0,0,0,0,0] WHERE id=1"),/check constraint/);
});
test('chest debit, inventory, receipt and history are committed exactly once',async()=>{
 const id=randomUUID(),first=(await open(id)).rows[0].result;
 assert.equal(first.balance,4500);assert.ok(first.title.id);assert.ok(first.player_title_id);
 assert.deepEqual((await open(id)).rows[0].result,first);
 assert.equal((await db.query('SELECT count(*)::int n FROM ct_player_titles')).rows[0].n,1);
 assert.equal((await db.query('SELECT count(*)::int n FROM ct_chest_openings')).rows[0].n,1);
 await assert.rejects(open(id,2),/different payload/);
});
test('failed purchase cannot debit wallet, leave inventory or store receipt',async()=>{
 const before=(await db.query('SELECT balance FROM ct_wallets WHERE user_id=$1',[uid(1)])).rows[0].balance;
 const id=randomUUID();await assert.rejects(open(id,8),/Insufficient/);
 assert.equal((await db.query('SELECT balance FROM ct_wallets WHERE user_id=$1',[uid(1)])).rows[0].balance,before);
 assert.equal((await db.query('SELECT * FROM ct_operations WHERE operation_id=$1',[id])).rows.length,0);
 await db.exec('UPDATE ct_titles SET available=false');
 await assert.rejects(open(),/No title/);
 await db.exec('UPDATE ct_titles SET available=true');
 assert.equal((await db.query('SELECT balance FROM ct_wallets WHERE user_id=$1',[uid(1)])).rows[0].balance,before);
});
test('racing purchase requests cannot spend more than the balance; duplicates remain inventory instances',async()=>{
 const results=await Promise.allSettled(Array.from({length:12},()=>open()));
 assert.equal(results.filter(r=>r.status==='fulfilled').length,9);
 assert.equal((await db.query('SELECT balance FROM ct_wallets WHERE user_id=$1',[uid(1)])).rows[0].balance,0);
 assert.equal((await db.query('SELECT count(*)::int n FROM ct_player_titles')).rows[0].n,10);
 assert.equal((await db.query('SELECT count(DISTINCT id)::int n FROM ct_player_titles')).rows[0].n,10);
});
test('equipping requires owned instance; only one equipped; public profile hides private data',async()=>{
 const id=(await db.query('SELECT id FROM ct_player_titles LIMIT 1')).rows[0].id;
 await assert.rejects(asPlayer(db,2,'SELECT ct_equip_title($1)',[id]),/not owned/);
 await asPlayer(db,1,'SELECT ct_equip_title($1)',[id]);
 const profile=(await asPlayer(db,2,'SELECT ct_public_profile($1) result',[uid(1)])).rows[0].result;
 assert.ok(profile.equipped_title.name);assert.equal(profile.balance,undefined);assert.equal(profile.email,undefined);
 await asPlayer(db,1,'SELECT ct_equip_title(NULL)');
 assert.equal((await db.query('SELECT * FROM ct_equipped_titles')).rows.length,0);
});
test('title shop uses server price, replays safely and prevents second purchase with new ID',async()=>{
 const id=randomUUID();const buy=op=>asPlayer(db,2,'SELECT ct_buy_title($1,$2) result',[op,'ct-1-001']);
 const first=(await buy(id)).rows[0].result;assert.equal(first.balance,3800);
 assert.deepEqual((await buy(id)).rows[0].result,first);
 await assert.rejects(buy(randomUUID()),/already purchased/);
 assert.equal((await asPlayer(db,2,'SELECT * FROM ct_player_titles')).rows.length,1);
});
test('random samples converge and stay inside the requested range',async()=>{
 const counts=(await db.query('SELECT ct_random_below(8) bucket,count(*)::int n FROM generate_series(1,40000) GROUP BY 1')).rows;
 assert.equal(counts.length,8);for(const c of counts){assert.ok(c.bucket>=0&&c.bucket<8);assert.ok(Math.abs(c.n-5000)<450,JSON.stringify(c));}
});
