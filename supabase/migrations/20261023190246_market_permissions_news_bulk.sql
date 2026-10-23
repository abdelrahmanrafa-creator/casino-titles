BEGIN;
ALTER TABLE public.ct_demo_cards ADD COLUMN credit_conversion_allowed boolean NOT NULL DEFAULT false;
ALTER TABLE public.ct_circle_codes ADD COLUMN credit_conversion_allowed boolean NOT NULL DEFAULT false;
CREATE OR REPLACE FUNCTION public.ct_circle_redeem(p_operation_id uuid,p_code text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;h text:=encode(sha256(convert_to(upper(trim(coalesce(p_code,''))),'UTF8')),'hex');q jsonb;c public.ct_circle_codes;BEGIN
 q:=jsonb_build_object('kind','circle_redeem','hash',h);PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;PERFORM public.ct_check_rate(u);
 IF EXISTS(SELECT 1 FROM public.ct_demo_cards WHERE user_id=u) THEN RAISE EXCEPTION 'Vous avez déjà une carte. Contactez un administrateur.';END IF;
 SELECT * INTO c FROM public.ct_circle_codes WHERE code_hash=h AND active AND expires_at>now() AND uses<max_uses AND EXISTS(SELECT 1 FROM public.ct_demo_card_tiers t WHERE t.id=tier_id AND t.active) FOR UPDATE;
 IF c.id IS NULL OR length(p_code)>64 OR EXISTS(SELECT 1 FROM public.ct_circle_claims WHERE user_id=u AND code_id=c.id) THEN r:='{"ok":false,"message":"Code invalide, expiré ou épuisé."}';
 ELSE
 INSERT INTO public.ct_demo_cards(user_id,tier_id,version,credit_conversion_allowed) VALUES(u,c.tier_id,(SELECT version+1 FROM public.ct_market_settings WHERE id),c.credit_conversion_allowed);
 UPDATE public.ct_market_settings SET version=version+1 WHERE id;UPDATE public.ct_circle_codes SET uses=uses+1 WHERE id=c.id;INSERT INTO public.ct_circle_claims VALUES(u,c.id);
 UPDATE public.ct_circle_applications SET status='approved',note='Accès obtenu par code.' WHERE user_id=u AND status='pending';r:=jsonb_build_object('ok',true,'tier_id',c.tier_id);END IF;
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;END $$;
CREATE OR REPLACE FUNCTION public.ct_admin_admissions(p_status text DEFAULT 'pending',p_before timestamptz DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 RETURN jsonb_build_object('applications',coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM(SELECT a.*,p.username FROM public.ct_circle_applications a JOIN public.ct_profiles p ON p.id=a.user_id WHERE a.status=p_status AND(p_before IS NULL OR a.created_at<p_before) ORDER BY a.created_at DESC LIMIT 50)x),'[]'::jsonb),'codes',coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM(SELECT id,label,tier_id,max_uses,uses,active,expires_at,credit_conversion_allowed FROM public.ct_circle_codes ORDER BY created_at DESC LIMIT 100)x),'[]'::jsonb));END $$;
CREATE OR REPLACE FUNCTION public.ct_admin_admission_update(p_operation_id uuid,p_action text,p_values jsonb,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
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
 INSERT INTO public.ct_demo_cards(user_id,tier_id,version,credit_conversion_allowed) VALUES(a.user_id,p_values->>'tier_id',(SELECT version+1 FROM public.ct_market_settings WHERE id),coalesce((p_values->>'credit_conversion_allowed')::boolean,false));UPDATE public.ct_market_settings SET version=version+1 WHERE id;END IF;
 UPDATE public.ct_circle_applications SET status=CASE WHEN p_action='approve' THEN 'approved' ELSE 'rejected' END,note=coalesce(p_values->>'note','') WHERE id=a.id;
 ELSIF p_action='create_code' THEN
 IF coalesce(p_values->>'code','') !~ '^[A-Za-z0-9-]{6,64}$' THEN RAISE EXCEPTION 'Code : 6 à 64 lettres, chiffres ou tirets';END IF;
 IF (p_values->>'expires_at')::timestamptz<=now() THEN RAISE EXCEPTION 'Expiration future requise';END IF;
 INSERT INTO public.ct_circle_codes(label,code_hash,tier_id,max_uses,expires_at,credit_conversion_allowed) VALUES(p_values->>'label',h,p_values->>'tier_id',(p_values->>'max_uses')::integer,(p_values->>'expires_at')::timestamptz,coalesce((p_values->>'credit_conversion_allowed')::boolean,false));
 ELSIF p_action='toggle_code' THEN UPDATE public.ct_circle_codes SET active=(p_values->>'active')::boolean WHERE id=(p_values->>'id')::uuid;IF NOT FOUND THEN RAISE EXCEPTION 'Code introuvable';END IF;
 ELSE RAISE EXCEPTION 'Action inconnue';END IF;
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(u,'admission_'||p_action,coalesce(p_values->>'id','codes'),p_reason,v);
 r:='{"ok":true}';INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;END $$;
CREATE OR REPLACE FUNCTION public.ct_admin_card_update(p_operation_id uuid,p_action text,p_values jsonb,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;q jsonb:=jsonb_build_object('kind','admin_card','action',p_action,'values',p_values,'reason',p_reason);c public.ct_demo_cards;t public.ct_demo_card_tiers;v_user uuid;
BEGIN PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;
 IF length(trim(coalesce(p_reason,''))) NOT BETWEEN 8 AND 1000 THEN RAISE EXCEPTION 'Justification requise';END IF;
 IF p_action='tier' THEN
  SELECT * INTO t FROM public.ct_demo_card_tiers WHERE id=p_values->>'id' FOR UPDATE;
  IF NOT FOUND OR(p_values->>'version')::bigint IS DISTINCT FROM t.version THEN RAISE EXCEPTION 'Carte modifiée. Actualisez.';END IF;
  UPDATE public.ct_demo_card_tiers SET active=(p_values->>'active')::boolean,purchases_enabled=(p_values->>'purchases_enabled')::boolean,eur_per_diamond=nullif(p_values->>'eur_per_diamond','')::numeric,min_purchase_cents=(p_values->>'min_purchase_cents')::bigint,max_purchase_cents=(p_values->>'max_purchase_cents')::bigint,daily_cents=(p_values->>'daily_cents')::bigint,lifetime_cents=nullif(p_values->>'lifetime_cents','')::bigint,version=version+1 WHERE id=t.id;
 ELSIF p_action IN('assign','suspend','revoke','conversion') THEN
  SELECT id INTO v_user FROM public.ct_profiles WHERE lower(username)=lower(trim(p_values->>'username')) AND NOT is_bot;
  IF v_user IS NULL THEN RAISE EXCEPTION 'Joueur introuvable';END IF;
  SELECT * INTO c FROM public.ct_demo_cards WHERE user_id=v_user FOR UPDATE;
  IF(p_values->>'version')::bigint IS DISTINCT FROM c.version THEN RAISE EXCEPTION 'Attribution modifiée. Actualisez.';END IF;
  IF p_action='assign' THEN
   IF NOT EXISTS(SELECT 1 FROM public.ct_demo_card_tiers WHERE id=p_values->>'tier_id') THEN RAISE EXCEPTION 'Carte inconnue';END IF;
   INSERT INTO public.ct_demo_cards(user_id,tier_id,version,credit_conversion_allowed) VALUES(v_user,p_values->>'tier_id',(SELECT version+1 FROM public.ct_market_settings WHERE id),coalesce((p_values->>'credit_conversion_allowed')::boolean,false)) ON CONFLICT(user_id) DO UPDATE SET tier_id=EXCLUDED.tier_id,credit_conversion_allowed=EXCLUDED.credit_conversion_allowed,suspended=false,version=EXCLUDED.version,updated_at=now();
  ELSIF p_action='conversion' THEN
   IF c.user_id IS NULL THEN RAISE EXCEPTION 'Aucune carte attribuée';END IF;
   UPDATE public.ct_demo_cards SET credit_conversion_allowed=(p_values->>'credit_conversion_allowed')::boolean,version=version+1,updated_at=now() WHERE user_id=v_user;
  ELSIF p_action='suspend' THEN
   IF c.user_id IS NULL THEN RAISE EXCEPTION 'Aucune carte attribuée';END IF;
   UPDATE public.ct_demo_cards SET suspended=(p_values->>'suspended')::boolean,version=version+1,updated_at=now() WHERE user_id=v_user;
  ELSE DELETE FROM public.ct_demo_cards WHERE user_id=v_user;END IF;
 ELSE RAISE EXCEPTION 'Action inconnue';END IF;
 UPDATE public.ct_market_settings SET version=version+1 WHERE id;
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(u,'card_'||p_action,coalesce(v_user::text,t.id),p_reason,p_values);
 r:='{"ok":true}';INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;
END $$;
CREATE OR REPLACE FUNCTION public.ct_admin_cards(p_search text DEFAULT '') RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 IF length(coalesce(p_search,''))>50 THEN RAISE EXCEPTION 'Recherche trop longue';END IF;
 RETURN jsonb_build_object('week_resets_at',((date_trunc('week',now() AT TIME ZONE 'Europe/Paris')+interval '1 week') AT TIME ZONE 'Europe/Paris'),'tiers',(SELECT jsonb_agg(to_jsonb(t)||jsonb_build_object('eur_per_diamond',eur_per_diamond::text) ORDER BY rank) FROM public.ct_demo_card_tiers t),'players',coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM(SELECT p.id,p.username,c.tier_id,c.version,c.suspended,c.credit_conversion_allowed,(SELECT coalesce(sum(total_cents),0) FROM public.ct_simulated_diamond_purchases WHERE user_id=p.id) spent_total_cents,(SELECT coalesce(sum(total_cents),0) FROM public.ct_simulated_diamond_purchases WHERE user_id=p.id AND created_at >= (date_trunc('week',now() AT TIME ZONE 'Europe/Paris') AT TIME ZONE 'Europe/Paris')) spent_week_cents FROM public.ct_profiles p LEFT JOIN public.ct_demo_cards c ON c.user_id=p.id WHERE NOT p.is_bot AND position(lower(coalesce(p_search,'')) IN lower(p.username))>0 ORDER BY p.username LIMIT 30)x),'[]'::jsonb));END $$;
