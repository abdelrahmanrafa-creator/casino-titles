import type {Title} from '../lib/api';
export function TitleEffect({title,large=false}:{title:Pick<Title,'name'|'rarity'>;large?:boolean}){
 return <span className={`title-effect rarity-${title.rarity} ${large?'title-large':''}`}>
  <span className="title-letters">{title.name}</span>
  {title.rarity>=4&&<span aria-hidden="true" className="title-sparks">✧ · ✦</span>}
  {title.rarity===7&&<span aria-hidden="true" className="honey-drops"><i/><i/><i/></span>}
 </span>;
}
