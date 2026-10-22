BEGIN;
ALTER TABLE public.ct_chest_types DROP CONSTRAINT ct_chest_types_id_check;
ALTER TABLE public.ct_chest_types ADD CONSTRAINT ct_chest_positive_id CHECK(id>0);
ALTER TABLE public.ct_chest_types ADD COLUMN rarity smallint NOT NULL DEFAULT 1 REFERENCES public.ct_rarities(id),
 ADD COLUMN description text NOT NULL DEFAULT 'Un titre. Une nouvelle signature.',
 ADD COLUMN category text NOT NULL DEFAULT 'standard' CHECK(category IN('standard','event')),
 ADD COLUMN starts_at timestamptz,ADD COLUMN ends_at timestamptz,
 ADD COLUMN stock_limit integer CHECK(stock_limit>0),ADD COLUMN stock_used integer NOT NULL DEFAULT 0 CHECK(stock_used>=0),
 ADD COLUMN per_player_limit integer CHECK(per_player_limit>0),ADD COLUMN title_pool text[],ADD COLUMN allow_exclusive boolean NOT NULL DEFAULT false,
 ADD CONSTRAINT ct_chest_dates CHECK(ends_at IS NULL OR starts_at IS NULL OR ends_at>starts_at),
 ADD CONSTRAINT ct_chest_stock CHECK(stock_limit IS NULL OR stock_used<=stock_limit),
 ADD CONSTRAINT ct_chest_pool CHECK(title_pool IS NULL OR (cardinality(title_pool)>0 AND array_position(title_pool,NULL) IS NULL)),
 ADD CONSTRAINT ct_exclusive_event CHECK(NOT allow_exclusive OR category='event');
UPDATE public.ct_chest_types c SET rarity=least(id,8),stock_used=(SELECT count(*) FROM public.ct_chest_openings o WHERE o.chest_id=c.id);
CREATE TABLE public.ct_chest_offers(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),chest_id smallint NOT NULL REFERENCES public.ct_chest_types(id),
 name text NOT NULL CHECK(length(trim(name)) BETWEEN 2 AND 80),sale_price bigint NOT NULL CHECK(sale_price>=0),
 starts_at timestamptz NOT NULL,ends_at timestamptz NOT NULL CHECK(ends_at>starts_at),active boolean NOT NULL DEFAULT true,
 stock_limit integer CHECK(stock_limit>0),stock_used integer NOT NULL DEFAULT 0 CHECK(stock_used>=0),
 per_player_limit integer CHECK(per_player_limit>0),created_at timestamptz NOT NULL DEFAULT now(),
 CHECK(stock_limit IS NULL OR stock_used<=stock_limit),CHECK(sale_price>0 OR per_player_limit IS NOT NULL)
);
ALTER TABLE public.ct_chest_offers ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ct_chest_offers FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.ct_chest_offers TO anon,authenticated;
CREATE POLICY ct_public_offers ON public.ct_chest_offers FOR SELECT USING(active);
CREATE INDEX ct_active_chest_offers ON public.ct_chest_offers(chest_id,active,starts_at,ends_at);
ALTER TABLE public.ct_chest_openings DROP CONSTRAINT ct_chest_openings_price_paid_check;
ALTER TABLE public.ct_chest_openings ADD CONSTRAINT ct_chest_opening_nonnegative_price CHECK(price_paid>=0),
 ADD COLUMN base_price bigint,ADD COLUMN offer_id uuid REFERENCES public.ct_chest_offers(id);
UPDATE public.ct_chest_openings SET base_price=price_paid;
CREATE INDEX ct_offer_player_usage ON public.ct_chest_openings(offer_id,user_id);
CREATE INDEX ct_chest_player_usage ON public.ct_chest_openings(chest_id,user_id);
CREATE OR REPLACE FUNCTION public.ct_chest_version() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF (to_jsonb(NEW)-'version'-'stock_used') IS DISTINCT FROM (to_jsonb(OLD)-'version'-'stock_used') OR NEW.version<>OLD.version THEN NEW.version:=OLD.version+1;ELSE NEW.version:=OLD.version;END IF;
 RETURN NEW;
