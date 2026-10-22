import type {CSSProperties} from 'react';
import {ChevronRight,CalendarDays,Tag} from 'lucide-react';
import {rarityNames,colors,type Chest} from '../lib/api';
import {ChestArt} from './ChestArt';
import {PriceTag} from './PriceTag';
export function ShopChests({chests,onOpen}:{chests:Chest[];onOpen:(chest:Chest)=>void}){
 return <div className="chest-grid">{chests.map(chest=><article className={`chest-card panel ${chest.category==='event'?'event-chest':''}`} key={chest.id} style={{'--accent':colors[(chest.rarity??1)-1]} as CSSProperties}>
  <div className="chest-labels"><span className="rarity-label">{rarityNames[(chest.rarity??1)-1]}</span>{chest.category==='event'&&<span className="event-badge"><CalendarDays size={11}/>ÉVÉNEMENT</span>}</div>
  <ChestArt rarity={chest.rarity??1}/><h3>{chest.name}</h3><p className="muted">{chest.description}</p>
  {chest.offer_id&&<p className="chest-offer-name"><Tag size={12}/>{chest.offer_name}</p>}
  <PriceTag base={chest.base_price??chest.price} current={chest.current_price??chest.price}/>
  {chest.offer_ends_at&&<small className="stock-note">Offre jusqu’au {new Date(chest.offer_ends_at).toLocaleString('fr-FR')}</small>}
  {chest.ends_at&&<small className="stock-note">Coffre jusqu’au {new Date(chest.ends_at).toLocaleString('fr-FR')}</small>}
  {chest.starts_at&&new Date(chest.starts_at).getTime()>Date.now()&&<small className="stock-note">Disponible le {new Date(chest.starts_at).toLocaleString('fr-FR')}</small>}
  {chest.remaining_stock!==null&&chest.remaining_stock!==undefined&&<small className="stock-note">{chest.remaining_stock} coffre(s) restant(s)</small>}
  <button className="text-btn odds-btn" onClick={()=>onOpen(chest)}>Voir les probabilités <ChevronRight size={13}/></button>
  <button className="btn chest-buy" disabled={chest.available===false} onClick={()=>onOpen(chest)}>{chest.available===false?'Indisponible actuellement':<>Découvrir ce coffre <span>Ouvrir ↗</span></>}</button>
 </article>)}</div>;
}
