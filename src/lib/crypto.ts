import {locale} from '../i18n/store';
export type CryptoAsset={symbol:string;name:string;category:string;color:string;price_e6:string;previous_e6:string;sparkline:string[];volume:number;float_atoms:string;total_atoms:string;buy_enabled:boolean;version:number};
export type CryptoMarket={simulated:true;as_of:string;bucket:number;version:number;buy_enabled:boolean;sell_enabled:boolean;fee_bps:number;spread_bps:number;max_trade:number;assets:CryptoAsset[]};
export type CryptoPosition={symbol:string;atoms:string;cost_basis:number;realized:number;value:string};
export type CryptoTrade={id:number;symbol:string;side:'buy'|'sell';atoms:string;price_e6:string;gross:number;fee:number;total:number;realized:number;created_at:string};
export type CryptoPortfolio={balance:number;positions:CryptoPosition[];realized:number;trades:CryptoTrade[]};
export type CryptoQuote={symbol:string;side:'buy'|'sell';atoms:string;price_e6:string;gross:number;fee:number;total:number;fee_bps:number;slippage_bps:string;expires_at:number;token:string;bucket:number;asset_version:number;settings_version:number};
export type CryptoPoint={time:number;price_e6:string};
export function cryptoUnits(atoms:string){const n=BigInt(atoms),whole=n/1000000n,part=(n%1000000n).toString().padStart(6,'0').replace(/0+$/,'');return whole.toString()+(part?'.'+part:'');}
export function cryptoAmount(atoms:string){const [whole,part]=cryptoUnits(atoms).split('.');return new Intl.NumberFormat(locale()).format(BigInt(whole))+(part?(locale().startsWith('fr')?',':'.')+part:'');}
export function cryptoPrice(price:string){const n=Number(price)/1000000;return new Intl.NumberFormat(locale(),{minimumFractionDigits:2,maximumFractionDigits:n<1?6:n<10?4:2}).format(n);}
export function cryptoCredits(value:bigint|string|number){return new Intl.NumberFormat(locale()).format(BigInt(value));}
export function cryptoChange(a:CryptoAsset){return(Number(a.price_e6)/Number(a.previous_e6)-1)*100;}
export function cryptoPercent(n:number){return(n>0?'+':'')+n.toLocaleString(locale(),{minimumFractionDigits:2,maximumFractionDigits:2})+' %';}
export const cryptoCategory:Record<string,string>={all:'Tous les actifs',layer1:'Réseaux',layer2:'Seconde couche',defi:'Finance décentralisée',payments:'Paiements',meme:'Communautaires',ai:'Intelligence artificielle',storage:'Infrastructure',stable:'Stables'};
export function cryptoPath(values:number[],width=600,height=230){if(!values.length)return '';const low=Math.min(...values),high=Math.max(...values),span=high-low||Math.max(high*.001,1);return values.map((v,i)=>(i?'L':'M')+(i*width/Math.max(1,values.length-1)).toFixed(2)+','+(height-12-(v-low)/span*(height-24)).toFixed(2)).join(' ');}
