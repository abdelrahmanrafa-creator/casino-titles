import {test,after} from 'node:test';
import assert from 'node:assert/strict';
import {readdir} from 'node:fs/promises';
import {createTitlesDatabase,asPlayer,uid} from './helpers/titlesDatabase.mjs';
const migrations=(await readdir(new URL('../supabase/migrations/',import.meta.url))).filter(f=>f.endsWith('.sql')&&!f.includes('010000_titles_identity')&&!f.includes('020000_titles_economy')).sort();
const db=await createTitlesDatabase(undefined,migrations);after(()=>db.close());
const rpc=async(name,id=uid(1))=>(await asPlayer(db,2,`SELECT ${name}($1) result`,[id])).rows[0].result;
test('public profile provides aggregate balance, no private rounds, and honest empty ratios',async()=>{
 const p=await rpc('ct_public_profile_details');assert.equal(p.balance,5000);assert.equal(p.statistics.games,0);assert.equal(p.statistics.win_percent,null);assert.equal(p.statistics.win_loss_ratio,null);assert.equal(p.statistics.return_percent,null);assert.ok(p.positions.length>0);assert.ok(!JSON.stringify(p).includes('deck'));
});
test('title prevalence counts distinct owners, separate copies and all active accounts including newcomers',async()=>{
 await db.query("INSERT INTO ct_player_titles(user_id,title_id,source) VALUES($1,'ct-1-001','test'),($1,'ct-1-001','test'),($2,'ct-1-001','test')",[uid(1),uid(2)]);
 let t=(await rpc('ct_public_collection'))[0];assert.equal(t.copies,2);assert.equal(t.global_copies,3);assert.equal(t.owners,2);assert.equal(t.population,2);assert.equal(t.percentage,100);
 await db.query('INSERT INTO auth.users VALUES($1,now())',[uid(3)]);await asPlayer(db,3,"SELECT ct_initialize_profile('Newcomer')");
 t=(await rpc('ct_public_collection'))[0];assert.equal(t.population,3);assert.ok(t.percentage>66&&t.percentage<67);
 await db.query('UPDATE ct_player_titles SET revoked_at=now() WHERE user_id=$1',[uid(2)]);t=(await rpc('ct_public_collection'))[0];assert.equal(t.owners,1);assert.equal(t.global_copies,2);
});
test('blackjack doubles and split stakes are included without exposing hand or future card data',async()=>{
 await db.query(`INSERT INTO ct_game_rounds(user_id,game,bet,payout,status,state) VALUES($1,'blackjack',100,300,'settled','{"hands":[{"bet":200},{"bet":100}],"deck":["secret"]}'),($1,'coinflip',100,200,'settled','{}'),($1,'coinflip',100,0,'settled','{}')`,[uid(1)]);
 const p=await rpc('ct_public_profile_details'),s=p.statistics;assert.equal(s.wagered,500);assert.equal(s.returned,500);assert.equal(s.net,0);assert.equal(s.biggest_bet,300);assert.equal(s.wins,1);assert.equal(s.losses,1);assert.equal(s.draws,1);assert.equal(s.win_loss_ratio,1);assert.equal(s.gains,100);assert.equal(s.loss_amount,100);assert.ok(!JSON.stringify(p).includes('secret'));
});
test('hidden ranking preference hides all current positions without hiding public profile',async()=>{
 await asPlayer(db,1,'SELECT ct_set_leaderboard_visibility(true)');const p=await rpc('ct_public_profile_details');assert.equal(p.leaderboard_hidden,true);assert.deepEqual(p.positions,[]);assert.equal(p.balance,5000);assert.equal(await rpc('ct_public_profile_details',uid(999)),null);
});
test('simulation fields and internal projections are inaccessible to ordinary visitors',async()=>{
 await assert.rejects(asPlayer(db,2,'SELECT is_bot FROM ct_profiles'),/permission denied/);
 for(const query of ["SELECT ct_public_profile_internal($1)","SELECT ct_find_players_internal('Ali')","SELECT ct_rankings_internal('credits','all')"]){await assert.rejects(asPlayer(db,2,query,query.includes('$1')?[uid(1)]:[]),/permission denied/);}
});
