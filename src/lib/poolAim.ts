export type PoolPoint={x:number;y:number};
export type PoolBall=PoolPoint&{n:number;out:boolean};
export type PoolSpin={x:number;y:number};
export function poolAnimationProgress(time:number,start:number,duration:number){return Math.max(0,Math.min(1,(time-start)/Math.max(1,duration)));}
export function poolSegmentClear(balls:PoolBall[],from:PoolPoint,to:PoolPoint,ignored:number[]){const dx=to.x-from.x,dy=to.y-from.y,len=Math.max(1,dx*dx+dy*dy);return !balls.some(b=>{if(b.out||ignored.includes(b.n))return false;const t=Math.max(0,Math.min(1,((b.x-from.x)*dx+(b.y-from.y)*dy)/len));return Math.hypot(b.x-from.x-t*dx,b.y-from.y-t*dy)<23;});}
export function poolSuggestedShot(balls:PoolBall[],white:PoolPoint,group:number){
 const own=balls.filter(b=>!b.out&&(group===1?b.n>=1&&b.n<=7:group===2?b.n>=9&&b.n<=15:b.n!==0&&b.n!==8));const targets=own.length?own:balls.filter(b=>b.n===8&&!b.out);let best:{angle:number;power:number;target:number;pot:boolean;rank:number}|null=null;
 for(const b of targets){for(const [x,y] of [[0,0],[500,0],[1000,0],[0,500],[500,500],[1000,500]]){const dx=x-b.x,dy=y-b.y,len=Math.hypot(dx,dy);if(len<1)continue;const ghost={x:b.x-dx/len*22,y:b.y-dy/len*22},distance=Math.hypot(ghost.x-white.x,ghost.y-white.y);if(distance<1||ghost.x<12||ghost.x>988||ghost.y<12||ghost.y>488)continue;const cut=((b.x-ghost.x)*(ghost.x-white.x)+(b.y-ghost.y)*(ghost.y-white.y))/(22*distance);if(cut<.2||!poolSegmentClear(balls,white,ghost,[0,b.n])||!poolSegmentClear(balls,b,{x,y},[0,b.n]))continue;const rank=distance+len/cut+200*(1-cut);if(!best||rank<best.rank)best={angle:Math.atan2(ghost.y-white.y,ghost.x-white.x),power:Math.round(Math.min(100,Math.max(20,(distance+len/Math.max(.35,cut))/10+10))),target:b.n,pot:true,rank};}}
 if(best)return best;const breaking=group===0&&targets.length===14&&Math.max(...targets.map(b=>b.x))-Math.min(...targets.map(b=>b.x))<130&&Math.max(...targets.map(b=>b.y))-Math.min(...targets.map(b=>b.y))<130;for(const b of targets){const distance=Math.hypot(b.x-white.x,b.y-white.y);if(distance<1)continue;const ghost={x:b.x-(b.x-white.x)/distance*22,y:b.y-(b.y-white.y)/distance*22};if(!poolSegmentClear(balls,white,ghost,[0,b.n]))continue;if(!best||distance<best.rank)best={angle:Math.atan2(b.y-white.y,b.x-white.x),power:breaking?100:55,target:b.n,pot:false,rank:distance};}return best;
}
export function normalizeAngle(angle:number){return Math.atan2(Math.sin(angle),Math.cos(angle));}
export function clampSpin(x:number,y:number):PoolSpin{const length=Math.hypot(x,y),scale=length>1?1/length:1;return{x:x*scale,y:y*scale};}
export function cuePositionFree(balls:PoolBall[],p:PoolPoint){return p.x>=25&&p.x<=975&&p.y>=25&&p.y<=475&&!balls.some(b=>b.n!==0&&!b.out&&Math.hypot(b.x-p.x,b.y-p.y)<23);}
export function fineAim(start:number,pointerStart:number,pointerNow:number){return normalizeAngle(start+normalizeAngle(pointerNow-pointerStart)*.18);}
export type AimGuide={segments:{from:PoolPoint;to:PoolPoint}[];contact?:PoolPoint;target?:PoolBall;objectEnd?:PoolPoint;cueEnd?:PoolPoint};
export function poolAimGuide(balls:PoolBall[],white:PoolPoint,angle:number,spin:PoolSpin={x:0,y:0}):AimGuide{
 let origin={...white},direction={x:Math.cos(angle),y:Math.sin(angle)};const guide:AimGuide={segments:[]};
 for(let bounce=0;bounce<2;bounce++){
  const wallX=direction.x>1e-9?(989-origin.x)/direction.x:direction.x< -1e-9?(11-origin.x)/direction.x:Infinity;
  const wallY=direction.y>1e-9?(489-origin.y)/direction.y:direction.y< -1e-9?(11-origin.y)/direction.y:Infinity;
  let distance=Math.max(0,Math.min(wallX,wallY));let target:PoolBall|undefined;
  for(const b of balls){if(b.n===0||b.out)continue;const dx=b.x-origin.x,dy=b.y-origin.y,projection=dx*direction.x+dy*direction.y,perp=dx*dx+dy*dy-projection*projection;if(projection<=0||perp>22*22)continue;const hit=projection-Math.sqrt(Math.max(0,22*22-perp));if(hit>=0&&hit<distance){distance=hit;target=b;}}
  const end={x:origin.x+direction.x*distance,y:origin.y+direction.y*distance};guide.segments.push({from:origin,to:end});
  if(target){const nx=(target.x-end.x)/22,ny=(target.y-end.y)/22,impact=Math.max(0,direction.x*nx+direction.y*ny);guide.contact=end;guide.target=target;guide.objectEnd={x:target.x+nx*150,y:target.y+ny*150};const cx=direction.x-impact*nx+Math.cos(angle)*spin.y*.36,cy=direction.y-impact*ny+Math.sin(angle)*spin.y*.36,len=Math.hypot(cx,cy);if(len>.02)guide.cueEnd={x:end.x+cx/len*110,y:end.y+cy/len*110};break;}
  if([[0,0],[500,0],[1000,0],[0,500],[500,500],[1000,500]].some(([x,y])=>Math.hypot(end.x-x,end.y-y)<30))break;
  if(wallX<wallY){direction={x:-direction.x*.88,y:direction.y+Math.abs(direction.x)*.88*spin.x*.22*(end.x<500?-1:1)};}else{direction={x:direction.x+Math.abs(direction.y)*.88*spin.x*.22*(end.y<250?1:-1),y:-direction.y*.88};}
  const length=Math.hypot(direction.x,direction.y);direction={x:direction.x/length,y:direction.y/length};origin={x:end.x+direction.x*.01,y:end.y+direction.y*.01};
 }
 return guide;
}

export function poolCuePlayable(balls:PoolBall[],point:PoolPoint,inHand:boolean){return !inHand||cuePositionFree(balls,point);}
