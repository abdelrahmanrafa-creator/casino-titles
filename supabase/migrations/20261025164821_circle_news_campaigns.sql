BEGIN;
ALTER TABLE public.ct_market_promotions ADD COLUMN starts_at timestamptz;
UPDATE public.ct_market_promotions SET starts_at=created_at;
ALTER TABLE public.ct_market_promotions ALTER COLUMN starts_at SET DEFAULT now(),ALTER COLUMN starts_at SET NOT NULL;
ALTER TABLE public.ct_market_promotions ADD COLUMN duration_days integer NOT NULL DEFAULT 1 CHECK(duration_days BETWEEN 1 AND 14),ADD COLUMN pricing_index bigint;
ALTER TABLE public.ct_market_promotions ADD CONSTRAINT ct_campaign_dates CHECK(expires_at>starts_at);
ALTER TABLE public.ct_market_promotions DROP CONSTRAINT ct_market_promotions_placement_check;
UPDATE public.ct_market_promotions SET placement='news' WHERE placement='home';
ALTER TABLE public.ct_market_promotions ADD CONSTRAINT ct_market_promotions_placement_check CHECK(placement IN('pin','news'));
ALTER TABLE public.ct_market_finance ADD COLUMN news_purchases bigint NOT NULL DEFAULT 0 CHECK(news_purchases>=0);
UPDATE public.ct_market_finance SET news_purchases=(SELECT count(*) FROM public.ct_market_promotions WHERE placement='news') WHERE id;
CREATE INDEX ct_market_news_campaign_dates ON public.ct_market_promotions(placement,starts_at,expires_at);

CREATE FUNCTION public.ct_campaign_base(p_index bigint) RETURNS bigint LANGUAGE sql IMMUTABLE SET search_path='' AS $$
 SELECT CASE WHEN p_index<0 OR p_index IS NULL THEN NULL WHEN p_index<6 THEN (ARRAY[250,375,750,1000,5000,10000]::bigint[])[p_index::int+1] ELSE least(1000000000::numeric,10000::numeric*power(2::numeric,least(17,p_index-5)))::bigint END;
$$;
REVOKE ALL ON FUNCTION public.ct_campaign_base(bigint) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.ct_market_campaign_quote(p_kind text,p_key text,p_placement text,p_starts_at timestamptz DEFAULT NULL,p_days integer DEFAULT 1) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid:=auth.uid();info jsonb;first_price bigint;counter bigint;start_time timestamptz:=coalesce(p_starts_at,date_trunc('second',now()));end_time timestamptz;days jsonb;total bigint;
BEGIN
 IF u IS NULL OR NOT public.ct_circle_member(u) OR EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=u) THEN RAISE EXCEPTION 'Carte active requise';END IF;
 IF p_placement IS NULL OR p_placement NOT IN('pin','news') OR p_days IS NULL OR p_days NOT BETWEEN 1 AND 14 THEN RAISE EXCEPTION 'Choisissez une durée de 1 à 14 jours';END IF;
 IF start_time<now()-interval '5 minutes' OR start_time>now()+interval '30 days' THEN RAISE EXCEPTION 'Choisissez une date dans les 30 prochains jours';END IF;
 info:=public.ct_market_offer_info(p_kind,p_key);
 IF info IS NULL OR(info->>'seller_id')::uuid<>u THEN RAISE EXCEPTION 'Seule votre annonce publique active peut être mise en avant';END IF;
 end_time:=start_time+p_days*interval '24 hours';
 IF EXISTS(SELECT 1 FROM public.ct_market_promotions WHERE kind=p_kind AND target_key=p_key AND starts_at<end_time AND expires_at>start_time) THEN RAISE EXCEPTION 'Cette annonce possède déjà une campagne sur ces dates';END IF;
 SELECT CASE p_placement WHEN 'news' THEN public.ct_campaign_base(news_purchases) ELSE pin_price END,CASE p_placement WHEN 'news' THEN news_purchases ELSE 0 END INTO first_price,counter FROM public.ct_market_finance WHERE id;
 SELECT sum(ceil(first_price::numeric*power(1.5::numeric,d)))::bigint,jsonb_agg(jsonb_build_object('day',d+1,'starts_at',start_time+d*interval '24 hours','price',ceil(first_price::numeric*power(1.5::numeric,d))::bigint) ORDER BY d)
 INTO total,days FROM generate_series(0,p_days-1)d;
 RETURN jsonb_build_object('kind',p_kind,'key',p_key,'placement',p_placement,'starts_at',start_time,'ends_at',end_time,'duration_days',p_days,'base',first_price,'pricing_index',counter,'days',days,'total',total,'offer',info,
  'token',md5(jsonb_build_array(p_kind,p_key,p_placement,start_time,end_time,p_days,counter,total,info->>'price',info->>'name',info->>'rarity')::text));
