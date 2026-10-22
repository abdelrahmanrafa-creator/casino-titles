import {useState,type FormEvent} from 'react';
import {supabase,rpc} from './lib/api';
export function Auth({authenticated,onComplete}:{authenticated:boolean;onComplete:()=>void}){
 const [mode,setMode]=useState<'login'|'signup'|'reset'>('signup');
 const [email,setEmail]=useState(''),[password,setPassword]=useState(''),[username,setUsername]=useState('');
 const [busy,setBusy]=useState(false),[message,setMessage]=useState('');
 async function submit(e:FormEvent){e.preventDefault();setBusy(true);setMessage('');try{
  if(authenticated){await rpc('ct_initialize_profile',{p_username:username});onComplete();}
  else if(mode==='reset'){
   const {error}=await supabase.auth.resetPasswordForEmail(email,{redirectTo:`${location.origin}/settings`});if(error)throw error;
   setMessage('Si ce compte existe, un lien de récupération a été envoyé.');
  }else if(mode==='signup'){
   const {error}=await supabase.auth.signUp({email,password,options:{emailRedirectTo:location.origin}});if(error)throw error;
   setMessage('Confirmez votre adresse e-mail pour rejoindre le cercle.');setPassword('');
  }else{const {error}=await supabase.auth.signInWithPassword({email,password});if(error)throw error;setPassword('');}
 }catch(error){setMessage((error as Error).message);}finally{setBusy(false);}}
 return <section className="auth-panel panel"><p className="eyebrow">LE CERCLE VOUS ATTEND</p><h2>{authenticated?'Votre signature.':mode==='signup'?'Prenez votre place.':mode==='reset'?'Retrouvez votre accès.':'Bon retour au club.'}</h2>
  <p className="muted">{authenticated?'Choisissez un pseudo unique pour votre profil.':'5 000 crédits offerts à la création de votre profil.'}</p>
  <form onSubmit={submit}>
   {authenticated?<label>Pseudo<input value={username} onChange={e=>setUsername(e.target.value)} required pattern="[a-zA-Z0-9_]{3,24}" placeholder="Votre pseudo" autoComplete="nickname"/><small>3–24 lettres, chiffres ou _</small></label>:<>
    <label>E-mail<input type="email" required value={email} onChange={e=>setEmail(e.target.value)} autoComplete="email" placeholder="vous@exemple.fr"/></label>
    {mode!=='reset'&&<label>Mot de passe<input type="password" minLength={8} required value={password} onChange={e=>setPassword(e.target.value)} autoComplete={mode==='signup'?'new-password':'current-password'} placeholder="8 caractères minimum"/></label>}
   </>}
   <button className="btn primary" disabled={busy}>{busy?'Connexion au cercle…':authenticated?'Créer mon profil':mode==='signup'?'Créer mon compte':mode==='reset'?'Recevoir le lien':'Se connecter'} <span>↗</span></button>
  </form>
  {!authenticated&&<div className="auth-links"><button className="text-btn" onClick={()=>setMode(mode==='login'?'signup':'login')}>{mode==='login'?'Créer un compte':'Déjà membre ? Connexion'}</button><button className="text-btn" onClick={()=>setMode('reset')}>Mot de passe oublié</button></div>}
  {message&&<p role="status" className="notice">{message}</p>}
  {authenticated&&<button className="text-btn" onClick={()=>{void supabase.auth.signOut();}}>Se déconnecter</button>}
  <p className="legal">Crédits virtuels uniquement. Aucun achat, dépôt, retrait ou gain en argent réel.</p>
 </section>;
}
