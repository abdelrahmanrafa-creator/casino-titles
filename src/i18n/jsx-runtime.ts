import {createContext,useContext,useSyncExternalStore,type ElementType,type ReactNode} from 'react';import {jsx as reactJsx,jsxs as reactJsxs,Fragment} from 'react/jsx-runtime';import {translateText} from './translate';import {getLanguage,subscribe} from './store';
export {Fragment};export type {JSX} from 'react/jsx-runtime';
const Translation=createContext(true);
function textChildren(value:ReactNode):ReactNode{if(typeof value==='string')return translateText(value);if(Array.isArray(value))return value.map(textChildren);return value;}
function LocalizedElement({tag,original,staticChildren=false}:{tag:ElementType;original:Record<string,unknown>;staticChildren?:boolean}){
 useSyncExternalStore(subscribe,getLanguage,()=> 'fr');const inherited=useContext(Translation);const enabled=inherited&&original.translate!=='no';
 const props={...original};if(enabled){if('children'in props)props.children=textChildren(props.children as ReactNode);for(const attr of ['aria-label','aria-description','title','placeholder','alt'])if(typeof props[attr]==='string')props[attr]=translateText(props[attr] as string);}
 if(tag==='option'&&original.value===undefined&&typeof original.children==='string')props.value=original.children;
 if(typeof tag==='string'&&['input','textarea','select'].includes(tag)){const invalid=props.onInvalid as ((e:React.FormEvent<HTMLInputElement>)=>void)|undefined,input=props.onInput as ((e:React.FormEvent<HTMLInputElement>)=>void)|undefined;props.onInvalid=(e:React.FormEvent<HTMLInputElement>)=>{invalid?.(e);const field=e.currentTarget,v=field.validity;field.setCustomValidity(translateText(v.valueMissing?'Veuillez remplir ce champ.':v.typeMismatch?'Veuillez saisir une adresse e-mail valide.':v.patternMismatch?'Veuillez respecter le format demandé.':v.rangeUnderflow?'La valeur est trop petite.':v.rangeOverflow?'La valeur est trop grande.':v.tooShort?'Le texte est trop court.':v.tooLong?'Le texte est trop long.':'Veuillez choisir une valeur valide.'));};props.onInput=(e:React.FormEvent<HTMLInputElement>)=>{e.currentTarget.setCustomValidity('');input?.(e);};}
 const element=(staticChildren?reactJsxs:reactJsx)(tag,props);return enabled===inherited?element:reactJsx(Translation.Provider,{value:enabled,children:element});
}
export function jsx(type:ElementType,props:Record<string,unknown>,key?:string){return reactJsx(LocalizedElement,{tag:type,original:props??{}},key);}
export function jsxs(type:ElementType,props:Record<string,unknown>,key?:string){return reactJsx(LocalizedElement,{tag:type,original:props??{},staticChildren:true},key);}
