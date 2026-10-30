import {useState} from 'react';
import {ChestArt} from './ChestArt';
import {ChestOdds} from './ChestOdds';
import {RarityBadge} from './MarketItemVisual';
import {SettingsDialog} from '../features/SettingsActions';
import {credits} from '../lib/api';
import {locale} from '../i18n/store';
export type ChestSnapshot={id:string;chest_id?:number;name:string;rarity:number;weights:number[];reserved:boolean;edition_number?:number|null;event_key?:string|null;created_at?:string;purchase_price?:number;pool_key?:string;custom_pool?:boolean;pool_size?:number|null};
export function ChestCharacteristics({copies,onClose}:{copies:ChestSnapshot[];onClose:()=>void}){
 return <SettingsDialog title="Caractéristiques du coffre" onClose={onClose}><ChestCharacteristicsContents copies={copies}/></SettingsDialog>;
}
export function ChestCharacteristicsContents({copies}:{copies:ChestSnapshot[]}){
 const [id,setId]=useState(copies[0]?.id);const c=copies.find(c=>c.id===id)??copies[0];if(!c)return null;
 return <><div className="purchase-heading"><ChestArt rarity={c.rarity} name={c.name}/><div><RarityBadge rarity={c.rarity}/><h3>{c.name}</h3><p>{copies.length} exemplaire(s) dans cette pile</p>{c.event_key&&<span className="edition-badge">Édition événement</span>}</div></div>{copies.length>1&&<label>Choisir un exemplaire<select value={c.id} onChange={e=>setId(e.target.value)}>{copies.map((s,i)=><option key={s.id} value={s.id}>#{s.edition_number?String(s.edition_number).padStart(3,'0'):i+1} · {s.reserved?'Réservé à un échange':'Prêt à ouvrir'}</option>)}</select></label>}<dl className="chest-characteristics"><div><dt>État</dt><dd>{c.reserved?'Réservé à un échange':'Prêt à ouvrir'}</dd></div>{c.edition_number&&<div><dt>Numéro d’édition</dt><dd translate="no">#{String(c.edition_number).padStart(3,'0')}</dd></div>}{c.created_at&&<div><dt>Ajouté le</dt><dd>{new Date(c.created_at).toLocaleString(locale())}</dd></div>}{c.purchase_price!==undefined&&<div><dt>Prix enregistré</dt><dd>{credits(c.purchase_price)} crédits</dd></div>}{c.custom_pool&&<div><dt>Contenu enregistré</dt><dd>{c.pool_size??0} titre(s) dans la sélection personnalisée</dd></div>}</dl><p className="legal">Ces probabilités sont celles enregistrées sur ce coffre. Elles restent consultables même si le coffre est réservé ou si la boutique change.</p><ChestOdds weights={c.weights}/><details><summary>Identifiant de l’exemplaire</summary><code translate="no" style={{overflowWrap:'anywhere'}}>{c.id}</code></details></>;
}
