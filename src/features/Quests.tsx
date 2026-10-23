import {useQuery} from '@tanstack/react-query';
import {Gift,Check} from 'lucide-react';
import {rpc,credits} from '../lib/api';
import type {Command} from './Games';
interface Quest {id:string;name:string;description:string;progress:number;target:number;reward:number;claimed:boolean;reward_chest_id?:number|null;reward_chest_name?:string|null;reward_chest_count?:number}
export function Quests({userId,command,busy}:{userId:string;command:Command;busy:boolean}){
 const {data:quests=[],error}=useQuery({queryKey:['quests',userId],queryFn:()=>rpc<Quest[]>('ct_my_quests')});
 return <section className="quests-section"><div className="section-title"><div><p className="eyebrow">CHAQUE ÉTAPE COMPTE</p><h2>Vos missions.</h2></div><Gift size={21}/></div>{error&&<p role="alert">{error.message}</p>}<div className="quest-grid">{quests.map(q=><article className="panel quest-card" key={q.id}><h3>{q.name}</h3><p className="muted">{q.description}</p><div className="progress"><i style={{width:`${Math.min(q.progress/q.target*100,100)}%`}}/></div><small>{Math.min(q.progress,q.target)} / {q.target} · {q.reward>0&&`${credits(q.reward)} crédits`}{q.reward_chest_id&&<> {q.reward>0?' + ':''}{q.reward_chest_count??1} coffre(s) {q.reward_chest_name??'scellé(s)'}</>}</small><button className="btn secondary" disabled={busy||q.claimed||q.progress<q.target} onClick={()=>void command('ct_claim_quest',{p_quest_id:q.id})}>{q.claimed?<><Check size={14}/> Récompense reçue</>:'Récupérer la récompense'}</button></article>)}</div></section>;
}
