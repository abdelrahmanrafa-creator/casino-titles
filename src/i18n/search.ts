import english from './catalog.json';import titleAliases from './search-aliases.json';
const aliases=new Map<string,string>(Object.entries(titleAliases));for(const [source,value] of Object.entries(english))if(value.length<=100&&!value.includes('{'))aliases.set(value.toLocaleLowerCase('en'),source);
export function sourceSearch(value:string){return aliases.get(value.trim().toLocaleLowerCase('en'))??value;}
