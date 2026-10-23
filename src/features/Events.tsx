import {locale} from '../i18n/store';
import {useQuery} from '@tanstack/react-query';
import {Gift,Trophy} from 'lucide-react';
import {supabase,rpc,credits,type Title} from '../lib/api';
import {TitleEffect} from '../components/TitleEffect';
import type {Command} from './Games';
interface Event {id:string;name:string;description:string;starts_at:string;ends_at:string;active:boolean;reward:number;title_id:string|null}
export function Events({userId,command,busy,catalog}:{userId?:string;command:Command;busy:boolean;catalog:Title[]}){
 const {data:events=[],error}=useQuery({queryKey:['events'],queryFn:async()=>{const {data,error}=await supabase.from('ct_events').select('*').eq('active',true).order('starts_at');if(error)throw error;return data as Event[];}});
 const {data:claimed=[]}=useQuery({queryKey:['events-claimed',userId],enabled:!!userId,queryFn:async()=>{const {data,error}=await supabase.from('ct_event_claims').select('event_id');if(error)throw error;return data.map(c=>c.event_id as string);}});
 return <div className="quest-grid">{error&&<p className="notice">{error.message}</p>}{events.map(e=>{const title=catalog.find(t=>t.id===e.title_id),ended=Date.now()>=new Date(e.ends_at).getTime(),upcoming=Date.now()<new Date(e.starts_at).getTime();return <article className="panel quest-card" key={e.id}><Gift size={23}/><h3>{e.name}</h3><p className="muted">{e.description}</p>{title&&<TitleEffect title={title}/>}<small>{credits(e.reward)} crédits · Jusqu’au {new Date(e.ends_at).toLocaleString(locale())}</small><button className="btn primary" disabled={busy||claimed.includes(e.id)||ended||upcoming} onClick={()=>void command('ct_claim_event',{p_event_id:e.id})}>{claimed.includes(e.id)?'Récompense reçue':ended?'Événement terminé':upcoming?'Bientôt disponible':'Recevoir la récompense'}</button></article>;})}{!events.length&&!error&&<p className="muted">Les prochains rendez-vous du cercle seront annoncés ici.</p>}</div>;
}
interface Achievement {id:string;name:string;progress:number;target:number;earned_at:string|null}
export function Achievements({userId}:{userId:string}){
 const {data:items=[],error}=useQuery({queryKey:['achievements',userId],queryFn:()=>rpc<Achievement[]>('ct_my_achievements')});
 return <section className="quests-section"><div className="section-title"><div><p className="eyebrow">VOTRE PARCOURS</p><h2>Les succès.</h2></div><Trophy size={21}/></div>{error&&<p className="notice">{error.message}</p>}<div className="quest-grid">{items.map(a=><article className="panel quest-card" key={a.id}><h3>{a.earned_at?'✦ ':''}{a.name}</h3><div className="progress"><i style={{width:`${Math.min(a.progress/a.target*100,100)}%`}}/></div><small>{a.earned_at?`Débloqué le ${new Date(a.earned_at).toLocaleDateString(locale())}`:`${Math.min(a.progress,a.target)} / ${a.target}`}</small></article>)}</div></section>;
}
