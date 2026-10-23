BEGIN;
CREATE TABLE public.ct_circle_applications(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),user_id uuid NOT NULL REFERENCES public.ct_profiles(id) ON DELETE CASCADE,message text NOT NULL CHECK(length(message) BETWEEN 10 AND 1000),status text NOT NULL DEFAULT 'pending' CHECK(status IN('pending','approved','rejected')),note text NOT NULL DEFAULT '' CHECK(length(note)<=1000),created_at timestamptz NOT NULL DEFAULT now());
CREATE UNIQUE INDEX ct_circle_pending ON public.ct_circle_applications(user_id) WHERE status='pending';
CREATE INDEX ct_circle_applicant ON public.ct_circle_applications(user_id,created_at DESC);
CREATE INDEX ct_circle_queue ON public.ct_circle_applications(status,created_at DESC);
CREATE TABLE public.ct_circle_codes(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),label text NOT NULL CHECK(length(label) BETWEEN 1 AND 80),code_hash text NOT NULL UNIQUE,tier_id text NOT NULL REFERENCES public.ct_demo_card_tiers(id),max_uses integer NOT NULL CHECK(max_uses BETWEEN 1 AND 100000),uses integer NOT NULL DEFAULT 0 CHECK(uses>=0 AND uses<=max_uses),active boolean NOT NULL DEFAULT true,expires_at timestamptz NOT NULL,created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX ct_circle_codes_tier ON public.ct_circle_codes(tier_id);
CREATE TABLE public.ct_circle_claims(user_id uuid NOT NULL REFERENCES public.ct_profiles(id) ON DELETE CASCADE,code_id uuid NOT NULL REFERENCES public.ct_circle_codes(id),PRIMARY KEY(user_id,code_id));
CREATE INDEX ct_circle_claim_code ON public.ct_circle_claims(code_id);
ALTER TABLE public.ct_circle_applications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ct_circle_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ct_circle_claims ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ct_circle_applications,public.ct_circle_codes,public.ct_circle_claims FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.ct_join_circle(p_operation_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;BEGIN u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,'{"kind":"join_circle"}');IF r IS NOT NULL THEN RETURN r;END IF;RAISE EXCEPTION 'Entrée payante supprimée : envoyez une candidature ou utilisez un code d’accès.';END $$;
CREATE OR REPLACE FUNCTION public.ct_circle_access() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('member',public.ct_circle_member(auth.uid()),'card',(SELECT to_jsonb(c)||jsonb_build_object('name',t.name,'active',t.active) FROM public.ct_demo_cards c JOIN public.ct_demo_card_tiers t ON t.id=c.tier_id WHERE c.user_id=auth.uid()),'application',(SELECT to_jsonb(a) FROM public.ct_circle_applications a WHERE user_id=auth.uid() ORDER BY created_at DESC,id DESC LIMIT 1),'tiers',(SELECT jsonb_agg(to_jsonb(t)||jsonb_build_object('eur_per_diamond',t.eur_per_diamond::text) ORDER BY rank) FROM public.ct_demo_card_tiers t));
$$;
CREATE FUNCTION public.ct_circle_apply(p_operation_id uuid,p_message text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;q jsonb:=jsonb_build_object('kind','circle_apply','message',p_message);BEGIN
 PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;PERFORM public.ct_check_rate(u);
 IF EXISTS(SELECT 1 FROM public.ct_demo_cards WHERE user_id=u) THEN RAISE EXCEPTION 'Vous avez déjà une carte. Contactez un administrateur.';END IF;
 IF length(trim(coalesce(p_message,''))) NOT BETWEEN 10 AND 1000 THEN RAISE EXCEPTION 'Présentez votre candidature en 10 à 1000 caractères';END IF;
 IF EXISTS(SELECT 1 FROM public.ct_circle_applications WHERE user_id=u AND (status='pending' OR created_at>now()-interval '1 day')) THEN RAISE EXCEPTION 'Une candidature est déjà en attente ou a été envoyée aujourd’hui';END IF;
 INSERT INTO public.ct_circle_applications(user_id,message) VALUES(u,trim(p_message));r:='{"ok":true}';INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;END $$;
CREATE FUNCTION public.ct_circle_redeem(p_operation_id uuid,p_code text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;h text:=encode(sha256(convert_to(upper(trim(coalesce(p_code,''))),'UTF8')),'hex');q jsonb;c public.ct_circle_codes;BEGIN
 q:=jsonb_build_object('kind','circle_redeem','hash',h);PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;PERFORM public.ct_check_rate(u);
 IF EXISTS(SELECT 1 FROM public.ct_demo_cards WHERE user_id=u) THEN RAISE EXCEPTION 'Vous avez déjà une carte. Contactez un administrateur.';END IF;
 SELECT * INTO c FROM public.ct_circle_codes WHERE code_hash=h AND active AND expires_at>now() AND uses<max_uses AND EXISTS(SELECT 1 FROM public.ct_demo_card_tiers t WHERE t.id=tier_id AND t.active) FOR UPDATE;
 IF c.id IS NULL OR length(p_code)>64 OR EXISTS(SELECT 1 FROM public.ct_circle_claims WHERE user_id=u AND code_id=c.id) THEN r:='{"ok":false,"message":"Code invalide, expiré ou épuisé."}';
 ELSE
 INSERT INTO public.ct_demo_cards(user_id,tier_id,version) VALUES(u,c.tier_id,(SELECT version+1 FROM public.ct_market_settings WHERE id));
 UPDATE public.ct_market_settings SET version=version+1 WHERE id;UPDATE public.ct_circle_codes SET uses=uses+1 WHERE id=c.id;INSERT INTO public.ct_circle_claims VALUES(u,c.id);
 UPDATE public.ct_circle_applications SET status='approved',note='Accès obtenu par code.' WHERE user_id=u AND status='pending';r:=jsonb_build_object('ok',true,'tier_id',c.tier_id);END IF;
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;END $$;
CREATE FUNCTION public.ct_admin_admissions(p_status text DEFAULT 'pending',p_before timestamptz DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 RETURN jsonb_build_object('applications',coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM(SELECT a.*,p.username FROM public.ct_circle_applications a JOIN public.ct_profiles p ON p.id=a.user_id WHERE a.status=p_status AND(p_before IS NULL OR a.created_at<p_before) ORDER BY a.created_at DESC LIMIT 50)x),'[]'::jsonb),'codes',coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM(SELECT id,label,tier_id,max_uses,uses,active,expires_at FROM public.ct_circle_codes ORDER BY created_at DESC LIMIT 100)x),'[]'::jsonb));END $$;
CREATE FUNCTION public.ct_admin_admission_update(p_operation_id uuid,p_action text,p_values jsonb,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;q jsonb;a public.ct_circle_applications;h text;v jsonb;BEGIN
 PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 h:=encode(sha256(convert_to(upper(trim(coalesce(p_values->>'code',''))),'UTF8')),'hex');v:=(p_values-'code')||jsonb_build_object('code_hash',h);q:=jsonb_build_object('kind','admission_admin','action',p_action,'values',v,'reason',p_reason);r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;
 IF length(trim(coalesce(p_reason,''))) NOT BETWEEN 8 AND 1000 THEN RAISE EXCEPTION 'Justification requise';END IF;
 IF p_action IN('approve','reject') THEN
 SELECT * INTO a FROM public.ct_circle_applications WHERE id=(p_values->>'id')::uuid FOR UPDATE;
 IF a.id IS NULL OR a.status<>'pending' THEN RAISE EXCEPTION 'Candidature déjà traitée. Actualisez.';END IF;
 IF p_action='approve' THEN
 IF EXISTS(SELECT 1 FROM public.ct_demo_cards WHERE user_id=a.user_id) THEN RAISE EXCEPTION 'Ce joueur possède déjà une carte';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.ct_demo_card_tiers WHERE id=p_values->>'tier_id' AND active) THEN RAISE EXCEPTION 'Carte inactive ou inconnue';END IF;
 INSERT INTO public.ct_demo_cards(user_id,tier_id,version) VALUES(a.user_id,p_values->>'tier_id',(SELECT version+1 FROM public.ct_market_settings WHERE id));UPDATE public.ct_market_settings SET version=version+1 WHERE id;END IF;
 UPDATE public.ct_circle_applications SET status=CASE WHEN p_action='approve' THEN 'approved' ELSE 'rejected' END,note=coalesce(p_values->>'note','') WHERE id=a.id;
 ELSIF p_action='create_code' THEN
 IF coalesce(p_values->>'code','') !~ '^[A-Za-z0-9-]{6,64}$' THEN RAISE EXCEPTION 'Code : 6 à 64 lettres, chiffres ou tirets';END IF;
 IF (p_values->>'expires_at')::timestamptz<=now() THEN RAISE EXCEPTION 'Expiration future requise';END IF;
 INSERT INTO public.ct_circle_codes(label,code_hash,tier_id,max_uses,expires_at) VALUES(p_values->>'label',h,p_values->>'tier_id',(p_values->>'max_uses')::integer,(p_values->>'expires_at')::timestamptz);
 ELSIF p_action='toggle_code' THEN UPDATE public.ct_circle_codes SET active=(p_values->>'active')::boolean WHERE id=(p_values->>'id')::uuid;IF NOT FOUND THEN RAISE EXCEPTION 'Code introuvable';END IF;
 ELSE RAISE EXCEPTION 'Action inconnue';END IF;
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(u,'admission_'||p_action,coalesce(p_values->>'id','codes'),p_reason,v);
 r:='{"ok":true}';INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;END $$;
REVOKE ALL ON FUNCTION public.ct_circle_apply(uuid,text),public.ct_circle_redeem(uuid,text),public.ct_admin_admissions(text,timestamptz),public.ct_admin_admission_update(uuid,text,jsonb,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_circle_apply(uuid,text),public.ct_circle_redeem(uuid,text),public.ct_admin_admissions(text,timestamptz),public.ct_admin_admission_update(uuid,text,jsonb,text) TO authenticated;
COMMIT;
