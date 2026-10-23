BEGIN;
-- A promotion changes the unit price first; quantity savings apply to that price.
CREATE OR REPLACE FUNCTION public.ct_bulk_chest_quote(p_chest_id smallint,p_quantity integer) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE c public.ct_chest_types;v jsonb;d integer;total bigint;
BEGIN
 IF p_quantity IS NULL OR p_quantity NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Choisissez 1 à 100 coffres';END IF;
 SELECT * INTO c FROM public.ct_chest_types WHERE id=p_chest_id;IF NOT FOUND THEN RAISE EXCEPTION 'Coffre indisponible';END IF;
 v:=public.ct_chest_quote(c.id,auth.uid());d:=CASE WHEN p_quantity>=100 THEN 5 WHEN p_quantity>=50 THEN 3 WHEN p_quantity>=10 THEN 2 ELSE 0 END;
 total:=greatest(0,round((v->>'current_price')::numeric*p_quantity*(100-d)/100))::bigint;
 RETURN jsonb_build_object('version',c.version,'unit_price',(v->>'current_price')::bigint,'offer_id',v->'offer_id','quantity',p_quantity,'discount_percent',d,'base_total',c.price*p_quantity,'gross_total',(v->>'current_price')::bigint*p_quantity,'total',total);
END $$;

-- One source is either a seller's matching individual listings or a reserved stock.
-- Hidden helper: callers cannot inspect private offers or arbitrary players' inventory.
CREATE FUNCTION public.ct_market_chest_sources() RETURNS TABLE(group_key text,source text,source_id text,seller_id uuid,seller text,chest_id smallint,name text,rarity smallint,base_price bigint,tiers jsonb,stock bigint,expires_at timestamptz,version bigint)
LANGUAGE sql STABLE SET search_path='' AS $$
 WITH singles AS (
 SELECT md5(jsonb_build_array(l.seller_id,sc.chest_id,l.name,l.rarity,l.price,sc.weights,sc.title_ids)::text) g,l.seller_id,p.username seller,sc.chest_id,l.name,l.rarity,l.price,count(*) stock,min(l.expires_at) expiry
 FROM public.ct_market_listings l JOIN public.ct_sealed_chests sc ON sc.id=l.asset_id AND sc.user_id=l.seller_id AND sc.opened_at IS NULL JOIN public.ct_profiles p ON p.id=l.seller_id
 WHERE l.asset_kind='chest' AND l.status='active' AND l.expires_at>now() AND l.wanted_kind IS NULL AND l.target_id IS NULL
 AND NOT public.ct_direct_reserved('chest',sc.id) AND public.ct_circle_member(l.seller_id) AND NOT EXISTS(SELECT 1 FROM public.ct_suspensions su WHERE su.user_id=l.seller_id)
 GROUP BY g,l.seller_id,p.username,sc.chest_id,l.name,l.rarity,l.price)
 SELECT s.g,'listings',s.g,s.seller_id,s.seller,s.chest_id,s.name,s.rarity,s.price,'[]'::jsonb,s.stock,s.expiry,0::bigint FROM singles s
 UNION ALL
 SELECT md5(jsonb_build_array(o.seller_id,o.chest_id,o.name,o.rarity,o.base_price,a.weights,a.title_ids)::text),'stock',o.id::text,o.seller_id,p.username,o.chest_id,o.name,o.rarity,o.base_price,o.tiers,o.remaining::bigint,o.expires_at,o.version
 FROM public.ct_wholesale_offers o JOIN public.ct_profiles p ON p.id=o.seller_id
 JOIN LATERAL(SELECT sc.weights,sc.title_ids FROM public.ct_wholesale_assets wa JOIN public.ct_sealed_chests sc ON sc.id=wa.asset_id WHERE wa.offer_id=o.id AND NOT wa.sold AND sc.user_id=o.seller_id AND sc.opened_at IS NULL ORDER BY wa.asset_id LIMIT 1)a ON true
 WHERE o.status='active' AND o.expires_at>now() AND o.remaining>0 AND public.ct_circle_member(o.seller_id) AND NOT EXISTS(SELECT 1 FROM public.ct_suspensions su WHERE su.user_id=o.seller_id)
$$;
REVOKE ALL ON FUNCTION public.ct_market_chest_sources() FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.ct_market_chest_groups(p_search text DEFAULT '',p_after text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF auth.uid() IS NULL OR NOT public.ct_circle_member(auth.uid()) OR EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=auth.uid()) THEN RAISE EXCEPTION 'Carte active requise';END IF;
 RETURN coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.group_key) FROM(
 SELECT s.group_key,s.seller_id,s.seller,s.chest_id,s.name,s.rarity,s.base_price,sum(s.stock)::integer stock,min(s.expires_at) expires_at,bool_or(jsonb_array_length(s.tiers)>0) has_tiers
 FROM public.ct_market_chest_sources() s WHERE (p_after IS NULL OR s.group_key>p_after) AND(s.name ILIKE '%'||left(coalesce(p_search,''),50)||'%' OR s.seller ILIKE '%'||left(coalesce(p_search,''),50)||'%')
 GROUP BY s.group_key,s.seller_id,s.seller,s.chest_id,s.name,s.rarity,s.base_price ORDER BY s.group_key LIMIT 50)x),'[]'::jsonb);
