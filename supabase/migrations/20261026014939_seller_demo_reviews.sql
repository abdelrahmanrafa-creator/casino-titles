BEGIN;
-- Demonstration content is isolated from verified, order-backed buyer reviews.
CREATE TABLE public.ct_seller_demo_reviews(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,seller_id uuid NOT NULL REFERENCES public.ct_profiles(id) ON DELETE CASCADE,market text NOT NULL CHECK(market IN('player','black')),ordinal smallint NOT NULL CHECK(ordinal BETWEEN 1 AND 120),author_alias text NOT NULL,rating smallint NOT NULL CHECK(rating BETWEEN 1 AND 5),comment text NOT NULL CHECK(length(comment) BETWEEN 1 AND 1000),created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(seller_id,market,ordinal));
CREATE INDEX ct_seller_demo_reviews_owner ON public.ct_seller_demo_reviews(market,seller_id,id DESC);
CREATE TABLE public.ct_seller_demo_review_batches(id text PRIMARY KEY,admin_id uuid REFERENCES public.ct_profiles(id) ON DELETE SET NULL,result jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.ct_seller_demo_reviews ENABLE ROW LEVEL SECURITY;ALTER TABLE public.ct_seller_demo_review_batches ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ct_seller_demo_reviews,public.ct_seller_demo_review_batches FROM PUBLIC,anon,authenticated;REVOKE ALL ON SEQUENCE public.ct_seller_demo_reviews_id_seq FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_demo_review_enrich(p_rows jsonb,p_market text) RETURNS jsonb LANGUAGE sql STABLE SET search_path='' AS $$
 WITH rows AS MATERIALIZED(SELECT value item,ordinality n FROM jsonb_array_elements(coalesce(p_rows,'[]')) WITH ORDINALITY),ratings AS(SELECT r.seller_id,count(*) review_count,round(avg(r.rating),2) rating FROM public.ct_seller_demo_reviews r WHERE r.market=p_market AND r.seller_id IN(SELECT(item->>'seller_id')::uuid FROM rows) GROUP BY r.seller_id)
 SELECT coalesce(jsonb_agg(rows.item||jsonb_build_object('demo_review_count',coalesce(r.review_count,0),'demo_rating',coalesce(r.rating,0)) ORDER BY rows.n),'[]'::jsonb) FROM rows LEFT JOIN ratings r ON r.seller_id=(rows.item->>'seller_id')::uuid;
$$;
ALTER FUNCTION public.ct_pm_browse(jsonb) RENAME TO ct_pm_browse_before_demo_reviews;
CREATE FUNCTION public.ct_pm_browse(p_filters jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$ DECLARE r jsonb;BEGIN r:=public.ct_pm_browse_before_demo_reviews(p_filters);RETURN r||jsonb_build_object('items',public.ct_demo_review_enrich(r->'items','player'));END $$;
ALTER FUNCTION public.ct_pm_shop(uuid,integer) RENAME TO ct_pm_shop_before_demo_reviews;
CREATE FUNCTION public.ct_pm_shop(p_seller uuid,p_page integer DEFAULT 1) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$ DECLARE r jsonb;BEGIN r:=public.ct_pm_shop_before_demo_reviews(p_seller,p_page);RETURN r||jsonb_build_object('demo_review_count',(SELECT count(*) FROM public.ct_seller_demo_reviews WHERE seller_id=p_seller AND market='player'),'demo_rating',(SELECT coalesce(round(avg(rating),2),0) FROM public.ct_seller_demo_reviews WHERE seller_id=p_seller AND market='player'));END $$;
ALTER FUNCTION public.ct_market_browser(text,text,text,integer,text,integer,bigint,bigint) RENAME TO ct_market_browser_before_demo_reviews;
CREATE FUNCTION public.ct_market_browser(p_kind text DEFAULT 'chest',p_search text DEFAULT '',p_alias text DEFAULT '',p_quantity integer DEFAULT 1,p_sort text DEFAULT 'recommended',p_page integer DEFAULT 1,p_min bigint DEFAULT NULL,p_max bigint DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$ DECLARE r jsonb;BEGIN r:=public.ct_market_browser_before_demo_reviews(p_kind,p_search,p_alias,p_quantity,p_sort,p_page,p_min,p_max);RETURN r||jsonb_build_object('offers',public.ct_demo_review_enrich(r->'offers','black'));END $$;
CREATE FUNCTION public.ct_seller_demo_reviews_page(p_seller uuid,p_market text,p_page integer DEFAULT 1) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required';END IF;
 IF p_market IS NULL OR p_market NOT IN('player','black') OR p_page IS NULL OR p_page NOT BETWEEN 1 AND 10000 THEN RAISE EXCEPTION 'Invalid filters';END IF;
 IF p_market='black' AND NOT(public.ct_circle_member(auth.uid()) OR public.ct_is_admin()) THEN RAISE EXCEPTION 'Carte active requise';END IF;
 RETURN jsonb_build_object('simulated',true,'verified',false,'seller',(SELECT username FROM public.ct_profiles WHERE id=p_seller),'rating',(SELECT coalesce(round(avg(rating),2),0) FROM public.ct_seller_demo_reviews WHERE seller_id=p_seller AND market=p_market),'total',(SELECT count(*) FROM public.ct_seller_demo_reviews WHERE seller_id=p_seller AND market=p_market),'reviews',coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY id DESC) FROM(SELECT id,author_alias,rating,comment,created_at,true simulated,false verified FROM public.ct_seller_demo_reviews WHERE seller_id=p_seller AND market=p_market ORDER BY id DESC LIMIT 20 OFFSET(p_page-1)*20)x),'[]'::jsonb));
