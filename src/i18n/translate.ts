import english from './catalog.json';import french from './fr.json';import {getLanguage,type Language} from './store';
const en=english as Record<string,string>,fr=french as Record<string,string>;
const lookup=(dictionary:Record<string,string>,key:string)=>Object.hasOwn(dictionary,key)?dictionary[key]:undefined;
const normalized=(s:string)=>s.replace(/\s+/g,' ').trim();const escape=(s:string)=>s.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
const patterns=Object.keys(en).flatMap(key=>{const printf=/^(Option inconnue|Valeur vide|Statistique invalide|No available title|Le catalogue sélectionné|Pas assez de titres)/.test(key)&&key.includes('%');const template=printf?key.replace('%','{0}'):key;if(!/\{\d+\}/.test(template)||/\{\d+\}\{\d+\}/.test(template))return[];const slots:number[]=[];let pattern='',at=0;for(const match of template.matchAll(/\{(\d+)\}/g)){pattern+=escape(template.slice(at,match.index))+'(.+?)';slots.push(Number(match[1]));at=match.index!+match[0].length;}pattern+=escape(template.slice(at));return [{key,printf,slots,regex:new RegExp('^'+pattern+'$'),weight:template.replace(/\{\d+\}/g,'').length}];}).sort((a,b)=>b.weight-a.weight);
const cache=new Map<string,string>();
export function translateText(value:string,language:Language=getLanguage(),depth=0):string{
 if(!value.trim()||depth>5)return value;const key=normalized(value),cacheKey=language+':'+key;const cached=cache.get(cacheKey);if(cached!==undefined)return value.replace(value.trim(),()=>cached);
 let answer=lookup(language==='en'?en:fr,key);
 if(answer===undefined&&depth<5){const numeric=key.match(/^([+−×#\d\s.,:%€💎]+)\s+(.+)$/u);if(numeric){const suffix=translateText(numeric[2],language,depth+1);if(suffix!==numeric[2])answer=numeric[1]+' '+suffix;}}
 if(answer===undefined){for(const p of patterns){const matches=key.match(p.regex);if(!matches)continue;const preserve=/^(Au tour de|Code|· Pour|\{0\} (pioche|pose|quitte|rejoint|remporte|:))/.test(p.key);const params=new Map(p.slots.map((slot,i)=>[slot,preserve?matches[i+1]:translateText(matches[i+1],language,depth+1)]));let target=language==='en'?en[p.key]:fr[p.key]??p.key;if(p.printf)target=target.replace('%','{0}');answer=target.replace(/\{(\d+)\}/g,(_,slot)=>params.get(Number(slot))??'');break;}}
 if(answer===undefined&&depth<5){const segments=key.split(/(\s*[·→↗↓]\s*)/);if(segments.length>1)answer=segments.map((s,i)=>i%2?s:translateText(s,language,depth+1)).join('');else{const numeric=key.match(/^([+−×#\d\s.,:%€💎]+)\s+(.+)$/u);if(numeric){const suffix=translateText(numeric[2],language,depth+1);if(suffix!==numeric[2])answer=numeric[1]+' '+suffix;}}}
 if(answer===undefined)answer=key;
 if(cache.size>12000)cache.clear();cache.set(cacheKey,answer);const translated=answer;return value.replace(value.trim(),()=>translated);
}
