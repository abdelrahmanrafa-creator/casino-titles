import {test,after} from 'node:test';
import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';
import ts from 'typescript';
import {QueryClient,QueryObserver} from '@tanstack/react-query';
import {createTitlesDatabase,asPlayer,uid} from './helpers/titlesDatabase.mjs';
const migration='20261030013517_live_data_sync.sql';
const files=(await readdir('supabase/migrations')).filter(f=>f.endsWith('.sql')&&!f.includes('010000_titles_identity')&&!f.includes('020000_titles_economy')&&f!==migration).sort();
const db=await createTitlesDatabase(undefined,files);after(()=>db.close());
await db.exec(`CREATE SCHEMA realtime;
 CREATE TABLE realtime.messages(id bigint GENERATED ALWAYS AS IDENTITY,payload jsonb,event text,topic text,private boolean,extension text DEFAULT 'broadcast');
 ALTER TABLE realtime.messages ENABLE ROW LEVEL SECURITY;
 CREATE FUNCTION realtime.topic() RETURNS text LANGUAGE sql STABLE AS $$SELECT current_setting('test.topic',true)$$;
 CREATE FUNCTION realtime.send(jsonb,text,text,boolean) RETURNS void LANGUAGE sql AS $$INSERT INTO realtime.messages(payload,event,topic,private) VALUES($1||jsonb_build_object('id',gen_random_uuid()),$2,$3,$4)$$;
 GRANT USAGE ON SCHEMA realtime TO authenticated; GRANT SELECT ON realtime.messages TO authenticated;`);
await db.exec(await readFile('supabase/migrations/'+migration,'utf8'));
const messages=async()=> (await db.query('SELECT payload,event,topic,private FROM realtime.messages ORDER BY id')).rows;
const clear=()=>db.exec('TRUNCATE realtime.messages');

