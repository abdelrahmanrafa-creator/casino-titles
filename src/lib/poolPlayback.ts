import type {RollingBall} from './poolRolling';
export type PoolFrame=[number,number,boolean,number?,number?,number?,number?][];
type Frame=PoolFrame;
// Interpolate only the server's path. Pocketing is a visual effect, never a new result.
export function samplePoolPlayback(before:RollingBall[],frames:Frame[],position:number):RollingBall[]{
 const p=Math.max(0,Math.min(frames.length-1,position)),i=Math.floor(p),a=frames[i],b=frames[Math.min(i+1,frames.length-1)],t=p-i;
 if(!a||!b)return before;
 return before.map((ball,n)=>{if(!a[n]||!b[n])return ball;const sinking=!a[n][2]&&b[n][2];return {...ball,x:a[n][0]+(b[n][0]-a[n][0])*t,y:a[n][1]+(b[n][1]-a[n][1])*t,out:a[n][2],q:a[n].length>=7&&b[n].length>=7?([3,4,5,6].map(k=>(a[n][k] as number)+((b[n][k] as number)-(a[n][k] as number))*t) as [number,number,number,number]):ball.q,sink:sinking?t:0,trailX:(b[n][0]-a[n][0])*.1,trailY:(b[n][1]-a[n][1])*.1};});
}

export function playbackPosition(elapsed:number,times:number[]){if(times.length<2)return 0;let lo=0,hi=times.length-1;while(lo<hi){const mid=Math.ceil((lo+hi)/2);if(times[mid]<=elapsed)lo=mid;else hi=mid-1;}return Math.min(times.length-1,lo+Math.max(0,Math.min(1,(elapsed-times[lo])/Math.max(1,(times[lo+1]??times[lo])-times[lo]))));}
