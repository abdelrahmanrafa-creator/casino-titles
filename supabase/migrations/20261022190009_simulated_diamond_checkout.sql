BEGIN;
CREATE TABLE public.ct_market_settings(id boolean PRIMARY KEY DEFAULT true CHECK(id),version bigint NOT NULL DEFAULT 1,market_enabled boolean NOT NULL DEFAULT true,purchases_enabled boolean NOT NULL DEFAULT true,wallets_frozen boolean NOT NULL DEFAULT false,credit_conversion_enabled boolean NOT NULL DEFAULT false,credits_per_diamond bigint NOT NULL DEFAULT 1000 CHECK(credits_per_diamond BETWEEN 1 AND 100000000),eur_per_diamond numeric(24,12) NOT NULL DEFAULT 9.414427287924 CHECK(eur_per_diamond BETWEEN 0.01 AND 1000000),max_purchase_cents bigint NOT NULL DEFAULT 50000 CHECK(max_purchase_cents BETWEEN 1 AND 100000000),daily_user_cents bigint NOT NULL DEFAULT 100000 CHECK(daily_user_cents BETWEEN 1 AND 1000000000),total_cap_cents bigint CHECK(total_cap_cents BETWEEN 1 AND 9000000000000));
INSERT INTO public.ct_market_settings(id) VALUES(true);
CREATE TABLE public.ct_simulated_diamond_purchases(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),user_id uuid NOT NULL REFERENCES public.ct_profiles(id),operation_id uuid NOT NULL,quantity integer NOT NULL CHECK(quantity BETWEEN 1 AND 10000),unit_eur numeric(24,12) NOT NULL,total_cents bigint NOT NULL CHECK(total_cents>0),settings_version bigint NOT NULL,demo_method text NOT NULL CHECK(demo_method='demo_card'),created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(user_id,operation_id));
CREATE INDEX ct_simulated_purchases_user_time ON public.ct_simulated_diamond_purchases(user_id,created_at DESC);
ALTER TABLE public.ct_market_settings ENABLE ROW LEVEL SECURITY;ALTER TABLE public.ct_simulated_diamond_purchases ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ct_market_settings,public.ct_simulated_diamond_purchases FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_diamond_store() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('version',version,'eur_per_diamond',eur_per_diamond::text,'purchases_enabled',purchases_enabled,'wallets_frozen',wallets_frozen,'market_enabled',market_enabled,'max_purchase_cents',max_purchase_cents,'daily_user_cents',daily_user_cents,'total_cap_reached',total_cap_cents IS NOT NULL AND(SELECT coalesce(sum(total_cents),0) FROM public.ct_simulated_diamond_purchases)>=total_cap_cents,'spent_today_cents',(SELECT coalesce(sum(total_cents),0) FROM public.ct_simulated_diamond_purchases WHERE user_id=auth.uid() AND created_at>=date_trunc('day',now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'),'simulated',true) FROM public.ct_market_settings WHERE id;
$$;
CREATE FUNCTION public.ct_buy_diamonds_simulated(p_operation_id uuid,p_quantity integer,p_expected_version bigint,p_expected_total_cents bigint,p_demo_method text DEFAULT 'demo_card') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;q jsonb:=jsonb_build_object('kind','simulated_diamond_purchase','quantity',p_quantity,'version',p_expected_version,'total_cents',p_expected_total_cents,'demo_method',p_demo_method);s public.ct_market_settings;v_cents bigint;v_spent bigint;v_total bigint;
BEGIN
 PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;PERFORM public.ct_check_rate(u);
 SELECT * INTO s FROM public.ct_market_settings WHERE id;
 IF NOT s.purchases_enabled OR s.wallets_frozen THEN RAISE EXCEPTION 'Les achats fictifs de diamants sont suspendus';END IF;
 IF p_quantity IS NULL OR p_quantity NOT BETWEEN 1 AND 10000 OR p_demo_method IS DISTINCT FROM 'demo_card' THEN RAISE EXCEPTION 'Simulation invalide : carte de démonstration uniquement';END IF;
 v_cents:=round(p_quantity*s.eur_per_diamond*100)::bigint;
 IF p_expected_version IS DISTINCT FROM s.version OR p_expected_total_cents IS DISTINCT FROM v_cents THEN RAISE EXCEPTION 'Le tarif a changé. Actualisez et confirmez le nouveau total.';END IF;
 SELECT coalesce(sum(total_cents),0) INTO v_spent FROM public.ct_simulated_diamond_purchases WHERE user_id=u AND created_at>=date_trunc('day',now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
 SELECT coalesce(sum(total_cents),0) INTO v_total FROM public.ct_simulated_diamond_purchases;
 IF v_cents>s.max_purchase_cents OR v_spent+v_cents>s.daily_user_cents OR(s.total_cap_cents IS NOT NULL AND v_total+v_cents>s.total_cap_cents) THEN RAISE EXCEPTION 'Plafond de simulation en euros atteint';END IF;
 INSERT INTO public.ct_simulated_diamond_purchases(user_id,operation_id,quantity,unit_eur,total_cents,settings_version,demo_method) VALUES(u,p_operation_id,p_quantity,s.eur_per_diamond,v_cents,s.version,p_demo_method);
 PERFORM public.ct_post_diamond(u,p_quantity,'simulated_purchase','sim-purchase:'||p_operation_id::text);
 r:=jsonb_build_object('ok',true,'simulated',true,'total_cents',v_cents,'diamonds',p_quantity,'message','Simulation réussie : aucun débit bancaire réel');
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;
END $$;
ALTER FUNCTION public.ct_market_command(uuid,text,jsonb) RENAME TO ct_market_command_before_store;
REVOKE ALL ON FUNCTION public.ct_market_command_before_store(uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_market_command(p_operation_id uuid,p_action text,p_values jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;q jsonb:=jsonb_build_object('kind','market','action',p_action,'values',p_values);s public.ct_market_settings;v_amount bigint;
BEGIN
 PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;SELECT * INTO s FROM public.ct_market_settings WHERE id;
 IF p_action='cancel' AND EXISTS(SELECT 1 FROM public.ct_market_listings WHERE id=(p_values->>'listing_id')::bigint AND seller_id<>u) THEN RAISE EXCEPTION 'Seul le vendeur peut annuler ici. Utilisez la modération administrateur.';END IF;
 IF p_action IN('list','accept') AND NOT s.market_enabled THEN RAISE EXCEPTION 'Le marché est suspendu par l’administration';END IF;
 IF p_action='accept' AND s.wallets_frozen THEN RAISE EXCEPTION 'Les échanges de diamants sont figés';END IF;
 IF p_action='convert' THEN
  IF NOT s.credit_conversion_enabled OR s.wallets_frozen THEN RAISE EXCEPTION 'La conversion de crédits est désactivée. Utilisez la boutique fictive de diamants.';END IF;
  v_amount:=(p_values->>'diamonds')::bigint;IF v_amount IS NULL OR v_amount NOT BETWEEN 1 AND 10000 THEN RAISE EXCEPTION 'Montant invalide';END IF;
  IF (p_values?'expected_credits_per_diamond' AND(p_values->>'expected_credits_per_diamond')::bigint IS DISTINCT FROM s.credits_per_diamond) OR(NOT(p_values?'expected_credits_per_diamond') AND s.credits_per_diamond<>1000) THEN RAISE EXCEPTION 'Le taux crédits/diamant a changé. Confirmez le nouveau taux.';END IF;
  PERFORM public.ct_check_rate(u);PERFORM public.ct_post_credit(u,-v_amount*s.credits_per_diamond,'diamond_conversion','diamond-convert:'||p_operation_id::text);PERFORM public.ct_post_diamond(u,v_amount,'conversion','convert:'||p_operation_id::text);
  r:=jsonb_build_object('ok',true,'diamonds',coalesce((SELECT balance FROM public.ct_diamond_wallets WHERE user_id=u),0));INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;
 END IF;
 RETURN public.ct_market_command_before_store(p_operation_id,p_action,p_values);
END $$;
CREATE FUNCTION public.ct_admin_market_data(p_search text DEFAULT '',p_before bigint DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 IF length(coalesce(p_search,''))>50 OR(p_before IS NOT NULL AND p_before<1) THEN RAISE EXCEPTION 'Invalid filters';END IF;
 RETURN jsonb_build_object('settings',(SELECT to_jsonb(s)||jsonb_build_object('eur_per_diamond',eur_per_diamond::text) FROM public.ct_market_settings s WHERE id),
 'revenue',jsonb_build_object('total_cents',(SELECT coalesce(sum(total_cents),0) FROM public.ct_simulated_diamond_purchases),'today_cents',(SELECT coalesce(sum(total_cents),0) FROM public.ct_simulated_diamond_purchases WHERE created_at>=date_trunc('day',now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'),'purchases',(SELECT count(*) FROM public.ct_simulated_diamond_purchases),'diamonds_sold',(SELECT coalesce(sum(quantity),0) FROM public.ct_simulated_diamond_purchases),'market_volume_diamonds',(SELECT coalesce(sum(diamonds),0) FROM public.ct_market_trades),'real_revenue_cents',0),
 'listings',coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.id DESC) FROM(SELECT l.*,p.username seller FROM public.ct_market_listings l JOIN public.ct_profiles p ON p.id=l.seller_id WHERE(p_before IS NULL OR l.id<p_before) AND position(lower(coalesce(p_search,'')) IN lower(l.name||' '||p.username))>0 ORDER BY l.id DESC LIMIT 50)x),'[]'::jsonb),
 'purchases',coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC) FROM(SELECT d.*,p.username FROM public.ct_simulated_diamond_purchases d JOIN public.ct_profiles p ON p.id=d.user_id ORDER BY d.created_at DESC,d.id DESC LIMIT 30)x),'[]'::jsonb));
END $$;
CREATE FUNCTION public.ct_admin_market_update(p_operation_id uuid,p_action text,p_values jsonb,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;q jsonb:=jsonb_build_object('kind','admin_market_update','action',p_action,'values',p_values,'reason',p_reason);s public.ct_market_settings;l public.ct_market_listings;
BEGIN
 PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;
 IF p_reason IS NULL OR length(trim(p_reason)) NOT BETWEEN 8 AND 1000 THEN RAISE EXCEPTION 'Justification de 8 caractères minimum requise';END IF;
 IF p_action='settings' THEN
  SELECT * INTO s FROM public.ct_market_settings WHERE id FOR UPDATE;
  IF(p_values->>'version')::bigint IS DISTINCT FROM s.version THEN RAISE EXCEPTION 'Réglages modifiés. Actualisez le panel.';END IF;
  IF NOT(p_values?'market_enabled' AND p_values?'purchases_enabled' AND p_values?'wallets_frozen' AND p_values?'credit_conversion_enabled' AND p_values?'credits_per_diamond' AND p_values?'eur_per_diamond' AND p_values?'max_purchase_cents' AND p_values?'daily_user_cents' AND p_values?'total_cap_cents') THEN RAISE EXCEPTION 'Réglages incomplets';END IF;
  UPDATE public.ct_market_settings SET market_enabled=(p_values->>'market_enabled')::boolean,purchases_enabled=(p_values->>'purchases_enabled')::boolean,wallets_frozen=(p_values->>'wallets_frozen')::boolean,credit_conversion_enabled=(p_values->>'credit_conversion_enabled')::boolean,credits_per_diamond=(p_values->>'credits_per_diamond')::bigint,eur_per_diamond=(p_values->>'eur_per_diamond')::numeric,max_purchase_cents=(p_values->>'max_purchase_cents')::bigint,daily_user_cents=(p_values->>'daily_user_cents')::bigint,total_cap_cents=(p_values->>'total_cap_cents')::bigint,version=version+1 WHERE id;
 ELSIF p_action='remove_listing' THEN
  SELECT * INTO l FROM public.ct_market_listings WHERE id=(p_values->>'listing_id')::bigint FOR UPDATE;
  IF NOT FOUND OR l.status<>'active' THEN RAISE EXCEPTION 'Annonce déjà traitée';END IF;
  UPDATE public.ct_market_listings SET status='cancelled' WHERE id=l.id;
 ELSE RAISE EXCEPTION 'Action inconnue';END IF;
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(u,'market_'||p_action,CASE WHEN p_action='settings' THEN 'settings' ELSE l.id::text END,p_reason,p_values);
 r:=jsonb_build_object('ok',true);INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;
END $$;
REVOKE ALL ON FUNCTION public.ct_diamond_store(),public.ct_buy_diamonds_simulated(uuid,integer,bigint,bigint,text),public.ct_market_command(uuid,text,jsonb),public.ct_admin_market_data(text,bigint),public.ct_admin_market_update(uuid,text,jsonb,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_diamond_store(),public.ct_buy_diamonds_simulated(uuid,integer,bigint,bigint,text),public.ct_market_command(uuid,text,jsonb),public.ct_admin_market_data(text,bigint),public.ct_admin_market_update(uuid,text,jsonb,text) TO authenticated;
CREATE OR REPLACE FUNCTION public.ct_diamond_balance() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('balance',coalesce((SELECT balance FROM public.ct_diamond_wallets WHERE user_id=auth.uid()),0),'credits_per_diamond',(SELECT credits_per_diamond FROM public.ct_market_settings WHERE id));
$$;
ALTER FUNCTION public.ct_market_snapshot(text,bigint) RENAME TO ct_market_snapshot_before_checkout;
REVOKE ALL ON FUNCTION public.ct_market_snapshot_before_checkout(text,bigint) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_market_snapshot(p_search text DEFAULT '',p_before bigint DEFAULT NULL) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT public.ct_market_snapshot_before_checkout(p_search,p_before)||jsonb_build_object('credits_per_diamond',(SELECT credits_per_diamond FROM public.ct_market_settings WHERE id));
$$;
REVOKE ALL ON FUNCTION public.ct_market_snapshot(text,bigint) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_market_snapshot(text,bigint) TO authenticated;
COMMIT;
