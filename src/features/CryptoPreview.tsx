// DEV-only fixture based on the local SQL simulator. Never calls production APIs.
import {useMemo,useRef} from 'react';
import {QueryClient,QueryClientProvider} from '@tanstack/react-query';
import {Crypto,type CryptoApi} from './Crypto';
import {LanguageSettings} from '../components/LanguageSettings';
import fixture from './crypto-preview-data.json';
import type {CryptoMarket,CryptoPortfolio,CryptoQuote} from '../lib/crypto';
export default function CryptoPreview(){
 const client=useMemo(()=>new QueryClient({defaultOptions:{queries:{retry:false,staleTime:Infinity}}}),[]),market=useRef(structuredClone(fixture.market) as CryptoMarket),portfolio=useRef<CryptoPortfolio>({balance:245800,positions:[{symbol:'BTC',atoms:'1250000',cost_basis:105000,realized:0,value:'116000'},{symbol:'ETH',atoms:'2400000',cost_basis:7600,realized:320,value:'8140'}],realized:320,trades:[]});
 const api:CryptoApi=async<T,>(name:string,args:Record<string,unknown>={})=>{
  let result:unknown;if(name==='ct_crypto_market')result={...market.current,as_of:new Date().toISOString()};
  else if(name==='ct_crypto_portfolio')result=portfolio.current;
  else if(name==='ct_crypto_chart')result=(fixture.charts as Record<string,unknown>)[String(args.p_symbol)+':'+String(args.p_range)]??(fixture.charts as Record<string,unknown>)['BTC'+':day'];
  else{const a=market.current.assets.find(a=>a.symbol===args.p_symbol)!,side=args.p_side as 'buy'|'sell',price=Number(a.price_e6)/1000000,budget=Number(args.p_budget),spend=Math.floor(budget/1.0025)-(Math.floor(budget/1.0025)+Math.ceil(Math.floor(budget/1.0025)*.0025)>budget?1:0),qty=side==='buy'?Math.floor(spend/price*1000000):Math.round(Number(args.p_units)*1000000),gross=Math.ceil(qty/1000000*price),fee=Math.ceil(gross*.0025);result={symbol:a.symbol,side,atoms:String(qty),price_e6:a.price_e6,gross,fee,total:side==='buy'?gross+fee:gross-fee,fee_bps:25,slippage_bps:'0.20',bucket:market.current.bucket,asset_version:a.version,settings_version:1,expires_at:Math.floor(Date.now()/1000)+20,token:'preview'};}
  return structuredClone(result) as T;
 };
 async function command(_name:string,args:Record<string,unknown>={}){const q=args.p_quote as CryptoQuote,p=portfolio.current;let pos=p.positions.find(p=>p.symbol===q.symbol);if(!pos){pos={symbol:q.symbol,atoms:'0',cost_basis:0,realized:0,value:'0'};p.positions.push(pos);}const buy=q.side==='buy';const removed=buy?0:Number(BigInt(pos.cost_basis)*BigInt(q.atoms)/BigInt(pos.atoms));p.balance+=buy?-q.total:q.total;pos.atoms=String(BigInt(pos.atoms)+(buy?1n:-1n)*BigInt(q.atoms));pos.cost_basis+=buy?q.total:-removed;if(!buy){pos.realized+=q.total-removed;p.realized+=q.total-removed;}pos.value=String(Math.round(Number(pos.atoms)/1000000*Number(q.price_e6)/1000000));p.trades.unshift({...q,id:p.trades.length+1,realized:0,created_at:new Date().toISOString()});return {ok:true};}
 return <QueryClientProvider client={client}><section className="panel" style={{padding:18}}><LanguageSettings persist={false}/></section><Crypto userId="crypto-preview" api={api} command={command} busy={false} onSignIn={()=>{}}/></QueryClientProvider>;
}
