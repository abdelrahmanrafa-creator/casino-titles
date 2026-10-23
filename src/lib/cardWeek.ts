import {translateText} from '../i18n/translate';
import {locale} from '../i18n/store';
export function cardWeekEnd(value?:string){return value?new Intl.DateTimeFormat(locale(),{timeZone:'Europe/Paris',dateStyle:'full',timeStyle:'short'}).format(new Date(value))+' '+translateText('(heure de Paris)'):translateText('Chaque lundi à 00:00 (heure de Paris)');}
