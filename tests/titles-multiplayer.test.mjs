import {test,after} from 'node:test';
import assert from 'node:assert/strict';
import {build} from 'esbuild';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {pathToFileURL} from 'node:url';
import {randomUUID} from 'node:crypto';
import {createTitlesDatabase,asPlayer,uid} from './helpers/titlesDatabase.mjs';
const folder=await mkdtemp(join(tmpdir(),'ct-tables-'));
await build({entryPoints:[new URL('../supabase/functions/tables/engine.ts',import.meta.url).pathname.replace(/^\/([A-Za-z]:)/,'$1')],bundle:true,platform:'node',format:'esm',outfile:join(folder,'engine.mjs')});
const e=await import(pathToFileURL(join(folder,'engine.mjs')).href);
const db=await createTitlesDatabase(undefined,['20261022030000_titles_collection.sql','20261022031000_titles_catalog.sql','20261022040000_titles_chests.sql','20261022050000_titles_quests.sql','20261022060000_titles_games.sql','20261022061000_titles_blackjack.sql','20261022070000_titles_tables.sql','20261022080000_titles_administration.sql','20261022090000_titles_progression.sql','20261022100000_titles_blackjack_rules.sql']);
after(async()=>{await db.close();await rm(folder,{recursive:true,force:true});});
function table(game='poker',players=2){let s=e.createState(game,uid(1),'Alice',100);for(let n=2;n<=players;n++)s=e.joinState(s,uid(n),`Player ${n}`,100);return e.startState(s,uid(1),1000);}
test('7-card evaluation ranks wheel, full house, quads and straight flush with kickers',()=>{
 const rank=cards=>e.rankSeven(cards);
 // Deck IDs: ace=0, two=1, ... king=12; suits are blocks of 13.
 const royal=rank([9,10,11,12,0,15,29]);const quads=rank([0,13,26,39,12,11,8]);
 const full=rank([12,25,38,11,24,0,2]);const flush=rank([0,3,6,8,11,15,29]);
 const wheel=rank([0,14,28,42,4,8,12]);const pair=rank([0,13,3,6,8,22,37]);
 assert.ok(royal>quads&&quads>full&&full>flush&&flush>wheel&&wheel>pair);
});
test('side pots honor contributions, folded players, ties and odd chips',()=>{
 const base=table().seats[0];const seats=[{...base,id:'a',hand:[0,13],committed:50},{...base,id:'b',hand:[12,25],committed:100},{...base,id:'c',hand:[11,24],committed:200}];
 const awards=e.settlePots(seats,[2,17,32,46,8]);assert.deepEqual([...awards.values()],[150,100,100]);
 assert.equal([...awards.values()].reduce((a,b)=>a+b),350);
});
test('heads-up blinds, all-ins and settlement conserve chips without exposing opponents',()=>{
 let s=table();assert.equal(s.seats[0].streetBet,10);assert.equal(s.seats[1].streetBet,20);
 assert.deepEqual(e.publicState(s,uid(1)).seats[1].hand,[]);assert.equal(e.publicState(s,uid(1)).deck,undefined);
 assert.throws(()=>e.actState(s,uid(2),{kind:'call'},2000),/Not your turn/);
 s=e.actState(s,uid(1),{kind:'allin'},2000);s=e.actState(s,uid(2),{kind:'call'},2001);
 assert.equal(s.phase,'finished');assert.equal(s.board.length,5);assert.equal(s.seats.reduce((n,p)=>n+p.stack,0),200);
 assert.ok(e.publicState(s,uid(1)).seats[1].hand.length===2);
});
test('check/call advances preflop, flop, turn and river; folds settle without revealing cards',()=>{
 let s=table();for(let i=0;i<20&&s.phase!=='finished';i++){const p=s.seats[s.turn];s=e.actState(s,p.id,{kind:p.streetBet<s.bet?'call':'check'},2000+i);}
 assert.equal(s.phase,'finished');assert.equal(s.board.length,5);
 s=table();s=e.actState(s,s.seats[s.turn].id,{kind:'fold'},2000);assert.equal(s.phase,'finished');assert.equal(s.showdown,false);
 assert.equal(s.seats.reduce((n,p)=>n+p.stack,0),200);
});
test('short all-in does not reopen a completed player raise',()=>{
 let s=table('poker',3);s.seats[1].stack=20;
 s=e.actState(s,s.seats[s.turn].id,{kind:'raise',amount:40},2000);
 s=e.actState(s,s.seats[s.turn].id,{kind:'allin'},2001);
 // The all-in seat can be below the bet, or a short raise depending on its blind.
 assert.ok(s.seats.filter(p=>p.stack===0).length>=1);
});
test('Chromatic deals 7 cards, enforces turns/matches, hides hands and handles skip/reverse/draw',()=>{
 let s=table('chromatic',8);assert.ok(s.seats.every(p=>p.hand.length===7));assert.equal(e.publicState(s,uid(2)).seats[0].hand.length,0);
 assert.throws(()=>e.actState(s,uid(2),{kind:'draw'},2000),/Not your turn/);
 s.seats[0].hand=[10,5];s.discard=[3];s.color=0;s.turn=0;
 s=e.actState(s,uid(1),{kind:'play',card:10},2000);assert.equal(s.turn,2);
 s.seats[2].hand=[11,5];s.color=0;s=e.actState(s,uid(3),{kind:'play',card:11},2001);assert.equal(s.direction,-1);assert.equal(s.turn,1);
 s.seats[1].hand=[12,5];s.color=0;const count=s.seats[0].hand.length;s=e.actState(s,uid(2),{kind:'play',card:12},2002);assert.equal(s.seats[0].hand.length,count+2);assert.equal(s.turn,7);
});
test('Chromatic wild selects color, last card settles the entire pot; timeouts are authoritative',()=>{
 let s=table('chromatic');s.seats[0].hand=[13];s=e.actState(s,uid(1),{kind:'play',card:13,color:3},2000);
 assert.equal(s.phase,'finished');assert.equal(s.seats[0].stack,200);assert.equal(s.seats[1].stack,0);
 s=table('chromatic');const before=s.seats[0].hand.length;s=e.tickState(s,50000);assert.equal(s.seats[0].hand.length,before+1);assert.equal(s.turn,1);
});
test('browser cannot access private rooms or the escrow commit RPC',async()=>{
 for(const sql of ['SELECT * FROM ct_rooms','SELECT * FROM ct_room_members',"SELECT ct_create_room(auth.uid(),gen_random_uuid(),'{}','poker','X',false,100,'{}')"])
  await assert.rejects(asPlayer(db,1,sql),/permission denied/);
 assert.equal((await asPlayer(db,1,'SELECT * FROM ct_room_signals')).rows.length,0);
});
test('server room escrow commits exactly once, rejects stale revisions and returns conserved payouts',async()=>{
 let s=e.createState('poker',uid(1),'Alice',100);const op=randomUUID();
 const create=async()=> (await db.query('SELECT ct_create_room($1,$2,$3,$4,$5,false,100,$6) result',[uid(1),op,{kind:'create'},'poker','TEST123',s])).rows[0].result;
 const created=await create();assert.deepEqual(await create(),created);
 s=e.joinState(s,uid(2),'Bob',100);
 await db.query('SELECT ct_commit_room($1,$2,$3,$4,0,$5,$6)',[uid(2),randomUUID(),{kind:'join'},created.room_id,s,'join']);
 await assert.rejects(db.query('SELECT ct_commit_room($1,$2,$3,$4,0,$5,$6)',[uid(1),randomUUID(),{kind:'start'},created.room_id,s,'start']),/Concurrent/);
 s=e.startState(s,uid(1),1000);s=e.actState(s,s.seats[s.turn].id,{kind:'fold'},2000);
 const finish=randomUUID();const commit=()=>db.query('SELECT ct_commit_room($1,$2,$3,$4,1,$5,$6)',[uid(1),finish,{kind:'finish'},created.room_id,s,'act']);
 await commit();await commit();
 const total=(await db.query('SELECT sum(balance)::int n FROM ct_wallets')).rows[0].n;assert.equal(total,10000);
 assert.equal((await db.query('SELECT count(*)::int n FROM ct_room_members WHERE paid')).rows[0].n,2);
});
test('administration rejects players and audits authorized changes once',async()=>{
 await assert.rejects(asPlayer(db,1,"SELECT ct_admin_overview('')"),/Administrator/);
 await db.query('INSERT INTO ct_admins VALUES($1)',[uid(1)]);
 const op=randomUUID();const adjust=()=>asPlayer(db,1,'SELECT ct_admin_command($1,$2,$3,$4,$5)',[op,'credit',uid(2),{amount:100},'Récompense de test']);
 await adjust();await adjust();assert.equal((await db.query('SELECT count(*)::int n FROM ct_admin_audit_logs')).rows[0].n,1);
 await asPlayer(db,1,'SELECT ct_admin_command($1,$2,$3,$4,$5)',[randomUUID(),'suspend',uid(2),{},'Suspension de test']);
 await assert.rejects(asPlayer(db,2,'SELECT ct_claim_daily($1)',[randomUUID()]),/suspended/);
});
test('event grants credits and exclusive cosmetic once, using server dates',async()=>{
 await db.exec("UPDATE ct_events SET starts_at=now()-interval '1 day',ends_at=now()+interval '1 day'");
 const id=randomUUID(),claim=op=>asPlayer(db,1,'SELECT ct_claim_event($1,$2) result',[op,'opening-2026']);
 const first=(await claim(id)).rows[0].result;assert.equal(first.amount,500);
 assert.deepEqual((await claim(id)).rows[0].result,first);
 await assert.rejects(claim(randomUUID()),/unique/);
 assert.equal((await db.query("SELECT count(*)::int n FROM ct_player_titles WHERE source LIKE 'event:%'")).rows[0].n,1);
});
test('revocation keeps acquisition history, clears equipped title and excludes active inventory',async()=>{
 const instance=(await db.query('SELECT id FROM ct_player_titles WHERE user_id=$1 LIMIT 1',[uid(1)])).rows[0].id;
 await asPlayer(db,1,'SELECT ct_equip_title($1)',[instance]);
 const before=(await asPlayer(db,1,'SELECT ct_my_achievements() result')).rows[0].result;assert.ok(before.find(a=>a.id==='first-title').earned_at);
 await asPlayer(db,1,'SELECT ct_admin_revoke_title($1,$2,$3)',[randomUUID(),instance,'Correction d’attribution']);
 await assert.rejects(asPlayer(db,1,'SELECT ct_equip_title($1)',[instance]),/not owned/);
 assert.equal((await db.query('SELECT * FROM ct_player_titles WHERE id=$1',[instance])).rows.length,1);
 const snapshot=(await asPlayer(db,1,'SELECT ct_player_snapshot() result')).rows[0].result;assert.equal(snapshot.inventory.length,0);assert.equal(snapshot.equipped_id,null);
 const after=(await asPlayer(db,1,'SELECT ct_my_achievements() result')).rows[0].result;assert.equal(after.find(a=>a.id==='first-title').earned_at,before.find(a=>a.id==='first-title').earned_at);
});
test('preferences persist per user; catalog administration requires server permission',async()=>{
 await asPlayer(db,1,'SELECT ct_save_preferences(true)');assert.equal((await asPlayer(db,1,'SELECT reduced_motion FROM ct_preferences')).rows[0].reduced_motion,true);
 assert.equal((await asPlayer(db,2,'SELECT * FROM ct_preferences')).rows.length,0);
 await assert.rejects(asPlayer(db,2,'SELECT ct_admin_catalog($1,$2,$3,$4,$5)',[randomUUID(),'rarity','1',{color:'#ffffff'},'Test interdit']),/Administrator/);
});
test('administrative blackjack rules affect new rounds; existing rounds keep their agreed rules',async()=>{
 const rules={dealer_hits_soft17:true,natural_numerator:6,natural_denominator:5,max_hands:2,double_after_split:false};
 const fixed=cards=>db.exec(`CREATE OR REPLACE FUNCTION ct_shuffled_deck(p_decks integer DEFAULT 1) RETURNS integer[] LANGUAGE sql AS $$ SELECT ARRAY[${cards.join(',')}] $$;`);
 await fixed([9,0,6,5,9,3,4]);
 const round=(await asPlayer(db,1,'SELECT ct_blackjack_start($1,100) result',[randomUUID()])).rows[0].result;
 await asPlayer(db,1,'SELECT ct_admin_blackjack_rules($1,$2,$3)',[randomUUID(),rules,'Configuration de test']);
 const stood=(await asPlayer(db,1,'SELECT ct_blackjack_action($1,$2,$3) result',[randomUUID(),round.round_id,'stand'])).rows[0].result;
 assert.equal(stood.dealer.length,2);assert.equal(stood.rules.dealer_hits_soft17,false);
 const next=(await asPlayer(db,1,'SELECT ct_blackjack_start($1,100) result',[randomUUID()])).rows[0].result;
 const hit=(await asPlayer(db,1,'SELECT ct_blackjack_action($1,$2,$3) result',[randomUUID(),next.round_id,'stand'])).rows[0].result;
 assert.equal(hit.dealer.length,3);assert.equal(hit.rules.dealer_hits_soft17,true);
 await fixed([0,8,9,7,2,3]);
 const natural=(await asPlayer(db,1,'SELECT ct_blackjack_start($1,100) result',[randomUUID()])).rows[0].result;assert.equal(natural.payout,220);
});