CREATE FUNCTION public.ct_conversion_access() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$ SELECT jsonb_build_object('global_enabled',s.credit_conversion_enabled,'allowed',coalesce(c.credit_conversion_allowed,false),'active',public.ct_circle_member(auth.uid()),'frozen',s.wallets_frozen,'market_enabled',s.market_enabled,'rate',s.credits_per_diamond) FROM public.ct_market_settings s LEFT JOIN public.ct_demo_cards c ON c.user_id=auth.uid() WHERE s.id $$;
REVOKE ALL ON FUNCTION public.ct_conversion_access() FROM PUBLIC,anon,authenticated;GRANT EXECUTE ON FUNCTION public.ct_conversion_access() TO authenticated;
ALTER FUNCTION public.ct_market_command(uuid,text,jsonb) RENAME TO ct_market_command_before_permissions;
REVOKE ALL ON FUNCTION public.ct_market_command_before_permissions(uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_market_command(p_operation_id uuid,p_action text,p_values jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;v jsonb;ids jsonb:='[]';item jsonb;i integer:=0;a uuid;seed public.ct_sealed_chests;
BEGIN PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,jsonb_build_object('kind','market','action',p_action,'values',p_values));IF r IS NOT NULL THEN RETURN r;END IF;
IF p_action='convert' THEN
 IF NOT public.ct_circle_member(u) THEN RAISE EXCEPTION 'Accès réservé au cercle fermé : carte active requise';END IF;
 IF NOT(SELECT credit_conversion_enabled AND NOT wallets_frozen FROM public.ct_market_settings WHERE id) THEN RAISE EXCEPTION 'La conversion de crédits est désactivée';END IF;
 IF NOT(SELECT credit_conversion_allowed FROM public.ct_demo_cards WHERE user_id=u) THEN RAISE EXCEPTION 'La conversion crédits → diamants n’est pas autorisée pour votre carte. Contactez un administrateur.';END IF;
 IF NOT(SELECT market_enabled FROM public.ct_market_settings WHERE id) THEN RAISE EXCEPTION 'Le marché est suspendu';END IF;
ELSIF p_action='list_many' THEN
 IF jsonb_typeof(p_values->'asset_ids') IS DISTINCT FROM 'array' OR jsonb_array_length(p_values->'asset_ids') NOT BETWEEN 1 AND 20 THEN RAISE EXCEPTION 'Choisissez entre 1 et 20 coffres disponibles';END IF;
 IF (SELECT count(DISTINCT value) FROM jsonb_array_elements(p_values->'asset_ids'))<>jsonb_array_length(p_values->'asset_ids') THEN RAISE EXCEPTION 'Exemplaire en double';END IF;
 FOR item IN SELECT value FROM jsonb_array_elements(p_values->'asset_ids') LOOP
 a:=(item#>>'{}')::uuid;
 IF i=0 THEN SELECT * INTO seed FROM public.ct_sealed_chests WHERE id=a AND user_id=u AND opened_at IS NULL;END IF;
 IF seed.id IS NULL OR NOT EXISTS(SELECT 1 FROM public.ct_sealed_chests WHERE id=a AND user_id=u AND opened_at IS NULL AND chest_id=seed.chest_id AND name=seed.name AND weights=seed.weights) THEN RAISE EXCEPTION 'Sélectionnez des coffres identiques disponibles';END IF;
 IF public.ct_direct_reserved('chest',a) OR EXISTS(SELECT 1 FROM public.ct_market_listings WHERE asset_kind='chest' AND asset_id=a AND status='active' AND expires_at>now()) THEN RAISE EXCEPTION 'Un coffre sélectionné est déjà réservé';END IF;
 i:=i+1;v:=public.ct_market_command_before_permissions(md5('list-many:'||p_operation_id::text||':'||i)::uuid,'list',(p_values-'asset_ids')||jsonb_build_object('asset_kind','chest','asset_id',a));ids:=ids||jsonb_build_array(v);END LOOP;
 r:=jsonb_build_object('ok',true,'quantity',i,'listings',ids);INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,jsonb_build_object('kind','market','action',p_action,'values',p_values),r);RETURN r;
END IF;
RETURN public.ct_market_command_before_permissions(p_operation_id,p_action,p_values);END $$;
REVOKE ALL ON FUNCTION public.ct_market_command(uuid,text,jsonb) FROM PUBLIC,anon,authenticated;GRANT EXECUTE ON FUNCTION public.ct_market_command(uuid,text,jsonb) TO authenticated;
CREATE TABLE public.ct_market_news(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,title text NOT NULL CHECK(length(title) BETWEEN 2 AND 120),body text NOT NULL CHECK(length(body) BETWEEN 1 AND 5000),kind text NOT NULL CHECK(kind IN('news','event','offer')),active boolean NOT NULL DEFAULT true,version bigint NOT NULL DEFAULT 1,author_id uuid REFERENCES public.ct_profiles(id) ON DELETE SET NULL,created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX ct_market_news_author ON public.ct_market_news(author_id);ALTER TABLE public.ct_market_news ENABLE ROW LEVEL SECURITY;REVOKE ALL ON public.ct_market_news FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_market_news(p_before bigint DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$ BEGIN IF NOT public.ct_is_admin() AND NOT public.ct_circle_member(auth.uid()) THEN RAISE EXCEPTION 'Carte active requise';END IF;RETURN coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM(SELECT id,title,body,kind,active,version,created_at FROM public.ct_market_news WHERE (active OR public.ct_is_admin()) AND(p_before IS NULL OR id<p_before) ORDER BY id DESC LIMIT 30)x),'[]'::jsonb);END $$;
CREATE FUNCTION public.ct_admin_market_news(p_operation_id uuid,p_values jsonb,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$ DECLARE u uuid;r jsonb;q jsonb:=jsonb_build_object('kind','market_news','values',p_values,'reason',p_reason);v_id bigint;BEGIN PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required';END IF;r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;IF length(trim(coalesce(p_reason,''))) NOT BETWEEN 8 AND 1000 THEN RAISE EXCEPTION 'Justification requise';END IF;
IF p_values->>'id' IS NULL THEN INSERT INTO public.ct_market_news(title,body,kind,author_id) VALUES(p_values->>'title',p_values->>'body',p_values->>'kind',u) RETURNING id INTO v_id;ELSE UPDATE public.ct_market_news SET title=p_values->>'title',body=p_values->>'body',kind=p_values->>'kind',active=(p_values->>'active')::boolean,version=version+1 WHERE id=(p_values->>'id')::bigint AND version=(p_values->>'version')::bigint RETURNING id INTO v_id;IF v_id IS NULL THEN RAISE EXCEPTION 'Annonce modifiée. Actualisez.';END IF;END IF;
INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(u,'market_news',v_id::text,p_reason,p_values);r:=jsonb_build_object('ok',true,'id',v_id);INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;END $$;
REVOKE ALL ON FUNCTION public.ct_market_news(bigint),public.ct_admin_market_news(uuid,jsonb,text) FROM PUBLIC,anon,authenticated;GRANT EXECUTE ON FUNCTION public.ct_market_news(bigint),public.ct_admin_market_news(uuid,jsonb,text) TO authenticated;
COMMIT;