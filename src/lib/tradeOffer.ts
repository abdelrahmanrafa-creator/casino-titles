export type TradeGroup={key:string;kind:'title'|'chest';name:string;rarity:number;available:number};
export type TradeDraft={diamonds:number;groups:Record<string,number>};
export function tradeSignature(d:TradeDraft){return JSON.stringify([d.diamonds,Object.entries(d.groups).filter(([,n])=>n>0).sort(([a],[b])=>a.localeCompare(b))]);}
export function tradeCount(d:TradeDraft){return Object.values(d.groups).reduce((a,b)=>a+b,0);}
export function setTradeQuantity(d:TradeDraft,g:TradeGroup,quantity:number,max=1000):TradeDraft{
 const n=Math.max(0,Math.min(Number.isFinite(quantity)?Math.floor(quantity):0,g.available,max-tradeCount(d)+(d.groups[g.key]??0)));
 const groups={...d.groups};if(n)groups[g.key]=n;else delete groups[g.key];return {...d,groups};
}
export function fillTrade(d:TradeDraft,groups:TradeGroup[],max=1000){return groups.reduce((next,g)=>setTradeQuantity(next,g,g.available,max),d);}