END $$;
CREATE FUNCTION public.ct_admin_seed_seller_demo_reviews(p_operation_id uuid,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;request jsonb:=jsonb_build_object('kind','seller_demo_reviews_v1','reason',p_reason);r jsonb;player_ids uuid[];black_ids uuid[];seller uuid;extra uuid;batch uuid;needed integer;i integer;j integer;k integer;n integer;stars integer;market_name text;t public.ct_titles;c public.ct_chest_types;asset uuid;offer uuid;pool text[];price bigint;review_total integer:=0;added integer:=0;names text[]:=ARRAY['Avery','Rowan','Morgan','Ellis','Blake','Parker','Quinn','Reese','Drew','Skyler','Finley','Arden','Taylor','Robin','Riley','Casey','Emery','Hayden','Sage','Harper'];opening text[]:=ARRAY['Great selection of titles.','The shop is easy to browse.','A nicely organized collection.','The chest selection looks excellent.','Plenty of interesting choices here.','The rare-title selection stands out.','The prices look sensible.','A clean and clear shop layout.','The bundles are worth a look.','The variety makes this shop interesting.','A strong selection for collectors.','Easy to compare different offers.'];ending text[]:=ARRAY['The item details are clear.','The quantity options are convenient.','I like the variety of rarities.','The presentation is really good.','The pricing is easy to understand.','There are some appealing bundles.','A pleasant place to browse.','The collection has a distinctive style.'];
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required';END IF;PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,request);IF r IS NOT NULL THEN RETURN r;END IF;
 IF length(trim(coalesce(p_reason,''))) NOT BETWEEN 8 AND 1000 THEN RAISE EXCEPTION 'Justification administrateur requise';END IF;
 SELECT result INTO r FROM public.ct_seller_demo_review_batches WHERE id='v1';IF r IS NOT NULL THEN RETURN r||jsonb_build_object('already_seeded',true);END IF;
 SELECT array_agg(id ORDER BY id) INTO player_ids FROM(SELECT p.id FROM public.ct_profiles p JOIN public.ct_bots b ON b.user_id=p.id JOIN public.ct_bot_batches ba ON ba.id=b.batch_id WHERE ba.config->>'player_market_stock'='v1' AND EXISTS(SELECT 1 FROM public.ct_pm_listings WHERE seller_id=p.id AND status='active') AND NOT EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=p.id) ORDER BY p.id LIMIT 30)x;
 IF cardinality(player_ids) IS DISTINCT FROM 30 THEN RAISE EXCEPTION 'Initialisez d’abord les stocks des boutiques du jeu';END IF;
 SELECT array_agg(id ORDER BY id) INTO black_ids FROM(SELECT p.id FROM public.ct_profiles p JOIN public.ct_bots b ON b.user_id=p.id WHERE public.ct_circle_member(p.id) AND NOT EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=p.id) AND(EXISTS(SELECT 1 FROM public.ct_market_listings WHERE seller_id=p.id AND status='active' AND expires_at>now() AND target_id IS NULL) OR EXISTS(SELECT 1 FROM public.ct_wholesale_offers WHERE seller_id=p.id AND status='active' AND expires_at>now())) ORDER BY p.id LIMIT 30)x;
 black_ids:=coalesce(black_ids,ARRAY[]::uuid[]);needed:=30-cardinality(black_ids);
 -- Reuse existing game vendors to reach 30 Black Market shops. Issue only finite,
 -- auditable stock: no fake orders, credits, account activity or verified reviews.
 IF needed>0 THEN
  FOR extra IN SELECT p.id FROM public.ct_profiles p JOIN public.ct_bots b ON b.user_id=p.id JOIN public.ct_bot_batches ba ON ba.id=b.batch_id WHERE ba.config->>'player_market_stock'='v1' AND NOT(p.id=ANY(black_ids)) AND NOT EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=p.id) ORDER BY p.id LIMIT needed LOOP
   INSERT INTO public.ct_demo_cards(user_id,tier_id) VALUES(extra,'basic') ON CONFLICT(user_id) DO NOTHING;
   SELECT * INTO t FROM public.ct_titles WHERE rarity=4 AND available AND NOT exclusive ORDER BY md5(id||extra::text) LIMIT 1;
   INSERT INTO public.ct_player_titles(user_id,title_id,source) VALUES(extra,t.id,'admin:demo_review_stock') RETURNING id INTO asset;
   price:=greatest(1,floor(coalesce(t.shop_price,75000)::numeric/1000*0.85));
   INSERT INTO public.ct_market_listings(seller_id,asset_kind,asset_id,name,rarity,definition_id,price) VALUES(extra,'title',asset,t.name,t.rarity,t.id,price);
   SELECT * INTO c FROM public.ct_chest_types WHERE category='standard' AND rarity=5 AND active ORDER BY id LIMIT 1;IF c.id IS NULL THEN RAISE EXCEPTION 'Coffre indisponible';END IF;
   SELECT array_agg(id ORDER BY id) INTO pool FROM public.ct_titles WHERE available AND(NOT exclusive OR c.allow_exclusive) AND(c.title_pool IS NULL OR id=ANY(c.title_pool));
   FOR k IN 1..8 LOOP IF c.weights[k]>0 AND NOT EXISTS(SELECT 1 FROM public.ct_titles WHERE id=ANY(pool) AND rarity=k) THEN RAISE EXCEPTION 'Catalogue du coffre incomplet';END IF;END LOOP;
   price:=greatest(2,floor(c.price::numeric/1000*0.85));
   INSERT INTO public.ct_wholesale_offers(seller_id,chest_id,name,rarity,base_price,tiers,remaining) VALUES(extra,c.id,c.name,c.rarity,price,jsonb_build_array(jsonb_build_object('min',10,'price',greatest(1,price-2))),12) RETURNING id INTO offer;
   FOR k IN 1..12 LOOP INSERT INTO public.ct_sealed_chests(user_id,chest_id,name,rarity,weights,title_ids,purchase_price) VALUES(extra,c.id,c.name,c.rarity,c.weights,pool,0) RETURNING id INTO asset;INSERT INTO public.ct_wholesale_assets(asset_id,offer_id) VALUES(asset,offer);END LOOP;
   black_ids:=array_append(black_ids,extra);added:=added+1;
  END LOOP;
 END IF;
 IF cardinality(black_ids)<>30 THEN RAISE EXCEPTION 'Nombre de boutiques insuffisant';END IF;
 FOREACH market_name IN ARRAY ARRAY['player','black'] LOOP
  FOR i IN 1..30 LOOP seller:=CASE WHEN market_name='player' THEN player_ids[i] ELSE black_ids[i] END;n:=2+floor((i-1)::numeric*118/29)::integer;
   FOR j IN 1..n LOOP stars:=CASE WHEN(j+i)%10<(1+i%7) THEN 4 ELSE 5 END;
    INSERT INTO public.ct_seller_demo_reviews(seller_id,market,ordinal,author_alias,rating,comment) VALUES(seller,market_name,j,names[1+((i+j)%20)]||'_'||lpad((i*127+j)::text,4,'0'),stars,opening[1+((i+j)%12)]||' '||ending[1+((i*3+j)%8)]);review_total:=review_total+1;
   END LOOP;
  END LOOP;
 END LOOP;
 r:=jsonb_build_object('ok',true,'already_seeded',false,'player_sellers',30,'black_sellers',30,'reviews',review_total,'black_stock_vendors_added',added,'verified_reviews_generated',0);
 INSERT INTO public.ct_seller_demo_review_batches(id,admin_id,result) VALUES('v1',u,r);INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(u,'seller_demo_reviews','v1',p_reason,r);
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,request,r);RETURN r;
END $$;
REVOKE ALL ON FUNCTION public.ct_demo_review_enrich(jsonb,text),public.ct_pm_browse_before_demo_reviews(jsonb),public.ct_pm_shop_before_demo_reviews(uuid,integer),public.ct_market_browser_before_demo_reviews(text,text,text,integer,text,integer,bigint,bigint),public.ct_pm_browse(jsonb),public.ct_pm_shop(uuid,integer),public.ct_market_browser(text,text,text,integer,text,integer,bigint,bigint),public.ct_seller_demo_reviews_page(uuid,text,integer),public.ct_admin_seed_seller_demo_reviews(uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_pm_browse(jsonb),public.ct_pm_shop(uuid,integer),public.ct_market_browser(text,text,text,integer,text,integer,bigint,bigint),public.ct_seller_demo_reviews_page(uuid,text,integer),public.ct_admin_seed_seller_demo_reviews(uuid,text) TO authenticated;
COMMIT;
