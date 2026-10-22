BEGIN;
CREATE TABLE public.ct_demo_card_tiers(
 id text PRIMARY KEY CHECK(id IN('basic','premium','gold','platinum','diamond','cosmic')),name text NOT NULL,rank integer NOT NULL UNIQUE,
 version bigint NOT NULL DEFAULT 1,active boolean NOT NULL DEFAULT true,purchases_enabled boolean NOT NULL DEFAULT true,
 eur_per_diamond numeric(24,12) CHECK(eur_per_diamond BETWEEN 0.01 AND 1000000),
 min_purchase_cents bigint NOT NULL DEFAULT 1 CHECK(min_purchase_cents BETWEEN 1 AND 100000000),
 max_purchase_cents bigint NOT NULL CHECK(max_purchase_cents BETWEEN 1 AND 100000000),
 daily_cents bigint NOT NULL CHECK(daily_cents BETWEEN 1 AND 1000000000),
 lifetime_cents bigint CHECK(lifetime_cents BETWEEN 1 AND 9000000000000),CHECK(min_purchase_cents<=max_purchase_cents));
INSERT INTO public.ct_demo_card_tiers(id,name,rank,max_purchase_cents,daily_cents,lifetime_cents) VALUES
 ('basic','Basique',1,50000,100000,1000000),('premium','Premium',2,100000,200000,5000000),('gold','Gold',3,200000,500000,10000000),('platinum','Platine',4,500000,1000000,50000000),('diamond','Diamond',5,1000000,5000000,100000000),('cosmic','Cosmic',6,5000000,10000000,NULL);
CREATE TABLE public.ct_demo_cards(user_id uuid PRIMARY KEY REFERENCES public.ct_profiles(id) ON DELETE CASCADE,tier_id text NOT NULL REFERENCES public.ct_demo_card_tiers(id),version bigint NOT NULL DEFAULT 1,suspended boolean NOT NULL DEFAULT false,created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX ct_demo_cards_tier ON public.ct_demo_cards(tier_id);
ALTER TABLE public.ct_simulated_diamond_purchases ADD COLUMN card_tier text REFERENCES public.ct_demo_card_tiers(id),ADD COLUMN card_version bigint;
CREATE INDEX ct_simulated_purchases_card ON public.ct_simulated_diamond_purchases(card_tier);
ALTER TABLE public.ct_demo_card_tiers ENABLE ROW LEVEL SECURITY;ALTER TABLE public.ct_demo_cards ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ct_demo_card_tiers,public.ct_demo_cards FROM PUBLIC,anon,authenticated;
-- No automatic card is issued to existing players. Issuance requires an administrator or a paid entry.
CREATE FUNCTION public.ct_circle_member(p_user uuid) RETURNS boolean LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM public.ct_demo_cards c JOIN public.ct_demo_card_tiers t ON t.id=c.tier_id WHERE c.user_id=p_user AND NOT c.suspended AND t.active);
$$;
REVOKE ALL ON FUNCTION public.ct_circle_member(uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_circle_access() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('member',public.ct_circle_member(auth.uid()),'entry_price',150000,'card',(SELECT to_jsonb(c)||jsonb_build_object('name',t.name,'active',t.active) FROM public.ct_demo_cards c JOIN public.ct_demo_card_tiers t ON t.id=c.tier_id WHERE c.user_id=auth.uid()),'tiers',(SELECT jsonb_agg(to_jsonb(t)||jsonb_build_object('eur_per_diamond',t.eur_per_diamond::text) ORDER BY rank) FROM public.ct_demo_card_tiers t));
$$;
CREATE FUNCTION public.ct_join_circle(p_operation_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;q jsonb:='{"kind":"join_circle"}';
BEGIN
 PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;
 IF EXISTS(SELECT 1 FROM public.ct_demo_cards WHERE user_id=u) THEN RAISE EXCEPTION 'Vous possédez déjà une carte. Contactez un administrateur si elle est suspendue.';END IF;
 IF NOT(SELECT active FROM public.ct_demo_card_tiers WHERE id='basic') OR NOT(SELECT market_enabled FROM public.ct_market_settings WHERE id) THEN RAISE EXCEPTION 'Les entrées dans le cercle sont suspendues';END IF;
 PERFORM public.ct_check_rate(u);PERFORM public.ct_post_credit(u,-150000,'circle_entry','circle-entry:'||p_operation_id::text);
 INSERT INTO public.ct_demo_cards(user_id,tier_id) VALUES(u,'basic');r:=jsonb_build_object('ok',true,'tier_id','basic','price',150000);
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;
END $$;
CREATE FUNCTION public.ct_admin_cards(p_search text DEFAULT '') RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 IF length(coalesce(p_search,''))>50 THEN RAISE EXCEPTION 'Recherche trop longue';END IF;
 RETURN jsonb_build_object('tiers',(SELECT jsonb_agg(to_jsonb(t)||jsonb_build_object('eur_per_diamond',eur_per_diamond::text) ORDER BY rank) FROM public.ct_demo_card_tiers t),'players',coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM(SELECT p.id,p.username,c.tier_id,c.version,c.suspended,(SELECT coalesce(sum(total_cents),0) FROM public.ct_simulated_diamond_purchases WHERE user_id=p.id) spent_total_cents FROM public.ct_profiles p LEFT JOIN public.ct_demo_cards c ON c.user_id=p.id WHERE NOT p.is_bot AND position(lower(coalesce(p_search,'')) IN lower(p.username))>0 ORDER BY p.username LIMIT 30)x),'[]'::jsonb));END $$;
