import {test,after} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {createTitlesDatabase,asPlayer} from './helpers/titlesDatabase.mjs';
const db=await createTitlesDatabase(undefined,['20261022030000_titles_collection.sql','20261022031000_titles_catalog.sql','20261022040000_titles_chests.sql','20261022050000_titles_quests.sql','20261022060000_titles_games.sql','20261022061000_titles_blackjack.sql','20261022070000_titles_tables.sql','20261022080000_titles_administration.sql','20261022090000_titles_progression.sql','20261022100000_titles_blackjack_rules.sql','20261022110000_titles_config_guards.sql','20261022120000_titles_integrity.sql']);
after(()=>db.close());
test('chest price/odds changes invalidate old confirmations; committed receipts still replay',async()=>{
 await db.exec('UPDATE ct_chest_types SET price=600 WHERE id=1');
 const op=randomUUID(),open=version=>asPlayer(db,1,'SELECT ct_open_chest($1,1::smallint,$2) result',[op,version]);
 await assert.rejects(open(0),/configuration changed/);
 const first=(await open(1)).rows[0].result;assert.equal(first.balance,4400);
 await db.exec('UPDATE ct_chest_types SET price=700 WHERE id=1');
 assert.deepEqual((await open(0)).rows[0].result,first);
 await assert.rejects(asPlayer(db,1,'SELECT ct_open_chest_v1($1,1::smallint)',[randomUUID()]),/permission denied/);
});
test('shop refuses a price different from the one the user saw',async()=>{
 await db.exec("UPDATE ct_titles SET shop_price=1500 WHERE id='ct-1-001'");
 const op=randomUUID(),buy=price=>asPlayer(db,2,'SELECT ct_buy_title($1,$2,$3) result',[op,'ct-1-001',price]);
 await assert.rejects(buy(1200),/price changed/);
 const result=(await buy(1500)).rows[0].result;assert.equal(result.balance,3500);
 assert.deepEqual((await buy(1200)).rows[0].result,result);
});
test('blackjack rejects changed rules before taking the stake',async()=>{
 const rules=(await db.query("SELECT to_jsonb(r)-'id' rules FROM ct_blackjack_rules r")).rows[0].rules;
 await db.exec('UPDATE ct_blackjack_rules SET dealer_hits_soft17=true');
 await assert.rejects(asPlayer(db,1,'SELECT ct_blackjack_start($1,100,$2)',[randomUUID(),rules]),/rules changed/);
 rules.dealer_hits_soft17=true;
 const result=(await asPlayer(db,1,'SELECT ct_blackjack_start($1,100,$2) result',[randomUUID(),rules])).rows[0].result;
 assert.equal(result.rules.dealer_hits_soft17,true);assert.equal(result.deck,undefined);
});
