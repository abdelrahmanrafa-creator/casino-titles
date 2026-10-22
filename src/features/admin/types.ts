import type {Chest} from '../../lib/api';
export interface AdminChest extends Chest {stock_used:number;stock_limit:number|null;per_player_limit:number|null;starts_at:string|null;ends_at:string|null;title_pool:string[]|null;allow_exclusive:boolean}
export interface Offer {id:string;chest_id:number;name:string;sale_price:number;starts_at:string;ends_at:string;active:boolean;stock_limit:number|null;stock_used:number;per_player_limit:number|null}
export interface EventDefinition {id:string;name:string;description:string;starts_at:string;ends_at:string;active:boolean;reward:number;title_id:string|null;kind:string;target:number}
export interface QuestDefinition {id:string;name:string;description:string;kind:string;target:number;reward:number;active:boolean}
export interface GameControl {game:string;active:boolean;min_bet:number;max_bet:number}
export interface Player {id:string;username:string;balance:number;suspended:boolean}
export interface Audit {id:string;action:string;target:string;reason:string;created_at:string;admin_id:string;details:Record<string,unknown>}
export interface Rules {dealer_hits_soft17:boolean;natural_numerator:number;natural_denominator:number;max_hands:number;double_after_split:boolean}
export interface Dashboard {overview:{players:number;credits:number;rounds:number;chests:number;results:Player[];audit:Audit[]};chests:AdminChest[];offers:Offer[];events:EventDefinition[];quests:QuestDefinition[];rules:Rules;controls:GameControl[];rarities:{id:number;name:string;color:string}[];admins:{id:string;username:string}[];security:{session_minutes:number;session_expires_at:string}}
export const localDate=(value:string|null)=>{if(!value)return '';const date=new Date(value);return new Date(date.getTime()-date.getTimezoneOffset()*60000).toISOString().slice(0,16);};
export const isoDate=(value:string)=>value?new Date(value).toISOString():null;
export const optionalNumber=(value:string)=>value===''?null:Number(value);
