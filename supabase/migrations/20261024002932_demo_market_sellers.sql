BEGIN;
-- Preserve existing market pagination, permissions and stock grouping. Only
-- dedicated, explicitly seeded demonstration sellers receive the public label.
ALTER FUNCTION public.ct_market_snapshot(text,bigint) RENAME TO ct_market_snapshot_before_demo_sellers;
REVOKE ALL ON FUNCTION public.ct_market_snapshot_before_demo_sellers(text,bigint) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_market_snapshot(p_search text DEFAULT '',p_before bigint DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE r jsonb;
BEGIN
 r:=public.ct_market_snapshot_before_demo_sellers(p_search,p_before);
 RETURN r||jsonb_build_object('listings',(SELECT coalesce(jsonb_agg(e.item||jsonb_build_object('simulated',EXISTS(
  SELECT 1 FROM public.ct_bots b JOIN public.ct_bot_batches batch ON batch.id=b.batch_id WHERE b.user_id=(e.item->>'seller_id')::uuid AND batch.config->>'market_demo_seed'='v1'
 )) ORDER BY e.ord),'[]'::jsonb) FROM jsonb_array_elements(r->'listings') WITH ORDINALITY e(item,ord)));
END $$;
REVOKE ALL ON FUNCTION public.ct_market_snapshot(text,bigint) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_market_snapshot(text,bigint) TO authenticated;

ALTER FUNCTION public.ct_market_chest_groups(text,text) RENAME TO ct_market_chest_groups_before_demo_sellers;
REVOKE ALL ON FUNCTION public.ct_market_chest_groups_before_demo_sellers(text,text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_market_chest_groups(p_search text DEFAULT '',p_after text DEFAULT NULL) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(e.item||jsonb_build_object('simulated',EXISTS(
  SELECT 1 FROM public.ct_bots b JOIN public.ct_bot_batches batch ON batch.id=b.batch_id WHERE b.user_id=(e.item->>'seller_id')::uuid AND batch.config->>'market_demo_seed'='v1'
 )) ORDER BY e.ord),'[]'::jsonb) FROM jsonb_array_elements(public.ct_market_chest_groups_before_demo_sellers(p_search,p_after)) WITH ORDINALITY e(item,ord);
$$;
REVOKE ALL ON FUNCTION public.ct_market_chest_groups(text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_market_chest_groups(text,text) TO authenticated;

-- A finite initial set, never an automatic replenisher or invented trade history.
-- No welcome credits or diamonds are minted. Buyers pay the NPC's diamond wallet
-- through the same atomic market functions as every other sale.
CREATE FUNCTION public.ct_admin_seed_demo_market(p_operation_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;request jsonb:='{"kind":"seed_demo_market_v1"}';batch uuid;npc uuid;vendor text;base_name text;tier text;c public.ct_chest_types;pool text[];asset uuid;t public.ct_titles;i integer;j integer;rar integer;qty integer;price bigint;title_rarity integer;title_price bigint;listings integer:=0;names jsonb:='[]';
BEGIN
 PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 r:=public.ct_replay(u,p_operation_id,request);IF r IS NOT NULL THEN RETURN r;END IF;
 SELECT id INTO batch FROM public.ct_bot_batches WHERE config->>'market_demo_seed'='v1' ORDER BY created_at,id LIMIT 1;
 IF batch IS NOT NULL THEN r:=jsonb_build_object('ok',true,'already_seeded',true,'batch_id',batch);
 ELSE
  SELECT id INTO tier FROM public.ct_demo_card_tiers WHERE active ORDER BY rank LIMIT 1;
  IF tier IS NULL THEN RAISE EXCEPTION 'Carte active requise';END IF;
  INSERT INTO public.ct_bot_batches(admin_id,config) VALUES(u,'{"market_demo_seed":"v1","finite_stock":true,"credit_reference_rate":1000}') RETURNING id INTO batch;
  FOR i IN 1..3 LOOP
   base_name:=CASE i WHEN 1 THEN 'Vesper' WHEN 2 THEN 'Halcyon' ELSE 'Ashen' END;
   vendor:=base_name;
   WHILE EXISTS(SELECT 1 FROM public.ct_profiles WHERE lower(username)=lower(vendor)) LOOP vendor:=base_name||'_'||substr(replace(gen_random_uuid()::text,'-',''),1,5);END LOOP;
   npc:=gen_random_uuid();INSERT INTO public.ct_profiles(id,username,avatar,is_bot) VALUES(npc,vendor,'✦',true);
   INSERT INTO public.ct_wallets(user_id,balance) VALUES(npc,0);
   INSERT INTO public.ct_bots(user_id,batch_id,max_rarity) VALUES(npc,batch,6);
   INSERT INTO public.ct_bot_summaries(user_id,games,wins,chests,chest_spending,bet) VALUES(npc,0,0,0,0,100);
   INSERT INTO public.ct_preferences(user_id,leaderboard_hidden) VALUES(npc,true);
   INSERT INTO public.ct_demo_cards(user_id,tier_id) VALUES(npc,tier);
   names:=names||jsonb_build_object('id',npc,'username',vendor);
   rar:=CASE i WHEN 1 THEN 5 WHEN 2 THEN 6 ELSE 4 END;
   qty:=CASE i WHEN 1 THEN 12 WHEN 2 THEN 8 ELSE 10 END;
   price:=CASE i WHEN 1 THEN 80 WHEN 2 THEN 300 ELSE 20 END;
   SELECT * INTO c FROM public.ct_chest_types WHERE active AND category='standard' AND rarity=rar ORDER BY id LIMIT 1;
   IF c.id IS NULL THEN RAISE EXCEPTION 'Coffre indisponible';END IF;
   SELECT array_agg(id ORDER BY id) INTO pool FROM public.ct_titles WHERE available AND(NOT exclusive OR c.allow_exclusive) AND(c.title_pool IS NULL OR id=ANY(c.title_pool));
   FOR j IN 1..8 LOOP IF c.weights[j]>0 AND NOT EXISTS(SELECT 1 FROM public.ct_titles WHERE id=ANY(pool) AND rarity=j) THEN RAISE EXCEPTION 'Catalogue du coffre incomplet';END IF;END LOOP;
   FOR j IN 1..qty LOOP
    INSERT INTO public.ct_sealed_chests(user_id,chest_id,name,rarity,weights,title_ids,purchase_price) VALUES(npc,c.id,c.name,c.rarity,c.weights,pool,0) RETURNING id INTO asset;
    INSERT INTO public.ct_market_listings(seller_id,asset_kind,asset_id,name,rarity,definition_id,price) VALUES(npc,'chest',asset,c.name,c.rarity,c.id::text,price);listings:=listings+1;
   END LOOP;
   FOR j IN 1..2 LOOP
    title_rarity:=CASE WHEN i=1 AND j=1 THEN 3 WHEN i=1 THEN 4 WHEN i=2 AND j=1 THEN 4 WHEN i=2 THEN 5 WHEN j=1 THEN 3 ELSE 6 END;
    SELECT * INTO t FROM public.ct_titles WHERE available AND NOT exclusive AND rarity=title_rarity ORDER BY random() LIMIT 1;
    IF t.id IS NULL THEN RAISE EXCEPTION 'Objet indisponible ou non possédé';END IF;
    title_price:=CASE WHEN t.shop_price IS NOT NULL THEN greatest(1,floor(t.shop_price::numeric/1000*(CASE i WHEN 3 THEN 0.7 ELSE 0.8 END)))::bigint WHEN title_rarity=5 THEN 180 ELSE 600 END;
    INSERT INTO public.ct_player_titles(user_id,title_id,source) VALUES(npc,t.id,'admin:market_demo') RETURNING id INTO asset;
    INSERT INTO public.ct_market_listings(seller_id,asset_kind,asset_id,name,rarity,definition_id,price) VALUES(npc,'title',asset,t.name,t.rarity,t.id,title_price);listings:=listings+1;
   END LOOP;
  END LOOP;
  INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(u,'market_demo_seed',batch::text,'Création demandée d’offres de démonstration',jsonb_build_object('sellers',names,'listings',listings,'chests',30,'titles',6));
  r:=jsonb_build_object('ok',true,'already_seeded',false,'batch_id',batch,'sellers',names,'listings',listings,'chests',30,'titles',6);
 END IF;
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,request,r);RETURN r;
END $$;
REVOKE ALL ON FUNCTION public.ct_admin_seed_demo_market(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_admin_seed_demo_market(uuid) TO authenticated;
COMMIT;
