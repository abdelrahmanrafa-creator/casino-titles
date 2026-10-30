// DEV-only interactive fixture. No accounts, inventory or wallets are changed.
import {useMemo,useRef,useState} from 'react';
import {QueryClient,QueryClientProvider} from '@tanstack/react-query';
import {TradeRoom,type TradeWorkspace} from './DirectTrades';
import {ChestCharacteristics} from '../components/ChestCharacteristics';
import {LanguageSettings} from '../components/LanguageSettings';
export default function TradePreview(){
 const client=useMemo(()=>new QueryClient({defaultOptions:{queries:{retry:false,staleTime:Infinity}}}),[]),[viewer,setViewer]=useState('qa-a'),[details,setDetails]=useState(false);
 const room=useRef<TradeWorkspace>({id:'qa-trade',status:'open',version:2,a:'qa-a',b:'qa-b',other_username:'Nova',a_name:'Azb',b_name:'Nova',a_diamonds:0,b_diamonds:80,a_confirmed:false,b_confirmed:false,my_balance:2000,my_reserved:0,expires_at:new Date(Date.now()+1800000).toISOString(),max_items:1000,groups:[],offers:[{key:'rare-title',kind:'title',name:'Novice du crépuscule',rarity:1,owner_id:'qa-b',available:1,quantity:1}]});
 const inventory={
  'qa-a':[{key:'mythic',kind:'chest' as const,name:'Mythique',rarity:5,available:500},{key:'rainbow',kind:'chest' as const,name:'Arc-en-ciel',rarity:6,available:108},{key:'rare-title',kind:'title' as const,name:'Novice du crépuscule',rarity:1,available:12}],
  'qa-b':[{key:'rare-title',kind:'title' as const,name:'Novice du crépuscule',rarity:1,available:6},{key:'cosmic',kind:'title' as const,name:'Nomade du vide stellaire',rarity:8,available:1}],
 };
 async function act(action:string,values:Record<string,unknown>){
  await new Promise(r=>setTimeout(r,80));const s=room.current;const mine=viewer===s.a;
  if(Number(values.version)!==s.version)return null;
  if(action==='offer_bulk'){
   s.offers=s.offers.filter(o=>o.owner_id!==viewer);
   for(const item of values.groups as {key:string;quantity:number}[]){const g=inventory[viewer as keyof typeof inventory].find(g=>g.key===item.key);if(g)s.offers.push({...g,owner_id:viewer,quantity:item.quantity});}
   if(mine)s.a_diamonds=Number(values.diamonds);else s.b_diamonds=Number(values.diamonds);s.version++;s.a_confirmed=false;s.b_confirmed=false;
  }else if(action==='confirm'){if(mine)s.a_confirmed=true;else s.b_confirmed=true;if(s.a_confirmed&&s.b_confirmed)s.status='completed';}else if(action==='cancel')s.status='cancelled';
  await client.invalidateQueries({queryKey:['trade-room']});return {ok:true,version:s.version};
 }
 return <QueryClientProvider client={client}><section className="panel"><LanguageSettings persist={false}/><button className="btn secondary" onClick={()=>setViewer(viewer==='qa-a'?'qa-b':'qa-a')}>↔ <span translate="no">{viewer==='qa-a'?'Nova':'Azb'}</span></button><button className="btn secondary" onClick={()=>setDetails(true)}>Caractéristiques du coffre</button></section>{details&&<ChestCharacteristics copies={[{id:"qa-chest-42",name:"Mythique",rarity:5,weights:[1000,1000,2000,2000,1250,500,2150,100],reserved:true,edition_number:42,purchase_price:150000,created_at:"2026-10-30T00:00:00Z",custom_pool:true,pool_size:25}]} onClose={()=>setDetails(false)}/>}<section className="panel trade-modal" style={{margin:'20px auto',maxHeight:'none'}}><TradeRoom key={viewer} userId={viewer} id="qa-trade" busy={false} act={act} load={async()=>structuredClone({...room.current,groups:inventory[viewer as keyof typeof inventory]})}/></section></QueryClientProvider>;
}
