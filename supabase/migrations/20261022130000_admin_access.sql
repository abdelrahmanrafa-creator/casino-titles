BEGIN;
CREATE TABLE public.ct_admin_security(
 id boolean PRIMARY KEY DEFAULT true CHECK(id),code_hash text NOT NULL CHECK(code_hash~'^[0-9a-f]{64}$'),
 salt text NOT NULL,revision integer NOT NULL DEFAULT 1,bootstrap_allowed boolean NOT NULL DEFAULT true,
 session_minutes integer NOT NULL DEFAULT 30 CHECK(session_minutes BETWEEN 5 AND 120)
);
CREATE TABLE public.ct_admin_sessions(
 user_id uuid NOT NULL REFERENCES public.ct_profiles(id) ON DELETE CASCADE,session_id uuid NOT NULL,
 revision integer NOT NULL,expires_at timestamptz NOT NULL,PRIMARY KEY(user_id,session_id)
);
CREATE TABLE public.ct_admin_attempts(
 user_id uuid PRIMARY KEY REFERENCES public.ct_profiles(id) ON DELETE CASCADE,
 failures integer NOT NULL DEFAULT 0,window_start timestamptz NOT NULL DEFAULT now(),blocked_until timestamptz
);
ALTER TABLE public.ct_admin_security ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ct_admin_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ct_admin_attempts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ct_admin_security,public.ct_admin_sessions,public.ct_admin_attempts FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_admin_session_id() RETURNS uuid LANGUAGE plpgsql STABLE SET search_path='' AS $$
DECLARE v_session text;
BEGIN
 v_session:=coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'session_id','');
 IF v_session!~'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN RETURN NULL;END IF;
 RETURN v_session::uuid;
END $$;
CREATE OR REPLACE FUNCTION public.ct_is_admin() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM public.ct_admins a JOIN public.ct_admin_sessions s ON s.user_id=a.user_id
 JOIN public.ct_admin_security c ON c.id AND c.revision=s.revision
 WHERE a.user_id=auth.uid() AND s.session_id=public.ct_admin_session_id() AND s.expires_at>now()
 AND NOT EXISTS(SELECT 1 FROM public.ct_suspensions b WHERE b.user_id=a.user_id));
$$;
CREATE FUNCTION public.ct_admin_access() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('unlocked',public.ct_is_admin(),
 'expires_at',(SELECT expires_at FROM public.ct_admin_sessions WHERE user_id=auth.uid() AND session_id=public.ct_admin_session_id()),
 'configured',EXISTS(SELECT 1 FROM public.ct_admin_security),
 'bootstrap_available',EXISTS(SELECT 1 FROM public.ct_admin_security WHERE bootstrap_allowed) AND NOT EXISTS(SELECT 1 FROM public.ct_admins));
$$;
CREATE FUNCTION public.ct_admin_unlock(p_code text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid:=auth.uid();v_session uuid:=public.ct_admin_session_id();c public.ct_admin_security;
 a public.ct_admin_attempts;v_valid boolean;v_expires timestamptz;
BEGIN
 IF v_uid IS NULL OR v_session IS NULL OR NOT EXISTS(SELECT 1 FROM public.ct_profiles WHERE id=v_uid) THEN RAISE EXCEPTION 'Authenticated profile and session required' USING ERRCODE='42501';END IF;
 IF EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=v_uid) THEN RAISE EXCEPTION 'Account suspended' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(v_uid::text,173));
 INSERT INTO public.ct_admin_attempts(user_id) VALUES(v_uid) ON CONFLICT DO NOTHING;
 SELECT * INTO a FROM public.ct_admin_attempts WHERE user_id=v_uid FOR UPDATE;
 IF a.blocked_until>now() THEN RETURN jsonb_build_object('ok',false,'error','Trop de tentatives. Réessayez après dix minutes.','blocked_until',a.blocked_until);END IF;
 IF a.window_start<=now()-interval '10 minutes' THEN
  UPDATE public.ct_admin_attempts SET failures=0,window_start=now(),blocked_until=NULL WHERE user_id=v_uid;
  a.failures:=0;
 END IF;
 SELECT * INTO c FROM public.ct_admin_security WHERE id FOR UPDATE;
 v_valid:=FOUND AND p_code IS NOT NULL AND length(p_code) BETWEEN 24 AND 200
 AND c.code_hash=encode(sha256(convert_to(c.salt||p_code,'UTF8')),'hex');
 IF v_valid AND c.bootstrap_allowed AND NOT EXISTS(SELECT 1 FROM public.ct_admins) THEN
  INSERT INTO public.ct_admins(user_id) VALUES(v_uid);
  UPDATE public.ct_admin_security SET bootstrap_allowed=false WHERE id;
  INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(v_uid,'admin_bootstrap',v_uid::text,'Activation initiale par preuve du code secret','{}');
 END IF;
 IF NOT v_valid OR NOT EXISTS(SELECT 1 FROM public.ct_admins WHERE user_id=v_uid) THEN
  UPDATE public.ct_admin_attempts SET failures=failures+1,blocked_until=CASE WHEN failures+1>=5 THEN now()+interval '10 minutes' ELSE NULL END WHERE user_id=v_uid;
  -- Return an error rather than raising: failed-attempt counters must COMMIT.
  RETURN jsonb_build_object('ok',false,'error','Accès refusé. Vérifiez vos identifiants d’administration.');
 END IF;
 v_expires:=now()+make_interval(mins=>c.session_minutes);
 INSERT INTO public.ct_admin_sessions(user_id,session_id,revision,expires_at) VALUES(v_uid,v_session,c.revision,v_expires)
 ON CONFLICT(user_id,session_id) DO UPDATE SET revision=EXCLUDED.revision,expires_at=EXCLUDED.expires_at;
 UPDATE public.ct_admin_attempts SET failures=0,blocked_until=NULL,window_start=now() WHERE user_id=v_uid;
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(v_uid,'admin_unlock',v_uid::text,'Ouverture d’une session d’administration',jsonb_build_object('expires_at',v_expires));
 RETURN jsonb_build_object('ok',true,'expires_at',v_expires);
