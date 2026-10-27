import {test,after} from 'node:test';import assert from 'node:assert/strict';import {randomUUID} from 'node:crypto';import {readdir} from 'node:fs/promises';import {createTitlesDatabase,asPlayer,uid} from './helpers/titlesDatabase.mjs';
const files=(await readdir(new URL('../supabase/migrations/',import.meta.url))).filter(f=>f.endsWith('.sql')&&!f.includes('010000_titles_identity')&&!f.includes('020000_titles_economy')).sort();
const db=await createTitlesDatabase(undefined,files);after(()=>db.close());
const call=async(n,action,values={},op=randomUUID())=>(await asPlayer(db,n,'SELECT ct_pool_command($1,$2,$3) r',[op,action,values])).rows[0].r;
const balance=async n=>Number((await db.query('SELECT balance FROM ct_wallets WHERE user_id=$1',[uid(n)])).rows[0].balance);
await db.query('SELECT ct_post_credit($1,500000,\'admin\',\'pool-qa-fund\'),ct_post_credit($2,500000,\'admin\',\'pool-qa-fund\')',[uid(1),uid(2)]);
test('title grants notify real recipients exactly once, preserve title rarity, and remain private',async()=>{
 const insert="INSERT INTO ct_player_titles(user_id,title_id,source) VALUES($1,'ct-4-001','admin')";await db.query(insert,[uid(1)]);
 const list=(await asPlayer(db,1,'SELECT ct_inbox_list() r')).rows[0].r;assert.equal(list.messages.length,1);const letter=list.messages[0];assert.equal(letter.system_payload.kind,'title_grant');assert.equal(letter.system_payload.rarity,4);assert.ok(letter.system_payload.name);
 assert.equal((await asPlayer(db,2,'SELECT ct_inbox_list() r')).rows[0].r.messages.length,0);await assert.rejects(asPlayer(db,2,'SELECT ct_inbox_open($1)',[letter.id]),/introuvable/);
 await db.query("INSERT INTO ct_player_titles(user_id,title_id,source) VALUES($1,'ct-2-001','purchase')",[uid(1)]);assert.equal((await asPlayer(db,1,'SELECT ct_inbox_summary() r')).rows[0].r.unread,1);
});
test('a completed order sends purchase and sale receipts with exact fees and immutable totals; replay does not duplicate mail',async()=>{
 const args=['notify-qa','player',uid(1),uid(2),'chest','Coffre mythique','1',5,3,300000,30000,[],{}];
 const sql='SELECT ct_order_insert($1,$2,$3,$4,$5,$6,$7,$8::smallint,$9,$10,$11,$12,$13) id';const order=(await db.query(sql,args)).rows[0].id;await db.query(sql,args);
 for(const [n,role,amount] of [[1,'purchase',300000],[2,'sale',270000]]){const letters=(await asPlayer(db,n,'SELECT ct_inbox_list() r')).rows[0].r.messages.filter(m=>m.system_payload?.kind==='order');assert.equal(letters.length,1);assert.equal(letters[0].system_payload.role,role);assert.equal(letters[0].system_payload.amount,amount);assert.equal(letters[0].system_payload.order_id,order);}
});
let invite;
test('invitations reserve no money, accept charges both atomically, rejects strangers and cannot double debit',async()=>{
 const before=[await balance(1),await balance(2)];invite=await call(1,'create',{ai:false,guest:uid(2),stake:20000});assert.equal(await balance(1),before[0]);
 await assert.rejects(call(1,'accept',{id:invite.id}),/indisponible/);const op=randomUUID(),r=await call(2,'accept',{id:invite.id},op);assert.equal(r.status,'active');assert.equal(await balance(1),before[0]-30000);assert.equal(await balance(2),before[1]-30000);assert.deepEqual(await call(2,'accept',{id:invite.id},op),r);assert.equal(await balance(2),before[1]-30000);
 await assert.rejects(asPlayer(db,1,'SELECT * FROM ct_pool_matches'),/permission denied/);await assert.rejects(asPlayer(db,1,'SELECT ct_pool_physics(ct_pool_rack(),0,70)'),/permission denied/);
});
test('shots are server-authoritative, versioned and replay-safe, with bounded animation frames and turn enforcement',async()=>{
 await assert.rejects(call(2,'shoot',{id:invite.id,version:2,angle:0,power:100}),/tour/);const op=randomUUID(),r=await call(1,'shoot',{id:invite.id,version:2,angle:0,power:100},op);assert.equal(r.shots,1);assert.equal(r.balls.length,16);const live=(await asPlayer(db,1,'SELECT ct_pool_lobby($1) r',[{[invite.id]:2}])).rows[0].r.find(m=>m.id===invite.id);assert.ok(live.last_shot.frames.length>1&&live.last_shot.frames.length<=301);assert.ok(live.last_shot.frames.every(f=>f.length===16&&f.every(b=>b.length===7)));assert.equal(r.last_shot.frames,undefined);assert.ok(r.last_shot.first>0);assert.deepEqual(await call(1,'shoot',{id:invite.id,version:2,angle:0,power:100},op),r);await assert.rejects(call(1,'shoot',{id:invite.id,version:2,angle:0,power:100}),/tour/);
});
test('resignation pays the entire escrow once, with treasury and wallets conserved',async()=>{
 const before=await balance(2),op=randomUUID();const r=await call(1,'resign',{id:invite.id},op);assert.equal(r.winner,1);assert.equal(r.status,'completed');assert.equal(await balance(2),before+40000);await call(1,'resign',{id:invite.id},op);assert.equal(await balance(2),before+40000);assert.equal((await db.query("SELECT count(*) n FROM ct_wallet_transactions WHERE idempotency_key=$1",['pool-win:'+invite.id])).rows[0].n,1);
 const mismatch=(await db.query('SELECT count(*) n FROM ct_wallet_transactions t LEFT JOIN ct_treasury_entries e ON e.wallet_transaction_id=t.id WHERE e.amount IS DISTINCT FROM -t.amount')).rows[0].n;assert.equal(mismatch,0);
});
test('failed acceptance rolls back both fees, AI costs only entry, timeout cannot be claimed early',async()=>{
 const i=await call(1,'create',{ai:false,guest:uid(2),stake:1000000}),before=await balance(1);await assert.rejects(call(2,'accept',{id:i.id}),/Insufficient/);assert.equal(await balance(1),before);assert.equal((await db.query('SELECT status FROM ct_pool_matches WHERE id=$1',[i.id])).rows[0].status,'invited');await call(1,'cancel',{id:i.id});
 const ai=await call(1,'create',{ai:true,stake:0});assert.equal(await balance(1),before-10000);await assert.rejects(call(1,'timeout',{id:ai.id}),/délai/);await assert.rejects(call(1,'ai',{id:ai.id,version:1}),/tour/);await call(1,'resign',{id:ai.id});
 const p=await call(1,'create',{ai:false,guest:uid(2),stake:0});const active=await call(2,'accept',{id:p.id});await assert.rejects(call(2,'timeout',{id:p.id}),/délai/);await db.query("UPDATE ct_pool_matches SET turn_at=now()-interval '3 minutes' WHERE id=$1",[active.id]);assert.equal((await call(2,'timeout',{id:p.id})).winner,1);
});
test('the computer aims at a real pocket; legal pots retain the turn, clearing then pocketing the eight wins',async()=>{
 const m=await call(1,'create',{ai:true,stake:0});let rack=(await db.query('SELECT ct_pool_rack() b')).rows[0].b;
 rack=rack.map(b=>({...b,out:![0,1,8].includes(b.n),...(b.n===0?{x:500,y:230}:b.n===1?{x:500,y:60}:b.n===8?{x:800,y:400}:{})}));
 await db.query('UPDATE ct_pool_matches SET balls=$2,turn=1,host_group=2,shots=2 WHERE id=$1',[m.id,JSON.stringify(rack)]);
 const ai=await call(1,'ai',{id:m.id,version:1});assert.equal(ai.last_shot.actor,1);assert.equal(ai.last_shot.foul,false);assert.ok(ai.last_shot.potted.includes(1));assert.equal(ai.turn,1);assert.equal(ai.status,'active');
 rack=rack.map(b=>({...b,out:![0,8].includes(b.n),...(b.n===8?{x:500,y:60}:{})}));await db.query('UPDATE ct_pool_matches SET balls=$2 WHERE id=$1',[m.id,JSON.stringify(rack)]);
 const finish=await call(1,'ai',{id:m.id,version:ai.version});assert.equal(finish.status,'completed');assert.equal(finish.winner,1);
});
test('an early eight loses, fouls give ball in hand, occupied cue positions and invalid powers are rejected',async()=>{
 const m=await call(1,'create',{ai:true,stake:0});const rack=(await db.query('SELECT ct_pool_rack() b')).rows[0].b.map(b=>({...b,out:![0,1,8].includes(b.n),...(b.n===0?{x:500,y:230}:b.n===8?{x:500,y:60}:b.n===1?{x:800,y:400}:{})}));
 await db.query('UPDATE ct_pool_matches SET balls=$2,host_group=1,shots=2,ball_in_hand=true WHERE id=$1',[m.id,JSON.stringify(rack)]);
 await assert.rejects(call(1,'shoot',{id:m.id,version:1,x:800,y:400,angle:0,power:50}),/zone libre/);await assert.rejects(call(1,'shoot',{id:m.id,version:1,x:500,y:230,angle:0,power:500}),/puissance/);
 const end=await call(1,'shoot',{id:m.id,version:1,x:500,y:230,angle:-Math.PI/2,power:60});assert.equal(end.winner,1);assert.equal(end.status,'completed');assert.equal(end.last_shot.foul,true);
});
test('zero spin matches the default solver; draw and follow change the cue trajectory even after later rebounds',async()=>{
 const rack=(await db.query('SELECT ct_pool_rack() b')).rows[0].b.map(b=>({...b,out:![0,1].includes(b.n),...(b.n===0?{x:250,y:250}:b.n===1?{x:400,y:250}:{})}));
 const sim=async(x,y)=>(await db.query('SELECT ct_pool_physics_spin($1,0,35,$2,$3) p',[JSON.stringify(rack),x,y])).rows[0].p;
 const plain=(await db.query('SELECT ct_pool_physics($1,0,35) p',[JSON.stringify(rack)])).rows[0].p,zero=await sim(0,0),draw=await sim(0,-1),follow=await sim(0,1);
 assert.deepEqual(zero.balls,plain.balls);assert.deepEqual(zero.frames,plain.frames);assert.ok(draw.balls[0].x<zero.balls[0].x-30);assert.ok(Math.max(...follow.frames.map(f=>f[0][0]))>zero.balls[0].x+30);assert.equal(draw.first,1);assert.ok(draw.events.some(e=>e.kind==='impact'&&e.ball===1));
});
test('left and right spin alter both horizontal and vertical cushion rebounds, with bounded finite frames',async()=>{
 for(const angle of [0,Math.PI/2]){const rack=(await db.query('SELECT ct_pool_rack() b')).rows[0].b.map(b=>({...b,out:b.n!==0,...(b.n===0?{x:600,y:250}:{})}));const sim=async(x)=>(await db.query('SELECT ct_pool_physics_spin($1,$2,100,$3,0) p',[JSON.stringify(rack),angle,x])).rows[0].p;const l=await sim(-1),r=await sim(1);assert.ok(Math.hypot(l.balls[0].x-r.balls[0].x,l.balls[0].y-r.balls[0].y)>10);assert.ok(l.frames.length<=301);assert.ok(l.frames.every(f=>f.every(b=>Number.isFinite(b[0])&&Number.isFinite(b[1]))));}
});
test('the server validates spin before changing match state; valid spin is auditable and replay-safe',async()=>{
 const m=await call(1,'create',{ai:true,stake:0}),before=await balance(1);for(const spin of [{spin_x:1,spin_y:1},{spin_x:2,spin_y:0},{spin_x:'NaN',spin_y:0}])await assert.rejects(call(1,'shoot',{id:m.id,version:1,angle:0,power:80,...spin}),/Effet/);
 assert.equal(await balance(1),before);assert.equal((await db.query('SELECT version FROM ct_pool_matches WHERE id=$1',[m.id])).rows[0].version,1);await assert.rejects(asPlayer(db,1,'SELECT ct_pool_physics_spin(ct_pool_rack(),0,60,0,1)'),/permission denied/);
 const op=randomUUID(),v={id:m.id,version:1,angle:0,power:80,spin_x:0,spin_y:-1},r=await call(1,'shoot',v,op);assert.equal(r.last_shot.spin_y,-1);assert.equal(r.last_shot.spin_x,0);assert.deepEqual(await call(1,'shoot',v,op),r);await assert.rejects(call(1,'shoot',{...v,spin_y:1},op),/reused/);assert.equal(await balance(1),before);
});
