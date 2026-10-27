import {useId} from 'react';
import type {RollingBall} from '../lib/poolRolling';
const shades=['#f9f7ed','#f6bd24','#2168bf','#d72c3b','#7139af','#e7761c','#147c57','#8c203e','#10141c','#f6bd24','#2168bf','#d72c3b','#7139af','#e7761c','#147c57','#8c203e'];
export function PoolBall({ball,white}:{ball:RollingBall;white:{x:number;y:number}}){
 const id='ball'+useId().replace(/[^a-zA-Z0-9]/g,'');if(ball.out)return null;
 const p=ball.n===0?white:ball,phase=ball.roll??0,heading=(ball.heading??0)*180/Math.PI,px=Math.sin(phase)*5.2,py=Math.cos(phase)*2.4-2.4,sink=ball.sink??0,scale=1-sink*.8;
 const tx=ball.trailX??0,ty=ball.trailY??0,len=Math.hypot(tx,ty),trailScale=Math.min(1,18/Math.max(1,len));
 return <g className="pool-rolling-ball" transform={`translate(${p.x},${p.y})`} opacity={1-sink*.9} pointerEvents="none">
  <defs><radialGradient id={id+'-shade'} cx="32%" cy="25%" r="78%"><stop stopColor="#fff" stopOpacity=".52"/><stop offset=".38" stopColor="#fff" stopOpacity=".02"/><stop offset=".72" stopColor="#000" stopOpacity=".14"/><stop offset="1" stopColor="#000" stopOpacity=".78"/></radialGradient><clipPath id={id+'-clip'}><circle r="10.9"/></clipPath></defs>
  {len>3&&<path className="pool-speed-trail" d={`M0 0l${-tx*trailScale} ${-ty*trailScale}`} stroke={shades[ball.n]} strokeWidth="16" strokeLinecap="round" opacity=".13"/>}
  <g transform={`scale(${scale})`}>
   <ellipse cx="2" cy="4" rx="12.2" ry="10.5" fill="#000" opacity=".22"/><ellipse cx="1" cy="2" rx="11" ry="10.2" fill="#000" opacity=".3"/>
   <circle r="11" fill={ball.n>8?'#f9f7e9':shades[ball.n]}/>
   <g clipPath={`url(#${id}-clip)`}><g transform={`rotate(${heading+phase*23})`}>{ball.n>8&&<><rect x="-13" y="-6.7" width="26" height="13.4" rx="3" fill={shades[ball.n]}/><path d="M-12-6.4h24M-12 6.4h24" stroke="#ffffff" strokeOpacity=".16" strokeWidth=".5"/></>}</g>
    {ball.n>0?<g transform={`translate(${px},${py}) rotate(${Math.sin(phase)*24})`}><circle r="5.6" fill="#fff9eb" stroke="#332c22" strokeOpacity=".18" strokeWidth=".45"/><text textAnchor="middle" dominantBaseline="central" fill="#161820" fontFamily="Arial,sans-serif" fontSize={ball.n>9?6.4:7.5} fontWeight="800">{ball.n}</text>{(ball.n===6||ball.n===9)&&<path d="M-1.7 3.4h3.4" stroke="#161820" strokeWidth=".5"/>}</g>:<g transform={`rotate(${phase*45})`}>{[0,120,240].map(a=><circle key={a} cx={Math.cos(a*Math.PI/180)*6} cy={Math.sin(a*Math.PI/180)*6} r=".8" fill="#ac2836" opacity=".7"/>)}</g>}
   </g>
   <circle r="11" fill={`url(#${id}-shade)`}/>
   <path d="M-7-5q2-4 7-3" fill="none" stroke="#fff" strokeWidth="1.5" strokeLinecap="round" opacity=".7"/>
   <ellipse cx="-3.2" cy="-4.9" rx="3.1" ry="1.2" transform="rotate(-25)" fill="#fff" opacity=".4"/>
   <path d="M3.5 8q3-1 4-4" stroke="#b5f7e4" strokeWidth=".8" opacity=".3" fill="none"/>
   <circle r="10.8" fill="none" stroke="#fff" strokeOpacity=".13" strokeWidth=".5"/>
  </g>
 </g>;
}