END $$;
CREATE FUNCTION public.ct_admin_lock() RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN DELETE FROM public.ct_admin_sessions WHERE user_id=auth.uid() AND session_id=public.ct_admin_session_id();END $$;
CREATE FUNCTION public.ct_admin_rotate_code(p_operation_id uuid,p_new_code text,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid:=auth.uid();v_request jsonb;v_result jsonb;v_salt text;v_revision integer;v_minutes integer;
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator unlock required' USING ERRCODE='42501';END IF;
 IF p_new_code IS NULL OR length(p_new_code) NOT BETWEEN 24 AND 200 OR p_reason IS NULL OR length(trim(p_reason))<8 THEN RAISE EXCEPTION 'Code of 24-200 characters and justification required';END IF;
 v_request:=jsonb_build_object('kind','admin_code_rotation','digest',encode(sha256(convert_to(p_new_code,'UTF8')),'hex'),'reason',p_reason);
 PERFORM pg_advisory_xact_lock(hashtextextended(v_uid::text||p_operation_id::text,93));v_result:=public.ct_replay(v_uid,p_operation_id,v_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 v_salt:=gen_random_uuid()::text;
 UPDATE public.ct_admin_security SET code_hash=encode(sha256(convert_to(v_salt||p_new_code,'UTF8')),'hex'),salt=v_salt,revision=revision+1,bootstrap_allowed=false WHERE id RETURNING revision,session_minutes INTO v_revision,v_minutes;
 DELETE FROM public.ct_admin_sessions;
 INSERT INTO public.ct_admin_sessions(user_id,session_id,revision,expires_at) VALUES(v_uid,public.ct_admin_session_id(),v_revision,now()+make_interval(mins=>v_minutes));
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(v_uid,'admin_code_rotation','security',p_reason,jsonb_build_object('revision',v_revision));
 v_result:='{"ok":true}'::jsonb;INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(v_uid,p_operation_id,v_request,v_result);RETURN v_result;
END $$;
CREATE FUNCTION public.ct_admin_role(p_operation_id uuid,p_target uuid,p_grant boolean,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid:=auth.uid();v_request jsonb:=jsonb_build_object('kind','admin_role','target',p_target,'grant',p_grant,'reason',p_reason);v_result jsonb;
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator unlock required' USING ERRCODE='42501';END IF;
 IF p_reason IS NULL OR length(trim(p_reason))<8 OR p_grant IS NULL THEN RAISE EXCEPTION 'Justification required';END IF;
 PERFORM pg_advisory_xact_lock(173,1);
 v_result:=public.ct_replay(v_uid,p_operation_id,v_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 IF p_grant THEN INSERT INTO public.ct_admins(user_id) VALUES(p_target) ON CONFLICT DO NOTHING;
 ELSE
  IF p_target=v_uid THEN RAISE EXCEPTION 'Cannot remove your own administrator role';END IF;
  DELETE FROM public.ct_admins WHERE user_id=p_target;
  DELETE FROM public.ct_admin_sessions WHERE user_id=p_target;
 END IF;
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(v_uid,'admin_role',p_target::text,p_reason,jsonb_build_object('granted',p_grant));
 v_result:='{"ok":true}'::jsonb;INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(v_uid,p_operation_id,v_request,v_result);RETURN v_result;
END $$;
REVOKE ALL ON FUNCTION public.ct_admin_session_id(),public.ct_admin_access(),public.ct_admin_unlock(text),public.ct_admin_lock(),public.ct_admin_rotate_code(uuid,text,text),public.ct_admin_role(uuid,uuid,boolean,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_admin_access(),public.ct_admin_unlock(text),public.ct_admin_lock(),public.ct_admin_rotate_code(uuid,text,text),public.ct_admin_role(uuid,uuid,boolean,text) TO authenticated;
COMMIT;