END $$;

CREATE FUNCTION public.ct_market_chest_group_quote(p_group text,p_quantity integer) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE s record;leftover integer:=p_quantity;n integer;unit bigint;total bigint:=0;stock bigint:=0;parts jsonb:='[]';signature text:='';v_seller uuid;v_name text;v_base bigint;
BEGIN
 IF auth.uid() IS NULL OR NOT public.ct_circle_member(auth.uid()) OR EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=auth.uid()) THEN RAISE EXCEPTION 'Carte active requise';END IF;
 IF p_quantity IS NULL OR p_quantity NOT BETWEEN 1 AND 1000 THEN RAISE EXCEPTION 'Choisissez 1 à 1000 coffres';END IF;
 -- Seller-authored tiers remain attached to their own stock. No new discount is invented.
 FOR s IN SELECT * FROM public.ct_market_chest_sources() WHERE group_key=p_group ORDER BY CASE WHEN source='stock' THEN 0 ELSE 1 END,expires_at,source_id LOOP
  stock:=stock+s.stock;v_seller:=s.seller_id;v_name:=s.name;v_base:=s.base_price;
  signature:=signature||jsonb_build_array(s.source,s.source_id,s.stock,s.version,s.tiers,s.expires_at)::text;
  n:=least(leftover,s.stock)::integer;
  IF n>0 THEN
   SELECT coalesce((SELECT (t->>'price')::bigint FROM jsonb_array_elements(s.tiers)t WHERE(t->>'min')::int<=n ORDER BY(t->>'min')::int DESC LIMIT 1),s.base_price) INTO unit;
   total:=total+unit*n;leftover:=leftover-n;
   parts:=parts||jsonb_build_object('source',s.source,'id',s.source_id,'quantity',n,'unit_price',unit,'total',unit*n,'tiers',s.tiers);
  END IF;
 END LOOP;
 IF leftover<>0 THEN RAISE EXCEPTION 'Stock insuffisant ou offre indisponible';END IF;
 RETURN jsonb_build_object('group_key',p_group,'quantity',p_quantity,'stock',stock,'seller_id',v_seller,'name',v_name,'base_price',v_base,'gross_total',v_base*p_quantity,'total',total,'parts',parts,'token',md5(signature||parts::text));
END $$;

CREATE FUNCTION public.ct_buy_market_chest_group(p_operation_id uuid,p_group text,p_quantity integer,p_expected_total bigint,p_quote_token text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;request jsonb:=jsonb_build_object('kind','market_chest_group','group',p_group,'quantity',p_quantity,'total',p_expected_total,'token',p_quote_token);quote jsonb;part jsonb;ids uuid[];listing_ids bigint[];v_seller uuid;v_total bigint;n integer;row record;
BEGIN
 PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,request);IF r IS NOT NULL THEN RETURN r;END IF;PERFORM public.ct_check_rate(u);
 IF EXISTS(SELECT 1 FROM public.ct_market_settings WHERE id AND(NOT market_enabled OR wallets_frozen)) THEN RAISE EXCEPTION 'Le marché est suspendu ou figé';END IF;
 quote:=public.ct_market_chest_group_quote(p_group,p_quantity);v_seller:=(quote->>'seller_id')::uuid;v_total:=(quote->>'total')::bigint;
 IF v_seller=u THEN RAISE EXCEPTION 'Vous ne pouvez pas acheter votre propre stock';END IF;
 IF p_expected_total IS DISTINCT FROM v_total OR p_quote_token IS DISTINCT FROM quote->>'token' THEN RAISE EXCEPTION 'Stock ou prix modifié. Vérifiez le nouveau total';END IF;
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
REVOKE ALL ON FUNCTION public.ct_market_chest_groups(text,text),public.ct_market_chest_group_quote(text,integer),public.ct_buy_market_chest_group(uuid,text,integer,bigint,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_market_chest_groups(text,text),public.ct_market_chest_group_quote(text,integer),public.ct_buy_market_chest_group(uuid,text,integer,bigint,text) TO authenticated;
CREATE INDEX ct_market_chest_public_stock ON public.ct_market_listings(seller_id,price,definition_id) WHERE asset_kind='chest' AND status='active' AND wanted_kind IS NULL AND target_id IS NULL;
COMMIT;
