BEGIN;
ALTER TABLE public.ct_demo_card_tiers ADD COLUMN market_fee_bps integer NOT NULL DEFAULT 1000 CHECK(market_fee_bps BETWEEN 0 AND 1000);
UPDATE public.ct_demo_card_tiers SET market_fee_bps=CASE id WHEN 'basic' THEN 1000 WHEN 'premium' THEN 800 WHEN 'gold' THEN 600 WHEN 'platinum' THEN 400 WHEN 'diamond' THEN 200 ELSE 0 END;
-- Activate fees after the matching checkout UI has been deployed.
CREATE TABLE public.ct_market_finance(id boolean PRIMARY KEY DEFAULT true CHECK(id),fees_enabled boolean NOT NULL DEFAULT false,pin_price bigint NOT NULL DEFAULT 25 CHECK(pin_price BETWEEN 1 AND 1000000),home_price bigint NOT NULL DEFAULT 250 CHECK(home_price BETWEEN 1 AND 1000000),CHECK(home_price>pin_price));
INSERT INTO public.ct_market_finance(id) VALUES(true);
CREATE TABLE public.ct_market_server_ledger(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,user_id uuid NOT NULL REFERENCES public.ct_profiles(id),diamond_ledger_id bigint NOT NULL UNIQUE REFERENCES public.ct_diamond_ledger(id),amount bigint NOT NULL CHECK(amount>0),reason text NOT NULL,created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX ct_market_server_reason ON public.ct_market_server_ledger(reason,id DESC);
CREATE TABLE public.ct_market_promotions(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),seller_id uuid NOT NULL REFERENCES public.ct_profiles(id),kind text NOT NULL CHECK(kind IN('listing','stock','credits')),target_key text NOT NULL,placement text NOT NULL CHECK(placement IN('pin','home')),price bigint NOT NULL CHECK(price>0),created_at timestamptz NOT NULL DEFAULT now(),expires_at timestamptz NOT NULL DEFAULT now()+interval '24 hours');
CREATE INDEX ct_market_promotions_target ON public.ct_market_promotions(kind,target_key,expires_at DESC);
CREATE INDEX ct_market_promotions_seller ON public.ct_market_promotions(seller_id,expires_at DESC);
ALTER TABLE public.ct_market_finance ENABLE ROW LEVEL SECURITY;ALTER TABLE public.ct_market_server_ledger ENABLE ROW LEVEL SECURITY;ALTER TABLE public.ct_market_promotions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ct_market_finance,public.ct_market_server_ledger,public.ct_market_promotions FROM PUBLIC,anon,authenticated;
REVOKE ALL ON SEQUENCE public.ct_market_server_ledger_id_seq FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.ct_market_fee_rate(p_user uuid) RETURNS integer LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT CASE WHEN NOT (SELECT fees_enabled FROM public.ct_market_finance WHERE id) THEN 0 ELSE coalesce((SELECT t.market_fee_bps FROM public.ct_demo_cards c JOIN public.ct_demo_card_tiers t ON t.id=c.tier_id WHERE c.user_id=p_user AND NOT c.suspended AND t.active),1000) END;
$$;
CREATE FUNCTION public.ct_market_payment(p_subtotal bigint) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE b integer;f bigint;
BEGIN
 IF auth.uid() IS NULL OR NOT public.ct_circle_member(auth.uid()) THEN RAISE EXCEPTION 'Carte active requise';END IF;
 IF p_subtotal IS NULL OR p_subtotal NOT BETWEEN 0 AND 1000000000000 THEN RAISE EXCEPTION 'Prix invalide';END IF;
 b:=public.ct_market_fee_rate(auth.uid());f:=ceil(p_subtotal::numeric*b/10000)::bigint;
 RETURN jsonb_build_object('subtotal',p_subtotal,'fee_bps',b,'fee',f,'total',p_subtotal+f);
END $$;
CREATE FUNCTION public.ct_capture_market_revenue() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE f bigint;
BEGIN
 IF NEW.amount<0 AND NEW.reason='market_purchase' THEN
  f:=ceil(-NEW.amount::numeric*public.ct_market_fee_rate(NEW.user_id)/10000)::bigint;
  IF f>0 THEN
   IF (SELECT balance FROM public.ct_diamond_wallets WHERE user_id=NEW.user_id)-public.ct_direct_diamonds(NEW.user_id)<f THEN RAISE EXCEPTION 'Diamants insuffisants, frais compris';END IF;
   PERFORM public.ct_post_diamond(NEW.user_id,-f,'market_fee',NEW.operation_key||':fee');
  END IF;
 ELSIF NEW.amount<0 AND NEW.reason IN('market_fee','market_promotion') THEN
  INSERT INTO public.ct_market_server_ledger(user_id,diamond_ledger_id,amount,reason) VALUES(NEW.user_id,NEW.id,-NEW.amount,NEW.reason);
 END IF;RETURN NEW;
