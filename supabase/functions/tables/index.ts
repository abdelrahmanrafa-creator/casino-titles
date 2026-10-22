import {createClient} from 'https://esm.sh/@supabase/supabase-js@2.117.3';
import {createState,joinState,startState,actState,leaveState,tickState,publicState,type TableState,type TableGame,type Action} from './engine.ts';
const headers={'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type','Access-Control-Allow-Methods':'POST, OPTIONS','Content-Type':'application/json','Cache-Control':'no-store'};
const answer=(value:unknown,status=200)=>new Response(JSON.stringify(value),{status,headers});
const db=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});
interface Room {id:string;code:string;private:boolean;buy_in:number;version:number;state:TableState;game:TableGame}
function databaseError(error:{message:string;code?:string}):never{throw {message:error.message,definitive:!!error.code&&!error.code.startsWith('08')};}
async function room(id:string){const {data,error}=await db.from('ct_rooms').select('*').eq('id',id).single();if(error)databaseError(error);return data as Room;}
function visible(r:Room,user:string){if(!r.state.seats.some(p=>p.id===user))throw new Error('Room membership required');return{room_id:r.id,code:r.code,private:r.private,buy_in:r.buy_in,version:r.version,...publicState(r.state,user)};}
Deno.serve(async(req:Request)=>{
 if(req.method==='OPTIONS')return new Response(null,{headers});
 if(req.method!=='POST')return answer({error:'Method not allowed',definitive:true},405);
 const token=req.headers.get('Authorization')?.replace(/^Bearer /,'');if(!token)return answer({error:'Authentication required',definitive:true},401);
 const {data:{user},error:authError}=await db.auth.getUser(token);if(authError||!user)return answer({error:'Authentication required',definitive:true},401);
 try{
  const body=await req.json();const actor=user.id;const cmd=body.command;
  const {data:profile,error:profileError}=await db.from('ct_profiles').select('username').eq('id',actor).single();
  if(profileError||!profile)throw new Error('Profile required');
  const {data:suspended,error:suspensionError}=await db.from('ct_suspensions').select('user_id').eq('user_id',actor).maybeSingle();if(suspensionError)databaseError(suspensionError);if(suspended)throw new Error('Account suspended');
  if(cmd==='list'){
   const {data,error}=await db.from('ct_rooms').select('id,game,buy_in,state,created_at').eq('private',false).eq('state->>phase','waiting').order('created_at',{ascending:false}).limit(30);if(error)throw error;
   const {data:members}=await db.from('ct_room_members').select('room_id').eq('user_id',actor).eq('paid',false);
   return answer({tables:data.map(r=>({id:r.id,game:r.game,buy_in:r.buy_in,players:r.state.seats.length,host:r.state.seats[0]?.name})),mine:members?.map(m=>m.room_id)??[]});
  }
  if(cmd==='state'){return answer(visible(await room(body.room_id),actor));}
  const operation=body.operation_id;
  if(typeof operation!=='string'||!/^[0-9a-f-]{36}$/i.test(operation))throw new Error('Operation ID required');
  const request={kind:'table',...body};
  const {data:replay,error:replayError}=await db.rpc('ct_replay',{p_uid:actor,p_id:operation,p_request:request});if(replayError)databaseError(replayError);
  if(replay){const r=await room(replay.room_id);return answer(cmd==='leave'&&!r.state.seats.some(p=>p.id===actor)?{left:true,room_id:r.id}:visible(r,actor));}
  if(cmd==='create'){
   if(typeof body.private!=='boolean')throw new Error('Privacy choice required');
   const state=createState(body.game,actor,profile.username,body.buy_in),code=crypto.randomUUID().replaceAll('-','').slice(0,12).toUpperCase();
   const {data,error}=await db.rpc('ct_create_room',{p_user_id:actor,p_operation_id:operation,p_request:request,p_game:body.game,p_code:code,p_private:body.private,p_buy_in:body.buy_in,p_state:state});if(error)databaseError(error);
   return answer(visible(await room(data.room_id),actor));
  }
  let roomId=body.room_id;
  if(cmd==='join'&&body.code){const {data,error}=await db.from('ct_rooms').select('id').eq('code',String(body.code).trim().toUpperCase()).single();if(error)throw new Error('Invitation not found');roomId=data.id;}
  for(let attempt=0;attempt<4;attempt++){
   const r=await room(roomId);let next:TableState;
   if(cmd==='join'){
    if(r.private&&r.code!==String(body.code??'').trim().toUpperCase())throw new Error('Invitation code required');
    next=joinState(r.state,actor,profile.username,r.buy_in);
   }else{
    visible(r,actor);
    if(cmd==='start')next=startState(r.state,actor);
    else if(cmd==='act')next=actState(r.state,actor,body.action as Action);
    else if(cmd==='leave')next=leaveState(r.state,actor);
    else if(cmd==='tick'){next=tickState(r.state);if(JSON.stringify(next)===JSON.stringify(r.state))return answer(visible(r,actor));}
    else throw new Error('Unknown table command');
   }
   const {data,error}=await db.rpc('ct_commit_room',{p_user_id:actor,p_operation_id:operation,p_request:request,p_room_id:r.id,p_expected_version:r.version,p_state:next,p_command:cmd});
   if(error?.code==='40001')continue;if(error)databaseError(error);
   if(cmd==='leave'&&!next.seats.some(p=>p.id===actor))return answer({left:true,room_id:r.id});
   return answer(visible(await room(data.room_id),actor));
  }
  return answer({error:'Concurrent room update, retry the same operation.',definitive:false},409);
 }catch(error){const message=error instanceof Error?error.message:String((error as {message?:string}).message??'Table operation failed');const definitive=(error as {definitive?:boolean}).definitive??!(error instanceof TypeError);return answer({error:message,definitive},definitive?400:503);}
});
