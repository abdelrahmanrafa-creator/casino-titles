import {lazy,Suspense,useCallback,useEffect,useRef,useState,type CSSProperties} from 'react';
import type {Session} from '@supabase/supabase-js';
import {useQuery,useQueryClient} from '@tanstack/react-query';
import {Link,NavLink,Route,Routes} from 'react-router-dom';
import {AnimatePresence,motion,useReducedMotion} from 'framer-motion';
import {ArrowUpRight,Diamond,Box,Check,ChevronRight,Coins,Crown,Gift,Grid2X2,Layers,LogOut,Search,Settings,ShieldCheck,Sparkles,Trophy,UserRound,Wallet,X} from 'lucide-react';
import {supabase,rpc,tableRequest,RpcFailure,credits,rarityNames,colors,type Snapshot,type Title,type Chest,type Award} from './lib/api';
import {pendingCommand,clearPending,readPending,type Pending} from './lib/pending';
import {TitleEffect} from './components/TitleEffect';
import {ChestArt} from './components/ChestArt';
import {ShopChests} from './components/ShopChests';
import {PriceTag} from './components/PriceTag';
import {DirectTrades} from './features/DirectTrades';
import {SealedInventory} from './features/SealedInventory';
import {Collection} from './features/Collection';
import {People} from './features/People';
const Market=lazy(()=>import('./features/Market').then(m=>({default:m.Market})));
const Rewards=lazy(()=>import('./features/Rewards').then(m=>({default:m.Rewards}))); 
import {Auth} from './Auth';
import {ProfileGate,type Profile} from './components/ProfileGate';
import {Quests} from './features/Quests';
import {Events,Achievements} from './features/Events';
const Games=lazy(()=>import('./features/Games').then(m=>({default:m.Games})));
const Tables=lazy(()=>import('./features/Tables').then(m=>({default:m.Tables})));
const Rankings=lazy(()=>import('./features/Rankings').then(m=>({default:m.Rankings})));
const PublicProfile=lazy(()=>import('./features/Rankings').then(m=>({default:m.PublicProfile})));
const Admin=lazy(()=>import('./features/Admin').then(m=>({default:m.Admin})));
const nav=[['/','Accueil',Grid2X2],['/casino','Casino',Layers],['/rewards','Crédits gratuits',Gift],['/market','Marché noir',Diamond],['/chests','Coffres',Box],['/shop','Boutique',Sparkles],['/inventory','Inventaire',Wallet],['/collection','Collection',Crown],['/rankings','Classements',Trophy],['/profile','Profil',UserRound],['/settings','Paramètres',Settings]] as const;

