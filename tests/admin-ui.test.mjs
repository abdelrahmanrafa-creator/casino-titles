import {test,after} from 'node:test';
import assert from 'node:assert/strict';
import {build} from 'esbuild';
import {mkdtemp,rm,mkdir,writeFile,readdir} from 'node:fs/promises';
import {join,resolve,sep} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {createElement} from 'react';
import {renderToStaticMarkup} from 'react-dom/server';
import {QueryClient,QueryClientProvider} from '@tanstack/react-query';
const root=fileURLToPath(new URL('../',import.meta.url)),temporary=await mkdtemp(join(root,'node_modules','.admin-ui-'));
after(async()=>{assert.ok(resolve(temporary).startsWith(resolve(root,'node_modules')+sep));await rm(temporary,{recursive:true,force:true});});
const colors=['#a1a1aa','#60a5fa','#b47aff','#f5b85a','#3ce0cc','#f0abfc','#ffca36','#b6a1ff'];
const stub=`export const supabase={from(){throw Error("Unexpected live table query in fixture");}};export const colors=${JSON.stringify(colors)};export const rarityNames=['COMMUN','RARE','ÉPIQUE','LÉGENDAIRE','MYTHIQUE','RAINBOW','XTREM','COSMIQUE'];export const credits=n=>new Intl.NumberFormat('fr-FR').format(n);export async function rpc(){throw Error('Unexpected live RPC in UI fixture');}`;
for(const [name,path] of [['Admin','src/features/Admin.tsx'],['PriceTag','src/components/PriceTag.tsx'],['Collection','src/features/Collection.tsx'],['Rewards','src/features/Rewards.tsx'],['GameGuide','src/features/GameGuide.tsx']])await build({entryPoints:[join(root,path)],outfile:join(temporary,`${name}.mjs`),bundle:true,platform:'node',format:'esm',jsx:'automatic',packages:"external",external:['react','react-dom','@tanstack/react-query'],plugins:[{name:'isolated-api-fixture',setup(b){b.onResolve({filter:/lib\/api$/},()=>({path:'api',namespace:'fixture'}));b.onLoad({filter:/.*/,namespace:'fixture'},()=>({contents:stub,loader:'js'}));}}]});
const {Admin}=await import(pathToFileURL(join(temporary,'Admin.mjs')).href),{PriceTag}=await import(pathToFileURL(join(temporary,'PriceTag.mjs')).href);
function admin(unlocked){const client=new QueryClient({defaultOptions:{queries:{retry:false}}});client.setQueryData(['admin-access','qa-preview'],{unlocked,configured:true,bootstrap_available:!unlocked,expires_at:'2026-10-22T23:59:00Z'});client.setQueryData(['admin-data','qa-preview','dashboard'],{overview:{players:0,credits:0,rounds:0,chests:0,results:[],audit:[]},chests:[],offers:[],events:[],quests:[],admins:[{id:'qa-preview',username:'Compte de recette'}],controls:[],rarities:[],rules:{dealer_hits_soft17:false,natural_numerator:3,natural_denominator:2,max_hands:4,double_after_split:true},security:{session_minutes:30}});return renderToStaticMarkup(createElement(QueryClientProvider,{client},createElement(MemoryRouter,null,createElement(Admin,{userId:'qa-preview',command:async()=>null,busy:false,catalog:[]}))));}
test('price presentation uses real del markup and the exact percentage; no fake discount at base price',()=>{
 const reduced=renderToStaticMarkup(createElement(PriceTag,{base:2000,current:1500}));assert.match(reduced,/<del/);assert.match(reduced,/−25 %/);assert.match(reduced,/1.500/);
 const ordinary=renderToStaticMarkup(createElement(PriceTag,{base:500,current:500}));assert.doesNotMatch(ordinary,/<del|discount-badge/);
 const free=renderToStaticMarkup(createElement(PriceTag,{base:500,current:0}));assert.match(free,/Gratuit/);assert.match(free,/−100 %/);
});
test('locked admin never renders protected controls, while unlocked layout exposes the functional sections',async()=>{
 const locked=admin(false);assert.match(locked,/Code d’administration/);assert.match(locked,/type="password"/);assert.doesNotMatch(locked,/Vue d’ensemble|Créer une réduction/);
 const html=admin(true);assert.match(html,/Offres &amp; réductions/);assert.match(html,/Coffres/);assert.match(html,/Journal d’audit/);assert.match(html,/Revenir au site/);
 await mkdir(join(root,'artifacts'),{recursive:true});const css=(await readdir(join(root,'dist','assets'))).find(n=>n.endsWith('.css'));
 await writeFile(join(root,'artifacts','admin-qa.html'),`<!doctype html><html lang="fr"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>QA visuelle — panneau administrateur</title><link rel="stylesheet" href="/dist/assets/${css}"></head><body><div style="padding:10px 18px;color:#ae92c6;font-size:11px;border-bottom:1px solid #ffffff12">QA visuelle — données de test, aperçu non connecté. Les vrais contrôles sont protégés par le serveur.</div><div class="main-content">${html}</div></body></html>`);
});
import {MemoryRouter} from 'react-router-dom';
const {Collection,collectionIdentity}=await import(pathToFileURL(join(temporary,'Collection.mjs')).href);
const secretTitle={id:'secret',name:'IDENTITE_COSMIQUE_TEST',description:'DESCRIPTION_SECRETE_TEST',acquisition:'SOURCE_SECRETE_TEST',rarity:8,effect:'galaxy',available:true,exclusive:false,shop_price:null};
test('collection conceals rare identity, description and source until owned; ordinary titles remain visible',()=>{
 for(const rarity of [6,7,8]){const identity=collectionIdentity({...secretTitle,rarity},false);assert.equal(identity.name,'???');assert.ok(identity.hidden);assert.doesNotMatch(JSON.stringify(identity),/IDENTITE_COSMIQUE_TEST|DESCRIPTION_SECRETE_TEST|SOURCE_SECRETE_TEST/);}
 assert.equal(collectionIdentity(secretTitle,true).name,secretTitle.name);assert.equal(collectionIdentity({...secretTitle,rarity:5},false).hidden,false);
 const html=renderToStaticMarkup(createElement(QueryClientProvider,{client:new QueryClient({defaultOptions:{queries:{retry:false}}})},createElement(MemoryRouter,null,createElement(Collection,{catalog:[secretTitle],inventory:false,onEquip:async()=>{}}))));assert.match(html,/\?\?\?/);assert.doesNotMatch(html,/IDENTITE_COSMIQUE_TEST|DESCRIPTION_SECRETE_TEST|SOURCE_SECRETE_TEST/);
});
test('owned secret is revealed once in the album and duplicate instances are counted',()=>{
 const state={inventory:[{id:'copy1',title_id:'secret',source:'chest',acquired_at:'2026-10-22T10:00:00Z'},{id:'copy2',title_id:'secret',source:'chest',acquired_at:'2026-10-22T11:00:00Z'}],equipped_id:'copy1'};
 const html=renderToStaticMarkup(createElement(QueryClientProvider,{client:new QueryClient({defaultOptions:{queries:{retry:false}}})},createElement(MemoryRouter,null,createElement(Collection,{catalog:[secretTitle],state,inventory:true,onEquip:async()=>{}}))));assert.match(html,/IDENTITE_COSMIQUE_TEST/);assert.match(html,/×2/);assert.match(html,/Équipé/);assert.doesNotMatch(html,/album-mystery/);
});

