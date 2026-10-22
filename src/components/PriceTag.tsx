import {credits} from '../lib/api';
export function PriceTag({base,current,compact=false}:{base:number;current:number;compact?:boolean}){
 const discounted=Number.isFinite(base)&&Number.isFinite(current)&&base>0&&current>=0&&current<base;
 const percent=discounted?Math.round((base-current)/base*1000)/10:0;
 return <span className={`price-tag ${compact?'price-compact':''}`}>
  {discounted&&<del aria-label={`Prix de base ${credits(base)} crédits`}>{credits(base)}</del>}
  <strong>{current===0?'Gratuit':credits(current)}<small>{current===0?'':' crédits'}</small></strong>
  {discounted&&<span className="discount-badge">−{percent.toLocaleString('fr-FR',{maximumFractionDigits:1})} %</span>}
 </span>;
}
