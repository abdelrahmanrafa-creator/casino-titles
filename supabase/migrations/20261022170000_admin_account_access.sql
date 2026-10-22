BEGIN;
-- Administrative permission follows the authenticated account, not an expiring code unlock.
CREATE OR REPLACE FUNCTION public.ct_is_admin() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT auth.uid() IS NOT NULL AND EXISTS(SELECT 1 FROM public.ct_admins a JOIN public.ct_profiles p ON p.id=a.user_id WHERE a.user_id=auth.uid())
 AND NOT EXISTS(SELECT 1 FROM public.ct_suspensions s WHERE s.user_id=auth.uid());
$$;
CREATE OR REPLACE FUNCTION public.ct_admin_access() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('unlocked',public.ct_is_admin(),'is_admin',public.ct_is_admin(),'expires_at',NULL,
 'configured',EXISTS(SELECT 1 FROM public.ct_admin_security),
 'bootstrap_available',EXISTS(SELECT 1 FROM public.ct_admin_security WHERE bootstrap_allowed) AND NOT EXISTS(SELECT 1 FROM public.ct_admins));
$$;
COMMIT;
