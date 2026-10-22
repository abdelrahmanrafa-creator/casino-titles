import {createClient} from '@supabase/supabase-js';
export const supabase=createClient(import.meta.env.VITE_SUPABASE_URL,import.meta.env.VITE_SUPABASE_ANON_KEY);
export class RpcFailure extends Error {
 constructor(message:string,public definitive:boolean){super(message);}
}
export async function rpc<T>(name:string,args:Record<string,unknown>={}):Promise<T>{
 const {data,error}=await supabase.rpc(name,args);
 if(error)throw new RpcFailure(error.message,Boolean(error.code)&&!error.code.startsWith('08'));
 return data as T;
}
export async function tableRequest<T>(body:Record<string,unknown>):Promise<T>{
 const {data:{session}}=await supabase.auth.getSession();
 if(!session)throw new RpcFailure('Connexion requise.',true);
 let response:Response;
 try{response=await fetch(`${import.meta.env.VITE_SUPABASE_URL}/functions/v1/ct-tables`,{method:'POST',headers:{Authorization:`Bearer ${session.access_token}`,apikey:import.meta.env.VITE_SUPABASE_ANON_KEY,'Content-Type':'application/json'},body:JSON.stringify(body)});}
 catch{throw new RpcFailure('Connexion interrompue. Reprenez la même opération.',false);}
 const data=await response.json().catch(()=>{throw new RpcFailure('Réponse serveur interrompue.',false);}) as T&{error?:string;definitive?:boolean};
 if(!response.ok)throw new RpcFailure(data.error??'Table indisponible.',data.definitive===true);
 return data;
}
export interface Title {id:string;name:string;rarity:number;description:string;effect:string;acquisition:string;shop_price:number|null;available:boolean;exclusive:boolean}
export interface Chest {id:number;name:string;price:number;weights:number[];active:boolean;version:number;rarity:number;category:'standard'|'event';description:string;starts_at:string|null;ends_at:string|null;base_price?:number;current_price?:number;discount_percent?:number;offer_id?:string|null;offer_name?:string|null;offer_ends_at?:string|null;remaining_stock?:number|null;available?:boolean}
export interface Owned {id:string;title_id:string;source:string;acquired_at:string}
export interface Wallet {balance:number;version:number}
export interface Receipt {id:string;amount:number;reason:string;balance_after:number;created_at:string;wallet_version:number}
export interface Snapshot {wallet:Wallet;transactions:Receipt[];daily_claimed:boolean;next_daily_at:string;server_time:string;inventory:Owned[];equipped_id:string|null;purchases:string[];openings:{id:string;chest_id:number;player_title_id:string;created_at:string}[]}
export interface Award {title:Title;player_title_id:string;opening_id?:string;balance:number;chest_id?:number}
export const rarityNames=['COMMUN','RARE','ÉPIQUE','LÉGENDAIRE','MYTHIQUE','RAINBOW','XTREM','COSMIQUE'];
export const colors=['#a1a1aa','#60a5fa','#b47aff','#f5b85a','#3ce0cc','#f0abfc','#ffca36','#b6a1ff'];
export const credits=(n:number)=>new Intl.NumberFormat('fr-FR').format(n);