const {Rewards}=await import(pathToFileURL(join(temporary,'Rewards.mjs')).href),{GameGuide}=await import(pathToFileURL(join(temporary,'GameGuide.mjs')).href);
test('reward hub explains pending clicks, upgrade price, gift, codes and server daily cap',async()=>{
 const client=new QueryClient({defaultOptions:{queries:{retry:false}}});client.setQueryData(['arcade','qa-preview'],{level:0,per_click:1,upgrade_cost:100,total_clicks:0,day_clicks:0,day_limit:5000,gift_claimed:false,milestones:[]});client.setQueryData(['events'],[]);client.setQueryData(['quests','qa-preview'],[]);
 const html=renderToStaticMarkup(createElement(QueryClientProvider,{client},createElement(MemoryRouter,null,createElement(Rewards,{userId:'qa-preview',command:async()=>null,busy:false,catalog:[],dailyClaimed:false}))));
 assert.match(html,/Cliquer pour gagner des crédits/);assert.match(html,/Code promo/);assert.match(html,/100 à 500/);assert.match(html,/5 000 clics/);assert.match(html,/Améliorer/);
 const css=(await readdir(join(root,'dist','assets'))).find(n=>n.endsWith('.css'));await writeFile(join(root,'artifacts','rewards-qa.html'),'<!doctype html><html lang="fr"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>QA visuelle — atelier de crédits</title><link rel="stylesheet" href="/dist/assets/'+css+'"><body><p style="padding:15px;color:#bca6dd;font-size:12px">Aperçu visuel avec données de test — aucun versement ni compte réel.</p><main class="main-content">'+html+'</main></body></html>');
});
test('visual guides explain returned stake rather than confusing it with net profit',async()=>{
 const html=renderToStaticMarkup(createElement(GameGuide,{game:'slots',bet:100}));assert.match(html,/600 crédits/);assert.match(html,/mise comprise/);assert.match(html,/cinq/);
 const css=(await readdir(join(root,'dist','assets'))).find(n=>n.endsWith('.css'));const guides=['blackjack','coinflip','roulette','baccarat','slots'].map(game=>renderToStaticMarkup(createElement(GameGuide,{game,bet:100}))).join('');await writeFile(join(root,'artifacts','games-qa.html'),'<!doctype html><html lang="fr"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>QA visuelle — guides de jeux</title><link rel="stylesheet" href="/dist/assets/'+css+'"><body><main class="main-content">'+guides+'</main></body></html>');
});
