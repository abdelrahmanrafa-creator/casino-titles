import {useState} from 'react';
import {useQuery} from '@tanstack/react-query';
import {Link,useParams} from 'react-router-dom';
import {rpc,credits,type Title} from '../lib/api';
import {TitleEffect} from '../components/TitleEffect';
interface RankedPlayer {id:string;username:string;avatar:string;score:number;equipped_title:Title|null}
export function Rankings(){
 const [metric,setMetric]=useState('credits'),[period,setPeriod]=useState('all');
 const {data:players=[],error}=useQuery({queryKey:['rankings',metric,period],queryFn:()=>rpc<RankedPlayer[]>('ct_rankings',{p_metric:metric,p_period:period}),refetchInterval:60000});
 return <><div className="page-heading"><p className="eyebrow">LE TABLEAU D’HONNEUR</p><h1>Les signatures du sommet.</h1><p className="muted">Classements établis exclusivement à partir des opérations enregistrées sur le serveur. La semaine commence le lundi à 00 h UTC.</p></div><div className="filters"><select aria-label="Classement" value={metric} onChange={e=>setMetric(e.target.value)}>{[['credits','Crédits'],['wins','Victoires solo'],['titles','Titres uniques'],['chests','Coffres ouverts'],['cosmic','Titres Cosmiques']].map(([v,l])=><option key={v} value={v}>{l}</option>)}</select><select aria-label="Période" value={period} onChange={e=>setPeriod(e.target.value)}><option value="all">Permanent</option><option value="week">Cette semaine</option></select></div>{period==='week'&&metric==='credits'&&<p className="legal">Crédits hebdomadaires : variation nette du portefeuille sur la semaine, récompenses et dépenses comprises.</p>}{error&&<p className="notice">{error.message}</p>}<div className="rank-list panel">{players.map((p,i)=><Link to={`/players/${p.id}`} key={p.id}><span className={`rank-number rank-${i+1}`}>{String(i+1).padStart(2,'0')}</span><span className="avatar">{p.avatar}</span><div><strong>{p.username}</strong>{p.equipped_title?<TitleEffect title={p.equipped_title}/>:<small>Collectionneur du cercle</small>}</div><b>{credits(p.score)}</b><span>↗</span></Link>)}{!players.length&&!error&&<p className="muted">Le cercle attend ses premiers collectionneurs.</p>}</div></>;
}
export function PublicProfile(){
 const {id}=useParams();const {data:player,error}=useQuery({queryKey:['public-profile',id],queryFn:()=>rpc<{username:string;avatar:string;created_at:string;unique_titles:number;equipped_title:Title|null}|null>('ct_public_profile',{p_user_id:id})});
 return <section className="panel profile-panel">{error?<p className="notice">{error.message}</p>:!player?<p className="muted">Profil indisponible.</p>:<><span className="avatar large">{player.avatar}</span><h2>{player.username}</h2>{player.equipped_title&&<TitleEffect large title={player.equipped_title}/>}<p>{player.unique_titles} titres uniques · Membre depuis le {new Date(player.created_at).toLocaleDateString('fr-FR')}</p><Link className="btn secondary" to="/rankings">Voir les classements</Link></>}</section>;
}