END $$;
CREATE FUNCTION public.ct_purchase_market_campaign(p_operation_id uuid,p_kind text,p_key text,p_placement text,p_starts_at timestamptz,p_days integer,p_expected_total bigint,p_quote_token text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;q jsonb;r jsonb;campaign_id uuid;request jsonb:=jsonb_build_object('kind','market_campaign','offer_kind',p_kind,'key',p_key,'placement',p_placement,'starts_at',p_starts_at,'days',p_days,'total',p_expected_total,'token',p_quote_token);charge bigint;end_time timestamptz;
BEGIN
 PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,request);IF r IS NOT NULL THEN RETURN r;END IF;PERFORM public.ct_check_rate(u);
 IF EXISTS(SELECT 1 FROM public.ct_market_settings WHERE id AND(NOT market_enabled OR wallets_frozen)) THEN RAISE EXCEPTION 'Le marché est suspendu ou figé';END IF;
 PERFORM 1 FROM public.ct_market_finance WHERE id FOR UPDATE;
 q:=public.ct_market_campaign_quote(p_kind,p_key,p_placement,p_starts_at,p_days);charge:=(q->>'total')::bigint;end_time:=(q->>'ends_at')::timestamptz;
 IF p_expected_total IS DISTINCT FROM charge OR p_quote_token IS DISTINCT FROM q->>'token' THEN RAISE EXCEPTION 'Le tarif a changé. Actualisez le devis avant de payer';END IF;
 IF coalesce((SELECT balance FROM public.ct_diamond_wallets WHERE user_id=u),0)-public.ct_direct_diamonds(u)<charge THEN RAISE EXCEPTION 'Diamants disponibles insuffisants';END IF;
 PERFORM public.ct_post_diamond(u,-charge,'market_promotion','campaign:'||p_operation_id::text);
 INSERT INTO public.ct_market_promotions(seller_id,kind,target_key,placement,price,starts_at,expires_at,duration_days,pricing_index)
 VALUES(u,p_kind,p_key,p_placement,charge,p_starts_at,end_time,p_days,(q->>'pricing_index')::bigint) RETURNING ct_market_promotions.id INTO campaign_id;
 IF p_placement='news' THEN UPDATE public.ct_market_finance SET news_purchases=news_purchases+1 WHERE ct_market_finance.id;END IF;
 -- Preserve actual inventory reservations through the purchased campaign.
 IF p_kind='listing' THEN UPDATE public.ct_market_listings SET expires_at=greatest(expires_at,end_time) WHERE ct_market_listings.id::text=p_key;
 ELSIF p_kind='stock' THEN UPDATE public.ct_wholesale_offers SET expires_at=greatest(expires_at,end_time) WHERE ct_wholesale_offers.id::text=p_key;
 ELSIF p_kind='credits' THEN UPDATE public.ct_credit_offers SET expires_at=greatest(expires_at,end_time) WHERE ct_credit_offers.id::text=p_key;END IF;
 r:=jsonb_build_object('ok',true,'id',campaign_id,'price',charge,'starts_at',p_starts_at,'ends_at',end_time,'placement',p_placement);INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,request,r);RETURN r;
END $$;

CREATE OR REPLACE FUNCTION public.ct_market_promotion_options() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required';END IF;
 RETURN (SELECT jsonb_build_object('pin_price',pin_price,'home_price',public.ct_campaign_base(news_purchases),'news_base',public.ct_campaign_base(news_purchases),'news_purchases',news_purchases,'max_days',14,'hours',24,
 'promotions',coalesce((SELECT jsonb_agg(jsonb_build_object('kind',kind,'target_key',target_key,'placement',placement,'starts_at',starts_at,'expires_at',expires_at,'price',price,'duration_days',duration_days) ORDER BY starts_at) FROM public.ct_market_promotions WHERE seller_id=auth.uid() AND expires_at>now()),'[]'::jsonb)) FROM public.ct_market_finance WHERE id);
END $$;