export default function App(){
 const queryClient=useQueryClient();const [session,setSession]=useState<Session|null>(null),[authReady,setAuthReady]=useState(false);
 const [notice,setNotice]=useState(''),[busy,setBusy]=useState(false),[pending,setPending]=useState<Pending|null>(null);
 const [award,setAward]=useState<Award|null>(null),[revealed,setRevealed]=useState(false),[odds,setOdds]=useState<Chest|null>(null);
 const [authOpen,setAuthOpen]=useState(false);const reduced=useReducedMotion();const uid=session?.user.id;
 const [shopTab,setShopTab]=useState('titles');
 const userRef=useRef(uid);userRef.current=uid;
 const {data:profile,refetch:refreshProfile,isPending:profileLoading,error:profileError}=useQuery({queryKey:['profile',uid],enabled:!!uid,queryFn:async()=>{
  const {data,error}=await supabase.from('ct_profiles').select('id,username,avatar,created_at').eq('id',uid!).maybeSingle();if(error)throw error;return data as Profile|null;
 }});
 const {data:diamonds}=useQuery({queryKey:['diamonds',uid],enabled:!!profile,queryFn:()=>rpc<{balance:number}>('ct_diamond_balance'),staleTime:60000,refetchInterval:120000});
 const {data:adminAccess}=useQuery({queryKey:['admin-access',uid],enabled:!!profile,queryFn:()=>rpc<{is_admin:boolean;unlocked:boolean;configured:boolean;bootstrap_available:boolean;expires_at:string|null}>('ct_admin_access'),refetchInterval:60000,staleTime:0});
 const {data:catalog=[],error:catalogError}=useQuery({queryKey:['titles'],staleTime:300000,refetchOnWindowFocus:false,queryFn:async()=>{
  const {data,error}=await supabase.from('ct_titles').select('*').order('rarity').order('id');if(error)throw error;return data as Title[];
 }});
 const {data:chests=[]}=useQuery({queryKey:['chests',uid],queryFn:()=>rpc<Chest[]>('ct_shop_chests'),refetchInterval:60000});
 const {data:rarities=[]}=useQuery({queryKey:['rarities'],queryFn:async()=>{const {data,error}=await supabase.from('ct_rarities').select('id,color');if(error)throw error;return data as {id:number;color:string}[];}});
 useEffect(()=>{for(const r of rarities)if(/^#[0-9a-f]{6}$/i.test(r.color))document.documentElement.style.setProperty(`--rarity-${r.id}`,r.color);},[rarities]);
 const {data:state,error:stateError,refetch:refreshState}=useQuery({queryKey:['player',uid],enabled:!!profile,queryFn:()=>rpc<Snapshot>('ct_player_snapshot'),refetchInterval:30000});
 useEffect(()=>{
  let active=true;
  const {data:{subscription}}=supabase.auth.onAuthStateChange((_event,s)=>{if(active){setSession(s);setAuthReady(true);setAuthOpen(false);queryClient.removeQueries({queryKey:['player']});}});
  void supabase.auth.getSession().then(({data,error})=>{if(active){setSession(data.session);setAuthReady(true);if(error)setNotice(error.message);}});
  return ()=>{active=false;subscription.unsubscribe();};
 },[queryClient]);
 useEffect(()=>{setPending(uid?readPending(uid):null);setAward(null);setNotice('');},[uid]);
 useEffect(()=>{if(!award)return;setRevealed(!!reduced);const timer=setTimeout(()=>setRevealed(true),reduced?0:2400);return ()=>clearTimeout(timer);},[award,reduced]);
 const command=useCallback(async(name:string,args:Record<string,unknown>={})=>{
  const target=uid;if(!target||!profile){setAuthOpen(true);return null;}if(busy)return null;
  setBusy(true);setNotice('');let op:Pending|undefined;
  try{
   op=pendingCommand(target,name,args);setPending(op);
   const result=name==='tables'?await tableRequest<Record<string,unknown>>({...args,operation_id:op.id}):await rpc<Record<string,unknown>>(name,{p_operation_id:op.id,...args});
   clearPending(target);if(userRef.current!==target)return null;
   setPending(null);await Promise.all([queryClient.invalidateQueries({queryKey:['player',target]}),queryClient.invalidateQueries({queryKey:['games',target]}),queryClient.invalidateQueries({queryKey:['quests',target]}),queryClient.invalidateQueries({queryKey:['tables',target]}),queryClient.invalidateQueries({queryKey:['events-claimed',target]}),queryClient.invalidateQueries({queryKey:['achievements',target]}),queryClient.invalidateQueries({queryKey:['chests']}),queryClient.invalidateQueries({queryKey:['arcade',target]}),queryClient.invalidateQueries({queryKey:['title-statistics']}),queryClient.invalidateQueries({queryKey:['public-collection']}),queryClient.invalidateQueries({queryKey:['public-profile-details']}),queryClient.invalidateQueries({queryKey:['market',target]}),queryClient.invalidateQueries({queryKey:['diamonds']}),queryClient.invalidateQueries({queryKey:['diamond-store']}),queryClient.invalidateQueries({queryKey:['sealed-inventory']}),queryClient.invalidateQueries({queryKey:['trade-room']}),queryClient.invalidateQueries({queryKey:['trade-inbox']}),queryClient.invalidateQueries({queryKey:['circle-access']})]);
   if(result.title&&name!=='ct_redeem_promo')setAward(result as unknown as Award);
   return result;
  }catch(error){
   if(error instanceof RpcFailure&&error.definitive){if(name==='ct_buy_diamonds_simulated'){void queryClient.invalidateQueries({queryKey:['diamond-store']});}clearPending(target);if(userRef.current===target)setPending(null);void queryClient.invalidateQueries({queryKey:['chests']});void queryClient.invalidateQueries({queryKey:['titles']});void queryClient.invalidateQueries({queryKey:['blackjack-rules']});}
   if(userRef.current===target)setNotice((error as Error).message);return null;
  }finally{if(userRef.current===target)setBusy(false);}
 },[uid,profile,busy,queryClient]);
 async function equip(id:string|null){try{await rpc('ct_equip_title',{p_player_title_id:id});await refreshState();setNotice(id?'Titre équipé.':'Titre retiré.');}catch(error){setNotice((error as Error).message);}}
 const equippedInstance=state?.inventory.find(i=>i.id===state.equipped_id),equipped=catalog.find(t=>t.id===equippedInstance?.title_id);
 const owned=new Set(state?.inventory.map(i=>i.title_id));
 const completeProfile=(created:Profile)=>{if(created.id!==userRef.current)return;queryClient.setQueryData(['profile',created.id],created);setAuthOpen(false);};
 const heading=(eyebrow:string,title:string,description:string)=><div className="page-heading"><p className="eyebrow">{eyebrow}</p><h1>{title}</h1><p className="muted">{description}</p></div>;
 const chestGrid=<ShopChests chests={chests} onOpen={setOdds}/>;
 function collection(inventory=false){return <Collection catalog={catalog} state={state} inventory={inventory} onEquip={equip}/>;}
 const gate=(content:React.ReactNode)=><ProfileGate ready={authReady} authenticated={!!session} loading={profileLoading} error={profileError} profile={profile} onRetry={()=>{void refreshProfile();}} onboarding={<Auth authenticated={!!session} onComplete={completeProfile}/>}>{content}</ProfileGate>;
 return <div className="app-shell">
  <aside className="sidebar"><Link to="/" className="brand"><span className="brand-mark">C<span>✦</span></span><div>CASINO<span>& TITLES</span></div></Link>
   <p className="nav-label">VOTRE ESPACE</p><nav>{nav.map(([path,label,Icon])=><NavLink end={path==='/'} key={path} to={path}><Icon size={19}/>{label}{path==='/chests'&&<small>{chests.length}</small>}</NavLink>)}</nav>
   <div className="sidebar-bottom"><ShieldCheck size={18}/><div>Le plaisir du jeu.<span>100 % crédits virtuels.</span></div></div>
  </aside>
  <div className="main-shell"><header className="topbar"><div className="mobile-brand">C<span>✦</span></div><div className="status-dot"/><span className="topbar-tag">LE CERCLE DES COLLECTIONNEURS</span><div className="topbar-right">
   {profile&&<DirectTrades key={uid} userId={uid!} command={command} busy={busy} notice={notice}/>}
   {profile&&adminAccess?.is_admin===true&&<Link to="/admin" className="btn secondary compact admin-shortcut"><ShieldCheck size={16}/><span>Administration</span></Link>}
   {profile&&<Link to="/market" className="topbar-diamonds" aria-label="Mon portefeuille de diamants"><Diamond size={17}/><strong>{credits(diamonds?.balance??0)}</strong></Link>}<div className="balance"><span className="coin-icon">C</span><div><small>VOTRE SOLDE</small><strong>{state?credits(state.wallet.balance):'—'} <span>Crédits</span></strong></div></div>
   {profile?<Link to="/profile" className="profile-chip"><span className="avatar">{profile.avatar}</span><div><strong>{profile.username}</strong>{equipped?<TitleEffect title={equipped}/>:<small>Collectionneur débutant</small>}</div></Link>:<button className="btn primary compact" onClick={()=>setAuthOpen(true)}>Rejoindre le cercle <ArrowUpRight size={15}/></button>}
  </div></header>
  <main className="main-content">
   {(catalogError||stateError)&&<p role="alert" className="notice">Connexion aux données indisponible. {String((catalogError||stateError)?.message)}</p>}
   {notice&&<div className="notice" role="status">{notice}<button aria-label="Fermer" onClick={()=>setNotice('')}><X size={16}/></button></div>}
   {pending&&<div className="notice">Une opération attend confirmation.<button className="text-btn" disabled={busy} onClick={()=>void command(pending.command,pending.args)}>Reprendre l’opération</button></div>}
   <Suspense fallback={<div role="status" className="panel empty-state">Chargement de votre espace…</div>}><Routes>
    <Route path="/" element={<>
     <div className="welcome-line"><span><span className="live-dot"/> VOTRE PROCHAINE GRANDE DÉCOUVERTE</span><span>Collection · Jeu · Prestige</span></div>
     <section className="hero"><div className="hero-copy"><p className="eyebrow"><Sparkles size={14}/> PLUS QU’UNE VICTOIRE. UNE SIGNATURE.</p><h1>Jouez le moment.<br/>Collectionnez<br/><em>l’exceptionnel.</em></h1><p>Entrez dans le cercle. Découvrez des titres animés, ouvrez des coffres et faites de chaque partie une nouvelle histoire.</p><div className="hero-buttons"><Link to="/chests" className="btn primary">Explorer les coffres <ArrowUpRight size={17}/></Link><Link to="/collection" className="btn secondary">Voir la collection</Link></div><div className="hero-proof"><span><ShieldCheck size={14}/> 100 % virtuel</span><span><Crown size={14}/> {catalog.length} titres à découvrir</span></div></div>
      <div className="hero-art"><div className="orbital orbit-one"/><div className="orbital orbit-two"/><span className="hero-star star-one">✦</span><span className="hero-star star-two">✧</span><ChestArt rarity={8}/><div className="hero-award"><span className="rarity-label">COSMIQUE</span><TitleEffect title={{name:'Nomade du vide stellaire',rarity:8}}/><small>L’EXCEPTION N’ATTEND QUE VOUS.</small></div></div>
     </section>
     <section className="stats-strip"><div><Box/><strong>{chests.length}</strong><span>Coffres uniques</span></div><div><Crown/><strong>{catalog.length}</strong><span>Titres à collectionner</span></div><div><Sparkles/><strong>8</strong><span>Niveaux de rareté</span></div><div><ShieldCheck/><strong>100 %</strong><span>Crédits virtuels</span></div></section>
     <div className="section-title"><div><p className="eyebrow">UNE OUVERTURE, MILLE POSSIBILITÉS</p><h2>À chaque coffre, son univers.</h2></div><Link to="/chests">Tous les coffres <ArrowUpRight size={16}/></Link></div>
     <div className="featured-chests">{chests.filter(c=>[1,4,6,8].includes(c.id)).map(c=><button className="featured-chest panel" key={c.id} onClick={()=>setOdds(c)} style={{'--accent':colors[c.rarity-1]} as CSSProperties}><ChestArt rarity={c.rarity}/><div><small>{rarityNames[c.rarity-1]}</small><h3>{c.name}</h3><PriceTag compact base={c.base_price??c.price} current={c.current_price??c.price}/></div><ArrowUpRight size={18}/></button>)}</div>
     <section className="panel home-rewards-banner"><Gift size={30}/><div><p className="eyebrow">PLUSIEURS FAÇONS DE GAGNER</p><h2>Vos prochains crédits commencent ici.</h2><p>Clicker évolutif, cadeau gratuit, missions, événements et codes promo.</p></div><Link className="btn primary" to="/rewards">Gagner des crédits <ArrowUpRight size={16}/></Link></section><People compact/><div className="home-bottom"><section className="daily-panel panel"><div className="gift-icon"><Gift size={25}/></div><div><p className="eyebrow">VOTRE RENDEZ-VOUS QUOTIDIEN</p><h3>Un nouveau jour. 750 crédits.</h3><p className="muted">Revenez chaque jour, poursuivez votre collection.</p></div><button className="btn secondary" disabled={busy||state?.daily_claimed} onClick={()=>void command('ct_claim_daily')}>{state?.daily_claimed?<><Check size={16}/> Récupérée</>:<>Récupérer <ArrowUpRight size={16}/></>}</button></section><Link to="/collection" className="collection-tease panel"><Crown size={25}/><div><h3>Votre légende prend forme.</h3><p>{owned.size} / {catalog.length} titres découverts</p><div className="progress"><i style={{width:`${owned.size/Math.max(1,catalog.length)*100}%`}}/></div></div><ChevronRight size={18}/></Link></div>
    </>}/>
    <Route path="/market" element={gate(<Market userId={uid??''} catalog={catalog} command={command} busy={busy}/>)}/>
    <Route path="/rewards" element={gate(<Rewards userId={uid??''} command={command} busy={busy} catalog={catalog} dailyClaimed={state?.daily_claimed??false}/>)}/>
    <Route path="/chests" element={<>{heading('LES PORTES DU PRESTIGE','Choisissez votre univers.','Les probabilités exactes sont affichées avant chaque ouverture. Les doublons sont conservés.')}{chestGrid}</>}/>
    <Route path="/collection" element={<>{heading('L’ALBUM DU CERCLE',`${catalog.length} façons de se distinguer.`,`${owned.size} titres découverts · ${(owned.size/320*100).toFixed(1)} % de votre collection.`)}{collection()}</>}/>
    <Route path="/inventory" element={<>{heading('VOS SIGNATURES','L’inventaire.', 'Équipez votre titre préféré et retrouvez chaque exemplaire obtenu.')}{gate(<><SealedInventory userId={uid??''} command={command} busy={busy}/>{collection(true)}</>)}</>}/>
    <Route path="/shop" element={<>{heading('LA SÉLECTION DU CERCLE','La boutique.','Des coffres, des signatures et des rendez-vous exclusifs. Prix et disponibilités vérifiés par le serveur.')}<div className="shop-tabs">{[['chests','Coffres'],['titles','Titres'],['offers','Offres spéciales'],['events','Événements']].map(([id,label])=><button className={`btn secondary ${shopTab===id?'chosen':''}`} key={id} onClick={()=>setShopTab(id)}>{label}</button>)}</div>{shopTab==='chests'?chestGrid:shopTab==='events'?<><div className="section-title"><h2>Les coffres événementiels.</h2></div><ShopChests chests={chests.filter(c=>c.category==='event')} onOpen={setOdds}/>{!chests.some(c=>c.category==='event')&&<p className="muted shop-empty">Les prochains coffres événementiels seront annoncés ici.</p>}<div className="section-title"><h2>Les rendez-vous du cercle.</h2></div><Events userId={uid} command={command} busy={busy} catalog={catalog}/></>:shopTab==='offers'?<><ShopChests chests={chests.filter(c=>c.offer_id)} onOpen={setOdds}/>{!chests.some(c=>c.offer_id)&&<div className="panel empty-state"><Gift/><h3>Les prochaines découvertes se préparent.</h3><p>Aucune réduction active pour votre compte actuellement. Retrouvez tous les coffres dans leur onglet.</p><button className="btn secondary" onClick={()=>setShopTab('chests')}>Explorer les coffres</button></div>}</>:<div className="title-grid">{catalog.filter(t=>t.shop_price!==null&&t.available&&!t.exclusive).map(t=><article className="title-card panel" key={t.id}><span className="rarity-label" style={{color:colors[t.rarity-1]}}>{rarityNames[t.rarity-1]}</span><TitleEffect title={t}/><p>{t.description}</p><button className="btn secondary" disabled={busy||state?.purchases.includes(t.id)} onClick={()=>void command('ct_buy_title',{p_title_id:t.id,p_expected_price:t.shop_price})}>{state?.purchases.includes(t.id)?'Déjà acheté':`${credits(t.shop_price!)} crédits`}</button></article>)}</div>}</>}/>
    <Route path="/profile" element={<>{heading('VOTRE PLACE DANS LE CERCLE','Votre profil.','Votre collection et votre progression sont enregistrées sur votre compte.')}{gate(<><section className="panel profile-panel"><span className="avatar large">{profile?.avatar}</span><h2>{profile?.username}</h2>{equipped?<TitleEffect large title={equipped}/>:<p className="muted">Aucun titre équipé</p>}<p>Membre depuis le {profile&&new Date(profile.created_at).toLocaleDateString('fr-FR')}</p><Link to="/inventory" className="btn secondary">Choisir ma signature</Link><Link to={`/players/${uid}`} className="text-btn">Voir mon profil public ↗</Link></section><Quests userId={uid??''} command={command} busy={busy}/><Achievements userId={uid??''}/><History state={state}/></>)}</>}/>
    <Route path="/settings" element={gate(<SettingsPanel userId={uid??''} onMessage={setNotice} onProfileSave={()=>{void refreshProfile();}}/>)}/>
    <Route path="/casino" element={gate(<><Games userId={uid??''} command={command} busy={busy}/><Tables userId={uid??''} command={command} busy={busy}/></>)}/>
    <Route path="/rankings" element={<><People/><Rankings/></>}/>
    <Route path="/players/:id" element={<PublicProfile/>}/>
    <Route path="/admin" element={gate(<Admin userId={uid??''} command={command} busy={busy} catalog={catalog}/>)}/>
    <Route path="*" element={<>{heading('HORS DU CERCLE','Cette page n’existe pas.','Retrouvez votre chemin vers votre collection.')}<Link to="/" className="btn primary">Revenir à l’accueil</Link></>}/>
   </Routes></Suspense>
   <footer className="footer"><span>© {new Date().getFullYear()} Casino & Titles</span><span>Le prestige se collectionne. Le jeu reste virtuel.</span><span><ShieldCheck size={13}/> Aucun argent réel</span></footer>
  </main></div>
  <nav className="mobile-nav">{nav.map(([path,label,Icon])=><NavLink end={path==='/'} to={path} key={path}><Icon size={19}/><span>{label}</span></NavLink>)}</nav>
  <AnimatePresence>{(authOpen||(session&&authReady&&!profileLoading&&!profileError&&profile===null))&&<motion.div className="modal-backdrop" initial={{opacity:0}} animate={{opacity:1}} exit={{opacity:0}}><div className="modal auth-modal" role="dialog" aria-modal="true" aria-label="Rejoindre le cercle"><button className="close-btn" aria-label="Fermer" onClick={()=>setAuthOpen(false)}><X/></button>{gate(<p>Votre profil est prêt.</p>)}</div></motion.div>}</AnimatePresence>
  {odds&&<div className="modal-backdrop"><section className="modal panel" role="dialog" aria-modal="true" aria-labelledby="odds-title"><button className="close-btn" aria-label="Fermer" onClick={()=>setOdds(null)}><X/></button><h2 id="odds-title">Coffre {odds.name}</h2><p className="muted">Un titre tiré au sort, ajouté immédiatement à votre inventaire.</p><PriceTag base={odds.base_price??odds.price} current={odds.current_price??odds.price}/><div className="odds-table">{rarityNames.map((name,i)=><div key={name}><span style={{color:colors[i]}}>{name}</span><strong>{(odds.weights[i]/100).toLocaleString('fr-FR')} %</strong></div>)}</div><p className="legal">Chaque titre éligible d’une même rareté a la même chance. Les doublons sont conservés. Si l’offre change ou expire, le serveur vous demande de confirmer le nouveau prix.</p><button className="btn primary" disabled={busy||odds.available===false} onClick={()=>{const {id,version}=odds;setOdds(null);void command('ct_open_chest',{p_chest_id:id,p_expected_version:version,p_expected_price:odds.current_price??odds.price,p_expected_offer_id:odds.offer_id??null});}}>Ouvrir · {credits(odds.current_price??odds.price)} crédits <ArrowUpRight size={16}/></button></section></div>}
  {award&&<div className="modal-backdrop reveal-backdrop"><section className={`modal reveal ${revealed?'is-revealed':''}`} role="dialog" aria-modal="true" aria-label="Votre titre obtenu" style={{'--accent':colors[award.title.rarity-1]} as CSSProperties}><div className="reveal-particles" aria-hidden="true">{Array.from({length:16},(_,i)=><i key={i} style={{'--i':i} as CSSProperties}/>)}</div><ChestArt rarity={award.title.rarity} open={revealed}/>{revealed?<><p className="eyebrow">{rarityNames[award.title.rarity-1]} · VOTRE NOUVELLE SIGNATURE</p><TitleEffect title={award.title} large/><p className="muted">{award.title.description}</p><div className="reveal-buttons"><button className="btn primary" onClick={()=>{void equip(award.player_title_id);setAward(null);}}>Équiper ce titre</button><button className="btn secondary" onClick={()=>setAward(null)}>Continuer</button></div></>:<><p className="eyebrow">LE CERCLE RÉVÈLE SES SECRETS…</p><button className="text-btn" onClick={()=>setRevealed(true)}>Passer l’animation</button></>}</section></div>}
 </div>;
}

function History({state}:{state?:Snapshot}){return <section className="panel history"><h2>Journal des crédits</h2><p className="muted">50 dernières opérations · Enregistrées automatiquement</p><div className="history-scroll"><table><thead><tr><th>Opération</th><th>Date</th><th>Montant</th><th>Solde après</th></tr></thead><tbody>{state?.transactions.map(t=><tr key={t.id}><td>{{welcome:'Bienvenue',daily:'Récompense quotidienne',chest:'Ouverture de coffre',purchase:'Achat de titre',quest:'Mission',wager:'Mise',payout:'Gain'}[t.reason]??t.reason}</td><td>{new Date(t.created_at).toLocaleString('fr-FR')}</td><td className={t.amount>0?'positive':''}>{t.amount>0?'+':''}{credits(t.amount)}</td><td>{credits(t.balance_after)}</td></tr>)}</tbody></table></div></section>;}
function SettingsPanel({userId,onMessage,onProfileSave}:{userId:string;onMessage:(message:string)=>void;onProfileSave:()=>void}){
 const [password,setPassword]=useState(''),[saving,setSaving]=useState(false);
 const [motionOff,setMotionOff]=useState(()=>localStorage.getItem('ct:reduced-motion')==='true');
 const [avatar,setAvatar]=useState('🎲');
 const [hidden,setHidden]=useState(false),[privacyReady,setPrivacyReady]=useState(false),[privacySaving,setPrivacySaving]=useState(false),[privacyUnavailable,setPrivacyUnavailable]=useState(false);const settingsClient=useQueryClient();
 useEffect(()=>{let active=true;void supabase.from('ct_preferences').select('reduced_motion,leaderboard_hidden').eq('user_id',userId).maybeSingle().then(({data,error})=>{if(active&&data){setMotionOff(data.reduced_motion);setHidden(data.leaderboard_hidden);}if(active&&!error)setPrivacyReady(true);if(active&&error){if(error.code==='42703'||error.code==='PGRST204'){setPrivacyUnavailable(true);void supabase.from('ct_preferences').select('reduced_motion').eq('user_id',userId).maybeSingle().then(({data})=>{if(active&&data)setMotionOff(data.reduced_motion);});}else onMessage(error.message);}});return ()=>{active=false;};},[userId]);
 useEffect(()=>{document.documentElement.dataset.reducedMotion=String(motionOff);localStorage.setItem('ct:reduced-motion',String(motionOff));},[motionOff]);
 return <section className="panel settings"><p className="eyebrow">À VOTRE IMAGE</p><h1>Les paramètres.</h1><section className="ranking-privacy"><h2>Votre place dans les classements</h2>{privacyUnavailable&&<p role="status" className="legal">Cette option sera disponible après activation de la confidentialité sur le serveur.</p>}<label className="toggle-row"><input type="checkbox" checked={hidden} disabled={!privacyReady||privacySaving} onChange={async e=>{const value=e.target.checked;setPrivacySaving(true);try{await rpc('ct_set_leaderboard_visibility',{p_hidden:value});setHidden(value);await settingsClient.invalidateQueries({queryKey:['rankings']});onMessage(value?'Votre compte est maintenant masqué de tous les classements.':'Votre compte apparaît à nouveau dans les classements.');}catch(error){onMessage((error as Error).message);}finally{setPrivacySaving(false);}}}/>Masquer mon compte des classements</label><p className="legal">S’applique à toutes les catégories, au classement permanent et à celui de la semaine. Votre profil et la recherche par pseudo restent accessibles. Vos crédits et votre progression sont conservés.</p></section><label className="toggle-row"><input type="checkbox" checked={motionOff} onChange={e=>{const value=e.target.checked;setMotionOff(value);void rpc('ct_save_preferences',{p_reduced_motion:value}).catch(error=>onMessage(error.message));}}/>Réduire les animations</label><form onSubmit={async e=>{e.preventDefault();const {error}=await supabase.from('ct_profiles').update({avatar}).eq('id',userId);if(error)onMessage(error.message);else{onProfileSave();onMessage('Avatar enregistré.');}}}><label>Avatar<select value={avatar} onChange={e=>setAvatar(e.target.value)}>{['🎲','♛','♠','✦','🌙','🦊','🐝','🪐'].map(a=><option key={a}>{a}</option>)}</select></label><button className="btn secondary">Enregistrer l’avatar</button></form><form onSubmit={async e=>{e.preventDefault();setSaving(true);const {error}=await supabase.auth.updateUser({password});onMessage(error?.message??'Mot de passe mis à jour.');setPassword('');setSaving(false);}}><label>Nouveau mot de passe<input required type="password" minLength={8} autoComplete="new-password" value={password} onChange={e=>setPassword(e.target.value)}/></label><button className="btn secondary" disabled={saving}>Changer le mot de passe</button></form><button className="btn secondary" onClick={()=>{void supabase.auth.signOut().then(({error})=>{if(error)onMessage(error.message);});}}><LogOut size={16}/> Se déconnecter</button></section>;
}
