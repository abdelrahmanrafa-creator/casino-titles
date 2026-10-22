import type {ReactNode} from 'react';
export interface Profile {id:string;username:string;avatar:string;created_at:string}
export function ProfileGate({ready,authenticated,loading,error,profile,onRetry,children,onboarding}:{ready:boolean;authenticated:boolean;loading:boolean;error:Error|null;profile:Profile|null|undefined;onRetry:()=>void;children:ReactNode;onboarding:ReactNode}){
 if(!ready||(authenticated&&loading&&!profile))return <section className="panel empty-state" role="status">Chargement de votre profil…</section>;
 if(authenticated&&error&&!profile)return <section className="panel empty-state"><h2>Votre profil n’a pas pu être chargé.</h2><p role="alert" className="notice">{error.message}</p><p>Votre compte est conservé. Réessayez pour retrouver votre profil.</p><button className="btn primary" onClick={onRetry}>Réessayer</button></section>;
 if(authenticated&&profile)return <>{children}</>;
 return <>{onboarding}</>;
}