test('credit changes notify only the affected player and administrators without financial data',async()=>{
 await clear();await db.query("SELECT ct_post_credit($1,321,'admin','live-test')",[uid(1)]);
 const rows=await messages();assert.ok(rows.some(r=>r.topic==='ct:live:user:'+uid(1)));assert.ok(rows.some(r=>r.topic==='ct:live:admin'));assert.ok(rows.every(r=>r.private&&r.event==='changed'&&Object.keys(r.payload).every(k=>['scope','id'].includes(k))));assert.ok(!rows.some(r=>r.topic.includes(uid(2))));
});
test('a transaction batches repeated changes and rollback leaves neither credits nor notifications',async()=>{
 await clear();await db.exec('BEGIN');for(let i=0;i<5;i++)await db.query("UPDATE ct_wallets SET balance=balance+1 WHERE user_id=$1",[uid(1)]);await db.exec('COMMIT');
 assert.equal((await messages()).filter(r=>r.topic==='ct:live:user:'+uid(1)).length,1);
 await clear();const before=(await db.query('SELECT balance FROM ct_wallets WHERE user_id=$1',[uid(1)])).rows[0].balance;
 await db.exec('BEGIN');await db.query('UPDATE ct_wallets SET balance=balance+100 WHERE user_id=$1',[uid(1)]);await db.exec('ROLLBACK');assert.equal((await messages()).length,0);assert.equal((await db.query('SELECT balance FROM ct_wallets WHERE user_id=$1',[uid(1)])).rows[0].balance,before);
});
test('no-op writes do not loop; shared configuration changes emit a catalog signal',async()=>{
 await clear();await db.query('UPDATE ct_wallets SET balance=balance WHERE user_id=$1',[uid(1)]);await db.exec('UPDATE ct_titles SET name=name WHERE false');assert.equal((await messages()).length,0);
 await db.exec('UPDATE ct_titles SET name=name WHERE id=(SELECT min(id) FROM ct_titles)');assert.ok((await messages()).some(r=>r.topic==='ct:live:global'&&r.payload.scope==='catalog'));
});
test('private channel RLS denies another player and admin channels; clients cannot emit signals',async()=>{
 await clear();await db.query("SELECT ct_post_credit($1,1,'admin','live-rls')",[uid(1)]);
 async function allowed(topic){return db.transaction(async tx=>{await tx.exec('SET LOCAL ROLE authenticated');await tx.query("SELECT set_config('request.jwt.claim.sub',$1,true),set_config('test.topic',$2,true)",[uid(2),topic]);return tx.query('SELECT * FROM realtime.messages');});}
 assert.equal((await allowed('ct:live:user:'+uid(1))).rows.length,0);assert.equal((await allowed('ct:live:admin')).rows.length,0);
 await db.query("SELECT ct_live_notify($1,'account')",['ct:live:user:'+uid(2)]);assert.ok((await allowed('ct:live:user:'+uid(2))).rows.length>0);
 await assert.rejects(asPlayer(db,2,"SELECT ct_live_notify('ct:live:global','catalog')"),/permission denied/);
});
test('failed realtime delivery does not roll back a valid wallet modification',async()=>{
 await db.exec(`CREATE OR REPLACE FUNCTION realtime.send(jsonb,text,text,boolean) RETURNS void LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION 'offline'; END$$;`);
 const before=(await db.query('SELECT balance FROM ct_wallets WHERE user_id=$1',[uid(1)])).rows[0].balance;
 await db.query('UPDATE ct_wallets SET balance=balance+7 WHERE user_id=$1',[uid(1)]);assert.equal(Number((await db.query('SELECT balance FROM ct_wallets WHERE user_id=$1',[uid(1)])).rows[0].balance),Number(before)+7);
});
const source=await readFile('src/lib/liveSync.ts','utf8');const js=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022}}).outputText;
const {liveQueryMatches,createLiveBatch}=await import('data:text/javascript;base64,'+Buffer.from(js).toString('base64'));
test('scoped invalidation refreshes all intended screens without restarting billiard playback',()=>{
 for(const root of ['player','diamonds','circle-access','sealed-inventory','inbox-summary','inbox-letter','orders'])assert.equal(liveQueryMatches([root,uid(1)],new Set(['account'])),true,root);
 for(const root of ['titles','chests','quests','game-controls'])assert.equal(liveQueryMatches([root],new Set(['catalog'])),true,root);
 assert.equal(liveQueryMatches(['pool'],new Set(['account','catalog','market','admin'])),false);assert.equal(liveQueryMatches(['admin-data'],new Set(['market'])),false);
});
test('batching deduplicates bursts, cannot starve, and cleans pending callbacks on logout',async()=>{
 const calls=[];const batch=createLiveBatch(s=>calls.push([...s].sort()),15);batch.push('account');batch.push('account');batch.push('catalog');await new Promise(r=>setTimeout(r,35));assert.deepEqual(calls,[['account','catalog']]);batch.push('market');batch.dispose();await new Promise(r=>setTimeout(r,35));assert.equal(calls.length,1);batch.push('news');await new Promise(r=>setTimeout(r,35));assert.equal(calls.length,1);
});
test('a mounted player balance updates from another session signal, catches in-flight changes and resumes after hidden state',async()=>{
 const client=new QueryClient({defaultOptions:{queries:{retry:false,staleTime:Infinity,gcTime:0}}});
 const win=new EventTarget(),doc=new EventTarget();doc.hidden=false;const channels=[];let cleanup;
 const originals=Object.fromEntries(['window','document','navigator','__liveTest'].map(k=>[k,Object.getOwnPropertyDescriptor(globalThis,k)]));
 const fakeSupabase={channel(topic){const c={topic,on(_type,_filter,fn){c.receive=fn;return c;},subscribe(fn){c.status=fn;return c;}};channels.push(c);return c;},async removeChannel(c){c.removed=true;}};
 Object.defineProperty(globalThis,'window',{value:win,configurable:true});Object.defineProperty(globalThis,'document',{value:doc,configurable:true});Object.defineProperty(globalThis,'navigator',{value:{onLine:true},configurable:true});
 globalThis.__liveTest={client,supabase:fakeSupabase,useEffect:fn=>{cleanup=fn();},liveQueryMatches,createLiveBatch,liveScopes:['account','catalog','market','community','news','admin','support']};
 const hookSource=(await readFile('src/lib/useLiveSync.ts','utf8')).replace(/^import .*;\r?\n/gm,'');
 const hookJs=ts.transpileModule('const {client,supabase,useEffect,liveQueryMatches,createLiveBatch,liveScopes}=globalThis.__liveTest;const useQueryClient=()=>client;\n'+hookSource,{compilerOptions:{module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022}}).outputText;
 let balance=100,calls=0,hold;const observer=new QueryObserver(client,{queryKey:['player',uid(1)],queryFn:async()=>{calls++;const captured=balance;if(hold)await hold;return {balance:captured};}});const stop=observer.subscribe(()=>{});
 const sleep=ms=>new Promise(r=>setTimeout(r,ms));
 try{
  const {useLiveSync}=await import('data:text/javascript;base64,'+Buffer.from(hookJs).toString('base64'));useLiveSync(uid(1),false);await sleep(10);assert.equal(observer.getCurrentResult().data.balance,100);assert.equal(channels.length,2);
  const signal=()=>channels[0].receive({payload:{scope:'account',balance:999999}});
  balance=600;signal();signal();await sleep(470);assert.equal(observer.getCurrentResult().data.balance,600);assert.equal(calls,2);
  let release;hold=new Promise(r=>release=r);balance=700;void observer.refetch();await sleep(10);balance=800;signal();await sleep(450);release();hold=null;await sleep(470);assert.equal(observer.getCurrentResult().data.balance,800);
  doc.hidden=true;balance=900;const before=calls;signal();await sleep(450);assert.equal(calls,before);doc.hidden=false;doc.dispatchEvent(new Event('visibilitychange'));await sleep(470);assert.equal(observer.getCurrentResult().data.balance,900);
  balance=1000;signal();cleanup();cleanup=undefined;await sleep(450);assert.equal(observer.getCurrentResult().data.balance,900);assert.ok(channels.every(c=>c.removed));
 }finally{cleanup?.();stop();client.clear();for(const [k,d] of Object.entries(originals))if(d)Object.defineProperty(globalThis,k,d);else delete globalThis[k];}
});
