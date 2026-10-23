BEGIN;
ALTER TABLE public.ct_demo_cards ADD COLUMN custom jsonb NOT NULL DEFAULT '{}';ALTER TABLE public.ct_circle_codes ADD COLUMN custom jsonb NOT NULL DEFAULT '{}';
UPDATE public.ct_demo_card_tiers SET lifetime_cents=CASE WHEN id='cosmic' THEN NULL ELSE least(coalesce(lifetime_cents,daily_cents*6),daily_cents*6) END,version=version+1;
ALTER TABLE public.ct_demo_card_tiers ADD CONSTRAINT ct_week_six_days CHECK((id='cosmic' AND lifetime_cents IS NULL) OR(id<>'cosmic' AND lifetime_cents IS NOT NULL AND lifetime_cents BETWEEN 1 AND daily_cents*6));
CREATE TABLE public.ct_card_usage_resets(user_id uuid PRIMARY KEY REFERENCES public.ct_profiles(id) ON DELETE CASCADE,daily_at timestamptz,weekly_at timestamptz);ALTER TABLE public.ct_card_usage_resets ENABLE ROW LEVEL SECURITY;REVOKE ALL ON public.ct_card_usage_resets FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_validate_card_custom(p_custom jsonb,p_tier text) RETURNS jsonb LANGUAGE plpgsql SET search_path='' AS $$ DECLARE j jsonb:=coalesce(p_custom,'{}');k text;v text;d bigint;t public.ct_demo_card_tiers;b public.ct_market_settings;BEGIN
 IF jsonb_typeof(j) IS DISTINCT FROM 'object' OR octet_length(j::text)>4000 THEN RAISE EXCEPTION 'Personnalisation invalide';END IF;SELECT * INTO t FROM public.ct_demo_card_tiers WHERE id=p_tier;IF t.id IS NULL THEN RAISE EXCEPTION 'Carte inconnue';END IF;
 FOR k IN SELECT jsonb_object_keys(j) LOOP
 IF k NOT IN('header','title','number','footer','color','color2','text_color','animation','eur_per_diamond','min_purchase_cents','max_purchase_cents','daily_cents','weekly_cents','purchases_enabled') THEN RAISE EXCEPTION 'Option inconnue : %',k;END IF;
 v:=j->>k;IF v IS NULL THEN RAISE EXCEPTION 'Valeur vide : %',k;END IF;
 IF k IN('header','title','number','footer') AND(length(trim(v)) NOT BETWEEN 1 AND 64 OR jsonb_typeof(j->k)<>'string') THEN RAISE EXCEPTION 'Texte de carte : 1 à 64 caractères';END IF;
 IF k IN('color','color2','text_color') AND v!~'^#[0-9A-Fa-f]{6}$' THEN RAISE EXCEPTION 'Couleur hexadécimale requise';END IF;
 IF k='animation' AND v NOT IN('default','none','shimmer','pulse','aurora','orbit','prism','sparkle','wave','glitch') THEN RAISE EXCEPTION 'Animation inconnue';END IF;
 IF k IN('min_purchase_cents','max_purchase_cents','daily_cents','weekly_cents') AND(v!~'^[0-9]+$' OR v::numeric NOT BETWEEN 1 AND 9000000000000) THEN RAISE EXCEPTION 'Montant personnalisé hors limites';END IF;
 IF k='eur_per_diamond' AND(v!~'^[0-9]+([.][0-9]{1,12})?$' OR v::numeric NOT BETWEEN 0.01 AND 90000000000) THEN RAISE EXCEPTION 'Taux personnalisé invalide';END IF;
 IF k='purchases_enabled' AND jsonb_typeof(j->k)<>'boolean' THEN RAISE EXCEPTION 'Autorisation invalide';END IF;
 END LOOP;
 IF coalesce((j->>'min_purchase_cents')::bigint,t.min_purchase_cents)>coalesce((j->>'max_purchase_cents')::bigint,t.max_purchase_cents) THEN RAISE EXCEPTION 'Minimum supérieur au maximum';END IF;
 SELECT * INTO b FROM public.ct_market_settings WHERE id;d:=coalesce((j->>'daily_cents')::bigint,CASE WHEN t.id='cosmic' THEN t.daily_cents ELSE least(t.daily_cents,b.daily_user_cents) END);
 IF p_tier='cosmic' AND j?'weekly_cents' THEN RAISE EXCEPTION 'La Cosmic n’a pas de limite hebdomadaire';END IF;
 IF p_tier<>'cosmic' AND j?'weekly_cents' AND(j->>'weekly_cents')::bigint>d*6 THEN RAISE EXCEPTION 'La limite hebdomadaire doit être au plus six plafonds quotidiens';END IF;RETURN j;END $$;
