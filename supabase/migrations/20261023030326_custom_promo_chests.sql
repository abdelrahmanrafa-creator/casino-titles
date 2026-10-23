BEGIN;
CREATE FUNCTION public.ct_grant_promo_chests(p_user uuid,p_chest smallint,p_count integer,p_operation uuid) RETURNS jsonb LANGUAGE plpgsql SET search_path='' AS $$
DECLARE c public.ct_chest_types;ids text[];v_id uuid;v_result jsonb:='[]';r integer;k integer;
BEGIN
 IF p_count IS NULL OR p_count NOT BETWEEN 1 AND 5 THEN RAISE EXCEPTION 'Choisissez 1 à 5 coffres';END IF;
 SELECT * INTO c FROM public.ct_chest_types WHERE id=p_chest AND active AND(starts_at IS NULL OR starts_at<=now()) AND(ends_at IS NULL OR ends_at>now()) FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Coffre de récompense indisponible';END IF;
 IF c.stock_limit IS NOT NULL AND c.stock_used+p_count>c.stock_limit THEN RAISE EXCEPTION 'Stock du coffre de récompense insuffisant';END IF;
 IF c.per_player_limit IS NOT NULL AND p_count+(SELECT count(*) FROM public.ct_chest_purchases WHERE user_id=p_user AND chest_id=c.id)+(SELECT count(*) FROM public.ct_chest_openings WHERE user_id=p_user AND chest_id=c.id AND sealed_id IS NULL)>c.per_player_limit THEN RAISE EXCEPTION 'Limite par joueur du coffre de récompense atteinte';END IF;
 PERFORM id FROM public.ct_titles WHERE available AND(NOT exclusive OR c.allow_exclusive) AND(c.title_pool IS NULL OR id=ANY(c.title_pool)) ORDER BY id FOR SHARE;
 SELECT array_agg(id ORDER BY id) INTO ids FROM public.ct_titles WHERE available AND(NOT exclusive OR c.allow_exclusive) AND(c.title_pool IS NULL OR id=ANY(c.title_pool));
 FOR r IN 1..8 LOOP IF c.weights[r]>0 AND NOT EXISTS(SELECT 1 FROM public.ct_titles WHERE id=ANY(ids) AND rarity=r) THEN RAISE EXCEPTION 'Catalogue du coffre incomplet';END IF;END LOOP;
 FOR k IN 1..p_count LOOP INSERT INTO public.ct_sealed_chests(user_id,chest_id,name,rarity,weights,title_ids) VALUES(p_user,c.id,c.name,c.rarity,c.weights,ids) RETURNING id INTO v_id;INSERT INTO public.ct_chest_purchases(user_id,chest_id,asset_id,price_paid,operation_id) VALUES(p_user,c.id,v_id,0,md5('promo:'||p_operation::text||':'||k::text)::uuid);v_result:=v_result||jsonb_build_array(jsonb_build_object('id',v_id,'name',c.name));END LOOP;
 UPDATE public.ct_chest_types SET stock_used=stock_used+p_count WHERE id=c.id;RETURN v_result;
END $$;
REVOKE ALL ON FUNCTION public.ct_grant_promo_chests(uuid,smallint,integer,uuid) FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.ct_redeem_promo(p_operation_id uuid,p_code text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;v_chest smallint;v_count integer;
BEGIN PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,jsonb_build_object('kind','promo','code',upper(trim(p_code))));IF r IS NOT NULL THEN RETURN r;END IF;
 r:=public.ct_redeem_promo_before_chests(p_operation_id,p_code);
 SELECT reward_chest_id,reward_chest_count INTO v_chest,v_count FROM public.ct_promos WHERE code=upper(trim(p_code)) FOR SHARE;
 IF v_chest IS NOT NULL THEN r:=r||jsonb_build_object('sealed_chests',public.ct_grant_promo_chests(u,v_chest,v_count,p_operation_id));UPDATE public.ct_operations SET result=r WHERE user_id=u AND operation_id=p_operation_id;END IF;RETURN r;END $$;
REVOKE ALL ON FUNCTION public.ct_redeem_promo(uuid,text) FROM PUBLIC,anon,authenticated;GRANT EXECUTE ON FUNCTION public.ct_redeem_promo(uuid,text) TO authenticated;

COMMIT;
