export type Language='fr'|'en';
const listeners=new Set<()=>void>();let language:Language='fr';let revision=0;
try{language=localStorage.getItem('ct:language')==='en'?'en':'fr';}catch{/* Storage is optional. */}
export const getLanguage=()=>language;
export const getLanguageRevision=()=>revision;
export const locale=()=>language==='en'?'en-GB':'fr-FR';
export function setLanguage(next:Language){if(next!=='fr'&&next!=='en')return;language=next;revision++;try{localStorage.setItem('ct:language',next);}catch{/* Continue in memory. */}if(typeof document!=='undefined')document.documentElement.lang=next;for(const notify of [...listeners])notify();}
export function subscribe(notify:()=>void){listeners.add(notify);return()=>{listeners.delete(notify);};}
