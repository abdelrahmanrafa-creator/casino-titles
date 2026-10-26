import {createContext,useContext,type InputHTMLAttributes,type ReactNode} from 'react';
const OwnerContext=createContext(false);
export function OwnerScope({enabled,children}:{enabled:boolean;children:ReactNode}){return <OwnerContext.Provider value={enabled}>{children}</OwnerContext.Provider>;}
export function AdminInput({'data-owner-fixed':fixed,...props}:InputHTMLAttributes<HTMLInputElement>&{'data-owner-fixed'?:boolean}){const owner=useContext(OwnerContext),max=Number(props.max),min=Number(props.min),lift=!fixed&&props.type==='number'&&Number.isFinite(max)&&(max>100||max===5);return <input {...props} max={owner&&lift?(max===5?2147483647:Number(props.step)===0.01?90000000000:9000000000000):props.max} min={owner&&!fixed&&props.type==='number'&&min<=-1000?-9000000000000:props.min}/>;}
