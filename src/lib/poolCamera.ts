// Fit the complete table with a margin before applying intentional zoom.
export function poolCameraPose(aspect:number,tilt:number,zoom=1){
 const ratio=Math.max(.1,aspect),slope=Math.max(0,tilt),norm=Math.hypot(1,slope),tan=Math.tan(Math.PI/8);
 const distance=(Math.max(570/(tan*ratio),(320+35*slope)/(norm*tan))+(320*slope+35)/norm)*1.06/Math.max(1,zoom);
 return {height:distance/norm,depth:distance*slope/norm,distance};
}
