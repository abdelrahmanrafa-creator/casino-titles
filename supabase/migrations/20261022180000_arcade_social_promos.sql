BEGIN;
CREATE TABLE public.ct_clickers(user_id uuid PRIMARY KEY REFERENCES public.ct_profiles(id) ON DELETE CASCADE,level integer NOT NULL DEFAULT 0 CHECK(level BETWEEN 0 AND 10),total_clicks bigint NOT NULL DEFAULT 0,day date NOT NULL DEFAULT (now() AT TIME ZONE 'UTC')::date,day_clicks integer NOT NULL DEFAULT 0 CHECK(day_clicks BETWEEN 0 AND 5000),tokens numeric NOT NULL DEFAULT 20 CHECK(tokens BETWEEN 0 AND 20),refilled_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.ct_free_gifts(user_id uuid NOT NULL REFERENCES public.ct_profiles(id) ON DELETE CASCADE,day date NOT NULL,amount integer NOT NULL CHECK(amount BETWEEN 100 AND 500),PRIMARY KEY(user_id,day));
CREATE TABLE public.ct_click_milestones(user_id uuid NOT NULL REFERENCES public.ct_profiles(id) ON DELETE CASCADE,threshold integer NOT NULL CHECK(threshold IN(100,500,1000,5000,10000)),PRIMARY KEY(user_id,threshold));
CREATE TABLE public.ct_promos(code text PRIMARY KEY CHECK(code~'^[A-Z0-9_-]{3,40}$'),name text NOT NULL CHECK(length(name) BETWEEN 2 AND 100),credits bigint NOT NULL DEFAULT 0 CHECK(credits BETWEEN 0 AND 1000000),title_id text REFERENCES public.ct_titles(id),active boolean NOT NULL DEFAULT true,starts_at timestamptz NOT NULL,ends_at timestamptz NOT NULL,max_uses integer CHECK(max_uses>0),used integer NOT NULL DEFAULT 0 CHECK(used>=0),version bigint NOT NULL DEFAULT 1,CHECK(credits>0 OR title_id IS NOT NULL),CHECK(ends_at>starts_at),CHECK(max_uses IS NULL OR used<=max_uses));
CREATE TABLE public.ct_promo_claims(user_id uuid NOT NULL REFERENCES public.ct_profiles(id) ON DELETE CASCADE,code text NOT NULL REFERENCES public.ct_promos(code),created_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(user_id,code));
ALTER TABLE public.ct_clickers ENABLE ROW LEVEL SECURITY;ALTER TABLE public.ct_free_gifts ENABLE ROW LEVEL SECURITY;ALTER TABLE public.ct_click_milestones ENABLE ROW LEVEL SECURITY;ALTER TABLE public.ct_promos ENABLE ROW LEVEL SECURITY;ALTER TABLE public.ct_promo_claims ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ct_clickers,public.ct_free_gifts,public.ct_click_milestones,public.ct_promos,public.ct_promo_claims FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_arcade_state() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('level',coalesce(c.level,0),'per_click',coalesce(c.level,0)+1,'upgrade_cost',100*power(2,coalesce(c.level,0))::bigint,'total_clicks',coalesce(c.total_clicks,0),'day_clicks',CASE WHEN c.day=(now() AT TIME ZONE 'UTC')::date THEN c.day_clicks ELSE 0 END,'day_limit',5000,'gift_claimed',EXISTS(SELECT 1 FROM public.ct_free_gifts WHERE user_id=auth.uid() AND day=(now() AT TIME ZONE 'UTC')::date),'milestones',coalesce((SELECT jsonb_agg(threshold) FROM public.ct_click_milestones WHERE user_id=auth.uid()),'[]'::jsonb)) FROM (SELECT auth.uid() id)u LEFT JOIN public.ct_clickers c ON c.user_id=u.id WHERE u.id IS NOT NULL;
$$;
CREATE FUNCTION public.ct_clicker_action(p_operation_id uuid,p_action text,p_clicks integer DEFAULT 0,p_expected_level integer DEFAULT 0) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid;v_request jsonb:=jsonb_build_object('kind','clicker','action',p_action,'clicks',p_clicks,'level',p_expected_level);v_result jsonb;c public.ct_clickers;v_day date:=(now() AT TIME ZONE 'UTC')::date;v_tokens numeric;v_amount bigint;v_cost bigint;
BEGIN
 v_uid:=public.ct_lock_wallet();IF EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=v_uid) THEN RAISE EXCEPTION 'Account suspended';END IF;
 v_result:=public.ct_replay(v_uid,p_operation_id,v_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 INSERT INTO public.ct_clickers(user_id) VALUES(v_uid) ON CONFLICT DO NOTHING;SELECT * INTO c FROM public.ct_clickers WHERE user_id=v_uid FOR UPDATE;
 IF p_expected_level IS DISTINCT FROM c.level THEN RAISE EXCEPTION 'Le niveau a changé. Actualisez le clicker.';END IF;
 IF p_action='click' THEN
  IF p_clicks IS NULL OR p_clicks NOT BETWEEN 1 AND 20 THEN RAISE EXCEPTION 'Entre 1 et 20 clics par collecte';END IF;
  v_tokens:=least(20,c.tokens+greatest(0,extract(epoch FROM(now()-c.refilled_at)))*8);
  IF p_clicks>floor(v_tokens) THEN RAISE EXCEPTION 'Clics trop rapides. Patientez quelques secondes.';END IF;
  IF (CASE WHEN c.day=v_day THEN c.day_clicks ELSE 0 END)+p_clicks>5000 THEN RAISE EXCEPTION 'Limite quotidienne du clicker atteinte';END IF;
  v_amount:=p_clicks*(c.level+1);
  UPDATE public.ct_clickers SET total_clicks=total_clicks+p_clicks,day=v_day,day_clicks=(CASE WHEN day=v_day THEN day_clicks ELSE 0 END)+p_clicks,tokens=v_tokens-p_clicks,refilled_at=now() WHERE user_id=v_uid;
  v_result:=public.ct_post_credit(v_uid,v_amount,'clicker','clicker:'||p_operation_id::text);
 ELSIF p_action='upgrade' THEN
  PERFORM public.ct_check_rate(v_uid);IF c.level>=10 OR p_clicks<>0 THEN RAISE EXCEPTION 'Amélioration indisponible';END IF;
  v_cost:=100*power(2,c.level)::bigint;v_result:=public.ct_post_credit(v_uid,-v_cost,'clicker_upgrade','clicker_upgrade:'||p_operation_id::text);
  UPDATE public.ct_clickers SET level=level+1 WHERE user_id=v_uid;
 ELSE RAISE EXCEPTION 'Action clicker inconnue';END IF;
 v_result:=v_result||jsonb_build_object('arcade',public.ct_arcade_state());INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(v_uid,p_operation_id,v_request,v_result);RETURN v_result;
END $$;
CREATE FUNCTION public.ct_free_reward(p_operation_id uuid,p_kind text,p_threshold integer DEFAULT 0) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid;v_request jsonb:=jsonb_build_object('kind','free_reward','reward',p_kind,'threshold',p_threshold);v_result jsonb;v_amount integer;v_day date:=(now() AT TIME ZONE 'UTC')::date;
BEGIN
 v_uid:=public.ct_lock_wallet();IF EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=v_uid) THEN RAISE EXCEPTION 'Account suspended';END IF;
 v_result:=public.ct_replay(v_uid,p_operation_id,v_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;PERFORM public.ct_check_rate(v_uid);
 IF p_kind='gift' AND p_threshold=0 THEN
  v_amount:=100+public.ct_random_below(401);INSERT INTO public.ct_free_gifts(user_id,day,amount) VALUES(v_uid,v_day,v_amount);
 ELSIF p_kind='milestone' AND p_threshold IN(100,500,1000,5000,10000) THEN
  IF NOT EXISTS(SELECT 1 FROM public.ct_clickers WHERE user_id=v_uid AND total_clicks>=p_threshold) THEN RAISE EXCEPTION 'Objectif de clics non atteint';END IF;
  v_amount:=p_threshold/2;INSERT INTO public.ct_click_milestones(user_id,threshold) VALUES(v_uid,p_threshold);
 ELSE RAISE EXCEPTION 'Récompense inconnue';END IF;
 v_result:=public.ct_post_credit(v_uid,v_amount,'free_reward','free_reward:'||p_operation_id::text);INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(v_uid,p_operation_id,v_request,v_result);RETURN v_result;
END $$;
CREATE FUNCTION public.ct_redeem_promo(p_operation_id uuid,p_code text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid;v_code text:=upper(trim(p_code));v_request jsonb:=jsonb_build_object('kind','promo','code',v_code);v_result jsonb;p public.ct_promos;v_instance uuid;
BEGIN
 v_uid:=public.ct_lock_wallet();IF EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=v_uid) THEN RAISE EXCEPTION 'Account suspended';END IF;
 v_result:=public.ct_replay(v_uid,p_operation_id,v_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;PERFORM public.ct_check_rate(v_uid);
 SELECT * INTO p FROM public.ct_promos WHERE code=v_code AND active AND starts_at<=now() AND ends_at>now() FOR UPDATE;
 IF NOT FOUND OR(p.max_uses IS NOT NULL AND p.used>=p.max_uses) THEN RAISE EXCEPTION 'Code invalide, expiré ou épuisé';END IF;
 IF EXISTS(SELECT 1 FROM public.ct_promo_claims WHERE user_id=v_uid AND code=v_code) THEN RAISE EXCEPTION 'Code déjà utilisé sur ce compte';END IF;
 INSERT INTO public.ct_promo_claims(user_id,code) VALUES(v_uid,v_code);UPDATE public.ct_promos SET used=used+1 WHERE code=v_code;
 v_result:=jsonb_build_object('amount',p.credits,'promo_name',p.name);
 IF p.credits>0 THEN v_result:=v_result||public.ct_post_credit(v_uid,p.credits,'promo','promo:'||v_code);END IF;
 IF p.title_id IS NOT NULL THEN
  INSERT INTO public.ct_player_titles(user_id,title_id,source) VALUES(v_uid,p.title_id,'promo:'||p.name) RETURNING id INTO v_instance;
  v_result:=v_result||jsonb_build_object('title',(SELECT to_jsonb(t) FROM public.ct_titles t WHERE id=p.title_id),'player_title_id',v_instance);
 END IF;
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(v_uid,p_operation_id,v_request,v_result);RETURN v_result;
END $$;
CREATE FUNCTION public.ct_admin_promos() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;RETURN coalesce((SELECT jsonb_agg(to_jsonb(p) ORDER BY code) FROM public.ct_promos p),'[]'::jsonb);END $$;
CREATE FUNCTION public.ct_admin_save_promo(p_operation_id uuid,p_values jsonb,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid:=auth.uid();v_request jsonb:=jsonb_build_object('kind','save_promo','values',p_values,'reason',p_reason);v_result jsonb;v_code text:=upper(trim(p_values->>'code'));v_existing public.ct_promos;
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 IF p_reason IS NULL OR length(trim(p_reason))<8 THEN RAISE EXCEPTION 'Justification required';END IF;
 PERFORM pg_advisory_xact_lock(173,3);v_result:=public.ct_replay(v_uid,p_operation_id,v_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 SELECT * INTO v_existing FROM public.ct_promos WHERE code=v_code FOR UPDATE;
 IF FOUND AND (p_values->>'version')::bigint IS DISTINCT FROM v_existing.version THEN RAISE EXCEPTION 'Code modifié depuis son affichage';END IF;
 INSERT INTO public.ct_promos(code,name,credits,title_id,active,starts_at,ends_at,max_uses) VALUES(v_code,p_values->>'name',(p_values->>'credits')::bigint,nullif(p_values->>'title_id',''),(p_values->>'active')::boolean,(p_values->>'starts_at')::timestamptz,(p_values->>'ends_at')::timestamptz,(p_values->>'max_uses')::integer)
 ON CONFLICT(code) DO UPDATE SET name=EXCLUDED.name,credits=EXCLUDED.credits,title_id=EXCLUDED.title_id,active=EXCLUDED.active,starts_at=EXCLUDED.starts_at,ends_at=EXCLUDED.ends_at,max_uses=EXCLUDED.max_uses,version=ct_promos.version+1;
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(v_uid,'save_promo',v_code,p_reason,p_values);
 v_result:='{"ok":true}'::jsonb;INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(v_uid,p_operation_id,v_request,v_result);RETURN v_result;
END $$;
CREATE FUNCTION public.ct_title_statistics() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) FROM(SELECT t.id title_id,count(DISTINCT i.user_id) FILTER(WHERE s.user_id IS NULL) owners FROM public.ct_titles t LEFT JOIN public.ct_player_titles i ON i.title_id=t.id AND i.revoked_at IS NULL LEFT JOIN public.ct_suspensions s ON s.user_id=i.user_id GROUP BY t.id)x;
$$;
CREATE FUNCTION public.ct_find_players(p_search text) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) FROM(SELECT p.id,p.username,p.avatar,public.ct_public_profile(p.id)->'equipped_title' equipped_title,(public.ct_public_profile(p.id)->>'unique_titles')::integer unique_titles FROM public.ct_profiles p WHERE length(trim(p_search)) BETWEEN 2 AND 32 AND position(lower(trim(p_search)) IN lower(p.username))>0 AND NOT EXISTS(SELECT 1 FROM public.ct_suspensions s WHERE s.user_id=p.id) ORDER BY CASE WHEN lower(p.username)=lower(trim(p_search)) THEN 0 ELSE 1 END,lower(p.username),p.id LIMIT 30)x;
$$;
CREATE FUNCTION public.ct_public_collection(p_user_id uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.rarity DESC,x.name),'[]'::jsonb) FROM(SELECT t.id,t.name,t.rarity,t.description,t.effect,count(*) copies FROM public.ct_player_titles i JOIN public.ct_titles t ON t.id=i.title_id WHERE i.user_id=p_user_id AND i.revoked_at IS NULL AND NOT EXISTS(SELECT 1 FROM public.ct_suspensions s WHERE s.user_id=p_user_id) GROUP BY t.id)x;
$$;
REVOKE ALL ON FUNCTION public.ct_arcade_state(),public.ct_clicker_action(uuid,text,integer,integer),public.ct_free_reward(uuid,text,integer),public.ct_redeem_promo(uuid,text),public.ct_admin_promos(),public.ct_admin_save_promo(uuid,jsonb,text),public.ct_title_statistics(),public.ct_find_players(text),public.ct_public_collection(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_arcade_state(),public.ct_clicker_action(uuid,text,integer,integer),public.ct_free_reward(uuid,text,integer),public.ct_redeem_promo(uuid,text),public.ct_admin_promos(),public.ct_admin_save_promo(uuid,jsonb,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ct_title_statistics(),public.ct_find_players(text),public.ct_public_collection(uuid) TO anon,authenticated;
INSERT INTO public.ct_quests(id,name,description,kind,target,reward) VALUES('collection-5','Les cinq premières signatures','Posséder cinq titres différents.','titles',5,600),('collection-25','Un album qui prend vie','Posséder vingt-cinq titres différents.','titles',25,3000),('explorer-3','Curiosité récompensée','Découvrir trois jeux différents.','variety',3,900),('tables-10','Dix histoires de jeu','Terminer dix parties solo.','games',10,800),('chests-25','Chercheur de trésors','Ouvrir vingt-cinq coffres.','chests',25,2000) ON CONFLICT DO NOTHING;
COMMIT;
