import {diamondValueCents,exactEuros} from '../lib/diamondPricing';
export function DiamondValue({quantity,rate}:{quantity:number;rate:string}){try{return <small className="diamond-euro-value">≈ {exactEuros(diamondValueCents(quantity,rate))} fictifs</small>;}catch{return null;}}
