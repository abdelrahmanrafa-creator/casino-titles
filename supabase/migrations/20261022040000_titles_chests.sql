BEGIN;
CREATE FUNCTION public.ct_valid_weights(p_weights integer[]) RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path='' AS $$
 SELECT cardinality(p_weights)=8 AND array_position(p_weights,NULL) IS NULL
 AND 0<=ALL(p_weights) AND (SELECT sum(x) FROM unnest(p_weights) x)=10000;
$$;
CREATE TABLE public.ct_chest_types (
 id smallint PRIMARY KEY CHECK(id BETWEEN 1 AND 8),name text NOT NULL UNIQUE,
 price bigint NOT NULL CHECK(price>0),weights integer[] NOT NULL CHECK(public.ct_valid_weights(weights)),
 active boolean NOT NULL DEFAULT true
);
INSERT INTO public.ct_chest_types(id,name,price,weights) VALUES
 (1,'Classique',500,ARRAY[6500,2500,800,180,20,0,0,0]),
 (2,'Rare',2000,ARRAY[2000,5000,2300,600,100,0,0,0]),
 (3,'Épique',7500,ARRAY[0,2000,5000,2300,600,90,10,0]),
 (4,'Légendaire',25000,ARRAY[0,0,3000,4500,2000,400,90,10]),
 (5,'Mythique',100000,ARRAY[0,0,0,3500,4500,1500,450,50]),
 (6,'Rainbow',350000,ARRAY[0,0,0,0,4500,4000,1300,200]),
 (7,'XTREM',1000000,ARRAY[0,0,0,0,1000,5000,3500,500]),
 (8,'Cosmique',5000000,ARRAY[0,0,0,0,0,2500,5500,2000]);
CREATE TABLE public.ct_chest_openings (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),user_id uuid NOT NULL REFERENCES public.ct_profiles(id) ON DELETE CASCADE,
 chest_id smallint NOT NULL REFERENCES public.ct_chest_types(id),player_title_id uuid NOT NULL REFERENCES public.ct_player_titles(id),
 price_paid bigint NOT NULL CHECK(price_paid>0),weights integer[] NOT NULL CHECK(public.ct_valid_weights(weights)),
 operation_id uuid NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(user_id,operation_id)
);
CREATE INDEX ct_chest_history ON public.ct_chest_openings(user_id,created_at DESC);
CREATE TABLE public.ct_purchases (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),user_id uuid NOT NULL REFERENCES public.ct_profiles(id) ON DELETE CASCADE,
 title_id text NOT NULL REFERENCES public.ct_titles(id),price_paid bigint NOT NULL CHECK(price_paid>0),
 operation_id uuid NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(user_id,operation_id),UNIQUE(user_id,title_id)
);
ALTER TABLE public.ct_chest_types ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ct_chest_openings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ct_purchases ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ct_chest_types,public.ct_chest_openings,public.ct_purchases FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.ct_chest_types TO anon,authenticated;
GRANT SELECT ON public.ct_chest_openings,public.ct_purchases TO authenticated;
CREATE POLICY ct_chest_catalog ON public.ct_chest_types FOR SELECT USING(true);
CREATE POLICY ct_chest_history ON public.ct_chest_openings FOR SELECT TO authenticated USING(user_id=auth.uid());
CREATE POLICY ct_purchase_history ON public.ct_purchases FOR SELECT TO authenticated USING(user_id=auth.uid());
-- UUIDv4's final 32 bits are random, untouched by version/variant bits.
-- Rejection sampling avoids modulo bias. Never use balance, player ID, time or previous losses.
CREATE FUNCTION public.ct_random_below(p_bound integer) RETURNS integer LANGUAGE plpgsql VOLATILE SET search_path='' AS $$
DECLARE v_sample bigint; v_limit bigint;
BEGIN
 IF p_bound IS NULL OR p_bound<1 THEN RAISE EXCEPTION 'Invalid random bound'; END IF;
 v_limit:=4294967296-(4294967296 % p_bound);
 LOOP
  v_sample:=('x'||right(replace(gen_random_uuid()::text,'-',''),8))::bit(32)::bigint;
  IF v_sample<v_limit THEN RETURN (v_sample % p_bound)::integer; END IF;
 END LOOP;
END $$;
CREATE FUNCTION public.ct_rarity_for_roll(p_weights integer[],p_roll integer) RETURNS smallint LANGUAGE plpgsql IMMUTABLE SET search_path='' AS $$
DECLARE v_sum integer:=0; i integer;
BEGIN
 IF NOT public.ct_valid_weights(p_weights) OR p_roll IS NULL OR p_roll NOT BETWEEN 0 AND 9999 THEN RAISE EXCEPTION 'Invalid rarity draw'; END IF;
 FOR i IN 1..8 LOOP v_sum:=v_sum+p_weights[i]; IF p_roll<v_sum THEN RETURN i::smallint; END IF; END LOOP;
 RAISE EXCEPTION 'Invalid rarity table';
