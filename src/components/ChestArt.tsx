import type {CSSProperties} from 'react';
import {colors} from '../lib/api';
export function ChestArt({rarity=1,open=false}:{rarity?:number;open?:boolean}){
 return <div className={`chest-art ${open?'chest-open':''} chest-${rarity}`} style={{'--chest-color':colors[rarity-1]} as CSSProperties} aria-hidden="true">
  <div className="chest-glow"/><div className="chest-lid"><i/><i/></div><div className="chest-body"><i/><i/></div><div className="chest-lock">✦</div>
 </div>;
}
