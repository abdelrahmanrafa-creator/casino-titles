import {useState} from 'react';
import {useQuery} from '@tanstack/react-query';
import {Link} from 'react-router-dom';
import {Search,Users} from 'lucide-react';
import {rpc,type Title} from '../lib/api';
import {TitleEffect} from '../components/TitleEffect';
interface Person {id:string;username:string;avatar:string;unique_titles:number;equipped_title:Title|null}
export function People({compact=false}:{compact?:boolean}){
 const [search,setSearch]=useState(''),[query,setQuery]=useState('');
 const {data:players=[],isFetching,error}=useQuery({queryKey:['people',query],queryFn:()=>rpc<Person[]>('ct_find_players',{p_search:query}),enabled:query.length>=2});
 return <section className={`panel people-panel ${compact?'people-compact':''}`}><div className="section-title"><div><p className="eyebrow">LES VISAGES DU CERCLE</p><h2>Retrouvez un collectionneur.</h2></div><Users size={22}/></div><p className="muted">Cherchez un pseudo pour découvrir son profil, sa signature et les titres qu’il possède.</p><form className="people-search" onSubmit={e=>{e.preventDefault();setQuery(search.trim());}}><label className="search"><Search size={17}/><input aria-label="Rechercher un joueur par pseudo" placeholder="Pseudo du joueur…" minLength={2} maxLength={32} required value={search} onChange={e=>setSearch(e.target.value)}/></label><button className="btn secondary" disabled={isFetching}>{isFetching?'Recherche…':'Rechercher'}</button></form>{error&&<p className="notice">{error.message}</p>}<div className="people-results">{players.map(p=><Link to={`/players/${p.id}`} key={p.id}><span className="avatar">{p.avatar}</span><div><strong>{p.username}</strong>{p.equipped_title?<TitleEffect title={p.equipped_title}/>:<small>Aucun titre équipé</small>}<small>{p.unique_titles} titres uniques</small></div><span>Voir le profil ↗</span></Link>)}</div>{query.length>=2&&!isFetching&&!error&&!players.length&&<p role="status" className="muted">Aucun joueur trouvé pour « {query} ».</p>}{players.length===30&&<p className="legal">30 résultats affichés. Précisez le pseudo pour affiner la recherche.</p>}</section>;
}
