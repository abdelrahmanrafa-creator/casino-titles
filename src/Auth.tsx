import {LanguageSettings} from './components/LanguageSettings';
import {useRef,useState,type FormEvent} from 'react';
import {supabase,rpc,accountRequest} from './lib/api';
import type {Profile} from './components/ProfileGate';
export function Auth({authenticated,onComplete}:{authenticated:boolean;onComplete:(profile:Profile)=>void|Promise<void>}){
 const [mode,setMode]=useState<'guest'|'login'|'signup'|'reset'>('guest');
 const [email,setEmail]=useState(''),[password,setPassword]=useState(''),[username,setUsername]=useState('');
 const guestNonce=useRef('');
 const [busy,setBusy]=useState(false),[message,setMessage]=useState('');
 async function submit(e:FormEvent){e.preventDefault();setBusy(true);setMessage('');try{
  if(authenticated){const profile=await rpc<Profile>('ct_initialize_profile',{p_username:username.trim()});if(!profile?.id||!profile.username)throw new Error('Le profil n’a pas pu être confirmé. Réessayez.');await onComplete(profile);}
  else if(mode==='guest'){
   if(!guestNonce.current){try{guestNonce.current=sessionStorage.getItem('ct:guest-attempt')??'';}catch{}if(!guestNonce.current)guestNonce.current=(crypto.randomUUID()+crypto.randomUUID()).replaceAll('-','');try{sessionStorage.setItem('ct:guest-attempt',guestNonce.current);}catch{}}
   const result=await accountRequest<{session:{access_token:string;refresh_token:string};profile:Profile}>({action:'guest',username:username.trim(),nonce:guestNonce.current});const {error}=await supabase.auth.setSession(result.session);if(error)throw error;try{sessionStorage.removeItem('ct:guest-attempt');}catch{}await onComplete(result.profile);
  }else if(mode==='reset'){
   const {error}=await supabase.auth.resetPasswordForEmail(email,{redirectTo:`${location.origin}/settings`});if(error)throw error;
   setMessage('Si ce compte existe, un lien de récupération a été envoyé.');
  }else if(mode==='signup'){
   const {error}=await supabase.auth.signUp({email,password,options:{emailRedirectTo:location.origin}});if(error)throw error;
   setMessage('Confirmez votre adresse e-mail pour rejoindre le cercle.');setPassword('');
  }else{const {error}=await supabase.auth.signInWithPassword({email,password});if(error)throw error;setPassword('');}
 }catch(error){setMessage((error as Error).message);}finally{setBusy(false);}}
 return <section className="auth-panel panel"><LanguageSettings compact persist={false}/><p className="eyebrow">LE CERCLE VOUS ATTEND</p><h2>{authenticated?'Votre signature.':mode==='guest'?'Entrez avec un pseudo.':mode==='signup'?'Prenez votre place.':mode==='reset'?'Retrouvez votre accès.':'Bon retour au club.'}</h2>
  <p className="muted">{authenticated?'Choisissez un pseudo unique pour votre profil.':'5 000 crédits offerts à la création de votre profil.'}</p>
  <form onSubmit={submit}>
   {(authenticated||mode==='guest')?<label>Pseudo<input value={username} onChange={e=>setUsername(e.target.value)} required pattern="[a-zA-Z0-9_]{3,24}" placeholder="Votre pseudo" autoComplete="nickname"/><small>3–24 lettres, chiffres ou _</small></label>:<>
    <label>E-mail<input type="email" required value={email} onChange={e=>setEmail(e.target.value)} autoComplete="email" placeholder="vous@exemple.fr"/></label>
    {mode!=='reset'&&<label>Mot de passe<input type="password" minLength={8} required value={password} onChange={e=>setPassword(e.target.value)} autoComplete={mode==='signup'?'new-password':'current-password'} placeholder="8 caractères minimum"/></label>}
   </>}
   <button className="btn primary" disabled={busy}>{busy?'Connexion au cercle…':authenticated?'Créer mon profil':mode==='guest'?'Jouer en invité':mode==='signup'?'Créer mon compte':mode==='reset'?'Recevoir le lien':'Se connecter'} <span>↗</span></button>
  </form>
  {!authenticated&&<div className="auth-links"><button className="text-btn" onClick={()=>setMode('guest')}>Entrer en invité · juste un pseudo</button><button className="text-btn" onClick={()=>setMode(mode==='login'?'signup':'login')}>{mode==='login'?'Créer un compte':'Déjà membre ? Connexion'}</button><button className="text-btn" onClick={()=>setMode('reset')}>Mot de passe oublié</button></div>}
  {!authenticated&&mode==='guest'&&<p className="legal">Votre progression est sauvegardée dans ce navigateur. Après déconnexion ou effacement de ses données, l’accès peut être perdu. Vous pouvez ajouter votre e-mail et un mot de passe dans Paramètres pour garder un accès durable.</p>}
  {message&&<p role="status" className="notice">{message}</p>}
  {authenticated&&<button className="text-btn" onClick={()=>{void supabase.auth.signOut();}}>Se déconnecter</button>}
  <p className="legal">Crédits virtuels uniquement. Aucun achat, dépôt, retrait ou gain en argent réel.</p>
 </section>;
}
