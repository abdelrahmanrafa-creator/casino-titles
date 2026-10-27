// Vector materials stay crisp at fullscreen and do not require a GPU-heavy filter.
export function PoolFinish(){return <g pointerEvents="none" aria-hidden="true">
 <defs>
  <linearGradient id="pool-brass" x2="0" y2="1"><stop stopColor="#f7dfaa"/><stop offset=".42" stopColor="#a68049"/><stop offset=".6" stopColor="#f4d69a"/><stop offset="1" stopColor="#5e4229"/></linearGradient>
  <linearGradient id="pool-cushion" x2="0" y2="1"><stop stopColor="#56bda3" stopOpacity=".55"/><stop offset=".3" stopColor="#153a35" stopOpacity=".3"/><stop offset="1" stopColor="#001f1b" stopOpacity=".9"/></linearGradient>
  <radialGradient id="pool-lamp"><stop stopColor="#e5ffcb" stopOpacity=".15"/><stop offset=".65" stopColor="#c8ffe5" stopOpacity=".025"/><stop offset="1" stopColor="#001610" stopOpacity=".38"/></radialGradient>
  <radialGradient id="pool-pocket-depth" cx=".5" cy=".25"><stop stopColor="#18211f"/><stop offset=".5" stopColor="#040707"/><stop offset="1" stopColor="#000"/></radialGradient>
  <pattern id="pool-net" width="8" height="8" patternUnits="userSpaceOnUse"><path d="M0 0l8 8M8 0L0 8" stroke="#bfa77d" strokeOpacity=".1" strokeWidth=".6"/></pattern>
 </defs>
 <rect width="1000" height="500" rx="12" fill="url(#pool-lamp)"/>
 <path d="M250 20v460M250 170a80 80 0 0 0 0 160" fill="none" stroke="#d8efcf" strokeOpacity=".12" strokeWidth="1"/>
 {[250,750].map(x=><circle key={x} cx={x} cy="250" r="2.5" fill="#dbecd5" opacity=".4"/>)}
 {/* Six separate cushions leave the mouths of the pockets visible. */}
 {[false,true].flatMap(bottom=>[30,530].map(x=><g key={x+':'+bottom} transform={bottom?'translate(1000 500) rotate(180)':undefined}><path d={`M${x} -17h440l-14 30h-412z`} fill="url(#pool-cushion)"/><path d={`M${x+14} 13h412`} stroke="#8edcc0" strokeOpacity=".3" strokeWidth="1.3"/></g>))}
 {[false,true].map(right=><g key={String(right)} transform={right?'translate(1000 500) rotate(180)':undefined}><path d="M-17 30v440l30-14V44z" fill="url(#pool-cushion)"/><path d="M13 44v412" stroke="#8edcc0" strokeOpacity=".3" strokeWidth="1.3"/></g>)}
 {[[0,0],[500,0],[1000,0],[0,500],[500,500],[1000,500]].map(([x,y])=><g key={x+':'+y}>
  <circle cx={x} cy={y} r="28" fill="none" stroke="url(#pool-brass)" strokeWidth="5"/>
  <circle cx={x} cy={y} r="24" fill="url(#pool-pocket-depth)"/>
  <circle cx={x} cy={y+4} r="17" fill="url(#pool-net)"/>
  <path d={`M${x-17} ${y-12}q17-13 34 0`} fill="none" stroke="#ffffff" strokeOpacity=".12" strokeWidth="1"/>
 </g>)}
 {[125,250,375].flatMap(y=>[-35,1035].map(x=><path key={x+':'+y} d={`M${x} ${y-4}l4 4-4 4-4-4z`} fill="#d9c7a0"/>))}
 <rect x="-43" y="-43" width="1086" height="586" rx="30" fill="none" stroke="#f7e3b6" strokeOpacity=".16"/>
 <rect x="-49" y="-43" width="1098" height="591" rx="35" fill="none" stroke="#000" strokeOpacity=".3" strokeWidth="5"/>
 </g>;}

export function PoolCue({power}:{power:number}){return <g transform={`translate(${-38-power*.25} 0)`}>
 <path d="M-267 4L-2 1" stroke="#000" strokeOpacity=".4" strokeWidth="8" strokeLinecap="round"/>
 <path d="M-260 0L-8 0" stroke="#442c23" strokeWidth="10" strokeLinecap="round"/>
 <path d="M-177-4L-10-2V2L-177 4z" fill="#d9b77d"/>
 <path d="M-176-2L-12-1" stroke="#fff1c4" strokeWidth="1.5"/>
 <path d="M-245 0h65" stroke="#151f23" strokeWidth="10"/>
 {Array.from({length:17},(_,i)=><path key={i} d={`M${-242+i*3.5} -4l2 8`} stroke="#d9c09b" strokeOpacity=".2"/>)}
 <path d="M-177 0h5M-249 0h4" stroke="#d9d0ad" strokeWidth="10"/>
 <path d="M-10 0h7" stroke="#fff1d7" strokeWidth="5"/><path d="M-3 0h4" stroke="#78c5d8" strokeWidth="5"/>
 </g>;}
