BEGIN;
CREATE FUNCTION public.ct_buy_chests(p_operation_id uuid,p_quantity integer,p_chest_id smallint,p_expected_version bigint,p_expected_price bigint,p_expected_offer_id uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;q jsonb:=jsonb_build_object('kind','buy_chests','quantity',p_quantity,'chest_id',p_chest_id,'version',p_expected_version,'price',p_expected_price,'offer',p_expected_offer_id);c public.ct_chest_types;v jsonb;ids text[];i integer;asset uuid;price bigint;offer uuid; n integer; assets jsonb:='[]';
BEGIN PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;PERFORM public.ct_check_rate(u);IF p_quantity IS NULL OR p_quantity NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Choisissez entre 1 et 100 coffres';END IF;
 SELECT * INTO c FROM public.ct_chest_types WHERE id=p_chest_id FOR UPDATE;IF NOT FOUND THEN RAISE EXCEPTION 'Coffre indisponible';END IF;
 v:=public.ct_chest_quote(c.id,u);price:=(v->>'current_price')::bigint;offer:=(v->>'offer_id')::uuid;
 IF NOT coalesce((v->>'available')::boolean,false) THEN RAISE EXCEPTION 'Coffre indisponible : dates, stock ou limite atteinte';END IF;
 IF p_expected_version IS DISTINCT FROM c.version OR p_expected_price IS DISTINCT FROM price OR p_expected_offer_id IS DISTINCT FROM offer THEN RAISE EXCEPTION 'Prix ou offre modifié. Actualisez les coffres.';END IF;
 PERFORM id FROM public.ct_titles WHERE available AND(NOT exclusive OR c.allow_exclusive) AND(c.title_pool IS NULL OR id=ANY(c.title_pool)) ORDER BY id FOR SHARE;
 SELECT array_agg(id ORDER BY id) INTO ids FROM public.ct_titles WHERE available AND(NOT exclusive OR c.allow_exclusive) AND(c.title_pool IS NULL OR id=ANY(c.title_pool));
 FOR i IN 1..8 LOOP IF c.weights[i]>0 AND NOT EXISTS(SELECT 1 FROM public.ct_titles WHERE id=ANY(ids) AND rarity=i) THEN RAISE EXCEPTION 'Catalogue du coffre incomplet';END IF;END LOOP;
 IF price>0 THEN PERFORM public.ct_post_credit(u,-price*p_quantity,'chest','chest-buy:'||p_operation_id::text);END IF;
 FOR n IN 1..p_quantity LOOP
 v:=public.ct_chest_quote(c.id,u);
 IF NOT coalesce((v->>'available')::boolean,false) OR (v->>'current_price')::bigint IS DISTINCT FROM price OR (v->>'offer_id')::uuid IS DISTINCT FROM offer THEN RAISE EXCEPTION 'Quantité indisponible : stock, offre ou limite par joueur atteinte. Aucun coffre acheté.';END IF;
 INSERT INTO public.ct_sealed_chests(user_id,chest_id,name,rarity,weights,title_ids,purchase_price) VALUES(u,c.id,c.name,c.rarity,c.weights,ids,price) RETURNING id INTO asset;
 INSERT INTO public.ct_chest_purchases(user_id,chest_id,offer_id,asset_id,price_paid,operation_id) VALUES(u,c.id,offer,asset,price,md5(p_operation_id::text||':'||n::text)::uuid);
 UPDATE public.ct_chest_types SET stock_used=stock_used+1 WHERE id=c.id;IF offer IS NOT NULL THEN UPDATE public.ct_chest_offers SET stock_used=stock_used+1 WHERE id=offer;END IF;
 assets:=assets||to_jsonb(asset);END LOOP;
 r:=jsonb_build_object('ok',true,'sealed_ids',assets,'quantity',p_quantity,'chest_id',c.id,'price_paid',price*p_quantity);INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;END $$;

REVOKE ALL ON FUNCTION public.ct_buy_chests(uuid,integer,smallint,bigint,bigint,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_buy_chests(uuid,integer,smallint,bigint,bigint,uuid) TO authenticated;

COMMIT;
