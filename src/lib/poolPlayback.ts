import type {RollingBall} from './poolRolling';
type Frame=[number,number,boolean][];
// Interpolate only the server's path. Pocketing is a visual effect, never a new result.
export function samplePoolPlayback(before:RollingBall[],frames:Frame[],position:number):RollingBall[]{
 const p=Math.max(0,Math.min(frames.length-1,position)),i=Math.floor(p),a=frames[i],b=frames[Math.min(i+1,frames.length-1)],t=p-i;
 if(!a||!b)return before;
 return before.map((ball,n)=>{if(!a[n]||!b[n])return ball;const sinking=!a[n][2]&&b[n][2];return {...ball,x:a[n][0]+(b[n][0]-a[n][0])*t,y:a[n][1]+(b[n][1]-a[n][1])*t,out:a[n][2],sink:sinking?t:0,trailX:(b[n][0]-a[n][0])*.1,trailY:(b[n][1]-a[n][1])*.1};});
}