END $$;
CREATE FUNCTION public.ct_chest_quote(p_chest_id smallint,p_user_id uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT to_jsonb(c)||jsonb_build_object('base_price',c.price,'current_price',coalesce(o.sale_price,c.price),
 'discount_percent',round(100.0*(c.price-coalesce(o.sale_price,c.price))/c.price,1),
 'offer_id',o.id,'offer_name',o.name,'offer_ends_at',o.ends_at,
 'remaining_stock',CASE WHEN c.stock_limit IS NULL THEN NULL ELSE c.stock_limit-c.stock_used END,
 'offer_remaining',CASE WHEN o.stock_limit IS NULL THEN NULL ELSE o.stock_limit-o.stock_used END,
 'available',c.active AND (c.starts_at IS NULL OR now()>=c.starts_at) AND (c.ends_at IS NULL OR now()<c.ends_at)
 AND (c.stock_limit IS NULL OR c.stock_used<c.stock_limit)
 AND (c.per_player_limit IS NULL OR (SELECT count(*) FROM public.ct_chest_openings WHERE chest_id=c.id AND user_id=p_user_id)<c.per_player_limit))
 FROM public.ct_chest_types c LEFT JOIN LATERAL(
 SELECT f.* FROM public.ct_chest_offers f WHERE f.chest_id=c.id AND f.active AND now()>=f.starts_at AND now()<f.ends_at AND f.sale_price<c.price
 AND(f.stock_limit IS NULL OR f.stock_used<f.stock_limit)
 AND(f.per_player_limit IS NULL OR (SELECT count(*) FROM public.ct_chest_openings WHERE offer_id=f.id AND user_id=p_user_id)<f.per_player_limit)
 ORDER BY f.sale_price,f.ends_at,f.id LIMIT 1)o ON true WHERE c.id=p_chest_id;
$$;
CREATE FUNCTION public.ct_shop_chests() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(public.ct_chest_quote(c.id,auth.uid()) ORDER BY c.category DESC,c.id),'[]'::jsonb) FROM public.ct_chest_types c WHERE active;
$$;
ALTER FUNCTION public.ct_open_chest(uuid,smallint,bigint) RENAME TO ct_open_chest_quoted_v1;
REVOKE ALL ON FUNCTION public.ct_open_chest_quoted_v1(uuid,smallint,bigint) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_open_chest(p_operation_id uuid,p_chest_id smallint,p_expected_version bigint,p_expected_price bigint,p_expected_offer_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid;v_request jsonb:=jsonb_build_object('kind','chest','chest_id',p_chest_id);v_result jsonb;
 c public.ct_chest_types;q jsonb;v_price bigint;v_offer uuid;v_rarity smallint;v_count integer;t public.ct_titles;v_instance uuid;v_opening uuid;
BEGIN
 v_uid:=public.ct_lock_wallet();v_result:=public.ct_replay(v_uid,p_operation_id,v_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 PERFORM public.ct_check_rate(v_uid);
 SELECT * INTO c FROM public.ct_chest_types WHERE id=p_chest_id FOR UPDATE;IF NOT FOUND THEN RAISE EXCEPTION 'Chest unavailable';END IF;
 q:=public.ct_chest_quote(c.id,v_uid);IF NOT coalesce((q->>'available')::boolean,false) THEN RAISE EXCEPTION 'Coffre indisponible : dates, stock ou limite atteinte.';END IF;
 v_price:=(q->>'current_price')::bigint;v_offer:=(q->>'offer_id')::uuid;
 IF p_expected_version IS DISTINCT FROM c.version OR p_expected_price IS DISTINCT FROM v_price OR p_expected_offer_id IS DISTINCT FROM v_offer THEN RAISE EXCEPTION 'Offre ou prix modifié. Actualisez la boutique avant de confirmer.';END IF;
 IF v_price>0 THEN v_result:=public.ct_post_credit(v_uid,-v_price,'chest','chest:'||p_operation_id::text);
 ELSE SELECT jsonb_build_object('amount',0,'balance',balance,'version',version) INTO v_result FROM public.ct_wallets WHERE user_id=v_uid;END IF;
 v_rarity:=public.ct_rarity_for_roll(c.weights,public.ct_random_below(10000));
 SELECT count(*) INTO v_count FROM public.ct_titles WHERE rarity=v_rarity AND available AND (NOT exclusive OR c.allow_exclusive) AND (c.title_pool IS NULL OR id=ANY(c.title_pool));
 IF v_count=0 THEN RAISE EXCEPTION 'No title available for rarity';END IF;
 SELECT * INTO t FROM public.ct_titles WHERE rarity=v_rarity AND available AND (NOT exclusive OR c.allow_exclusive) AND (c.title_pool IS NULL OR id=ANY(c.title_pool)) ORDER BY id OFFSET public.ct_random_below(v_count) LIMIT 1;
 INSERT INTO public.ct_player_titles(user_id,title_id,source) VALUES(v_uid,t.id,'chest:'||c.name) RETURNING id INTO v_instance;
 INSERT INTO public.ct_chest_openings(user_id,chest_id,player_title_id,price_paid,base_price,offer_id,weights,operation_id) VALUES(v_uid,c.id,v_instance,v_price,c.price,v_offer,c.weights,p_operation_id) RETURNING id INTO v_opening;
 UPDATE public.ct_chest_types SET stock_used=stock_used+1 WHERE id=c.id;
 IF v_offer IS NOT NULL THEN UPDATE public.ct_chest_offers SET stock_used=stock_used+1 WHERE id=v_offer;END IF;
 v_result:=v_result||jsonb_build_object('title',to_jsonb(t),'player_title_id',v_instance,'opening_id',v_opening,'chest_id',c.id,'price_paid',v_price,'base_price',c.price,'offer_id',v_offer);
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(v_uid,p_operation_id,v_request,v_result);RETURN v_result;
END $$;
CREATE FUNCTION public.ct_admin_save_chest(p_operation_id uuid,p_values jsonb,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid:=auth.uid();v_id smallint:=(p_values->>'id')::smallint;v_request jsonb:=jsonb_build_object('kind','admin_chest','values',p_values,'reason',p_reason);v_result jsonb;v_old public.ct_chest_types;v_weights integer[];v_pool text[];v_index integer;
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator unlock required' USING ERRCODE='42501';END IF;
 IF p_reason IS NULL OR length(trim(p_reason)) NOT BETWEEN 8 AND 1000 THEN RAISE EXCEPTION 'Justification required';END IF;
 PERFORM pg_advisory_xact_lock(173,2);v_result:=public.ct_replay(v_uid,p_operation_id,v_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 IF v_id IS NULL THEN SELECT (coalesce(max(id),0)+1)::smallint INTO v_id FROM public.ct_chest_types;
 ELSE
  SELECT * INTO v_old FROM public.ct_chest_types WHERE id=v_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Chest not found';END IF;
  IF v_old.version IS DISTINCT FROM (p_values->>'version')::bigint THEN RAISE EXCEPTION 'Chest modified by another administrator. Reload first.';END IF;
 END IF;
 SELECT array_agg(value::integer ORDER BY ordinality) INTO v_weights FROM jsonb_array_elements_text(p_values->'weights') WITH ORDINALITY;
 IF NOT coalesce(public.ct_valid_weights(v_weights),false) THEN RAISE EXCEPTION 'Probabilities must total exactly 100 percent';END IF;
 IF length(trim(coalesce(p_values->>'name','')) ) NOT BETWEEN 2 AND 80 THEN RAISE EXCEPTION 'Chest name required';END IF;
 IF jsonb_typeof(p_values->'title_pool')='array' THEN SELECT array_agg(value ORDER BY ordinality) INTO v_pool FROM jsonb_array_elements_text(p_values->'title_pool') WITH ORDINALITY;END IF;
 FOR v_index IN 1..8 LOOP
  IF v_weights[v_index]>0 AND NOT EXISTS(SELECT 1 FROM public.ct_titles WHERE rarity=v_index AND available AND (NOT exclusive OR coalesce((p_values->>'allow_exclusive')::boolean,false)) AND (v_pool IS NULL OR id=ANY(v_pool))) THEN RAISE EXCEPTION 'No available title for rarity %',v_index;END IF;
 END LOOP;
 INSERT INTO public.ct_chest_types(id,name,price,weights,active,rarity,description,category,starts_at,ends_at,stock_limit,per_player_limit,title_pool,allow_exclusive)
 VALUES(v_id,trim(p_values->>'name'),(p_values->>'price')::bigint,v_weights,(p_values->>'active')::boolean,(p_values->>'rarity')::smallint,coalesce(p_values->>'description',''),coalesce(p_values->>'category','standard'),(p_values->>'starts_at')::timestamptz,(p_values->>'ends_at')::timestamptz,(p_values->>'stock_limit')::integer,(p_values->>'per_player_limit')::integer,v_pool,coalesce((p_values->>'allow_exclusive')::boolean,false))
 ON CONFLICT(id) DO UPDATE SET name=EXCLUDED.name,price=EXCLUDED.price,weights=EXCLUDED.weights,active=EXCLUDED.active,rarity=EXCLUDED.rarity,description=EXCLUDED.description,category=EXCLUDED.category,starts_at=EXCLUDED.starts_at,ends_at=EXCLUDED.ends_at,stock_limit=EXCLUDED.stock_limit,per_player_limit=EXCLUDED.per_player_limit,title_pool=EXCLUDED.title_pool,allow_exclusive=EXCLUDED.allow_exclusive;
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(v_uid,'save_chest',v_id::text,p_reason,p_values);
 v_result:=jsonb_build_object('ok',true,'chest_id',v_id);INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(v_uid,p_operation_id,v_request,v_result);RETURN v_result;
END $$;
CREATE FUNCTION public.ct_admin_save_offer(p_operation_id uuid,p_values jsonb,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid:=auth.uid();v_id uuid:=(p_values->>'id')::uuid;v_chest smallint:=(p_values->>'chest_id')::smallint;v_request jsonb:=jsonb_build_object('kind','admin_offer','values',p_values,'reason',p_reason);v_result jsonb;v_price bigint;v_old public.ct_chest_offers;
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator unlock required' USING ERRCODE='42501';END IF;
 IF p_reason IS NULL OR length(trim(p_reason)) NOT BETWEEN 8 AND 1000 THEN RAISE EXCEPTION 'Justification required';END IF;
 PERFORM pg_advisory_xact_lock(173,2);v_result:=public.ct_replay(v_uid,p_operation_id,v_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 SELECT price INTO v_price FROM public.ct_chest_types WHERE id=v_chest FOR UPDATE;IF NOT FOUND THEN RAISE EXCEPTION 'Chest not found';END IF;
 IF (p_values->>'sale_price')::bigint>=v_price THEN RAISE EXCEPTION 'Sale price must be lower than the real base price';END IF;
 IF v_id IS NOT NULL THEN SELECT * INTO v_old FROM public.ct_chest_offers WHERE id=v_id FOR UPDATE;
  IF NOT FOUND OR v_old.chest_id<>v_chest THEN RAISE EXCEPTION 'Offer not found for chest';END IF;
 ELSE v_id:=gen_random_uuid();END IF;
 INSERT INTO public.ct_chest_offers(id,chest_id,name,sale_price,starts_at,ends_at,active,stock_limit,per_player_limit)
 VALUES(v_id,v_chest,trim(p_values->>'name'),(p_values->>'sale_price')::bigint,(p_values->>'starts_at')::timestamptz,(p_values->>'ends_at')::timestamptz,(p_values->>'active')::boolean,(p_values->>'stock_limit')::integer,(p_values->>'per_player_limit')::integer)
 ON CONFLICT(id) DO UPDATE SET name=EXCLUDED.name,sale_price=EXCLUDED.sale_price,starts_at=EXCLUDED.starts_at,ends_at=EXCLUDED.ends_at,active=EXCLUDED.active,stock_limit=EXCLUDED.stock_limit,per_player_limit=EXCLUDED.per_player_limit;
 UPDATE public.ct_chest_types SET version=version+1 WHERE id=v_chest;
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(v_uid,'save_offer',v_id::text,p_reason,p_values);
 v_result:=jsonb_build_object('ok',true,'offer_id',v_id);INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(v_uid,p_operation_id,v_request,v_result);RETURN v_result;
END $$;
CREATE FUNCTION public.ct_admin_dashboard() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator unlock required' USING ERRCODE='42501';END IF;
 RETURN jsonb_build_object('overview',public.ct_admin_overview(''),
 'chests',(SELECT coalesce(jsonb_agg(to_jsonb(c) ORDER BY id),'[]'::jsonb) FROM public.ct_chest_types c),
 'offers',(SELECT coalesce(jsonb_agg(to_jsonb(o) ORDER BY starts_at DESC),'[]'::jsonb) FROM public.ct_chest_offers o),
 'events',(SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY starts_at DESC),'[]'::jsonb) FROM public.ct_events e),
 'quests',(SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY reward),'[]'::jsonb) FROM public.ct_quests q),
 'rules',(SELECT to_jsonb(r) FROM public.ct_blackjack_rules r WHERE id),
 'admins',(SELECT coalesce(jsonb_agg(jsonb_build_object('id',p.id,'username',p.username)),'[]'::jsonb) FROM public.ct_admins a JOIN public.ct_profiles p ON p.id=a.user_id),
 'security',jsonb_build_object('session_minutes',(SELECT session_minutes FROM public.ct_admin_security WHERE id),'session_expires_at',(SELECT expires_at FROM public.ct_admin_sessions WHERE user_id=auth.uid() AND session_id=public.ct_admin_session_id())));
END $$;
REVOKE ALL ON FUNCTION public.ct_chest_quote(smallint,uuid),public.ct_shop_chests(),public.ct_open_chest(uuid,smallint,bigint,bigint,uuid),public.ct_admin_save_chest(uuid,jsonb,text),public.ct_admin_save_offer(uuid,jsonb,text),public.ct_admin_dashboard() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_shop_chests() TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_open_chest(uuid,smallint,bigint,bigint,uuid),public.ct_admin_save_chest(uuid,jsonb,text),public.ct_admin_save_offer(uuid,jsonb,text),public.ct_admin_dashboard() TO authenticated;
COMMIT;