END $$;
CREATE TRIGGER ct_capture_market_revenue AFTER INSERT ON public.ct_diamond_ledger FOR EACH ROW EXECUTE FUNCTION public.ct_capture_market_revenue();
REVOKE ALL ON FUNCTION public.ct_market_fee_rate(uuid),public.ct_capture_market_revenue() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.ct_market_payment(bigint) FROM PUBLIC,anon,authenticated;GRANT EXECUTE ON FUNCTION public.ct_market_payment(bigint) TO authenticated;

ALTER FUNCTION public.ct_market_chest_group_quote(text,integer) RENAME TO ct_market_chest_group_quote_before_fees;
REVOKE ALL ON FUNCTION public.ct_market_chest_group_quote_before_fees(text,integer) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_market_chest_group_quote(p_group text,p_quantity integer) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE q jsonb;p jsonb;
BEGIN q:=public.ct_market_chest_group_quote_before_fees(p_group,p_quantity);p:=public.ct_market_payment((q->>'total')::bigint);
 RETURN q||p||jsonb_build_object('token',md5((q->>'token')||':'||(p->>'fee_bps')));
END $$;
REVOKE ALL ON FUNCTION public.ct_market_chest_group_quote(text,integer) FROM PUBLIC,anon,authenticated;GRANT EXECUTE ON FUNCTION public.ct_market_chest_group_quote(text,integer) TO authenticated;

