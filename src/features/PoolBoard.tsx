import {memo,useLayoutEffect,useRef,useState,type ComponentProps,type Dispatch,type SetStateAction} from 'react';
import {PoolTable} from './PoolTable';
import {poolAnimationProgress} from '../lib/poolAim';
import type {PoolMatch} from './Pool';
type Props=Omit<ComponentProps<typeof PoolTable>,'balls'|'pulse'>&{match:PoolMatch;onAnimating:Dispatch<SetStateAction<boolean>>};
// Only the board updates each frame; forms, queries and controls remain outside playback.
export const PoolBoard=memo(function PoolBoard({match,onAnimating,...table}:Props){
 const [balls,setBalls]=useState(match.balls),[playing,setPlaying]=useState(false),[preparing,setPreparing]=useState(false),[pulse,setPulse]=useState<{x:number;y:number;key:string;kind:string}|null>(null);
 const previous=useRef<{id:string;shots:number}|null>(null),frame=useRef(0);
 useLayoutEffect(()=>{
  const before=previous.current;previous.current={id:match.id,shots:match.shots};const shot=match.last_shot;
  const reduced=document.documentElement.dataset.reducedMotion==='true'||window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  if(!before||before.id!==match.id||before.shots===match.shots||reduced||!shot?.before?.length||!shot.frames?.length||!shot.frames.every(f=>f.length===shot.before.length)){
   setBalls(match.balls);setPlaying(false);setPreparing(false);onAnimating(false);return;
  }
  const aiCue=match.ai&&shot.actor===1;setPlaying(true);setPreparing(aiCue);onAnimating(true);setPulse(null);setBalls(shot.before);
  const start=performance.now()+(aiCue?220:0),frames=[shot.before.map(b=>[b.x,b.y,b.out] as [number,number,boolean]),...shot.frames],duration=Math.max(650,Math.min(3200,frames.length*24));let lastEvent='';
  const tick=(time:number)=>{if(time>=start)setPreparing(false);const p=poolAnimationProgress(time,start,duration),pos=p*(frames.length-1),i=Math.floor(pos),a=frames[i],b=frames[Math.min(i+1,frames.length-1)],blend=pos-i;
   setBalls(shot.before.map((ball,n)=>({...ball,x:a[n][0]+(b[n][0]-a[n][0])*blend,y:a[n][1]+(b[n][1]-a[n][1])*blend,out:a[n][2]})));
   const event=shot.events?.find(e=>e.step<=pos*8&&e.step>pos*8-12);if(event){const key=match.id+':'+match.shots+':'+event.step;if(lastEvent!==key){lastEvent=key;setPulse({x:event.x,y:event.y,key,kind:event.kind});}}
   if(p<1)frame.current=requestAnimationFrame(tick);else{setBalls(match.balls);setPlaying(false);onAnimating(false);}
  };frame.current=requestAnimationFrame(tick);
  return()=>{cancelAnimationFrame(frame.current);onAnimating(false);};
 // A new version without a new shot must never replay an earlier trajectory.
 // eslint-disable-next-line react-hooks/exhaustive-deps
 },[match.id,match.shots,onAnimating]);
 return <PoolTable {...table} angle={preparing?match.last_shot?.angle??table.angle:table.angle} power={preparing?match.last_shot?.power??table.power:table.power} aiming={preparing||table.aiming} striking={preparing||table.striking} balls={balls} white={playing?balls.find(b=>b.n===0)??table.white:table.white} pulse={playing?pulse:null}/>;
});
