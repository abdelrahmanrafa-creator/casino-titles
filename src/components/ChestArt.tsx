import type {CSSProperties} from 'react';
import {colors} from '../lib/api';
export function ChestArt({rarity=1,open=false,name=''}:{rarity?:number;open?:boolean;name?:string}){
 const halloween=name.toLowerCase().includes('halloween');
 return <div className={`chest-art ${open?'chest-open':''} chest-${rarity} ${halloween?'chest-halloween':''}`} style={{'--chest-color':halloween?'#ff9138':colors[rarity-1]} as CSSProperties} aria-hidden="true">
  <div className="chest-glow"/><div className="chest-lid"><i/><i/></div><div className="chest-body"><i/><i/></div><div className="chest-lock">{halloween?'🎃':'✦'}</div>{halloween&&<><span className="halloween-bat bat-one">🦇</span><span className="halloween-bat bat-two">🦇</span><div className="halloween-web"/><span className="halloween-candle">✧</span></>}
 </div>;
}