ALTER FUNCTION public.ct_market_command(uuid,text,jsonb) RENAME TO ct_market_command_before_fees;
REVOKE ALL ON FUNCTION public.ct_market_command_before_fees(uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_market_command(p_operation_id uuid,p_action text,p_values jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;p jsonb;price bigint;
BEGIN
 PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();
 IF p_action='accept' AND NOT EXISTS(SELECT 1 FROM public.ct_operations WHERE user_id=u AND operation_id=p_operation_id) THEN
  SELECT l.price INTO price FROM public.ct_market_listings l WHERE id=(p_values->>'listing_id')::bigint;
  IF price IS NOT NULL THEN p:=public.ct_market_payment(price);IF(p->>'fee')::bigint>0 AND(p_values->>'expected_fee')::bigint IS DISTINCT FROM(p->>'fee')::bigint THEN RAISE EXCEPTION 'Les frais ont changé. Vérifiez le total avant de confirmer';END IF;END IF;
 END IF;
 RETURN public.ct_market_command_before_fees(p_operation_id,p_action,p_values);
END $$;
ALTER FUNCTION public.ct_credit_market_command(uuid,text,jsonb) RENAME TO ct_credit_market_command_before_fees;
REVOKE ALL ON FUNCTION public.ct_credit_market_command_before_fees(uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_credit_market_command(p_operation_id uuid,p_action text,p_values jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;p jsonb;price bigint;
BEGIN
 PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();
 IF p_action='buy' AND NOT EXISTS(SELECT 1 FROM public.ct_operations WHERE user_id=u AND operation_id=p_operation_id) THEN
  SELECT o.price INTO price FROM public.ct_credit_offers o WHERE id=(p_values->>'id')::bigint;
  IF price IS NOT NULL THEN p:=public.ct_market_payment(price);IF(p->>'fee')::bigint>0 AND(p_values->>'expected_fee')::bigint IS DISTINCT FROM(p->>'fee')::bigint THEN RAISE EXCEPTION 'Les frais ont changé. Vérifiez le total avant de confirmer';END IF;END IF;
 END IF;RETURN public.ct_credit_market_command_before_fees(p_operation_id,p_action,p_values);
END $$;
ALTER FUNCTION public.ct_wholesale_command(uuid,text,jsonb) RENAME TO ct_wholesale_command_before_fees;
REVOKE ALL ON FUNCTION public.ct_wholesale_command_before_fees(uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_wholesale_command(p_operation_id uuid,p_action text,p_values jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;p jsonb;price bigint;o public.ct_wholesale_offers;
BEGIN
 PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();
 IF p_action='buy' AND NOT EXISTS(SELECT 1 FROM public.ct_operations WHERE user_id=u AND operation_id=p_operation_id) THEN
  SELECT * INTO o FROM public.ct_wholesale_offers WHERE id=(p_values->>'id')::uuid;
  IF o.id IS NOT NULL THEN SELECT coalesce((SELECT(t->>'price')::bigint FROM jsonb_array_elements(o.tiers)t WHERE(t->>'min')::int<=(p_values->>'quantity')::int ORDER BY(t->>'min')::int DESC LIMIT 1),o.base_price)*(p_values->>'quantity')::int INTO price;p:=public.ct_market_payment(price);
   IF(p->>'fee')::bigint>0 AND(p_values->>'expected_fee')::bigint IS DISTINCT FROM(p->>'fee')::bigint THEN RAISE EXCEPTION 'Les frais ont changé. Vérifiez le total avant de confirmer';END IF;
  END IF;
 END IF;RETURN public.ct_wholesale_command_before_fees(p_operation_id,p_action,p_values);
END $$;
REVOKE ALL ON FUNCTION public.ct_market_command(uuid,text,jsonb),public.ct_credit_market_command(uuid,text,jsonb),public.ct_wholesale_command(uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_market_command(uuid,text,jsonb),public.ct_credit_market_command(uuid,text,jsonb),public.ct_wholesale_command(uuid,text,jsonb) TO authenticated;

ALTER FUNCTION public.ct_market_snapshot(text,bigint) RENAME TO ct_market_snapshot_before_finance;
REVOKE ALL ON FUNCTION public.ct_market_snapshot_before_finance(text,bigint) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_market_snapshot(p_search text DEFAULT '',p_before bigint DEFAULT NULL) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$ SELECT public.ct_market_snapshot_before_finance(p_search,p_before)||jsonb_build_object('fee_bps',public.ct_market_fee_rate(auth.uid())) $$;
ALTER FUNCTION public.ct_credit_market(text,bigint,text) RENAME TO ct_credit_market_before_finance;
REVOKE ALL ON FUNCTION public.ct_credit_market_before_finance(text,bigint,text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_credit_market(p_view text DEFAULT 'browse',p_before bigint DEFAULT NULL,p_search text DEFAULT '') RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE r jsonb;rows jsonb;offset_n bigint:=greatest(0,coalesce(p_before,0));n bigint;
BEGIN
 r:=public.ct_credit_market_before_finance(p_view,CASE WHEN p_view='browse' THEN NULL ELSE p_before END,p_search);
 IF p_view='browse' THEN
  WITH available AS MATERIALIZED(
   SELECT o.*,p.username seller,t.username target,b.username buyer,EXISTS(SELECT 1 FROM public.ct_market_promotions pr WHERE pr.kind='credits' AND pr.target_key=o.id::text AND pr.expires_at>now()) pinned
   FROM public.ct_credit_offers o JOIN public.ct_profiles p ON p.id=o.seller_id LEFT JOIN public.ct_profiles t ON t.id=o.target_id LEFT JOIN public.ct_profiles b ON b.id=o.buyer_id
   WHERE o.status='active' AND o.expires_at>now() AND(o.target_id IS NULL OR o.target_id=auth.uid() OR o.seller_id=auth.uid()) AND public.ct_circle_member(o.seller_id) AND NOT EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=o.seller_id) AND p.username ILIKE '%'||left(coalesce(p_search,''),50)||'%'
  ),ranked AS(SELECT *,row_number() OVER(ORDER BY pinned DESC,id DESC) rn FROM available)
  SELECT coalesce((SELECT jsonb_agg(to_jsonb(x)-'rn' ORDER BY rn) FROM ranked x WHERE rn>offset_n AND rn<=offset_n+30),'[]'::jsonb),(SELECT count(*) FROM available) INTO rows,n;
  r:=r||jsonb_build_object('offers',rows,'next_before',CASE WHEN n>offset_n+30 THEN offset_n+30 END);
 END IF;
 RETURN r||jsonb_build_object('fee_bps',public.ct_market_fee_rate(auth.uid()));
END $$;
REVOKE ALL ON FUNCTION public.ct_market_snapshot(text,bigint),public.ct_credit_market(text,bigint,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_market_snapshot(text,bigint),public.ct_credit_market(text,bigint,text) TO authenticated;

CREATE FUNCTION public.ct_market_offer_info(p_kind text,p_key text) RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path='' AS $$
DECLARE r jsonb;
BEGIN
 IF p_kind='listing' THEN
  SELECT jsonb_build_object('seller_id',l.seller_id,'seller',p.username,'name',l.name,'rarity',l.rarity,'price',l.price,'stock',1,'kind',l.asset_kind,'group_key',CASE WHEN sc.id IS NOT NULL THEN md5(jsonb_build_array(l.seller_id,sc.chest_id,l.name,l.rarity,l.price,sc.weights,sc.title_ids)::text) END)
  INTO r FROM public.ct_market_listings l JOIN public.ct_profiles p ON p.id=l.seller_id LEFT JOIN public.ct_sealed_chests sc ON l.asset_kind='chest' AND sc.id=l.asset_id AND sc.user_id=l.seller_id AND sc.opened_at IS NULL
  WHERE l.id::text=p_key AND l.status='active' AND l.expires_at>now() AND l.target_id IS NULL AND l.wanted_kind IS NULL AND public.ct_circle_member(l.seller_id) AND NOT EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=l.seller_id)
  AND(l.asset_kind='chest' AND sc.id IS NOT NULL OR l.asset_kind='title' AND EXISTS(SELECT 1 FROM public.ct_player_titles WHERE id=l.asset_id AND user_id=l.seller_id AND revoked_at IS NULL));
 ELSIF p_kind='stock' THEN
  SELECT jsonb_build_object('seller_id',o.seller_id,'seller',p.username,'name',o.name,'rarity',o.rarity,'price',o.base_price,'stock',o.remaining,'kind','chest','group_key',md5(jsonb_build_array(o.seller_id,o.chest_id,o.name,o.rarity,o.base_price,sc.weights,sc.title_ids)::text)) INTO r
  FROM public.ct_wholesale_offers o JOIN public.ct_profiles p ON p.id=o.seller_id JOIN LATERAL(SELECT s.weights,s.title_ids FROM public.ct_wholesale_assets a JOIN public.ct_sealed_chests s ON s.id=a.asset_id WHERE a.offer_id=o.id AND NOT a.sold AND s.user_id=o.seller_id AND s.opened_at IS NULL LIMIT 1)sc ON true
  WHERE o.id::text=p_key AND o.status='active' AND o.remaining>0 AND o.expires_at>now() AND public.ct_circle_member(o.seller_id) AND NOT EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=o.seller_id);
 ELSIF p_kind='credits' THEN
  SELECT jsonb_build_object('seller_id',o.seller_id,'seller',p.username,'name',o.amount::text||' crédits','rarity',1,'price',o.price,'stock',1,'kind','credits') INTO r FROM public.ct_credit_offers o JOIN public.ct_profiles p ON p.id=o.seller_id WHERE o.id::text=p_key AND o.status='active' AND o.expires_at>now() AND o.target_id IS NULL AND public.ct_circle_member(o.seller_id) AND NOT EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=o.seller_id);
 END IF;RETURN r;
END $$;
REVOKE ALL ON FUNCTION public.ct_market_offer_info(text,text) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.ct_market_promotion_options() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required';END IF;
 RETURN (SELECT jsonb_build_object('pin_price',pin_price,'home_price',home_price,'hours',24,'promotions',coalesce((SELECT jsonb_agg(jsonb_build_object('kind',kind,'target_key',target_key,'placement',placement,'expires_at',expires_at)) FROM public.ct_market_promotions WHERE seller_id=auth.uid() AND expires_at>now()),'[]'::jsonb)) FROM public.ct_market_finance WHERE id);
END $$;
CREATE FUNCTION public.ct_promote_market_offer(p_operation_id uuid,p_kind text,p_key text,p_placement text,p_expected_price bigint) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;info jsonb;price bigint;request jsonb:=jsonb_build_object('kind','promote_market','offer_kind',p_kind,'key',p_key,'placement',p_placement,'price',p_expected_price);
BEGIN
 PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,request);IF r IS NOT NULL THEN RETURN r;END IF;PERFORM public.ct_check_rate(u);
 IF NOT public.ct_circle_member(u) THEN RAISE EXCEPTION 'Carte active requise';END IF;
 IF EXISTS(SELECT 1 FROM public.ct_market_settings WHERE id AND(NOT market_enabled OR wallets_frozen)) THEN RAISE EXCEPTION 'Le marché est suspendu ou figé';END IF;
 IF p_placement IS NULL OR p_placement NOT IN('pin','home') THEN RAISE EXCEPTION 'Option de mise en avant invalide';END IF;
 info:=public.ct_market_offer_info(p_kind,p_key);
 IF info IS NULL OR(info->>'seller_id')::uuid<>u THEN RAISE EXCEPTION 'Seule votre annonce publique active peut être mise en avant';END IF;
 IF EXISTS(SELECT 1 FROM public.ct_market_promotions WHERE kind=p_kind AND target_key=p_key AND expires_at>now()) THEN RAISE EXCEPTION 'Cette annonce est déjà mise en avant';END IF;
 IF p_placement='home' AND(SELECT count(*) FROM public.ct_market_promotions WHERE placement='home' AND expires_at>now() AND public.ct_market_offer_info(kind,target_key) IS NOT NULL)>=6 THEN RAISE EXCEPTION 'Les six places d’accueil sont occupées. Réessayez plus tard';END IF;
 SELECT CASE p_placement WHEN 'pin' THEN pin_price ELSE home_price END INTO price FROM public.ct_market_finance WHERE id;
 IF p_expected_price IS DISTINCT FROM price THEN RAISE EXCEPTION 'Le prix de mise en avant a changé';END IF;
 IF coalesce((SELECT balance FROM public.ct_diamond_wallets WHERE user_id=u),0)-public.ct_direct_diamonds(u)<price THEN RAISE EXCEPTION 'Diamants disponibles insuffisants';END IF;
 PERFORM public.ct_post_diamond(u,-price,'market_promotion','promotion:'||p_operation_id::text);
 INSERT INTO public.ct_market_promotions(seller_id,kind,target_key,placement,price) VALUES(u,p_kind,p_key,p_placement,price);
 r:=jsonb_build_object('ok',true,'price',price,'expires_at',now()+interval '24 hours');INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,request,r);RETURN r;
END $$;
CREATE FUNCTION public.ct_market_featured() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(x.item ORDER BY x.created_at DESC),'[]'::jsonb) FROM(SELECT info||jsonb_build_object('promotion_id',p.id,'expires_at',p.expires_at,'simulated',EXISTS(SELECT 1 FROM public.ct_bots b JOIN public.ct_bot_batches batch ON batch.id=b.batch_id WHERE b.user_id=p.seller_id AND batch.config->>'market_demo_seed'='v1')) item,p.created_at FROM public.ct_market_promotions p CROSS JOIN LATERAL(SELECT public.ct_market_offer_info(p.kind,p.target_key) info)s WHERE p.placement='home' AND p.expires_at>now() AND info IS NOT NULL ORDER BY p.created_at DESC LIMIT 6)x;
$$;
CREATE FUNCTION public.ct_admin_market_finance() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required';END IF;
 RETURN jsonb_build_object('balance',(SELECT coalesce(sum(amount),0) FROM public.ct_market_server_ledger),'fees',(SELECT coalesce(sum(amount),0) FROM public.ct_market_server_ledger WHERE reason='market_fee'),'promotions',(SELECT coalesce(sum(amount),0) FROM public.ct_market_server_ledger WHERE reason='market_promotion'),'tiers',(SELECT jsonb_agg(jsonb_build_object('name',name,'fee_bps',market_fee_bps) ORDER BY rank) FROM public.ct_demo_card_tiers),'pin_price',(SELECT pin_price FROM public.ct_market_finance WHERE id),'home_price',(SELECT home_price FROM public.ct_market_finance WHERE id));
END $$;
REVOKE ALL ON FUNCTION public.ct_market_promotion_options(),public.ct_promote_market_offer(uuid,text,text,text,bigint),public.ct_market_featured(),public.ct_admin_market_finance() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_market_promotion_options(),public.ct_promote_market_offer(uuid,text,text,text,bigint),public.ct_admin_market_finance() TO authenticated;
GRANT EXECUTE ON FUNCTION public.ct_market_featured() TO anon,authenticated;

CREATE FUNCTION public.ct_market_browser(p_kind text DEFAULT 'chest',p_search text DEFAULT '',p_alias text DEFAULT '',p_quantity integer DEFAULT 1,p_sort text DEFAULT 'recommended',p_page integer DEFAULT 1,p_min bigint DEFAULT NULL,p_max bigint DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb;rate bigint;rows jsonb;total integer;
BEGIN
 IF auth.uid() IS NULL OR NOT public.ct_circle_member(auth.uid()) OR EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=auth.uid()) THEN RAISE EXCEPTION 'Carte active requise';END IF;
 IF p_kind IS NULL OR p_kind NOT IN('chest','title') OR p_quantity IS NULL OR p_quantity NOT BETWEEN 1 AND 1000 OR p_page IS NULL OR p_page NOT BETWEEN 1 AND 10000 OR p_sort IS NULL OR p_sort NOT IN('recommended','newest','unit_asc','unit_desc','total_asc','discount_desc') OR p_min<0 OR p_max<0 OR p_min>p_max THEN RAISE EXCEPTION 'Filtres du marché invalides';END IF;
 SELECT credits_per_diamond INTO rate FROM public.ct_market_settings WHERE id;
 WITH active_promos AS MATERIALIZED(SELECT p.*,public.ct_market_offer_info(p.kind,p.target_key) info FROM public.ct_market_promotions p WHERE p.expires_at>now()),
 sources AS MATERIALIZED(SELECT s.*,coalesce(sum(s.stock) OVER(PARTITION BY s.group_key ORDER BY CASE WHEN s.source='stock' THEN 0 ELSE 1 END,s.expires_at,s.source_id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0) preceding_stock FROM public.ct_market_chest_sources() s WHERE p_kind='chest' AND(position(lower(left(coalesce(p_search,''),50)) IN lower(s.name||' '||s.seller))>0 OR nullif(p_alias,'') IS NOT NULL AND position(lower(left(p_alias,50)) IN lower(s.name||' '||s.seller))>0)),
 allocated AS(SELECT *,least(stock,greatest(0,p_quantity-preceding_stock)) take FROM sources),
 priced_sources AS(SELECT a.*,coalesce((SELECT(t->>'price')::bigint FROM jsonb_array_elements(a.tiers)t WHERE(t->>'min')::int<=a.take ORDER BY(t->>'min')::int DESC LIMIT 1),a.base_price) unit FROM allocated a),
 candidates AS MATERIALIZED(
 SELECT s.group_key key,'chest'::text kind,s.seller_id,s.seller,min(s.name) name,min(s.rarity)::int rarity,min(s.base_price) base_price,sum(s.stock)::bigint stock,max(c.price)::numeric/rate reference_unit,min(s.expires_at) expires_at,
  EXISTS(SELECT 1 FROM active_promos p WHERE p.info->>'group_key'=s.group_key AND p.info IS NOT NULL) pinned,
  public.ct_market_payment(sum(s.take*s.unit)::bigint) quote
 FROM priced_sources s JOIN public.ct_chest_types c ON c.id=s.chest_id
 WHERE p_kind='chest' AND(position(lower(left(coalesce(p_search,''),50)) IN lower(s.name||' '||s.seller))>0 OR nullif(p_alias,'') IS NOT NULL AND position(lower(left(p_alias,50)) IN lower(s.name||' '||s.seller))>0)
 GROUP BY s.group_key,s.seller_id,s.seller HAVING sum(s.stock)>=p_quantity
 UNION ALL
 SELECT l.id::text,'title',l.seller_id,p.username,l.name,l.rarity,l.price,1,t.shop_price::numeric/rate,l.expires_at,
  EXISTS(SELECT 1 FROM active_promos pr WHERE pr.kind='listing' AND pr.target_key=l.id::text AND pr.info IS NOT NULL),public.ct_market_payment(l.price)
 FROM public.ct_market_listings l JOIN public.ct_profiles p ON p.id=l.seller_id JOIN public.ct_titles t ON t.id=l.definition_id
 WHERE p_kind='title' AND l.asset_kind='title' AND l.status='active' AND l.expires_at>now() AND l.target_id IS NULL AND l.wanted_kind IS NULL AND public.ct_circle_member(l.seller_id) AND NOT EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=l.seller_id)
 AND(position(lower(left(coalesce(p_search,''),50)) IN lower(l.name||' '||p.username))>0 OR nullif(p_alias,'') IS NOT NULL AND position(lower(left(p_alias,50)) IN lower(l.name||' '||p.username))>0)
 ),priced AS MATERIALIZED(
 SELECT x.*,CASE WHEN reference_unit>0 THEN round((1-(quote->>'total')::numeric/(reference_unit*CASE kind WHEN 'chest' THEN p_quantity ELSE 1 END))*100,1) END discount,
 EXISTS(SELECT 1 FROM public.ct_bots b JOIN public.ct_bot_batches batch ON batch.id=b.batch_id WHERE b.user_id=x.seller_id AND batch.config->>'market_demo_seed'='v1') simulated
 FROM candidates x WHERE(p_min IS NULL OR(quote->>'total')::bigint>=p_min) AND(p_max IS NULL OR(quote->>'total')::bigint<=p_max)
 ),sorted AS(
 SELECT *,row_number() OVER(ORDER BY CASE WHEN p_sort='recommended' THEN pinned END DESC,
 CASE WHEN p_sort='unit_asc' THEN base_price END ASC NULLS LAST,CASE WHEN p_sort='unit_desc' THEN base_price END DESC NULLS LAST,
 CASE WHEN p_sort='total_asc' THEN(quote->>'total')::bigint END ASC NULLS LAST,CASE WHEN p_sort='discount_desc' THEN discount END DESC NULLS LAST,
 expires_at DESC,key ASC) row_n FROM priced
 ) SELECT jsonb_build_object('offers',coalesce((SELECT jsonb_agg(to_jsonb(s)-'row_n' ORDER BY row_n) FROM sorted s WHERE row_n>(p_page-1)*12 AND row_n<=p_page*12),'[]'::jsonb),'total',(SELECT count(*) FROM priced),'page',p_page,'page_size',12,'pages',greatest(1,ceil((SELECT count(*) FROM priced)/12.0)),'quantity',p_quantity,'fee_bps',public.ct_market_fee_rate(auth.uid())) INTO result;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.ct_market_browser(text,text,text,integer,text,integer,bigint,bigint) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_market_browser(text,text,text,integer,text,integer,bigint,bigint) TO authenticated;
CREATE OR REPLACE FUNCTION public.ct_buy_market_chest_group(p_operation_id uuid,p_group text,p_quantity integer,p_expected_total bigint,p_quote_token text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;request jsonb:=jsonb_build_object('kind','market_chest_group','group',p_group,'quantity',p_quantity,'total',p_expected_total,'token',p_quote_token);quote jsonb;part jsonb;ids uuid[];listing_ids bigint[];v_seller uuid;v_total bigint;n integer;row record;
BEGIN
 PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,request);IF r IS NOT NULL THEN RETURN r;END IF;PERFORM public.ct_check_rate(u);
 IF EXISTS(SELECT 1 FROM public.ct_market_settings WHERE id AND(NOT market_enabled OR wallets_frozen)) THEN RAISE EXCEPTION 'Le marché est suspendu ou figé';END IF;
 quote:=public.ct_market_chest_group_quote(p_group,p_quantity);v_seller:=(quote->>'seller_id')::uuid;v_total:=(quote->>'subtotal')::bigint;
 IF v_seller=u THEN RAISE EXCEPTION 'Vous ne pouvez pas acheter votre propre stock';END IF;
 IF p_expected_total IS DISTINCT FROM(quote->>'total')::bigint OR p_quote_token IS DISTINCT FROM quote->>'token' THEN RAISE EXCEPTION 'Stock ou prix modifié. Vérifiez le nouveau total';END IF;
 IF coalesce((SELECT balance FROM public.ct_diamond_wallets WHERE user_id=u),0)-public.ct_direct_diamonds(u)<v_total THEN RAISE EXCEPTION 'Diamants disponibles insuffisants';END IF;
 PERFORM public.ct_post_diamond(u,-v_total,'market_purchase','market-group:'||p_operation_id::text);PERFORM public.ct_post_diamond(v_seller,v_total,'market_sale','market-group:'||p_operation_id::text);
 FOR part IN SELECT value FROM jsonb_array_elements(quote->'parts') LOOP
  n:=(part->>'quantity')::integer;
  IF part->>'source'='stock' THEN
   PERFORM 1 FROM public.ct_wholesale_offers WHERE id=(part->>'id')::uuid FOR UPDATE;
   SELECT array_agg(x.asset_id) INTO ids FROM(SELECT wa.asset_id FROM public.ct_wholesale_assets wa JOIN public.ct_sealed_chests sc ON sc.id=wa.asset_id WHERE wa.offer_id=(part->>'id')::uuid AND NOT wa.sold AND sc.user_id=v_seller AND sc.opened_at IS NULL ORDER BY wa.asset_id LIMIT n FOR UPDATE OF wa,sc)x;
   IF cardinality(ids) IS DISTINCT FROM n THEN RAISE EXCEPTION 'Stock réservé indisponible';END IF;
   UPDATE public.ct_wholesale_assets SET sold=true WHERE asset_id=ANY(ids);
   UPDATE public.ct_wholesale_offers SET remaining=remaining-n,status=CASE WHEN remaining=n THEN 'sold' ELSE 'active' END,version=version+1 WHERE id=(part->>'id')::uuid;
   INSERT INTO public.ct_wholesale_trades(offer_id,buyer_id,seller_id,quantity,unit_price,total,asset_ids) VALUES((part->>'id')::uuid,u,v_seller,n,(part->>'unit_price')::bigint,(part->>'total')::bigint,ids);
  ELSE
   SELECT array_agg(x.asset_id),array_agg(x.id) INTO ids,listing_ids FROM(
    SELECT l.asset_id,l.id FROM public.ct_market_listings l JOIN public.ct_sealed_chests sc ON sc.id=l.asset_id AND sc.user_id=l.seller_id AND sc.opened_at IS NULL
    WHERE l.seller_id=v_seller AND l.asset_kind='chest' AND l.status='active' AND l.expires_at>now() AND l.wanted_kind IS NULL AND l.target_id IS NULL AND NOT public.ct_direct_reserved('chest',sc.id)
    AND md5(jsonb_build_array(l.seller_id,sc.chest_id,l.name,l.rarity,l.price,sc.weights,sc.title_ids)::text)=p_group ORDER BY l.id LIMIT n FOR UPDATE OF l,sc)x;
   IF cardinality(ids) IS DISTINCT FROM n THEN RAISE EXCEPTION 'Stock réservé indisponible';END IF;
   UPDATE public.ct_market_listings SET status='sold',buyer_id=u WHERE id=ANY(listing_ids);
   INSERT INTO public.ct_market_trades(listing_id,seller_id,buyer_id,diamonds,offered_kind,offered_name,wanted_kind,wanted_id)
   SELECT l.id,l.seller_id,u,l.price,l.asset_kind,l.name,NULL,NULL FROM public.ct_market_listings l WHERE l.id=ANY(listing_ids);
  END IF;
  UPDATE public.ct_sealed_chests SET user_id=u WHERE id=ANY(ids);
 END LOOP;
 r:=jsonb_build_object('ok',true,'quantity',p_quantity,'total',v_total);INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,request,r);RETURN r;
END $$;


CREATE FUNCTION public.ct_admin_expand_demo_chests(p_operation_id uuid,p_target integer DEFAULT 150) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;request jsonb:=jsonb_build_object('kind','expand_demo_chests_v3','target',p_target);batch uuid;vendors uuid[];n integer;added integer:=0;i integer:=0;npc uuid;c public.ct_chest_types;pool text[];offer uuid;asset uuid;v_price bigint;rar integer;j integer;qty integer;rate bigint;
BEGIN
 PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required';END IF;
 r:=public.ct_replay(u,p_operation_id,request);IF r IS NOT NULL THEN RETURN r;END IF;
 IF p_target IS NULL OR p_target NOT BETWEEN 100 AND 200 THEN RAISE EXCEPTION 'Choisissez 100 à 200 offres';END IF;
 SELECT id INTO batch FROM public.ct_bot_batches WHERE config->>'market_demo_seed'='v1' ORDER BY created_at LIMIT 1;
 IF batch IS NULL THEN RAISE EXCEPTION 'Vendeurs de démonstration indisponibles';END IF;
 IF coalesce((SELECT(config->>'expanded_chest_offers_v3')::boolean FROM public.ct_bot_batches WHERE id=batch),false) THEN RETURN jsonb_build_object('ok',true,'already_seeded',true);END IF;
 SELECT array_agg(b.user_id ORDER BY b.user_id) INTO vendors FROM public.ct_bots b JOIN public.ct_bot_batches ba ON ba.id=b.batch_id WHERE ba.config->>'market_demo_seed'='v1' AND b.active;
 IF cardinality(vendors) IS NULL OR cardinality(vendors)>20 THEN RAISE EXCEPTION 'Maximum 20 vendeurs fictifs';END IF;
 SELECT credits_per_diamond INTO rate FROM public.ct_market_settings WHERE id;
 SELECT count(DISTINCT group_key) INTO n FROM public.ct_market_chest_sources() WHERE seller_id=ANY(vendors);
 WHILE n+added<p_target LOOP
  i:=i+1;npc:=vendors[1+((i-1)%cardinality(vendors))];rar:=4+(((i-1)/cardinality(vendors))%4);
  SELECT * INTO c FROM public.ct_chest_types WHERE active AND category='standard' AND rarity=rar ORDER BY id LIMIT 1;
  IF c.id IS NULL THEN RAISE EXCEPTION 'Coffre indisponible';END IF;
  SELECT array_agg(id ORDER BY id) INTO pool FROM public.ct_titles WHERE available AND(NOT exclusive OR c.allow_exclusive) AND(c.title_pool IS NULL OR id=ANY(c.title_pool));
  FOR j IN 1..8 LOOP IF c.weights[j]>0 AND NOT EXISTS(SELECT 1 FROM public.ct_titles WHERE id=ANY(pool) AND rarity=j) THEN RAISE EXCEPTION 'Catalogue du coffre incomplet';END IF;END LOOP;
  v_price:=greatest(1,floor(c.price::numeric/rate*(CASE WHEN i%17=0 THEN .55 ELSE .72+(i%15)/100.0 END)))::bigint;
  WHILE EXISTS(SELECT 1 FROM public.ct_wholesale_offers WHERE seller_id=npc AND chest_id=c.id AND base_price=v_price AND status='active' AND expires_at>now()) OR EXISTS(SELECT 1 FROM public.ct_market_listings ml WHERE seller_id=npc AND asset_kind='chest' AND definition_id=c.id::text AND ml.price=v_price AND status='active' AND expires_at>now()) LOOP v_price:=v_price+1;END LOOP;
  qty:=10+(i%11);
  INSERT INTO public.ct_wholesale_offers(seller_id,chest_id,name,rarity,base_price,tiers,remaining) VALUES(npc,c.id,c.name,c.rarity,v_price,jsonb_build_array(jsonb_build_object('min',10,'price',greatest(1,floor(v_price*.97)::bigint))),qty) RETURNING id INTO offer;
  FOR j IN 1..qty LOOP INSERT INTO public.ct_sealed_chests(user_id,chest_id,name,rarity,weights,title_ids,purchase_price) VALUES(npc,c.id,c.name,c.rarity,c.weights,pool,0) RETURNING id INTO asset;INSERT INTO public.ct_wholesale_assets(asset_id,offer_id) VALUES(asset,offer);END LOOP;
  added:=added+1;
 END LOOP;
 UPDATE public.ct_bot_batches SET config=config||jsonb_build_object('expanded_chest_offers_v3',true,'new_chest_offers',added) WHERE id=batch;
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(u,'market_demo_expand_v3',batch::text,'Ajout demandé d’offres de coffres simulées',jsonb_build_object('added',added,'target',p_target,'sellers',cardinality(vendors)));
 r:=jsonb_build_object('ok',true,'added',added,'groups',n+added,'sellers',cardinality(vendors));INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,request,r);RETURN r;
END $$;
REVOKE ALL ON FUNCTION public.ct_admin_expand_demo_chests(uuid,integer) FROM PUBLIC,anon,authenticated;GRANT EXECUTE ON FUNCTION public.ct_admin_expand_demo_chests(uuid,integer) TO authenticated;

COMMIT;
