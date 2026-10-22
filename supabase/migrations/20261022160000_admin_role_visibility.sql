BEGIN;
CREATE OR REPLACE FUNCTION public.ct_admin_access() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('unlocked',public.ct_is_admin(),
 'is_admin',EXISTS(SELECT 1 FROM public.ct_admins a WHERE a.user_id=auth.uid()) AND NOT EXISTS(SELECT 1 FROM public.ct_suspensions s WHERE s.user_id=auth.uid()),
 'expires_at',(SELECT expires_at FROM public.ct_admin_sessions WHERE user_id=auth.uid() AND session_id=public.ct_admin_session_id()),
 'configured',EXISTS(SELECT 1 FROM public.ct_admin_security),
 'bootstrap_available',EXISTS(SELECT 1 FROM public.ct_admin_security WHERE bootstrap_allowed) AND NOT EXISTS(SELECT 1 FROM public.ct_admins));
$$;
COMMIT;