ALTER FUNCTION public.ct_promote_market_offer(uuid,text,text,text,bigint) RENAME TO ct_promote_market_offer_before_campaigns;
REVOKE ALL ON FUNCTION public.ct_promote_market_offer_before_campaigns(uuid,text,text,text,bigint) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_promote_market_offer(p_operation_id uuid,p_kind text,p_key text,p_placement text,p_expected_price bigint) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;
BEGIN
 PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();
 IF NOT EXISTS(SELECT 1 FROM public.ct_operations WHERE user_id=u AND operation_id=p_operation_id) AND p_placement<>'pin' THEN RAISE EXCEPTION 'Utilisez le devis des Actualités du cercle pour cette mise en avant';END IF;
 RETURN public.ct_promote_market_offer_before_campaigns(p_operation_id,p_kind,p_key,p_placement,p_expected_price);
END $$;
REVOKE ALL ON FUNCTION public.ct_promote_market_offer(uuid,text,text,text,bigint) FROM PUBLIC,anon,authenticated;GRANT EXECUTE ON FUNCTION public.ct_promote_market_offer(uuid,text,text,text,bigint) TO authenticated;

CREATE FUNCTION public.ct_market_circle_offers(p_page integer DEFAULT 1) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE r jsonb;
BEGIN
 IF auth.uid() IS NULL OR(NOT public.ct_circle_member(auth.uid()) AND NOT public.ct_is_admin()) OR EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=auth.uid()) THEN RAISE EXCEPTION 'Carte active requise';END IF;
 IF p_page IS NULL OR p_page NOT BETWEEN 1 AND 10000 THEN RAISE EXCEPTION 'Page invalide';END IF;
 WITH active AS MATERIALIZED(
 SELECT p.id,p.created_at,p.starts_at,info||jsonb_build_object('promotion_id',p.id,'offer_kind',p.kind,'target_key',p.target_key,'starts_at',p.starts_at,'ends_at',p.expires_at,'simulated',EXISTS(SELECT 1 FROM public.ct_bots b JOIN public.ct_bot_batches batch ON batch.id=b.batch_id WHERE b.user_id=p.seller_id AND batch.config->>'market_demo_seed'='v1')) item
 FROM public.ct_market_promotions p CROSS JOIN LATERAL(SELECT public.ct_market_offer_info(p.kind,p.target_key) info)s
 WHERE p.placement='news' AND p.starts_at<=now() AND p.expires_at>now() AND info IS NOT NULL
 ),ranked AS(SELECT *,row_number() OVER(ORDER BY starts_at DESC,created_at DESC,id DESC) rn FROM active)
 SELECT jsonb_build_object('offers',coalesce((SELECT jsonb_agg(item ORDER BY rn) FROM ranked WHERE rn>(p_page-1)*6 AND rn<=p_page*6),'[]'::jsonb),'total',(SELECT count(*) FROM active),'pages',greatest(1,ceil((SELECT count(*) FROM active)/6.0)),'page',p_page) INTO r;RETURN r;
END $$;
CREATE FUNCTION public.ct_market_circle_offer_detail(p_promotion_id uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.ct_market_promotions;info jsonb;q jsonb;
BEGIN
 IF auth.uid() IS NULL OR NOT public.ct_circle_member(auth.uid()) OR EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=auth.uid()) THEN RAISE EXCEPTION 'Carte active requise';END IF;
 SELECT * INTO p FROM public.ct_market_promotions WHERE id=p_promotion_id AND placement='news' AND starts_at<=now() AND expires_at>now();
 IF p.id IS NULL THEN RAISE EXCEPTION 'Cette offre n’est plus disponible';END IF;
 info:=public.ct_market_offer_info(p.kind,p.target_key);IF info IS NULL THEN RAISE EXCEPTION 'Cette offre n’est plus disponible';END IF;
 IF info->>'kind'='chest' THEN q:=public.ct_market_chest_group_quote(info->>'group_key',1);ELSE q:=public.ct_market_payment((info->>'price')::bigint);END IF;
 RETURN info||jsonb_build_object('promotion_id',p.id,'target_key',p.target_key,'offer_kind',p.kind,'quote',q,'amount',CASE WHEN p.kind='credits' THEN(SELECT amount FROM public.ct_credit_offers WHERE id::text=p.target_key) END);
