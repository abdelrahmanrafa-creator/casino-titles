// Notifications only invalidate cached reads. Never trust broadcast payloads as game data.
export type LiveScope='account'|'catalog'|'market'|'community'|'news'|'admin'|'support';
const groups:Record<LiveScope,Set<string>>={
 account:new Set(['player','profile','diamonds','admin-access','sealed-inventory','pending-chest-rewards','circle-access','conversion-access','diamond-store','player-market-inventory','arcade','quests','achievements','events-claimed','orders','order','inbox','inbox-summary','inbox-letter','trade-room','trade-inbox','guest-conversion','chest-passport','chest-serials','games']),
 catalog:new Set(['titles','rarities','chests','quests','events','blackjack-rules','game-controls','diamond-store','circle-access','conversion-access','player-market-shop']),
 market:new Set(['market','credit-market','wholesale','market-chest-groups','market-chest-quote','market-browser','market-featured','market-promotion-options','market-campaign-quote','circle-offers','circle-offer-detail','market-payment','player-market','player-market-quote','player-market-shop','seller-demo-reviews']),
 community:new Set(['rankings','people','title-statistics','public-collection','public-profile-details']),
 news:new Set(['market-news','circle-offers','circle-offer-detail','market-featured','inbox','inbox-summary']),
 admin:new Set(['admin-data','admin-access','admin-code-claims','owner-bot-jobs','title-distribution-audience','title-distributions']),
 support:new Set(['support','support-thread','admin-data']),
};
export function liveQueryMatches(key:readonly unknown[],scopes:ReadonlySet<LiveScope>){
 const root=String(key[0]);
 return [...scopes].some(scope=>groups[scope].has(root));
}
// A trailing debounce can starve under sustained activity. Use a fixed batching window.
export function createLiveBatch(flush:(scopes:Set<LiveScope>)=>void,delay=400){
 let timer:ReturnType<typeof setTimeout>|undefined;let pending=new Set<LiveScope>();let closed=false;
 return {push(scope:LiveScope){if(closed)return;pending.add(scope);if(timer===undefined)timer=setTimeout(()=>{timer=undefined;const next=pending;pending=new Set();flush(next);},delay);},dispose(){closed=true;if(timer!==undefined)clearTimeout(timer);pending.clear();}};
}
export const liveScopes=Object.keys(groups) as LiveScope[];