CREATE FUNCTION public.ct_admin_card_update(p_operation_id uuid,p_action text,p_values jsonb,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;q jsonb:=jsonb_build_object('kind','admin_card','action',p_action,'values',p_values,'reason',p_reason);c public.ct_demo_cards;t public.ct_demo_card_tiers;v_user uuid;
BEGIN PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;
 IF length(trim(coalesce(p_reason,''))) NOT BETWEEN 8 AND 1000 THEN RAISE EXCEPTION 'Justification requise';END IF;
 IF p_action='tier' THEN
  SELECT * INTO t FROM public.ct_demo_card_tiers WHERE id=p_values->>'id' FOR UPDATE;
  IF NOT FOUND OR(p_values->>'version')::bigint IS DISTINCT FROM t.version THEN RAISE EXCEPTION 'Carte modifiée. Actualisez.';END IF;
  UPDATE public.ct_demo_card_tiers SET active=(p_values->>'active')::boolean,purchases_enabled=(p_values->>'purchases_enabled')::boolean,eur_per_diamond=nullif(p_values->>'eur_per_diamond','')::numeric,min_purchase_cents=(p_values->>'min_purchase_cents')::bigint,max_purchase_cents=(p_values->>'max_purchase_cents')::bigint,daily_cents=(p_values->>'daily_cents')::bigint,lifetime_cents=nullif(p_values->>'lifetime_cents','')::bigint,version=version+1 WHERE id=t.id;
 ELSIF p_action IN('assign','suspend','revoke') THEN
  SELECT id INTO v_user FROM public.ct_profiles WHERE lower(username)=lower(trim(p_values->>'username')) AND NOT is_bot;
  IF v_user IS NULL THEN RAISE EXCEPTION 'Joueur introuvable';END IF;
  SELECT * INTO c FROM public.ct_demo_cards WHERE user_id=v_user FOR UPDATE;
  IF(p_values->>'version')::bigint IS DISTINCT FROM c.version THEN RAISE EXCEPTION 'Attribution modifiée. Actualisez.';END IF;
  IF p_action='assign' THEN
   IF NOT EXISTS(SELECT 1 FROM public.ct_demo_card_tiers WHERE id=p_values->>'tier_id') THEN RAISE EXCEPTION 'Carte inconnue';END IF;
   INSERT INTO public.ct_demo_cards(user_id,tier_id,version) VALUES(v_user,p_values->>'tier_id',(SELECT version+1 FROM public.ct_market_settings WHERE id)) ON CONFLICT(user_id) DO UPDATE SET tier_id=EXCLUDED.tier_id,suspended=false,version=EXCLUDED.version,updated_at=now();
  ELSIF p_action='suspend' THEN
   IF c.user_id IS NULL THEN RAISE EXCEPTION 'Aucune carte attribuée';END IF;
   UPDATE public.ct_demo_cards SET suspended=(p_values->>'suspended')::boolean,version=version+1,updated_at=now() WHERE user_id=v_user;
  ELSE DELETE FROM public.ct_demo_cards WHERE user_id=v_user;END IF;
 ELSE RAISE EXCEPTION 'Action inconnue';END IF;
 UPDATE public.ct_market_settings SET version=version+1 WHERE id;
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(u,'card_'||p_action,coalesce(v_user::text,t.id),p_reason,p_values);
 r:='{"ok":true}';INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;
END $$;
CREATE OR REPLACE FUNCTION public.ct_diamond_store() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('version',s.version,'eur_per_diamond',coalesce(t.eur_per_diamond,s.eur_per_diamond)::text,'purchases_enabled',s.purchases_enabled AND coalesce(t.purchases_enabled,false) AND public.ct_circle_member(auth.uid()),'wallets_frozen',s.wallets_frozen,'market_enabled',s.market_enabled,'max_purchase_cents',least(s.max_purchase_cents,coalesce(t.max_purchase_cents,s.max_purchase_cents)),'min_purchase_cents',coalesce(t.min_purchase_cents,1),'daily_user_cents',least(s.daily_user_cents,coalesce(t.daily_cents,s.daily_user_cents)),'lifetime_cents',t.lifetime_cents,'spent_total_cents',(SELECT coalesce(sum(total_cents),0) FROM public.ct_simulated_diamond_purchases WHERE user_id=auth.uid()),'total_cap_reached',s.total_cap_cents IS NOT NULL AND(SELECT coalesce(sum(total_cents),0) FROM public.ct_simulated_diamond_purchases)>=s.total_cap_cents,'spent_today_cents',(SELECT coalesce(sum(total_cents),0) FROM public.ct_simulated_diamond_purchases WHERE user_id=auth.uid() AND created_at>=date_trunc('day',now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'),'card_tier',t.id,'card_name',t.name,'simulated',true) FROM public.ct_market_settings s LEFT JOIN public.ct_demo_cards c ON c.user_id=auth.uid() LEFT JOIN public.ct_demo_card_tiers t ON t.id=c.tier_id WHERE s.id;
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
 IF v_cents<t.min_purchase_cents OR v_cents>least(s.max_purchase_cents,t.max_purchase_cents) OR v_spent+v_cents>least(s.daily_user_cents,t.daily_cents) OR(t.lifetime_cents IS NOT NULL AND v_lifetime+v_cents>t.lifetime_cents) OR(s.total_cap_cents IS NOT NULL AND v_total+v_cents>s.total_cap_cents) THEN RAISE EXCEPTION 'Plafond de simulation ou montant minimum de la carte atteint';END IF;
 INSERT INTO public.ct_simulated_diamond_purchases(user_id,operation_id,quantity,unit_eur,total_cents,settings_version,demo_method,card_tier,card_version) VALUES(u,p_operation_id,p_quantity,v_rate,v_cents,s.version,p_demo_method,t.id,t.version);
 PERFORM public.ct_post_diamond(u,p_quantity,'simulated_purchase','sim-purchase:'||p_operation_id::text);r:=jsonb_build_object('ok',true,'simulated',true,'total_cents',v_cents,'diamonds',p_quantity,'card_tier',t.id);
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;
END $$;
ALTER FUNCTION public.ct_market_command(uuid,text,jsonb) RENAME TO ct_market_command_before_circle;
REVOKE ALL ON FUNCTION public.ct_market_command_before_circle(uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_market_command(p_operation_id uuid,p_action text,p_values jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;l public.ct_market_listings;
BEGIN PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,jsonb_build_object('kind','market','action',p_action,'values',p_values));IF r IS NOT NULL THEN RETURN r;END IF;
 IF p_action IN('list','accept','convert') AND NOT public.ct_circle_member(u) THEN RAISE EXCEPTION 'Accès réservé au cercle fermé : carte active requise';END IF;
 IF p_action='accept' THEN SELECT * INTO l FROM public.ct_market_listings WHERE id=(p_values->>'listing_id')::bigint;IF l.status='active' AND NOT public.ct_circle_member(l.seller_id) THEN RAISE EXCEPTION 'Le vendeur ne dispose plus d’une carte active';END IF;END IF;
 RETURN public.ct_market_command_before_circle(p_operation_id,p_action,p_values);END $$;
ALTER FUNCTION public.ct_market_snapshot(text,bigint) RENAME TO ct_market_snapshot_before_circle;
REVOKE ALL ON FUNCTION public.ct_market_snapshot_before_circle(text,bigint) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_market_snapshot(p_search text DEFAULT '',p_before bigint DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE r jsonb;BEGIN r:=public.ct_market_snapshot_before_circle(p_search,p_before);IF NOT public.ct_circle_member(auth.uid()) THEN r:=r||jsonb_build_object('listings','[]'::jsonb);END IF;RETURN r;END $$;
ALTER FUNCTION public.ct_trade_command(uuid,text,jsonb) RENAME TO ct_trade_command_before_circle;
REVOKE ALL ON FUNCTION public.ct_trade_command_before_circle(uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_trade_command(p_operation_id uuid,p_action text,p_values jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;t public.ct_direct_trades;v_target uuid;
BEGIN PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,jsonb_build_object('kind','direct_trade','action',p_action,'values',p_values));IF r IS NOT NULL THEN RETURN r;END IF;
 IF p_action<>'cancel' THEN
  IF NOT public.ct_circle_member(u) THEN RAISE EXCEPTION 'Accès réservé au cercle fermé : carte active requise';END IF;
  IF p_action='invite' THEN SELECT id INTO v_target FROM public.ct_profiles WHERE lower(username)=lower(trim(p_values->>'username'));ELSE SELECT * INTO t FROM public.ct_direct_trades WHERE id=(p_values->>'trade_id')::uuid AND u IN(a,b);v_target:=CASE WHEN t.a=u THEN t.b ELSE t.a END;END IF;
  IF NOT public.ct_circle_member(v_target) THEN RAISE EXCEPTION 'Ce joueur ne dispose pas d’une carte active du cercle';END IF;
 END IF;RETURN public.ct_trade_command_before_circle(p_operation_id,p_action,p_values);END $$;
REVOKE ALL ON FUNCTION public.ct_circle_access(),public.ct_join_circle(uuid),public.ct_admin_cards(text),public.ct_admin_card_update(uuid,text,jsonb,text),public.ct_market_command(uuid,text,jsonb),public.ct_market_snapshot(text,bigint),public.ct_trade_command(uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_circle_access(),public.ct_join_circle(uuid),public.ct_admin_cards(text),public.ct_admin_card_update(uuid,text,jsonb,text),public.ct_market_command(uuid,text,jsonb),public.ct_market_snapshot(text,bigint),public.ct_trade_command(uuid,text,jsonb) TO authenticated;
COMMIT;

