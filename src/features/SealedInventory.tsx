import {useState} from 'react';
import {useQuery} from '@tanstack/react-query';
import {Link} from 'react-router-dom';
import {Box} from 'lucide-react';
import {rpc,rarityNames} from '../lib/api';
import {ChestArt} from '../components/ChestArt';
import type {Command} from './Games';
type Sealed={id:string;name:string;rarity:number;weights:number[];reserved:boolean};
export function SealedInventory({userId,command,busy}:{userId:string;command:Command;busy:boolean}){
 const {data:chests=[],error,refetch}=useQuery({queryKey:['sealed-inventory',userId],queryFn:()=>rpc<Sealed[]>('ct_sealed_inventory')});
 const [selected,setSelected]=useState<Sealed|null>(null);
 return <section><div className="section-title"><div><p className="eyebrow">OUVRIR QUAND VOUS VOULEZ</p><h2>Vos coffres.</h2></div><Box/></div><p className="muted">Gardez vos coffres, ouvrez-les plus tard ou proposez-les contre des diamants et des objets.</p>{error&&<p role="alert">{error.message}<button className="btn secondary" onClick={()=>void refetch()}>Réessayer</button></p>}<div className="market-grid">{chests.map(c=><article className="panel market-card" key={c.id}><ChestArt rarity={c.rarity}/><h3>{c.name}</h3><small>#{c.id.slice(-4)} · {c.reserved?'Réservé à un échange':'Prêt à ouvrir'}</small><button className="btn primary" disabled={busy||c.reserved} onClick={()=>setSelected(c)}>Ouvrir ce coffre</button>{!c.reserved&&<Link className="btn secondary" to={`/market?asset=${c.id}`}>Vendre ou échanger</Link>}</article>)}</div>{!chests.length&&!error&&<p className="muted">Aucun coffre en réserve. Achetez-en à la boutique ou gagnez-en avec les quêtes.</p>}<Link className="text-btn" to="/chests">Acheter un coffre ↗</Link>{selected&&<div className="modal-backdrop"><section className="modal panel" role="dialog" aria-modal="true" aria-label="Ouvrir un coffre"><button className="close-btn" onClick={()=>setSelected(null)} aria-label="Fermer">×</button><h2>{selected.name}</h2><p>Un titre sera ajouté à votre collection. L’ouverture ne coûte aucun crédit supplémentaire.</p>{selected.weights.map((w,i)=>w>0&&<p key={i}>{rarityNames[i]} : {w/100}%</p>)}<button className="btn primary" disabled={busy} onClick={async()=>{const r=await command('ct_market_command',{p_action:'open_sealed',p_values:{asset_id:selected.id}});if(r){setSelected(null);await refetch();}}}>Confirmer l’ouverture</button></section></div>}</section>;
}
