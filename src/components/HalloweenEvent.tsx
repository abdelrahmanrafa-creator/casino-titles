import {Link} from 'react-router-dom';
import type {Chest} from '../lib/api';
import {locale} from '../i18n/store';
import {ChestArt} from './ChestArt';
export function HalloweenEvent({chests}:{chests:Chest[]}){const c=chests.find(c=>c.event_key==='halloween-2026'&&c.available!==false);if(!c)return null;return <aside className="halloween-banner"><div className="halloween-banner-art"><ChestArt rarity={5} name={c.name}/></div><div><p className="eyebrow">🎃 ÉVÉNEMENT SPÉCIAL · HALLOWEEN 2026</p><h2>La nuit a ses trésors.</h2><p>25 titres limités, un coffre numéroté et 1 % de chance de découvrir le titre cosmique Halloween.</p><small>Fin de l’événement : {c.ends_at?new Date(c.ends_at).toLocaleString(locale()):'—'}</small></div><Link className="btn primary" to="/chests?event=halloween">Découvrir Halloween</Link></aside>;}
