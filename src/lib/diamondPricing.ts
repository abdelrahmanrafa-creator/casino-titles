export function diamondTotalCents(quantity:number,unitEuro:string):number{
 if(!Number.isSafeInteger(quantity)||quantity<1||quantity>10000||!/^\d+(\.\d{1,12})?$/.test(unitEuro))throw Error('Montant invalide');
 const [whole,fraction='']=unitEuro.split('.'),scale=10n**12n,unit=BigInt(whole)*scale+BigInt(fraction.padEnd(12,'0'));
 const cents=(BigInt(quantity)*unit*100n+scale/2n)/scale;if(cents>BigInt(Number.MAX_SAFE_INTEGER))throw Error('Montant trop élevé');return Number(cents);
}
export const euros=(cents:number)=>new Intl.NumberFormat('fr-FR',{style:'currency',currency:'EUR'}).format(cents/100);
export function diamondValueCents(quantity:number,unitEuro:string):bigint{if(!Number.isSafeInteger(quantity)||quantity<0||!/^\d+(\.\d{1,12})?$/.test(unitEuro))throw Error('Montant invalide');const [whole,fraction='']=unitEuro.split('.'),scale=10n**12n;return(BigInt(quantity)*(BigInt(whole)*scale+BigInt(fraction.padEnd(12,'0')))*100n+scale/2n)/scale;}
export function exactEuros(cents:bigint){const positive=cents<0n?-cents:cents;return(cents<0n?'−':'')+new Intl.NumberFormat('fr-FR').format(positive/100n)+','+String(positive%100n).padStart(2,'0')+' €';}
