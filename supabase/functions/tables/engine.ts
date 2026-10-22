// Shared, pure authoritative engines. Only the Edge Function can persist their state.
export type TableGame='poker'|'chromatic';
export interface Seat {id:string;name:string;stack:number;committed:number;streetBet:number;hand:number[];folded:boolean;acted:boolean;raiseOpen:boolean}
export interface TableState {game:TableGame;phase:string;host:string;seats:Seat[];deck:number[];board:number[];dealer:number;turn:number;bet:number;minRaise:number;blind:number;deadline:number;direction:number;discard:number[];color:number;winners:string[];log:string[];showdown:boolean}
export interface Action {kind:string;amount?:number;card?:number;color?:number}
const requireThat=(test:unknown,message:string)=>{if(!test)throw new Error(message);};
export function randomBelow(bound:number){requireThat(Number.isSafeInteger(bound)&&bound>0,'Invalid random bound');const bytes=new Uint32Array(1),limit=2**32-(2**32%bound);do{crypto.getRandomValues(bytes);}while(bytes[0]>=limit);return bytes[0]%bound;}
export function shuffle(cards:number[]){const copy=[...cards];for(let i=copy.length-1;i>0;i--){const j=randomBelow(i+1);[copy[i],copy[j]]=[copy[j],copy[i]];}return copy;}
const deck=()=>shuffle(Array.from({length:52},(_,i)=>i));
const draw=(state:TableState)=>{const card=state.deck.pop();if(card===undefined)throw new Error('Deck exhausted');return card;};
const record=(s:TableState,text:string)=>{s.log=[...s.log.slice(-19),text];};
export function createState(game:TableGame,host:string,name:string,buyIn:number):TableState{
 requireThat(['poker','chromatic'].includes(game),'Unknown table game');
 requireThat(Number.isSafeInteger(buyIn)&&buyIn>=100&&buyIn<=100000&&buyIn%100===0,'Buy-in must be a multiple of 100 from 100 to 100000');
 return {game,host,phase:'waiting',seats:[seat(host,name,buyIn)],deck:[],board:[],dealer:0,turn:0,bet:0,minRaise:20,blind:20,deadline:0,direction:1,discard:[],color:0,winners:[],log:[],showdown:false};
}
function seat(id:string,name:string,stack:number):Seat{return{id,name,stack,committed:0,streetBet:0,hand:[],folded:false,acted:false,raiseOpen:true};}
export function joinState(state:TableState,id:string,name:string,buyIn:number){const s=structuredClone(state);requireThat(s.phase==='waiting','Table already started');requireThat(s.seats.length<8,'Table full');requireThat(!s.seats.some(p=>p.id===id),'Already seated');s.seats.push(seat(id,name,buyIn));record(s,`${name} rejoint la table.`);return s;}
function next(s:TableState,from:number,predicate:(p:Seat)=>boolean){for(let i=1;i<=s.seats.length;i++){const index=(from+i*s.direction+s.seats.length*2)%s.seats.length;if(predicate(s.seats[index]))return index;}return -1;}
function put(p:Seat,amount:number){requireThat(Number.isSafeInteger(amount)&&amount>=0&&amount<=p.stack,'Invalid chip amount');p.stack-=amount;p.committed+=amount;p.streetBet+=amount;}
export function startState(state:TableState,actor:string,now=Date.now()){
 const s=structuredClone(state);requireThat(s.phase==='waiting'&&actor===s.host,'Host must start a waiting table');requireThat(s.seats.length>=2,'At least two players required');
 s.deadline=now+45000;
 if(s.game==='poker'){
  s.deck=deck();s.phase='preflop';for(let i=0;i<2;i++)for(const p of s.seats)p.hand.push(draw(s));
  const sb=s.seats.length===2?s.dealer:next(s,s.dealer,()=>true),bb=next(s,sb,()=>true);
  put(s.seats[sb],Math.min(s.blind/2,s.seats[sb].stack));put(s.seats[bb],Math.min(s.blind,s.seats[bb].stack));
  s.bet=s.blind;s.minRaise=s.blind;s.turn=next(s,bb,p=>p.stack>0&&!p.folded);record(s,'Les blinds sont posées. Préflop.');
 }else{
  s.deck=shuffle(Array.from({length:112},(_,i)=>i));s.phase='playing';for(let i=0;i<7;i++)for(const p of s.seats)p.hand.push(draw(s));
  for(const p of s.seats){p.committed=p.stack;p.stack=0;}
  // Start on an ordinary numbered card; returned special cards are shuffled back.
  const index=s.deck.findIndex(c=>c%14<10);const [first]=s.deck.splice(index,1);s.discard=[first];s.color=Math.floor(first%56/14);s.turn=0;
  record(s,'Chromatic commence. Faites correspondre la couleur ou le symbole.');
 }
 return s;
}
// Five-card score packed in base 15. Ranking category dominates all kickers.
export function rankFive(cards:number[]):number{
 requireThat(cards.length===5&&new Set(cards).size===5,'Five distinct cards required');
 const ranks=cards.map(c=>c%13+2).sort((a,b)=>b-a),flush=cards.every(c=>Math.floor(c/13)===Math.floor(cards[0]/13));
 const unique=[...new Set(ranks)],straight=unique.length===5&&(unique[0]-unique[4]===4?unique[0]:unique.join(',')==='14,5,4,3,2'?5:0);
 const groups=[...new Set(ranks)].map(rank=>({rank,count:ranks.filter(r=>r===rank).length})).sort((a,b)=>b.count-a.count||b.rank-a.rank);
 let category=0,kickers:number[]=ranks;
 if(flush&&straight){category=8;kickers=[straight];}
 else if(groups[0].count===4){category=7;kickers=groups.map(g=>g.rank);}
 else if(groups[0].count===3&&groups[1].count===2){category=6;kickers=groups.map(g=>g.rank);}
 else if(flush){category=5;}
 else if(straight){category=4;kickers=[straight];}
 else if(groups[0].count===3){category=3;kickers=groups.map(g=>g.rank);}
 else if(groups[0].count===2&&groups[1].count===2){category=2;kickers=groups.map(g=>g.rank);}
 else if(groups[0].count===2){category=1;kickers=groups.map(g=>g.rank);}
 let score=category;for(let i=0;i<5;i++)score=score*15+(kickers[i]??0);return score;
}
// Poker ranks use 2..A, whereas visual deck uses A..K. Convert before evaluation.
function pokerCard(card:number){return Math.floor(card/13)*13+(card%13===0?12:card%13-1);}
export function rankSeven(cards:number[]){requireThat(cards.length===7&&new Set(cards).size===7,'Seven distinct cards required');const c=cards.map(pokerCard);let best=0;
 for(let a=0;a<3;a++)for(let b=a+1;b<4;b++)for(let d=b+1;d<5;d++)for(let e=d+1;e<6;e++)for(let f=e+1;f<7;f++)best=Math.max(best,rankFive([c[a],c[b],c[d],c[e],c[f]]));return best;
}
export function settlePots(seats:Seat[],board:number[],dealer=0){
 const awards=new Map(seats.map(p=>[p.id,0]));const levels=[...new Set(seats.map(p=>p.committed).filter(n=>n>0))].sort((a,b)=>a-b);let prior=0;
 for(const level of levels){const contributors=seats.filter(p=>p.committed>=level),pot=(level-prior)*contributors.length;prior=level;
  const eligible=contributors.filter(p=>!p.folded);requireThat(eligible.length>0,'Pot has no eligible player');
  const scores=eligible.map(p=>({id:p.id,score:eligible.length===1?0:rankSeven([...p.hand,...board])}));const best=Math.max(...scores.map(p=>p.score)),winners=scores.filter(p=>p.score===best).map(p=>p.id);
  // Odd chips go clockwise from the dealer to a winning seat.
  const ordered=Array.from({length:seats.length},(_,i)=>seats[(dealer+i+1)%seats.length]).filter(p=>winners.includes(p.id));
  const share=Math.floor(pot/winners.length);let remainder=pot%winners.length;for(const p of ordered)awards.set(p.id,awards.get(p.id)!+share+(remainder-->0?1:0));
 }
 return awards;
}
function finishPoker(s:TableState){
 const remaining=s.seats.filter(p=>!p.folded);s.showdown=remaining.length>1;
 if(remaining.length>1)while(s.board.length<5){if(s.board.length===0){draw(s);s.board.push(draw(s),draw(s),draw(s));}else{draw(s);s.board.push(draw(s));}}
 const payouts=settlePots(s.seats,s.board,s.dealer);s.winners=[...payouts].filter(([,v])=>v>0).map(([id])=>id);
 for(const p of s.seats){p.stack+=payouts.get(p.id)!;p.committed=0;p.streetBet=0;}
 s.phase='finished';s.deadline=0;record(s,'Main terminée. Les pots sont distribués sans commission.');
}
function advancePoker(s:TableState,now:number){
 if(s.seats.filter(p=>!p.folded).length===1){finishPoker(s);return;}
 const able=s.seats.filter(p=>!p.folded&&p.stack>0);
 // A lone player with chips still has to answer an outstanding bet, but cannot bet into all-ins.
 const streetComplete=able.every(p=>p.streetBet===s.bet&&(p.acted||able.length<=1));
 if(streetComplete){
  if(s.phase==='river'||able.length<=1){finishPoker(s);return;}
  draw(s);if(s.phase==='preflop'){s.board.push(draw(s),draw(s),draw(s));s.phase='flop';}else{s.board.push(draw(s));s.phase=s.phase==='flop'?'turn':'river';}
  for(const p of s.seats){p.streetBet=0;p.acted=false;p.raiseOpen=true;}s.bet=0;s.minRaise=s.blind;
  s.turn=next(s,s.dealer,p=>!p.folded&&p.stack>0);record(s,s.phase.toUpperCase());
 }else{s.turn=next(s,s.turn,p=>!p.folded&&p.stack>0&&(!p.acted||p.streetBet<s.bet));}
 requireThat(s.turn>=0,'No next player');s.deadline=now+45000;
}
function pokerAction(s:TableState,action:Action,now:number){
 const p=s.seats[s.turn],toCall=Math.max(s.bet-p.streetBet,0),otherAble=s.seats.some((other,i)=>i!==s.turn&&!other.folded&&other.stack>0);
 if(action.kind==='fold'){p.folded=true;p.acted=true;}
 else if(action.kind==='check'){requireThat(toCall===0,'Call or fold required');p.acted=true;}
 else if(action.kind==='call'){put(p,Math.min(toCall,p.stack));p.acted=true;}
 else if(action.kind==='raise'||action.kind==='allin'){
  const target=action.kind==='allin'?p.stack+p.streetBet:action.amount!;
  requireThat(Number.isSafeInteger(target)&&target>p.streetBet&&target<=p.stack+p.streetBet,'Invalid total raise');
  if(target<=s.bet){requireThat(action.kind==='allin','Raise must exceed current bet');put(p,target-p.streetBet);p.acted=true;}
  else{
   requireThat(p.raiseOpen&&otherAble,'Raising is not reopened');const raise=target-s.bet,allIn=target===p.stack+p.streetBet;
   requireThat(raise>=s.minRaise||allIn,'Raise is below the minimum');
   put(p,target-p.streetBet);
   if(raise>=s.minRaise){s.minRaise=raise;for(const other of s.seats)if(other.id!==p.id){other.acted=false;other.raiseOpen=true;}}
   else for(const other of s.seats)if(other.acted)other.raiseOpen=false;
   s.bet=target;p.acted=true;
  }
 }else throw new Error('Unknown poker action');
 record(s,`${p.name} : ${action.kind}${action.amount?` ${action.amount}`:''}.`);advancePoker(s,now);
}
function colorDraw(s:TableState,p:Seat){if(!s.deck.length){requireThat(s.discard.length>1,'No drawable cards');const top=s.discard.pop()!;s.deck=shuffle(s.discard);s.discard=[top];}p.hand.push(draw(s));}
function finishColor(s:TableState,winner:Seat){const pot=s.seats.reduce((n,p)=>n+p.committed,0);for(const p of s.seats){p.stack=p.id===winner.id?pot:0;p.committed=0;}s.winners=[winner.id];s.phase='finished';s.deadline=0;record(s,`${winner.name} remporte la partie.`);}
function colorAction(s:TableState,action:Action,now:number){
 const p=s.seats[s.turn];let skip=0;
 if(action.kind==='draw'){colorDraw(s,p);record(s,`${p.name} pioche et passe.`);}
 else if(action.kind==='play'){
  requireThat(Number.isInteger(action.card)&&p.hand.includes(action.card!),'Card not owned');const card=action.card!,rank=card%14,color=Math.floor(card%56/14),top=s.discard.at(-1)!;
  requireThat(rank===13||color===s.color||rank===top%14,'Card must match color or rank');
  requireThat(rank!==13||(Number.isInteger(action.color)&&action.color!>=0&&action.color!<=3),'Choose a color');
  p.hand.splice(p.hand.indexOf(card),1);s.discard.push(card);s.color=rank===13?action.color!:color;record(s,`${p.name} pose une carte.`);
  if(p.hand.length===0){finishColor(s,p);return;}
  if(rank===10)skip=1;
  if(rank===11){s.direction*=-1;if(s.seats.filter(p=>!p.folded).length===2)skip=1;}
  if(rank===12){const victim=next(s,s.turn,other=>!other.folded);colorDraw(s,s.seats[victim]);colorDraw(s,s.seats[victim]);skip=1;}
 }else throw new Error('Unknown Chromatic action');
 s.turn=next(s,s.turn,other=>!other.folded);if(skip)s.turn=next(s,s.turn,other=>!other.folded);s.deadline=now+45000;
}
export function actState(state:TableState,actor:string,action:Action,now=Date.now()){
 const s=structuredClone(state);requireThat(s.phase!=='waiting'&&s.phase!=='finished','Table not playing');
 requireThat(s.seats[s.turn]?.id===actor,'Not your turn');requireThat(now<s.deadline,'Turn expired; refresh the table');
 if(s.game==='poker')pokerAction(s,action,now);else colorAction(s,action,now);return s;
}
export function tickState(state:TableState,now=Date.now()){
 const s=structuredClone(state);if(s.phase==='waiting'||s.phase==='finished'||now<s.deadline)return s;
 const p=s.seats[s.turn];if(s.game==='poker')pokerAction(s,{kind:p.streetBet<s.bet?'fold':'check'},now);else colorAction(s,{kind:'draw'},now);
 record(s,`${p.name} : délai dépassé.`);return s;
}
export function leaveState(state:TableState,actor:string,now=Date.now()){
 const s=structuredClone(state),index=s.seats.findIndex(p=>p.id===actor);requireThat(index>=0,'Not seated');
 if(s.phase==='waiting'){s.seats.splice(index,1);s.host=s.seats[0]?.id??actor;if(!s.seats.length)s.phase='finished';return s;}
 requireThat(s.phase!=='finished','Table already finished');const p=s.seats[index];p.folded=true;
 if(s.game==='poker'){
  if(s.seats.filter(p=>!p.folded).length===1)finishPoker(s);
  else if(index===s.turn)advancePoker(s,now);
 }else{
  const remaining=s.seats.filter(p=>!p.folded);if(remaining.length===1)finishColor(s,remaining[0]);else if(index===s.turn){s.turn=next(s,s.turn,p=>!p.folded);s.deadline=now+45000;}
 }
 record(s,`${p.name} quitte la table.`);return s;
}
export function publicState(s:TableState,viewer:string){
 return {game:s.game,phase:s.phase,host:s.host,board:s.board,dealer:s.dealer,turn:s.turn,bet:s.bet,minRaise:s.minRaise,blind:s.blind,deadline:s.deadline,direction:s.direction,color:s.color,top:s.discard.at(-1),winners:s.winners,log:s.log,
 seats:s.seats.map(p=>({id:p.id,name:p.name,stack:p.stack,committed:p.committed,streetBet:p.streetBet,folded:p.folded,hand_count:p.hand.length,
 hand:p.id===viewer||(s.showdown&&!p.folded)?p.hand:[],raiseOpen:p.raiseOpen})),showdown:s.showdown};
}
