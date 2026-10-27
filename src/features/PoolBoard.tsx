import {rollPoolBalls} from '../lib/poolRolling';
import {samplePoolPlayback,playbackPosition} from '../lib/poolPlayback';
import {memo,useLayoutEffect,useRef,useState,type ComponentProps,type Dispatch,type SetStateAction} from 'react';
import {PoolTable} from './PoolTable';
import {poolAnimationProgress} from '../lib/poolAim';
import type {PoolMatch} from './Pool';
type Props=Omit<ComponentProps<typeof PoolTable>,'balls'|'pulse'>&{match:PoolMatch;onAnimating:Dispatch<SetStateAction<boolean>>;onSound?:(kind:string,intensity?:number)=>void};
// Only the board updates each frame; forms, queries and controls remain outside playback.
export const PoolBoard=memo(function PoolBoard({match,onAnimating,onSound,...table}:Props){
 const sound=useRef(onSound);sound.current=onSound;
 const [balls,setBalls]=useState(match.balls),[playing,setPlaying]=useState(false),[preparing,setPreparing]=useState(false),[cueStrike,setCueStrike]=useState(false),[pulse,setPulse]=useState<{x:number;y:number;key:string;kind:string}|null>(null);
 const previous=useRef<{id:string;shots:number}|null>(null),frame=useRef(0);
 useLayoutEffect(()=>{
  const before=previous.current;previous.current={id:match.id,shots:match.shots};const shot=match.last_shot;
  const reduced=document.documentElement.dataset.reducedMotion==='true'||window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  if(!before||before.id!==match.id||before.shots===match.shots||reduced||!shot?.before?.length||!shot.frames?.length||!shot.frames.every(f=>f.length===shot.before.length)){
   setBalls(match.balls);setPlaying(false);setPreparing(false);setCueStrike(false);onAnimating(false);return;
  }
  setPlaying(true);setPreparing(true);setCueStrike(false);onAnimating(true);setPulse(null);setBalls(shot.before);
  const start=performance.now()+320,frames=[shot.before.map(b=>[b.x,b.y,b.out,...(b.q??[0,0,0,1])] as [number,number,boolean,number,number,number,number]),...shot.frames],duration=shot.duration_ms?Math.max(650,Math.min(12000,shot.duration_ms)):Math.max(650,Math.min(3200,frames.length*24)),times=shot.frame_times?.length===shot.frames.length?[0,...shot.frame_times]:null;let lastStep=-1,cueSound=false;
  const tick=(time:number)=>{setCueStrike(time>=start-140&&time<start+80);if(time>=start+80)setPreparing(false);if(time>=start&&!cueSound){cueSound=true;sound.current?.('cue',shot.power/100);}const p=poolAnimationProgress(time,start,duration),pos=times?playbackPosition(p*(shot.duration_ms??duration),times):p*(frames.length-1);
   setBalls(previous=>rollPoolBalls(previous,samplePoolPlayback(shot.before,frames,pos)));
   const event=shot.events?.filter(e=>(e.time_ms??e.step)<= (times?p*(shot.duration_ms??duration):pos*8)&&(e.time_ms??e.step)>lastStep).at(-1);if(event){const key=match.id+':'+match.shots+':'+event.step;setPulse({x:event.x,y:event.y,key,kind:event.kind});sound.current?.(event.kind,event.intensity);}lastStep=times?p*(shot.duration_ms??duration):pos*8;
   if(p<1)frame.current=requestAnimationFrame(tick);else{setBalls(previous=>rollPoolBalls(previous,match.balls));setPlaying(false);onAnimating(false);}
  };frame.current=requestAnimationFrame(tick);
  return()=>{cancelAnimationFrame(frame.current);onAnimating(false);};
 // A new version without a new shot must never replay an earlier trajectory.
 // eslint-disable-next-line react-hooks/exhaustive-deps
 },[match.id,match.shots,onAnimating]);
 return <PoolTable {...table} angle={preparing?match.last_shot?.angle??table.angle:table.angle} power={preparing?match.last_shot?.power??table.power:table.power} aiming={preparing||table.aiming} striking={cueStrike||table.striking} balls={balls} white={playing?balls.find(b=>b.n===0)??table.white:table.white} pulse={playing?pulse:null}/>;
});
