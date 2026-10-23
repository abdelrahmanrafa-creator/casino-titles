import {jsx,jsxs} from './jsx-runtime';import type {ElementType} from 'react';export {Fragment} from './jsx-runtime';export type {JSX} from 'react/jsx-runtime';
export function jsxDEV(type:ElementType,props:Record<string,unknown>,key?:string,staticChildren=false){return(staticChildren?jsxs:jsx)(type,props,key);}