END $$;
REVOKE ALL ON FUNCTION public.ct_market_campaign_quote(text,text,text,timestamptz,integer),public.ct_purchase_market_campaign(uuid,text,text,text,timestamptz,integer,bigint,text),public.ct_market_circle_offers(integer),public.ct_market_circle_offer_detail(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_market_campaign_quote(text,text,text,timestamptz,integer),public.ct_purchase_market_campaign(uuid,text,text,text,timestamptz,integer,bigint,text),public.ct_market_circle_offers(integer),public.ct_market_circle_offer_detail(uuid) TO authenticated;
CREATE OR REPLACE FUNCTION public.ct_market_browser(p_kind text DEFAULT 'chest',p_search text DEFAULT '',p_alias text DEFAULT '',p_quantity integer DEFAULT 1,p_sort text DEFAULT 'recommended',p_page integer DEFAULT 1,p_min bigint DEFAULT NULL,p_max bigint DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb;rate bigint;rows jsonb;total integer;
BEGIN
 IF auth.uid() IS NULL OR NOT public.ct_circle_member(auth.uid()) OR EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=auth.uid()) THEN RAISE EXCEPTION 'Carte active requise';END IF;
 IF p_kind IS NULL OR p_kind NOT IN('chest','title') OR p_quantity IS NULL OR p_quantity NOT BETWEEN 1 AND 1000 OR p_page IS NULL OR p_page NOT BETWEEN 1 AND 10000 OR p_sort IS NULL OR p_sort NOT IN('recommended','newest','unit_asc','unit_desc','total_asc','discount_desc') OR p_min<0 OR p_max<0 OR p_min>p_max THEN RAISE EXCEPTION 'Filtres du marché invalides';END IF;
 SELECT credits_per_diamond INTO rate FROM public.ct_market_settings WHERE id;
 WITH active_promos AS MATERIALIZED(SELECT p.*,public.ct_market_offer_info(p.kind,p.target_key) info FROM public.ct_market_promotions p WHERE p.expires_at>now() AND p.starts_at<=now()),
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
CREATE OR REPLACE FUNCTION public.ct_credit_market(p_view text DEFAULT 'browse',p_before bigint DEFAULT NULL,p_search text DEFAULT '') RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE r jsonb;rows jsonb;offset_n bigint:=greatest(0,coalesce(p_before,0));n bigint;
BEGIN
 r:=public.ct_credit_market_before_finance(p_view,CASE WHEN p_view='browse' THEN NULL ELSE p_before END,p_search);
 IF p_view='browse' THEN
  WITH available AS MATERIALIZED(
   SELECT o.*,p.username seller,t.username target,b.username buyer,EXISTS(SELECT 1 FROM public.ct_market_promotions pr WHERE pr.kind='credits' AND pr.target_key=o.id::text AND pr.expires_at>now() AND pr.starts_at<=now()) pinned
   FROM public.ct_credit_offers o JOIN public.ct_profiles p ON p.id=o.seller_id LEFT JOIN public.ct_profiles t ON t.id=o.target_id LEFT JOIN public.ct_profiles b ON b.id=o.buyer_id
   WHERE o.status='active' AND o.expires_at>now() AND(o.target_id IS NULL OR o.target_id=auth.uid() OR o.seller_id=auth.uid()) AND public.ct_circle_member(o.seller_id) AND NOT EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=o.seller_id) AND p.username ILIKE '%'||left(coalesce(p_search,''),50)||'%'
  ),ranked AS(SELECT *,row_number() OVER(ORDER BY pinned DESC,id DESC) rn FROM available)
  SELECT coalesce((SELECT jsonb_agg(to_jsonb(x)-'rn' ORDER BY rn) FROM ranked x WHERE rn>offset_n AND rn<=offset_n+30),'[]'::jsonb),(SELECT count(*) FROM available) INTO rows,n;
  r:=r||jsonb_build_object('offers',rows,'next_before',CASE WHEN n>offset_n+30 THEN offset_n+30 END);
 END IF;
 RETURN r||jsonb_build_object('fee_bps',public.ct_market_fee_rate(auth.uid()));
END $$;

ALTER FUNCTION public.ct_admin_market_finance() RENAME TO ct_admin_market_finance_before_campaigns;
REVOKE ALL ON FUNCTION public.ct_admin_market_finance_before_campaigns() FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_admin_market_finance() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT public.ct_admin_market_finance_before_campaigns()||jsonb_build_object('news_purchases',(SELECT news_purchases FROM public.ct_market_finance WHERE id),'news_next_base',(SELECT public.ct_campaign_base(news_purchases) FROM public.ct_market_finance WHERE id));
$$;
REVOKE ALL ON FUNCTION public.ct_admin_market_finance() FROM PUBLIC,anon,authenticated;GRANT EXECUTE ON FUNCTION public.ct_admin_market_finance() TO authenticated;
COMMIT;
