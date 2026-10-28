export function poolPullPoint(x:number,y:number,rotated:boolean){return {main:rotated?-x:y,cross:rotated?y:x};}
export function poolPullGesture(startMain:number,startCross:number,x:number,y:number,width:number,height:number,rotated:boolean){
 const point=poolPullPoint(x,y,rotated),distance=point.main-startMain,crossDistance=Math.abs(point.cross-startCross),length=rotated?width:height;
 const ratio=Math.max(0,Math.min(1,distance/Math.max(50,length*.7)));
 return {distance,crossDistance,cancelled:crossDistance>(rotated?height:width)*2.5,power:Math.max(5,Math.round(100*Math.pow(ratio,1.25))),ratio};
}
