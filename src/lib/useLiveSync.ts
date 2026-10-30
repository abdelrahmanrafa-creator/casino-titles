import {useEffect} from 'react';
import {useQueryClient} from '@tanstack/react-query';
import {supabase} from './api';
import {createLiveBatch,liveQueryMatches,liveScopes,type LiveScope} from './liveSync';

export function useLiveSync(userId:string|undefined,isAdmin:boolean){
 const client=useQueryClient();
 useEffect(()=>{
  if(!userId)return;
  let disposed=false,dirty=false;const afterFetch=new Set<LiveScope>();
  const refresh=(scopes:Set<LiveScope>)=>{
   if(disposed)return;
   if(document.hidden||!navigator.onLine){dirty=true;return;}
   dirty=false;
   // A notification can arrive while an older snapshot is still in flight.
   // Queue one follow-up after that read settles instead of cancelling or losing it.
   for(const scope of scopes)if(client.getQueryCache().findAll({predicate:q=>liveQueryMatches(q.queryKey,new Set([scope]))}).some(q=>q.state.fetchStatus==='fetching'))afterFetch.add(scope);
   // Inactive pages are marked stale for the next visit, but are never fetched here.
   // Do not cancel a running read: repeated broadcasts must not starve slow connections.
   void client.invalidateQueries({predicate:q=>liveQueryMatches(q.queryKey,scopes),refetchType:'active'},{cancelRefetch:false});
  };
  const batch=createLiveBatch(refresh);
  const unsubscribe=client.getQueryCache().subscribe(()=>{
   for(const scope of afterFetch)if(!client.getQueryCache().findAll({predicate:q=>liveQueryMatches(q.queryKey,new Set([scope]))}).some(q=>q.state.fetchStatus==='fetching')){afterFetch.delete(scope);batch.push(scope);}
  });
  const all=()=>liveScopes.forEach(s=>batch.push(s));
  const resume=()=>{if(!document.hidden&&navigator.onLine)all();};
  const channels=[`ct:live:user:${userId}`,'ct:live:global',...(isAdmin?['ct:live:admin']:[])].map(topic=>supabase.channel(topic,{config:{private:true}})
   .on('broadcast',{event:'changed'},message=>{
    const scope=message.payload?.scope;
    if(liveScopes.includes(scope))batch.push(scope);
   }).subscribe(status=>{if(status==='SUBSCRIBED')all();}));
  // Catch missed notifications (offline, expired sockets, time based expiry).
  const fallback=setInterval(()=>{if(!document.hidden&&navigator.onLine)all();else dirty=true;},30000);
  const visibility=()=>{if(dirty||!document.hidden)resume();};
  window.addEventListener('online',resume);window.addEventListener('focus',resume);
  document.addEventListener('visibilitychange',visibility);
  return ()=>{disposed=true;unsubscribe();afterFetch.clear();batch.dispose();clearInterval(fallback);window.removeEventListener('online',resume);window.removeEventListener('focus',resume);document.removeEventListener('visibilitychange',visibility);for(const channel of channels)void supabase.removeChannel(channel);};
 },[client,userId,isAdmin]);
}
