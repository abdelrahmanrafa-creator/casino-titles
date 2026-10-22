import {test,after} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {createTitlesDatabase,asPlayer,uid} from './helpers/titlesDatabase.mjs';
const db=await createTitlesDatabase(undefined,['20261022030000_titles_collection.sql','20261022031000_titles_catalog.sql','20261022040000_titles_chests.sql','20261022050000_titles_quests.sql','20261022060000_titles_games.sql','20261022061000_titles_blackjack.sql']);
after(()=>db.close());
const value=async(sql,args=[])=>Object.values((await db.query(sql,args)).rows[0])[0];
const play=(game,choice={},id=randomUUID())=>asPlayer(db,1,'SELECT ct_play_game($1,$2,100,$3) result',[id,game,choice]);
const start=()=>asPlayer(db,1,'SELECT ct_blackjack_start($1,100) result',[randomUUID()]);
const action=(id,choice,op=randomUUID(),n=1)=>asPlayer(db,n,'SELECT ct_blackjack_action($1,$2,$3) result',[op,id,choice]);
async function deck(cards){await db.exec(`CREATE OR REPLACE FUNCTION public.ct_shuffled_deck(p_decks integer DEFAULT 1) RETURNS integer[] LANGUAGE sql VOLATILE SET search_path='' AS $$ SELECT ARRAY[${cards.join(',')}] $$;`);}
test('blackjack ace values and baccarat card totals',async()=>{
 assert.equal(await value('SELECT ct_card_total(ARRAY[0,13,9])'),12);
 assert.equal(await value('SELECT ct_card_total(ARRAY[0,9])'),21);
 assert.equal(await value('SELECT ct_card_total(ARRAY[0,9],true)'),1);
});
test('roulette zero loses outside bets; exact numbers, groups, red and black pay correctly',async()=>{
 for(const kind of ['red','black','even','odd','low','high','dozen','column'])assert.equal(await value('SELECT ct_roulette_multiplier(0,$1)',[{kind,value:'1'}]),0);
 assert.equal(await value('SELECT ct_roulette_multiplier(0,$1)',[{kind:'number',value:'0'}]),36);
 assert.equal(await value('SELECT ct_roulette_multiplier(36,$1)',[{kind:'column',value:'3'}]),3);
 assert.equal(await value('SELECT ct_roulette_multiplier(25,$1)',[{kind:'dozen',value:'3'}]),3);
 for(let n=1;n<=36;n++)assert.equal(await value("SELECT ct_roulette_multiplier($1,'{\"kind\":\"red\"}')+ct_roulette_multiplier($1,'{\"kind\":\"black\"}')",[n]),2);
});
test('Punto Banco third-card banker table covers all 80 decisions',async()=>{
 for(let banker=0;banker<8;banker++)for(let third=0;third<=9;third++){
  const expected=banker<=2||(banker===3&&third!==8)||(banker===4&&third>=2&&third<=7)||(banker===5&&third>=4&&third<=7)||(banker===6&&[6,7].includes(third));
  assert.equal(await value('SELECT ct_banker_draw($1,$2)',[banker,third]),expected);
 }
});
test('slots pays five distinct lines using one fifth of the total wager',async()=>{
 const result=await value('SELECT ct_slot_payout(ARRAY[4,4,4,4,4,4,4,4,4],100)');
 assert.equal(result.payout,20000);assert.deepEqual(result.winning_lines,[1,2,3,4,5]);
});
test('instant games atomically debit/settle, replay and reject fraudulent input',async()=>{
 const id=randomUUID(),first=(await play('coinflip',{side:'pile'},id)).rows[0].result;
 assert.deepEqual((await play('coinflip',{side:'pile'},id)).rows[0].result,first);
 await assert.rejects(play('coinflip',{side:'face'},id),/different payload/);
 const before=await value('SELECT balance FROM ct_wallets WHERE user_id=$1',[uid(1)]);
 await assert.rejects(play('coinflip',{side:'always-win'}),/Choose/);
 assert.equal(await value('SELECT balance FROM ct_wallets WHERE user_id=$1',[uid(1)]),before);
 for(const [game,choice] of [['slots',{}],['roulette',{kind:'number',value:'0'}],['baccarat',{side:'banker'}]]){
  const result=(await play(game,choice)).rows[0].result;assert.ok(result.round_id);assert.ok(result.payout>=0);
 }
});
test('blackjack private deck and dealer hole card never leave the server; reconnection recovers round',async()=>{
 await deck([9,8,6,7,2,3,4,5]);
 const first=(await start()).rows[0].result;assert.equal(first.status,'active');assert.equal(first.dealer.length,1);assert.equal(first.deck,undefined);
 const restored=(await asPlayer(db,1,'SELECT ct_active_blackjack() result')).rows[0].result;assert.deepEqual(restored,first);
 await assert.rejects(asPlayer(db,1,'SELECT * FROM ct_game_rounds'),/permission denied/);
 await assert.rejects(action(first.round_id,'stand',randomUUID(),2),/not found/);
 const result=(await action(first.round_id,'stand')).rows[0].result;assert.equal(result.status,'settled');assert.equal(result.dealer.length,2);
});
test('natural blackjack pays 3:2, dealer blackjack and equal naturals are handled',async()=>{
 await deck([0,8,9,7,2,3]);let result=(await start()).rows[0].result;assert.equal(result.payout,250);assert.equal(result.status,'settled');
 await deck([8,0,7,9,2,3]);result=(await start()).rows[0].result;assert.equal(result.payout,0);
 await deck([0,13,9,22,2,3]);result=(await start()).rows[0].result;assert.equal(result.payout,100);
});
test('double draws exactly one card, debits once and replays action safely',async()=>{
 await deck([4,8,5,7,9,2,3]);let result=(await start()).rows[0].result;const id=randomUUID();
 result=(await action(result.round_id,'double',id)).rows[0].result;assert.equal(result.bet,200);assert.equal(result.hands[0].cards.length,3);assert.equal(result.payout,400);
 assert.deepEqual((await action(result.round_id,'double',id)).rows[0].result,result);
});
test('splitting aces creates two hands, one extra card each, with no natural premium',async()=>{
 await deck([0,8,13,7,9,22,3,4]);let result=(await start()).rows[0].result;
 result=(await action(result.round_id,'split')).rows[0].result;assert.equal(result.status,'settled');assert.equal(result.bet,200);
 assert.equal(result.hands.length,2);assert.equal(result.payout,400);assert.ok(result.hands.every(h=>h.cards.length===2&&h.split));
});
test('quests rely on persisted server progress, are once-only and free onboarding is claimable',async()=>{
 const claim=(quest,id=randomUUID())=>asPlayer(db,2,'SELECT ct_claim_quest($1,$2) result',[id,quest]);
 await assert.rejects(claim('first_chest'),/not completed/);
 const id=randomUUID(),first=(await claim('welcome',id)).rows[0].result;assert.equal(first.amount,250);
 assert.deepEqual((await claim('welcome',id)).rows[0].result,first);
 await assert.rejects(claim('welcome'),/already claimed/);
});
