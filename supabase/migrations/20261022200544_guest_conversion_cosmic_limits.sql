BEGIN;
-- Controlled bridge for legacy guests with a server-generated placeholder email.
-- Only the service can mark that placeholder unconfirmed before the Auth API sets a real address.
CREATE FUNCTION public.ct_prepare_guest_conversion(p_user uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a jsonb;
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended(p_user::text,321));
 SELECT to_jsonb(u) INTO a FROM auth.users u WHERE id=p_user FOR UPDATE;
 IF a IS NULL OR coalesce((a->'raw_app_meta_data'->>'ct_guest')::boolean,false)=false OR NOT EXISTS(SELECT 1 FROM public.ct_profiles WHERE id=p_user AND NOT is_bot) OR EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=p_user) THEN RAISE EXCEPTION 'Compte invité requis';END IF;
 IF a->>'email' NOT LIKE '%@guest.casino.invalid' AND a->>'email_confirmed_at' IS NOT NULL THEN RAISE EXCEPTION 'Adresse déjà confirmée. Choisissez votre mot de passe.';END IF;
 PERFORM public.ct_check_rate(p_user);
 UPDATE auth.users SET email_confirmed_at=NULL WHERE id=p_user;
END $$;
REVOKE ALL ON FUNCTION public.ct_prepare_guest_conversion(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_prepare_guest_conversion(uuid) TO service_role;
DO $$ DECLARE c record;BEGIN
 FOR c IN SELECT conname FROM pg_constraint WHERE conrelid='public.ct_demo_card_tiers'::regclass AND contype='c' AND(pg_get_constraintdef(oid) LIKE '%eur_per_diamond%' OR pg_get_constraintdef(oid) LIKE '%min_purchase_cents%' OR pg_get_constraintdef(oid) LIKE '%max_purchase_cents%' OR pg_get_constraintdef(oid) LIKE '%daily_cents%') LOOP EXECUTE format('ALTER TABLE public.ct_demo_card_tiers DROP CONSTRAINT %I',c.conname);END LOOP;
END $$;
ALTER TABLE public.ct_demo_card_tiers ADD CONSTRAINT ct_card_rates CHECK(eur_per_diamond IS NULL OR(eur_per_diamond>=0.01 AND eur_per_diamond<=CASE WHEN id='cosmic' THEN 90000000000 ELSE 1000000 END)),
 ADD CONSTRAINT ct_card_minimum CHECK(min_purchase_cents BETWEEN 1 AND CASE WHEN id='cosmic' THEN 9000000000000 ELSE 100000000 END),
 ADD CONSTRAINT ct_card_maximum CHECK(max_purchase_cents BETWEEN 1 AND CASE WHEN id='cosmic' THEN 9000000000000 ELSE 100000000 END),
 ADD CONSTRAINT ct_card_daily CHECK(daily_cents BETWEEN 1 AND CASE WHEN id='cosmic' THEN 9000000000000 ELSE 1000000000 END),
 ADD CONSTRAINT ct_card_range CHECK(min_purchase_cents<=max_purchase_cents);
CREATE OR REPLACE FUNCTION public.ct_diamond_store() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('version',s.version,'eur_per_diamond',coalesce(t.eur_per_diamond,s.eur_per_diamond)::text,'purchases_enabled',s.purchases_enabled AND coalesce(t.purchases_enabled,false) AND public.ct_circle_member(auth.uid()),'wallets_frozen',s.wallets_frozen,'market_enabled',s.market_enabled,'max_purchase_cents',CASE WHEN t.id='cosmic' THEN t.max_purchase_cents ELSE least(s.max_purchase_cents,t.max_purchase_cents) END,'min_purchase_cents',coalesce(t.min_purchase_cents,1),'daily_user_cents',CASE WHEN t.id='cosmic' THEN t.daily_cents ELSE least(s.daily_user_cents,t.daily_cents) END,'lifetime_cents',t.lifetime_cents,'spent_total_cents',(SELECT coalesce(sum(total_cents),0) FROM public.ct_simulated_diamond_purchases WHERE user_id=auth.uid()),'total_cap_reached',s.total_cap_cents IS NOT NULL AND(SELECT coalesce(sum(total_cents),0) FROM public.ct_simulated_diamond_purchases)>=s.total_cap_cents,'spent_today_cents',(SELECT coalesce(sum(total_cents),0) FROM public.ct_simulated_diamond_purchases WHERE user_id=auth.uid() AND created_at>=date_trunc('day',now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'),'card_tier',t.id,'card_name',t.name,'simulated',true) FROM public.ct_market_settings s LEFT JOIN public.ct_demo_cards c ON c.user_id=auth.uid() LEFT JOIN public.ct_demo_card_tiers t ON t.id=c.tier_id WHERE s.id;
$$;
CREATE OR REPLACE FUNCTION public.ct_buy_diamonds_simulated(p_operation_id uuid,p_quantity integer,p_expected_version bigint,p_expected_total_cents bigint,p_demo_method text DEFAULT 'demo_card') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;q jsonb:=jsonb_build_object('kind','simulated_diamond_purchase','quantity',p_quantity,'version',p_expected_version,'total_cents',p_expected_total_cents,'demo_method',p_demo_method);s public.ct_market_settings;t public.ct_demo_card_tiers;c public.ct_demo_cards;v_rate numeric;v_cents bigint;v_spent bigint;v_total bigint;v_lifetime bigint;
BEGIN
 PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;PERFORM public.ct_check_rate(u);
 SELECT * INTO s FROM public.ct_market_settings WHERE id;SELECT * INTO c FROM public.ct_demo_cards WHERE user_id=u;SELECT * INTO t FROM public.ct_demo_card_tiers WHERE id=c.tier_id;
 IF NOT public.ct_circle_member(u) THEN RAISE EXCEPTION 'Une carte active du cercle fermé est requise';END IF;
 IF NOT s.purchases_enabled OR s.wallets_frozen OR NOT t.purchases_enabled THEN RAISE EXCEPTION 'Les achats fictifs de diamants sont suspendus';END IF;
 IF p_quantity IS NULL OR p_quantity NOT BETWEEN 1 AND 10000 OR p_demo_method IS DISTINCT FROM 'demo_card' THEN RAISE EXCEPTION 'Simulation invalide : carte de démonstration uniquement';END IF;
 v_rate:=coalesce(t.eur_per_diamond,s.eur_per_diamond);v_cents:=round(p_quantity*v_rate*100)::bigint;
 IF p_expected_version IS DISTINCT FROM s.version OR p_expected_total_cents IS DISTINCT FROM v_cents THEN RAISE EXCEPTION 'Le tarif a changé. Actualisez et confirmez le nouveau total.';END IF;
 SELECT coalesce(sum(total_cents),0),coalesce(sum(total_cents) FILTER(WHERE created_at>=date_trunc('day',now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'),0) INTO v_lifetime,v_spent FROM public.ct_simulated_diamond_purchases WHERE user_id=u;
 SELECT coalesce(sum(total_cents),0) INTO v_total FROM public.ct_simulated_diamond_purchases;
 IF v_cents<t.min_purchase_cents OR v_cents>(CASE WHEN t.id='cosmic' THEN t.max_purchase_cents ELSE least(s.max_purchase_cents,t.max_purchase_cents) END) OR v_spent+v_cents>(CASE WHEN t.id='cosmic' THEN t.daily_cents ELSE least(s.daily_user_cents,t.daily_cents) END) OR(t.lifetime_cents IS NOT NULL AND v_lifetime+v_cents>t.lifetime_cents) OR(s.total_cap_cents IS NOT NULL AND v_total+v_cents>s.total_cap_cents) THEN RAISE EXCEPTION 'Plafond de simulation ou montant minimum de la carte atteint';END IF;
 INSERT INTO public.ct_simulated_diamond_purchases(user_id,operation_id,quantity,unit_eur,total_cents,settings_version,demo_method,card_tier,card_version) VALUES(u,p_operation_id,p_quantity,v_rate,v_cents,s.version,p_demo_method,t.id,t.version);
 PERFORM public.ct_post_diamond(u,p_quantity,'simulated_purchase','sim-purchase:'||p_operation_id::text);r:=jsonb_build_object('ok',true,'simulated',true,'total_cents',v_cents,'diamonds',p_quantity,'card_tier',t.id);
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;
END $$;
COMMIT;
