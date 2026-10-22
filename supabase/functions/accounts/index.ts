import {createClient} from 'https://esm.sh/@supabase/supabase-js@2.117.3';
const headers={'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type','Access-Control-Allow-Methods':'POST, OPTIONS','Content-Type':'application/json','Cache-Control':'no-store'};
const reply=(value:unknown,status=200)=>new Response(JSON.stringify(value),{status,headers});
const url=Deno.env.get('SUPABASE_URL')!,key=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,anon=Deno.env.get('SUPABASE_ANON_KEY')!;
const db=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});
const hash=async(text:string)=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(text)))).map(x=>x.toString(16).padStart(2,'0')).join('');
const publicClient=()=>createClient(url,anon,{auth:{persistSession:false,autoRefreshToken:false}});
Deno.serve(async(req:Request)=>{
 if(req.method==='OPTIONS')return new Response(null,{headers});if(req.method!=='POST')return reply({error:'Method not allowed',definitive:true},405);
 let actor:string|undefined,operation:string|undefined,claimed=false;
 try{
  const body=await req.json();
  if(body.action==='guest'){
   const username=String(body.username??'').trim(),nonce=String(body.nonce??'');if(!/^[a-zA-Z0-9_]{3,24}$/.test(username)||!/^[a-f0-9]{64}$/.test(nonce))throw Error('Pseudo ou requête invité invalide');
   const ip=req.headers.get('x-forwarded-for')?.split(',').at(-1)?.trim()??'unknown';const quota=await db.rpc('ct_guest_quota',{p_bucket:await hash(ip+key)});if(quota.error)throw quota.error;
   const secret=await crypto.subtle.importKey('raw',new TextEncoder().encode(key),{name:'HMAC',hash:'SHA-256'},false,['sign']);const signature=new Uint8Array(await crypto.subtle.sign('HMAC',secret,new TextEncoder().encode(nonce)));const password='G!9a'+Array.from(signature).map(x=>x.toString(16).padStart(2,'0')).join('');const email='guest-'+await hash(nonce)+'@guest.casino.invalid';
   let client=publicClient(),login=await client.auth.signInWithPassword({email,password});let created:string|undefined;
   if(login.error){const {data:existing}=await db.from('ct_profiles').select('id').ilike('username',username.replaceAll('_','\\_')).maybeSingle();if(existing)throw Error('Ce pseudo est déjà utilisé. Choisissez-en un autre.');const made=await db.auth.admin.createUser({email,password,email_confirm:true,app_metadata:{ct_guest:true}});if(made.error)throw made.error;created=made.data.user.id;client=publicClient();login=await client.auth.signInWithPassword({email,password});}
   if(login.error||!login.data.session){if(created)await db.auth.admin.deleteUser(created);throw Error('Connexion invité indisponible. Réessayez.');}
   const initialized=await client.rpc('ct_initialize_profile',{p_username:username});if(initialized.error){if(created)await db.auth.admin.deleteUser(created);throw initialized.error;}
   return reply({session:login.data.session,profile:initialized.data});
  }
  const token=req.headers.get('Authorization')?.replace(/^Bearer /,'');if(!token)return reply({error:'Connexion requise',definitive:true},401);
  const auth=await db.auth.getUser(token);if(auth.error||!auth.data.user)return reply({error:'Connexion requise',definitive:true},401);actor=auth.data.user.id;
  const client=createClient(url,anon,{global:{headers:{Authorization:'Bearer '+token}},auth:{persistSession:false,autoRefreshToken:false}});
  const permitted=await client.rpc('ct_is_admin');if(permitted.error||permitted.data!==true)return reply({error:'Administrator required',definitive:true},403);
  const target=String(body.user_id??''),action=body.action,values=body.values??{};operation=String(body.operation_id??'');if(!/^[0-9a-f-]{36}$/i.test(operation)||!['email','reset'].includes(action))throw Error('Requête de compte invalide');
  const begun=await client.rpc('ct_account_job',{p_operation_id:operation,p_user_id:target,p_action:action,p_values:values,p_reason:body.reason});if(begun.error)throw begun.error;
  if(begun.data.replay){if(begun.data.result?.error)return reply(begun.data.result,400);if(begun.data.status==='completed')return reply(begun.data.result);return reply({error:'Cette opération est en cours. Actualisez dans quelques instants.',definitive:false},409);}
  claimed=true;const found=await db.auth.admin.getUserById(target);if(found.error||!found.data.user)throw Error('Compte Auth introuvable');const user=found.data.user,guest=user.app_metadata?.ct_guest===true,currentEmail=guest?null:user.email;
  if((values.expected_email??null)!==(currentEmail??null))throw Error('L’adresse a changé. Actualisez la fiche du joueur.');
  if(action==='email'){
   const email=String(values.email??'').trim().toLowerCase();if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)||email.length>254||email.endsWith('@guest.casino.invalid'))throw Error('Adresse e-mail invalide');
   const updated=await db.auth.admin.updateUserById(target,{email,email_confirm:true,app_metadata:{...user.app_metadata,ct_guest:false}});if(updated.error)throw updated.error;
  }else{if(!currentEmail)throw Error('Associez d’abord une adresse e-mail au compte invité.');const reset=await publicClient().auth.resetPasswordForEmail(currentEmail,{redirectTo:'https://casino-titles-cercle.sassyjay19.chatgpt.site/settings'});if(reset.error)throw reset.error;}
  const result={ok:true,message:action==='email'?'Adresse e-mail modifiée.':'Lien de réinitialisation envoyé au joueur.'};const done=await db.rpc('ct_account_finish',{p_admin:actor,p_operation:operation,p_result:result});if(done.error)throw done.error;return reply(result);
 }catch(error){const message=error instanceof Error?error.message:String((error as {message?:string})?.message??'Opération indisponible');const result={error:message,definitive:true};if(claimed&&actor&&operation)await db.rpc('ct_account_finish',{p_admin:actor,p_operation:operation,p_result:result});return reply(result,400);}
});