END $$;
CREATE FUNCTION public.ct_open_chest(p_operation_id uuid,p_chest_id smallint) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid; v_request jsonb:=jsonb_build_object('kind','chest','chest_id',p_chest_id);v_result jsonb;
 v_chest public.ct_chest_types;v_rarity smallint;v_title public.ct_titles;v_count integer;v_instance uuid;v_opening uuid;
BEGIN
 v_uid:=public.ct_lock_wallet();v_result:=public.ct_replay(v_uid,p_operation_id,v_request);
 IF v_result IS NOT NULL THEN RETURN v_result; END IF;
 PERFORM public.ct_check_rate(v_uid);
 SELECT * INTO v_chest FROM public.ct_chest_types WHERE id=p_chest_id AND active FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Chest unavailable'; END IF;
 v_result:=public.ct_post_credit(v_uid,-v_chest.price,'chest','chest:'||p_operation_id::text);
 v_rarity:=public.ct_rarity_for_roll(v_chest.weights,public.ct_random_below(10000));
 SELECT count(*) INTO v_count FROM public.ct_titles WHERE rarity=v_rarity AND available AND NOT exclusive;
 IF v_count=0 THEN RAISE EXCEPTION 'No title available for rarity'; END IF;
 SELECT * INTO v_title FROM public.ct_titles WHERE rarity=v_rarity AND available AND NOT exclusive
 ORDER BY id OFFSET public.ct_random_below(v_count) LIMIT 1;
 INSERT INTO public.ct_player_titles(user_id,title_id,source) VALUES(v_uid,v_title.id,'chest:'||v_chest.name) RETURNING id INTO v_instance;
 INSERT INTO public.ct_chest_openings(user_id,chest_id,player_title_id,price_paid,weights,operation_id)
 VALUES(v_uid,p_chest_id,v_instance,v_chest.price,v_chest.weights,p_operation_id) RETURNING id INTO v_opening;
 v_result:=v_result||jsonb_build_object('title',to_jsonb(v_title),'player_title_id',v_instance,'opening_id',v_opening,'chest_id',v_chest.id);
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(v_uid,p_operation_id,v_request,v_result);
 RETURN v_result;
END $$;
CREATE FUNCTION public.ct_buy_title(p_operation_id uuid,p_title_id text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid;v_request jsonb:=jsonb_build_object('kind','buy_title','title_id',p_title_id);v_result jsonb;
 v_title public.ct_titles;v_instance uuid;
BEGIN
 v_uid:=public.ct_lock_wallet();v_result:=public.ct_replay(v_uid,p_operation_id,v_request);
 IF v_result IS NOT NULL THEN RETURN v_result; END IF;
 PERFORM public.ct_check_rate(v_uid);
 SELECT * INTO v_title FROM public.ct_titles WHERE id=p_title_id AND available AND NOT exclusive AND shop_price IS NOT NULL FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Title unavailable in shop'; END IF;
 IF EXISTS(SELECT 1 FROM public.ct_purchases WHERE user_id=v_uid AND title_id=p_title_id) THEN RAISE EXCEPTION 'Title already purchased'; END IF;
 v_result:=public.ct_post_credit(v_uid,-v_title.shop_price,'purchase','purchase:'||p_operation_id::text);
 INSERT INTO public.ct_purchases(user_id,title_id,price_paid,operation_id) VALUES(v_uid,p_title_id,v_title.shop_price,p_operation_id);
 INSERT INTO public.ct_player_titles(user_id,title_id,source) VALUES(v_uid,p_title_id,'shop') RETURNING id INTO v_instance;
 v_result:=v_result||jsonb_build_object('title',to_jsonb(v_title),'player_title_id',v_instance);
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(v_uid,p_operation_id,v_request,v_result);
 RETURN v_result;
END $$;
CREATE FUNCTION public.ct_player_snapshot() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT public.ct_economy_snapshot()||jsonb_build_object(
 'inventory',coalesce((SELECT jsonb_agg(to_jsonb(i) ORDER BY i.acquired_at DESC,i.id DESC) FROM public.ct_player_titles i WHERE i.user_id=auth.uid()),'[]'::jsonb),
 'equipped_id',(SELECT player_title_id FROM public.ct_equipped_titles WHERE user_id=auth.uid()),
 'openings',coalesce((SELECT jsonb_agg(to_jsonb(o) ORDER BY o.created_at DESC,o.id DESC) FROM
 (SELECT * FROM public.ct_chest_openings WHERE user_id=auth.uid() ORDER BY created_at DESC,id DESC LIMIT 30) o),'[]'::jsonb),
 'purchases',coalesce((SELECT jsonb_agg(title_id) FROM public.ct_purchases WHERE user_id=auth.uid()),'[]'::jsonb));
$$;
REVOKE ALL ON FUNCTION public.ct_random_below(integer),public.ct_rarity_for_roll(integer[],integer),public.ct_open_chest(uuid,smallint),public.ct_buy_title(uuid,text),public.ct_player_snapshot() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_open_chest(uuid,smallint),public.ct_buy_title(uuid,text),public.ct_player_snapshot() TO authenticated;
COMMIT;
