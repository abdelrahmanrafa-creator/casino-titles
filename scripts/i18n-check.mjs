import {readFile} from 'node:fs/promises';import {collect} from './i18n-extract.mjs';
const en=JSON.parse(await readFile('src/i18n/catalog.json','utf8')),fr=JSON.parse(await readFile('src/i18n/fr.json','utf8'));const missing=(await collect()).filter(key=>!Object.hasOwn(en,key));
if(missing.length)throw Error('Missing English translations. Add them to src/i18n/messages, then run npm run i18n:build:\n'+missing.join('\n'));
for(const [key,value] of Object.entries(en)){if(!value.trim())throw Error('Empty English translation: '+key);const slots=s=>[...s.matchAll(/\{(\d+)\}/g)].map(m=>m[1]).sort().join(',');if(slots(key)!==slots(value))throw Error('Translation parameters do not match: '+key);}
for(const [key,value] of Object.entries(fr))if(!value.trim())throw Error('Empty French translation: '+key);
console.log('French/English coverage complete: '+Object.keys(en).length+' entries.');
