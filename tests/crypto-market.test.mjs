import {test,after} from 'node:test';import assert from 'node:assert/strict';import {readdir,readFile} from 'node:fs/promises';import ts from 'typescript';import {randomUUID} from 'node:crypto';import {createTitlesDatabase,asPlayer,uid} from './helpers/titlesDatabase.mjs';
const files=(await readdir('supabase/migrations')).filter(f=>f.endsWith('.sql')&&!f.includes('010000_titles_identity')&&!f.includes('020000_titles_economy')).sort(),db=await createTitlesDatabase(undefined,files);after(()=>db.close());
const rpc=async(n,name,args=[])=>(await asPlayer(db,n,`SELECT ${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) r`,args)).rows[0].r;
await db.query("SELECT ct_post_credit($1,10000000,'admin','crypto-test')",[uid(1)]);await db.query('INSERT INTO ct_admins(user_id) VALUES($1)',[uid(1)]);
let buyQuote,buyResult,buyOp;
test('shared simulated market and bounded charts evolve with server time without filling a price-history table',async()=>{
 const m=await rpc(1,'ct_crypto_market');assert.equal(m.simulated,true);assert.equal(m.assets.length,32);assert.ok(m.assets.every(a=>BigInt(a.price_e6)>0n&&a.sparkline.length===13));const before=await db.query("SELECT ct_crypto_mark('BTC',30000000) a,ct_crypto_mark('BTC',30000001) b");assert.notEqual(before.rows[0].a,before.rows[0].b);
 const bob=await rpc(2,'ct_crypto_market');if(bob.bucket===m.bucket)assert.deepEqual(bob,m);else{assert.equal(bob.bucket,m.bucket+1);const price=(await db.query("SELECT ct_crypto_mark('BTC',$1)::text p",[bob.bucket])).rows[0].p;assert.equal(bob.assets.find(a=>a.symbol==='BTC').price_e6,price);}for(const range of ['hour','day','week']){const chart=await rpc(1,'ct_crypto_chart',['BTC',range]);assert.ok(chart.points.length<=169);assert.ok(chart.points.every(p=>BigInt(p.price_e6)>0n));}await assert.rejects(rpc(1,'ct_crypto_chart',['BTC','forever']),/Période/);
 assert.equal((await db.query('SELECT count(*)::int n FROM ct_crypto_public_cache')).rows[0].n,1);
});
test('buy quote respects an exact credit budget, reserves no money and discloses fees and spread',async()=>{
 const before=(await rpc(1,'ct_player_snapshot')).balance;buyQuote=await rpc(1,'ct_crypto_quote',['BTC','buy',null,100000]);assert.ok(BigInt(buyQuote.atoms)>0n);assert.ok(buyQuote.total<=100000);assert.equal(buyQuote.total,buyQuote.gross+buyQuote.fee);assert.ok(buyQuote.token);assert.equal((await rpc(1,'ct_player_snapshot')).balance,before);
});
test('atomic buy debits once, assigns real game holdings, reduces float and mirrors the treasury',async()=>{
 const before=(await db.query('SELECT balance FROM ct_wallets WHERE user_id=$1',[uid(1)])).rows[0].balance,float=(await db.query("SELECT float_atoms FROM ct_crypto_assets WHERE symbol='BTC'")).rows[0].float_atoms;buyOp=randomUUID();buyResult=await rpc(1,'ct_crypto_trade',[buyOp,buyQuote]);assert.deepEqual(await rpc(1,'ct_crypto_trade',[buyOp,buyQuote]),buyResult);
 assert.equal(BigInt((await db.query('SELECT balance FROM ct_wallets WHERE user_id=$1',[uid(1)])).rows[0].balance),BigInt(before)-BigInt(buyQuote.total));const p=await rpc(1,'ct_crypto_portfolio');assert.equal(p.positions[0].atoms,buyQuote.atoms);assert.equal(p.positions[0].cost_basis,buyQuote.total);assert.equal(BigInt((await db.query("SELECT float_atoms FROM ct_crypto_assets WHERE symbol='BTC'")).rows[0].float_atoms),BigInt(float)-BigInt(buyQuote.atoms));
 assert.equal((await db.query('SELECT count(*)::int n FROM ct_crypto_trades')).rows[0].n,1);const e=await rpc(1,'ct_admin_economy',[30,null,'']);assert.equal(e.difference,0);assert.equal(e.ledger_difference,0);
});
test('forged and foreign quotes, stale books, oversized inputs and short sales cannot mint credits',async()=>{
 await assert.rejects(rpc(1,'ct_crypto_trade',[randomUUID(),{...buyQuote,total:1}]),/invalide/);await assert.rejects(rpc(2,'ct_crypto_trade',[randomUUID(),buyQuote]),/invalide/);await assert.rejects(rpc(1,'ct_crypto_trade',[randomUUID(),buyQuote]),/cours a changé/);
 for(const q of ['-1','0','1.0000001','NaN','1e5'])await assert.rejects(rpc(1,'ct_crypto_quote',['ETH','buy',q,null]));await assert.rejects(rpc(2,'ct_crypto_quote',['BTC','sell','1',null]),/indisponible/);await assert.rejects(rpc(1,'ct_crypto_quote',['BTC','buy',null,100000001]));
 assert.equal((await db.query('SELECT count(*)::int n FROM ct_crypto_trades')).rows[0].n,1);
});
test('selling all credits the net amount once, empties the position, records realized gains/losses and restores supply',async()=>{
 const units=(Number(buyQuote.atoms)/1000000).toFixed(6);const q=await rpc(1,'ct_crypto_quote',['BTC','sell',units,null]);assert.equal(q.total,q.gross-q.fee);const op=randomUUID(),r=await rpc(1,'ct_crypto_trade',[op,q]);assert.deepEqual(await rpc(1,'ct_crypto_trade',[op,q]),r);const p=await rpc(1,'ct_crypto_portfolio');assert.equal(p.positions[0].atoms,'0');assert.equal(p.positions[0].cost_basis,0);assert.equal(p.realized,q.total-buyQuote.total);assert.equal((await db.query("SELECT float_atoms=total_atoms ok FROM ct_crypto_assets WHERE symbol='BTC'")).rows[0].ok,true);assert.ok(q.total<buyQuote.total,'fees and spread prevent a same-tick free profit');
});
test('wallet failure rolls back supply, portfolio, history and all credit legs',async()=>{
 const q=await rpc(2,'ct_crypto_quote',['ETH','buy',null,100]);await db.query('UPDATE ct_wallets SET balance=0 WHERE user_id=$1',[uid(2)]);const f=(await db.query("SELECT float_atoms FROM ct_crypto_assets WHERE symbol='ETH'")).rows[0].float_atoms;
 await assert.rejects(rpc(2,'ct_crypto_trade',[randomUUID(),q]),/Insufficient/);assert.equal((await db.query("SELECT float_atoms FROM ct_crypto_assets WHERE symbol='ETH'")).rows[0].float_atoms,f);assert.equal((await rpc(2,'ct_crypto_portfolio')).trades.length,0);
});
test('admin pause, settings versions and audit are enforced and seeds/helpers/private holdings are not exposed',async()=>{
 const d=await rpc(1,'ct_admin_crypto');assert.equal(d.stats.trades,2);const v={action:'settings',version:d.settings.version,buy_enabled:false,sell_enabled:true,fee_bps:15,max_trade:1000000};await rpc(1,'ct_admin_crypto_update',[randomUUID(),v,'Test de pause crypto']);await assert.rejects(rpc(1,'ct_crypto_quote',['ETH','buy',null,100]),/suspendues/);await assert.rejects(rpc(2,'ct_admin_crypto'),/Administrator/);assert.ok(!JSON.stringify(d).includes('secret'));
 for(const t of ['ct_crypto_settings','ct_crypto_positions','ct_crypto_trades','ct_crypto_assets'])await assert.rejects(asPlayer(db,2,'SELECT * FROM '+t),/permission denied/);await assert.rejects(rpc(2,'ct_crypto_mark',['BTC',99999999]),/permission denied/);assert.equal((await rpc(2,'ct_crypto_portfolio')).positions.length,0);
});
test('a large purchase cannot print credits by pumping an illiquid coin and immediately selling it back',async()=>{
 const settings=(await rpc(1,'ct_admin_crypto')).settings;await rpc(1,'ct_admin_crypto_update',[randomUUID(),{action:'settings',version:settings.version,buy_enabled:true,sell_enabled:true,fee_bps:25,max_trade:10000000},'Test de liquidité crypto']);
 const q=await rpc(1,'ct_crypto_quote',['BONK','buy',null,7000000]);await rpc(1,'ct_crypto_trade',[randomUUID(),q]);const qty=BigInt(q.atoms),units=(qty/1000000n).toString()+'.'+(qty%1000000n).toString().padStart(6,'0');const sell=await rpc(1,'ct_crypto_quote',['BONK','sell',units,null]);assert.ok(sell.total<q.total,'self-induced impact must remain below round-trip execution costs');await rpc(1,'ct_crypto_trade',[randomUUID(),sell]);
});
const helper=await readFile('src/lib/crypto.ts','utf8'),compiled=ts.transpileModule(helper.replace("import {locale} from '../i18n/store';","const locale=()=> 'en-GB';"),{compilerOptions:{module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022}}).outputText;
const {cryptoUnits,cryptoAmount,cryptoPath}=await import('data:text/javascript;base64,'+Buffer.from(compiled).toString('base64'));
test('fractional holdings preserve all six decimals beyond JavaScript safe integers and charts handle flat or empty data',()=>{
 assert.equal(cryptoUnits('123456789012345678'),'123456789012.345678');assert.equal(cryptoAmount('123456789012345678'),'123,456,789,012.345678');assert.equal(cryptoUnits('1000000'),'1');assert.equal(cryptoUnits('1'),'0.000001');assert.equal(cryptoPath([]),'');assert.doesNotMatch(cryptoPath([100,100,100]),/NaN|Infinity/);
});
