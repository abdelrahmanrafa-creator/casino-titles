import { PGlite } from '@electric-sql/pglite';
import { readFile } from 'node:fs/promises';
export const uid=n=>`00000000-0000-0000-0000-${String(n).padStart(12,'0')}`;
export async function createTitlesDatabase(directory, extra=[]){
 const db=new PGlite(directory);
 await db.exec(`CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role; CREATE SCHEMA auth;
 CREATE TABLE auth.users(id uuid PRIMARY KEY,email_confirmed_at timestamptz);
 CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
 GRANT USAGE ON SCHEMA auth TO anon,authenticated;
 INSERT INTO auth.users VALUES('${uid(1)}',now()),('${uid(2)}',now());`);
 for(const filename of ['20261022010000_titles_identity.sql','20261022020000_titles_economy.sql',...extra])
  await db.exec(await readFile(new URL(`../../supabase/migrations/${filename}`,import.meta.url),'utf8'));
 if(extra.some(f=>f.includes('market_fees_discovery_promotions')))await db.exec('UPDATE ct_market_finance SET fees_enabled=false');
 await db.exec(`SELECT set_config('request.jwt.claim.sub','${uid(1)}',false); SELECT ct_initialize_profile('Alice');
 SELECT set_config('request.jwt.claim.sub','${uid(2)}',false); SELECT ct_initialize_profile('Bob');`);
 return db;
}
// Transaction-scoped role and identity; serialized by PGlite. No global session switch races.
export async function asPlayer(db,n,sql,params=[],session=n){
 return db.transaction(async tx=>{
  await tx.exec('SET LOCAL ROLE authenticated');
  await tx.query("SELECT set_config('request.jwt.claim.sub',$1,true)",[uid(n)]);
  await tx.query("SELECT set_config('request.jwt.claims',$1,true)",[JSON.stringify({sub:uid(n),session_id:uid(session)})]);
  return tx.query(sql,params);
 });
}
