BEGIN;
CREATE FUNCTION public.ct_open_sealed_batch(p_operation_id uuid,p_asset_ids uuid[]) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;request jsonb:=jsonb_build_object('kind','open_sealed_batch','assets',p_asset_ids);s public.ct_sealed_chests;t public.ct_titles;v_rarity smallint;n integer;instance uuid;opening uuid;a uuid;awards jsonb:='[]';
BEGIN
 PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,request);IF r IS NOT NULL THEN RETURN r;END IF;PERFORM public.ct_check_rate(u);
 IF p_asset_ids IS NULL OR cardinality(p_asset_ids) NOT BETWEEN 1 AND 100 OR array_position(p_asset_ids,NULL) IS NOT NULL OR cardinality(p_asset_ids)<>(SELECT count(DISTINCT x) FROM unnest(p_asset_ids)x) THEN RAISE EXCEPTION 'Choisissez de 1 à 100 coffres différents';END IF;
 -- Lock and validate the entire selection before granting any title.
 PERFORM id FROM public.ct_sealed_chests WHERE id=ANY(p_asset_ids) ORDER BY id FOR UPDATE;
 IF(SELECT count(*) FROM public.ct_sealed_chests WHERE id=ANY(p_asset_ids) AND user_id=u AND opened_at IS NULL)<>cardinality(p_asset_ids) THEN RAISE EXCEPTION 'Un coffre est déjà ouvert ou ne vous appartient pas. Aucun coffre ouvert.';END IF;
 IF EXISTS(SELECT 1 FROM unnest(p_asset_ids)x WHERE public.ct_direct_reserved('chest',x)) OR EXISTS(SELECT 1 FROM public.ct_market_listings WHERE asset_kind='chest' AND asset_id=ANY(p_asset_ids) AND status='active' AND expires_at>now()) THEN RAISE EXCEPTION 'Un coffre est réservé à une vente ou un échange. Aucun coffre ouvert.';END IF;
 PERFORM id FROM public.ct_titles WHERE id IN(SELECT unnest(title_ids) FROM public.ct_sealed_chests WHERE id=ANY(p_asset_ids)) ORDER BY id FOR SHARE;
 FOREACH a IN ARRAY p_asset_ids LOOP
  SELECT * INTO s FROM public.ct_sealed_chests WHERE id=a;
  v_rarity:=public.ct_rarity_for_roll(s.weights,public.ct_random_below(10000));
  SELECT count(*) INTO n FROM public.ct_titles WHERE id=ANY(s.title_ids) AND ct_titles.rarity=v_rarity;
  IF n=0 THEN RAISE EXCEPTION 'Contenu d’un coffre indisponible. Aucun coffre ouvert.';END IF;
  SELECT * INTO t FROM public.ct_titles WHERE id=ANY(s.title_ids) AND ct_titles.rarity=v_rarity ORDER BY id OFFSET public.ct_random_below(n) LIMIT 1;
  INSERT INTO public.ct_player_titles(user_id,title_id,source) VALUES(u,t.id,'sealed:'||s.name) RETURNING id INTO instance;
  INSERT INTO public.ct_chest_openings(user_id,chest_id,player_title_id,price_paid,base_price,weights,operation_id,sealed_id) VALUES(u,s.chest_id,instance,0,0,s.weights,md5('batch-open:'||p_operation_id::text||':'||a::text)::uuid,a) RETURNING id INTO opening;
  UPDATE public.ct_sealed_chests SET opened_at=now() WHERE id=a;
  awards:=awards||jsonb_build_object('title',to_jsonb(t),'player_title_id',instance,'opening_id',opening,'sealed_id',a);
 END LOOP;
 r:=jsonb_build_object('ok',true,'quantity',cardinality(p_asset_ids),'awards',awards);INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,request,r);RETURN r;
END $$;
REVOKE ALL ON FUNCTION public.ct_open_sealed_batch(uuid,uuid[]) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_open_sealed_batch(uuid,uuid[]) TO authenticated;
COMMIT;
