import {readFile} from 'node:fs/promises';
const config={...process.env};
try{for(const line of (await readFile(new URL('../.env.local',import.meta.url),'utf8')).split(/\r?\n/)){const match=line.match(/^([A-Z_]+)\s*=\s*(.*?)\s*$/);if(match&&!config[match[1]])config[match[1]]=match[2].replace(/^['"]|['"]$/g,'');}}catch{/* CI uses environment variables. */}
const url=config.VITE_SUPABASE_URL,key=config.VITE_SUPABASE_ANON_KEY;
if(!url||!key)throw Error('Public Supabase configuration required');
const headers={apikey:key,'Content-Type':'application/json'};
async function check(label,path,options,verify){const response=await fetch(url+path,{headers,...options});const body=await response.json();if(!verify(response,body))throw Error(`${label}: unexpected HTTP ${response.status}`);console.log(`PASS ${label} (HTTP ${response.status})`);}
await check('catalog online','/rest/v1/ct_titles?select=id',{},(r,b)=>r.ok&&Array.isArray(b)&&b.length>=320);
await check('wallet inaccessible anonymously','/rest/v1/ct_wallets?select=balance',{},r=>[401,403].includes(r.status));
await check('private room state inaccessible anonymously','/rest/v1/ct_rooms?select=id',{},r=>[401,403].includes(r.status));
await check('credit helper inaccessible anonymously','/rest/v1/rpc/ct_post_credit',{method:'POST',body:JSON.stringify({p_uid:'00000000-0000-0000-0000-000000000001',p_delta:1,p_reason:'test',p_key:'test'})},r=>[401,403].includes(r.status));
await check('table function rejects unauthenticated requests','/functions/v1/ct-tables',{method:'POST',body:JSON.stringify({command:'list'})},r=>r.status===401);
await check('email authentication available','/auth/v1/settings',{},(r,b)=>r.ok&&b.external?.email===true);
