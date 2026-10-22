// Persist only the command identifier and parameters, never a balance, outcome or credential.
// An ambiguous network failure retains this key; retry replays the server receipt.
export interface Pending {id:string;command:string;args:Record<string,unknown>}
export function pendingCommand(userId:string,command:string,args:Record<string,unknown>):Pending{
 const key=`ct:pending:${userId}`;
 const raw=localStorage.getItem(key);
 if(raw){const prior=JSON.parse(raw) as Pending;
  if(prior.command!==command||JSON.stringify(prior.args)!==JSON.stringify(args))
   throw new Error('Une opération attend sa confirmation. Reprenez-la avant de continuer.');
  return prior;
 }
 const operation={id:crypto.randomUUID(),command,args};
 localStorage.setItem(key,JSON.stringify(operation));return operation;
}
export function readPending(userId:string):Pending|null{
 const raw=localStorage.getItem(`ct:pending:${userId}`);return raw?JSON.parse(raw) as Pending:null;
}
export function clearPending(userId:string){localStorage.removeItem(`ct:pending:${userId}`);}
