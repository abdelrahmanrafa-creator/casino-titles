import {credits} from '../lib/api';
import {locale} from '../i18n/store';
export function marketFee(amount:number,bps=0){return Number.isSafeInteger(amount)&&amount>=0&&Number.isInteger(bps)&&bps>=0?Number((BigInt(amount)*BigInt(bps)+9999n)/10000n):0;}
export function MarketFees({subtotal,bps,total,fee}:{subtotal:number;bps:number;total?:number;fee?:number}){const charge=fee??marketFee(subtotal,bps);return <dl className="market-fees"><div><dt>Prix des objets</dt><dd>{credits(subtotal)} 💎</dd></div><div><dt>Frais de votre carte · {(bps/100).toLocaleString(locale())} %</dt><dd>+{credits(charge)} 💎</dd></div><div><dt>Total à payer</dt><dd>{credits(total??subtotal+charge)} 💎</dd></div></dl>;}