REVOKE ALL ON FUNCTION public.ct_validate_card_custom(jsonb,text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_card_details(p_user uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path='' AS $$
DECLARE c public.ct_demo_cards;t public.ct_demo_card_tiers;s public.ct_market_settings;reset public.ct_card_usage_resets;j jsonb;rate numeric;d bigint;m bigint;w bigint;sp_day bigint;sp_week bigint;total bigint;all_total numeric;diamonds bigint;ws timestamptz:=date_trunc('week',now() AT TIME ZONE 'Europe/Paris') AT TIME ZONE 'Europe/Paris';ds timestamptz:=date_trunc('day',now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';BEGIN
 SELECT * INTO c FROM public.ct_demo_cards WHERE user_id=p_user;SELECT * INTO t FROM public.ct_demo_card_tiers WHERE id=c.tier_id;SELECT * INTO s FROM public.ct_market_settings WHERE id;SELECT * INTO reset FROM public.ct_card_usage_resets WHERE user_id=p_user;j:=coalesce(c.custom,'{}');rate:=coalesce((j->>'eur_per_diamond')::numeric,t.eur_per_diamond,s.eur_per_diamond);
 d:=coalesce((j->>'daily_cents')::bigint,CASE WHEN t.id='cosmic' THEN t.daily_cents ELSE least(s.daily_user_cents,t.daily_cents) END);m:=coalesce((j->>'max_purchase_cents')::bigint,CASE WHEN t.id='cosmic' THEN t.max_purchase_cents ELSE least(s.max_purchase_cents,t.max_purchase_cents) END);
 w:=CASE WHEN t.id='cosmic' THEN NULL ELSE least(coalesce((j->>'weekly_cents')::bigint,t.lifetime_cents,d*6),d*6) END;
 SELECT coalesce(sum(total_cents),0),coalesce(sum(total_cents) FILTER(WHERE created_at>=greatest(ds,coalesce(reset.daily_at,ds))),0),coalesce(sum(total_cents) FILTER(WHERE created_at>=greatest(ws,coalesce(reset.weekly_at,ws))),0) INTO total,sp_day,sp_week FROM public.ct_simulated_diamond_purchases WHERE user_id=p_user;
 IF s.total_cap_cents IS NOT NULL THEN SELECT coalesce(sum(total_cents),0) INTO all_total FROM public.ct_simulated_diamond_purchases;ELSE all_total:=0;END IF;SELECT coalesce((SELECT balance FROM public.ct_diamond_wallets WHERE user_id=p_user),0) INTO diamonds;
 RETURN jsonb_build_object('version',s.version,'eur_per_diamond',rate::text,'purchases_enabled',s.purchases_enabled AND coalesce((j->>'purchases_enabled')::boolean,t.purchases_enabled,false) AND public.ct_circle_member(p_user),'wallets_frozen',s.wallets_frozen,'market_enabled',s.market_enabled,'max_purchase_cents',m,'min_purchase_cents',coalesce((j->>'min_purchase_cents')::bigint,t.min_purchase_cents,1),'daily_user_cents',d,'weekly_cents',w,'lifetime_cents',NULL,'spent_today_cents',sp_day,'spent_week_cents',sp_week,'spent_total_cents',total,'total_cap_reached',s.total_cap_cents IS NOT NULL AND all_total>=s.total_cap_cents,'week_starts_at',ws,'week_resets_at',(date_trunc('week',now() AT TIME ZONE 'Europe/Paris')+interval '1 week') AT TIME ZONE 'Europe/Paris','daily_reset_at',reset.daily_at,'weekly_reset_at',reset.weekly_at,'card_tier',t.id,'card_name',coalesce(j->>'title',t.name),'card_custom',j,'diamond_balance',diamonds,'diamond_value_cents',round(diamonds::numeric*rate*100)::text,'simulated',true);
END $$;REVOKE ALL ON FUNCTION public.ct_card_details(uuid) FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.ct_diamond_store() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$ SELECT public.ct_card_details(auth.uid()) $$;
CREATE OR REPLACE FUNCTION public.ct_buy_diamonds_simulated(p_operation_id uuid,p_quantity integer,p_expected_version bigint,p_expected_total_cents bigint,p_demo_method text DEFAULT 'demo_card') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;q jsonb:=jsonb_build_object('kind','simulated_diamond_purchase','quantity',p_quantity,'version',p_expected_version,'total_cents',p_expected_total_cents,'demo_method',p_demo_method);s public.ct_market_settings;t public.ct_demo_card_tiers;c public.ct_demo_cards;v_rate numeric;v_cents bigint;v_spent bigint;v_total bigint;v_lifetime bigint;v_details jsonb;
BEGIN
 PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;PERFORM public.ct_check_rate(u);
 SELECT * INTO s FROM public.ct_market_settings WHERE id;SELECT * INTO c FROM public.ct_demo_cards WHERE user_id=u;SELECT * INTO t FROM public.ct_demo_card_tiers WHERE id=c.tier_id;
 IF NOT public.ct_circle_member(u) THEN RAISE EXCEPTION 'Une carte active du cercle fermé est requise';END IF;
 IF NOT s.purchases_enabled OR s.wallets_frozen THEN RAISE EXCEPTION 'Les achats fictifs de diamants sont suspendus';END IF;
 IF p_quantity IS NULL OR p_quantity NOT BETWEEN 1 AND 10000 OR p_demo_method IS DISTINCT FROM 'demo_card' THEN RAISE EXCEPTION 'Simulation invalide : carte de démonstration uniquement';END IF;
 v_details:=public.ct_card_details(u);IF NOT(v_details->>'purchases_enabled')::boolean THEN RAISE EXCEPTION 'Les achats fictifs de diamants sont suspendus';END IF;
 v_rate:=(v_details->>'eur_per_diamond')::numeric;v_cents:=round(p_quantity*v_rate*100)::bigint;
 IF p_expected_version IS DISTINCT FROM s.version OR p_expected_total_cents IS DISTINCT FROM v_cents THEN RAISE EXCEPTION 'Le tarif a changé. Actualisez et confirmez le nouveau total.';END IF;
 v_lifetime:=(v_details->>'spent_week_cents')::bigint;v_spent:=(v_details->>'spent_today_cents')::bigint;
 SELECT coalesce(sum(total_cents),0) INTO v_total FROM public.ct_simulated_diamond_purchases;
 IF v_cents<(v_details->>'min_purchase_cents')::bigint OR v_cents>(v_details->>'max_purchase_cents')::bigint OR v_spent+v_cents>(v_details->>'daily_user_cents')::bigint OR(v_details->>'weekly_cents' IS NOT NULL AND v_lifetime+v_cents>(v_details->>'weekly_cents')::bigint) OR(s.total_cap_cents IS NOT NULL AND v_total+v_cents>s.total_cap_cents) THEN RAISE EXCEPTION 'Plafond de simulation ou montant minimum de la carte atteint';END IF;
 INSERT INTO public.ct_simulated_diamond_purchases(user_id,operation_id,quantity,unit_eur,total_cents,settings_version,demo_method,card_tier,card_version,created_at) VALUES(u,p_operation_id,p_quantity,v_rate,v_cents,s.version,p_demo_method,t.id,t.version,clock_timestamp());
 PERFORM public.ct_post_diamond(u,p_quantity,'simulated_purchase','sim-purchase:'||p_operation_id::text);r:=jsonb_build_object('ok',true,'simulated',true,'total_cents',v_cents,'diamonds',p_quantity,'card_tier',t.id);
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;
END $$;
CREATE OR REPLACE FUNCTION public.ct_admin_card_update(p_operation_id uuid,p_action text,p_values jsonb,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;q jsonb:=jsonb_build_object('kind','admin_card','action',p_action,'values',p_values,'reason',p_reason);c public.ct_demo_cards;t public.ct_demo_card_tiers;v_user uuid;
BEGIN PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;
 IF length(trim(coalesce(p_reason,''))) NOT BETWEEN 8 AND 1000 THEN RAISE EXCEPTION 'Justification requise';END IF;
 IF p_action='tier' THEN
  SELECT * INTO t FROM public.ct_demo_card_tiers WHERE id=p_values->>'id' FOR UPDATE;
  IF NOT FOUND OR(p_values->>'version')::bigint IS DISTINCT FROM t.version THEN RAISE EXCEPTION 'Carte modifiée. Actualisez.';END IF;
  UPDATE public.ct_demo_card_tiers SET active=(p_values->>'active')::boolean,purchases_enabled=(p_values->>'purchases_enabled')::boolean,eur_per_diamond=nullif(p_values->>'eur_per_diamond','')::numeric,min_purchase_cents=(p_values->>'min_purchase_cents')::bigint,max_purchase_cents=(p_values->>'max_purchase_cents')::bigint,daily_cents=(p_values->>'daily_cents')::bigint,lifetime_cents=nullif(p_values->>'lifetime_cents','')::bigint,version=version+1 WHERE id=t.id;
 ELSIF p_action IN('assign','suspend','revoke','conversion','personalize','reset') THEN
  SELECT id INTO v_user FROM public.ct_profiles WHERE lower(username)=lower(trim(p_values->>'username')) AND NOT is_bot;
  IF v_user IS NULL THEN RAISE EXCEPTION 'Joueur introuvable';END IF;
  SELECT * INTO c FROM public.ct_demo_cards WHERE user_id=v_user FOR UPDATE;
  IF(p_values->>'version')::bigint IS DISTINCT FROM c.version THEN RAISE EXCEPTION 'Attribution modifiée. Actualisez.';END IF;
  IF p_action='assign' THEN
   IF NOT EXISTS(SELECT 1 FROM public.ct_demo_card_tiers WHERE id=p_values->>'tier_id') THEN RAISE EXCEPTION 'Carte inconnue';END IF;
   INSERT INTO public.ct_demo_cards(user_id,tier_id,version,credit_conversion_allowed,custom) VALUES(v_user,p_values->>'tier_id',(SELECT version+1 FROM public.ct_market_settings WHERE id),coalesce((p_values->>'credit_conversion_allowed')::boolean,false),public.ct_validate_card_custom(coalesce(p_values->'custom','{}'),p_values->>'tier_id')) ON CONFLICT(user_id) DO UPDATE SET tier_id=EXCLUDED.tier_id,credit_conversion_allowed=EXCLUDED.credit_conversion_allowed,custom=EXCLUDED.custom,suspended=false,version=EXCLUDED.version,updated_at=now();
  ELSIF p_action='personalize' THEN
   IF c.user_id IS NULL THEN RAISE EXCEPTION 'Aucune carte attribuée';END IF;
   UPDATE public.ct_demo_cards SET custom=public.ct_validate_card_custom(p_values->'custom',c.tier_id),credit_conversion_allowed=coalesce((p_values->>'credit_conversion_allowed')::boolean,credit_conversion_allowed),version=version+1,updated_at=now() WHERE user_id=v_user;
  ELSIF p_action='reset' THEN
   IF c.user_id IS NULL THEN RAISE EXCEPTION 'Aucune carte attribuée';END IF;
   IF p_values->>'scope' NOT IN('daily','weekly','both') OR p_values->>'scope' IS NULL THEN RAISE EXCEPTION 'Compteur inconnu';END IF;
   INSERT INTO public.ct_card_usage_resets(user_id,daily_at,weekly_at) VALUES(v_user,CASE WHEN p_values->>'scope' IN('daily','both') THEN clock_timestamp() END,CASE WHEN p_values->>'scope' IN('weekly','both') THEN clock_timestamp() END) ON CONFLICT(user_id) DO UPDATE SET daily_at=coalesce(EXCLUDED.daily_at,ct_card_usage_resets.daily_at),weekly_at=coalesce(EXCLUDED.weekly_at,ct_card_usage_resets.weekly_at);
   UPDATE public.ct_demo_cards SET version=version+1,updated_at=now() WHERE user_id=v_user;
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
 RETURN jsonb_build_object('week_resets_at',((date_trunc('week',now() AT TIME ZONE 'Europe/Paris')+interval '1 week') AT TIME ZONE 'Europe/Paris'),'tiers',(SELECT jsonb_agg(to_jsonb(t)||jsonb_build_object('eur_per_diamond',eur_per_diamond::text) ORDER BY rank) FROM public.ct_demo_card_tiers t),'players',coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM(SELECT p.id,p.username,c.tier_id,c.version,c.suspended,c.credit_conversion_allowed,c.custom,public.ct_card_details(p.id) effective,(SELECT coalesce(sum(total_cents),0) FROM public.ct_simulated_diamond_purchases WHERE user_id=p.id) spent_total_cents,(public.ct_card_details(p.id)->>'spent_week_cents')::bigint spent_week_cents FROM public.ct_profiles p LEFT JOIN public.ct_demo_cards c ON c.user_id=p.id WHERE NOT p.is_bot AND position(lower(coalesce(p_search,'')) IN lower(p.username))>0 ORDER BY p.username LIMIT 30)x),'[]'::jsonb));END $$;
CREATE OR REPLACE FUNCTION public.ct_circle_redeem(p_operation_id uuid,p_code text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;h text:=encode(sha256(convert_to(upper(trim(coalesce(p_code,''))),'UTF8')),'hex');q jsonb;c public.ct_circle_codes;BEGIN
 q:=jsonb_build_object('kind','circle_redeem','hash',h);PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;PERFORM public.ct_check_rate(u);
 IF EXISTS(SELECT 1 FROM public.ct_demo_cards WHERE user_id=u) THEN RAISE EXCEPTION 'Vous avez déjà une carte. Contactez un administrateur.';END IF;
 SELECT * INTO c FROM public.ct_circle_codes WHERE code_hash=h AND active AND expires_at>now() AND uses<max_uses AND EXISTS(SELECT 1 FROM public.ct_demo_card_tiers t WHERE t.id=tier_id AND t.active) FOR UPDATE;
 IF c.id IS NULL OR length(p_code)>64 OR EXISTS(SELECT 1 FROM public.ct_circle_claims WHERE user_id=u AND code_id=c.id) THEN r:='{"ok":false,"message":"Code invalide, expiré ou épuisé."}';
 ELSE
 INSERT INTO public.ct_demo_cards(user_id,tier_id,version,credit_conversion_allowed,custom) VALUES(u,c.tier_id,(SELECT version+1 FROM public.ct_market_settings WHERE id),c.credit_conversion_allowed,public.ct_validate_card_custom(c.custom,c.tier_id));
 UPDATE public.ct_market_settings SET version=version+1 WHERE id;UPDATE public.ct_circle_codes SET uses=uses+1 WHERE id=c.id;INSERT INTO public.ct_circle_claims VALUES(u,c.id);
 UPDATE public.ct_circle_applications SET status='approved',note='Accès obtenu par code.' WHERE user_id=u AND status='pending';r:=jsonb_build_object('ok',true,'tier_id',c.tier_id);END IF;
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;END $$;
CREATE OR REPLACE FUNCTION public.ct_admin_admissions(p_status text DEFAULT 'pending',p_before timestamptz DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 RETURN jsonb_build_object('applications',coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM(SELECT a.*,p.username FROM public.ct_circle_applications a JOIN public.ct_profiles p ON p.id=a.user_id WHERE a.status=p_status AND(p_before IS NULL OR a.created_at<p_before) ORDER BY a.created_at DESC LIMIT 50)x),'[]'::jsonb),'codes',coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM(SELECT id,label,tier_id,max_uses,uses,active,expires_at,credit_conversion_allowed,custom FROM public.ct_circle_codes ORDER BY created_at DESC LIMIT 100)x),'[]'::jsonb));END $$;
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
 INSERT INTO public.ct_demo_cards(user_id,tier_id,version,credit_conversion_allowed,custom) VALUES(a.user_id,p_values->>'tier_id',(SELECT version+1 FROM public.ct_market_settings WHERE id),coalesce((p_values->>'credit_conversion_allowed')::boolean,false),public.ct_validate_card_custom(coalesce(p_values->'custom','{}'),p_values->>'tier_id'));UPDATE public.ct_market_settings SET version=version+1 WHERE id;END IF;
 UPDATE public.ct_circle_applications SET status=CASE WHEN p_action='approve' THEN 'approved' ELSE 'rejected' END,note=coalesce(p_values->>'note','') WHERE id=a.id;
 ELSIF p_action='create_code' THEN
 IF coalesce(p_values->>'code','') !~ '^[A-Za-z0-9-]{6,64}$' THEN RAISE EXCEPTION 'Code : 6 à 64 lettres, chiffres ou tirets';END IF;
 IF (p_values->>'expires_at')::timestamptz<=now() THEN RAISE EXCEPTION 'Expiration future requise';END IF;
 INSERT INTO public.ct_circle_codes(label,code_hash,tier_id,max_uses,expires_at,credit_conversion_allowed,custom) VALUES(p_values->>'label',h,p_values->>'tier_id',(p_values->>'max_uses')::integer,(p_values->>'expires_at')::timestamptz,coalesce((p_values->>'credit_conversion_allowed')::boolean,false),public.ct_validate_card_custom(coalesce(p_values->'custom','{}'),p_values->>'tier_id'));
 ELSIF p_action='toggle_code' THEN UPDATE public.ct_circle_codes SET active=(p_values->>'active')::boolean WHERE id=(p_values->>'id')::uuid;IF NOT FOUND THEN RAISE EXCEPTION 'Code introuvable';END IF;
 ELSE RAISE EXCEPTION 'Action inconnue';END IF;
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(u,'admission_'||p_action,coalesce(p_values->>'id','codes'),p_reason,v);
 r:='{"ok":true}';INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;END $$;
UPDATE public.ct_market_settings SET version=version+1 WHERE id;
COMMIT;