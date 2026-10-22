BEGIN;
-- Keep real profiles linked to Auth while bot profiles have no Auth identity at all.
ALTER TABLE public.ct_profiles ADD COLUMN is_bot boolean NOT NULL DEFAULT false;
ALTER TABLE public.ct_profiles ADD COLUMN auth_user_id uuid;
UPDATE public.ct_profiles SET auth_user_id=id;
ALTER TABLE public.ct_profiles DROP CONSTRAINT ct_profiles_id_fkey;
ALTER TABLE public.ct_profiles ADD CONSTRAINT ct_profiles_auth_user_id_fkey FOREIGN KEY(auth_user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE public.ct_profiles ADD CONSTRAINT ct_profile_identity CHECK((is_bot AND auth_user_id IS NULL) OR(NOT is_bot AND auth_user_id IS NOT NULL AND auth_user_id=id));
CREATE UNIQUE INDEX ct_profiles_auth_identity ON public.ct_profiles(auth_user_id);
CREATE FUNCTION public.ct_profile_identity_default() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
BEGIN IF NOT NEW.is_bot AND NEW.auth_user_id IS NULL THEN NEW.auth_user_id:=NEW.id;END IF;RETURN NEW;END $$;
CREATE TRIGGER ct_profile_identity_defaults BEFORE INSERT ON public.ct_profiles FOR EACH ROW EXECUTE FUNCTION public.ct_profile_identity_default();
CREATE TABLE public.ct_bot_batches(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),admin_id uuid NOT NULL REFERENCES public.ct_profiles(id),config jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX ct_bot_batches_admin ON public.ct_bot_batches(admin_id);
CREATE TABLE public.ct_bots(user_id uuid PRIMARY KEY REFERENCES public.ct_profiles(id) ON DELETE CASCADE,batch_id uuid NOT NULL REFERENCES public.ct_bot_batches(id),active boolean NOT NULL DEFAULT true,version bigint NOT NULL DEFAULT 1,max_rarity smallint NOT NULL CHECK(max_rarity BETWEEN 0 AND 7),created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX ct_bots_batch ON public.ct_bots(batch_id);
ALTER TABLE public.ct_bot_batches ENABLE ROW LEVEL SECURITY;ALTER TABLE public.ct_bots ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ct_bot_batches,public.ct_bots FROM PUBLIC,anon,authenticated;
ALTER TABLE public.ct_game_rounds ADD COLUMN simulated boolean NOT NULL DEFAULT false;
ALTER TABLE public.ct_chest_openings ADD COLUMN simulated boolean NOT NULL DEFAULT false;
CREATE OR REPLACE FUNCTION public.ct_lock_wallet() RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid:=auth.uid();
BEGIN
 IF v_uid IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501';END IF;
 PERFORM 1 FROM public.ct_wallets WHERE user_id=v_uid FOR UPDATE;IF NOT FOUND THEN RAISE EXCEPTION 'Profile required';END IF;
 IF EXISTS(SELECT 1 FROM public.ct_profiles WHERE id=v_uid AND is_bot) THEN RAISE EXCEPTION 'Bot accounts are frozen' USING ERRCODE='42501';END IF;
 IF EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=v_uid) THEN RAISE EXCEPTION 'Account suspended' USING ERRCODE='42501';END IF;RETURN v_uid;
END $$;
CREATE FUNCTION public.ct_bot_guards() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM public.ct_profiles WHERE id=NEW.user_id AND is_bot) THEN
  IF TG_TABLE_NAME='ct_player_titles' THEN
   IF EXISTS(SELECT 1 FROM public.ct_titles WHERE id=NEW.title_id AND rarity=8) THEN RAISE EXCEPTION 'Bots cannot own Cosmic titles';END IF;
  ELSE RAISE EXCEPTION 'Bots cannot join tables or become administrators';END IF;
 END IF;RETURN NEW;
END $$;
CREATE TRIGGER ct_bot_no_cosmic BEFORE INSERT OR UPDATE OF user_id,title_id ON public.ct_player_titles FOR EACH ROW EXECUTE FUNCTION public.ct_bot_guards();
CREATE TRIGGER ct_bot_no_tables BEFORE INSERT OR UPDATE OF user_id ON public.ct_room_members FOR EACH ROW EXECUTE FUNCTION public.ct_bot_guards();
CREATE TRIGGER ct_bot_no_admin BEFORE INSERT OR UPDATE OF user_id ON public.ct_admins FOR EACH ROW EXECUTE FUNCTION public.ct_bot_guards();
CREATE FUNCTION public.ct_bot_title_reclassification() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN IF NEW.rarity=8 AND EXISTS(SELECT 1 FROM public.ct_player_titles i JOIN public.ct_profiles p ON p.id=i.user_id WHERE i.title_id=NEW.id AND p.is_bot) THEN RAISE EXCEPTION 'Bots cannot own Cosmic titles';END IF;RETURN NEW;END $$;
CREATE TRIGGER ct_bot_no_cosmic_reclassification BEFORE UPDATE OF rarity ON public.ct_titles FOR EACH ROW EXECUTE FUNCTION public.ct_bot_title_reclassification();
REVOKE ALL ON FUNCTION public.ct_bot_title_reclassification() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.ct_profile_identity_default(),public.ct_bot_guards() FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.ct_admin_create_bots(p_operation_id uuid,p_values jsonb,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET statement_timeout='25s' AS $$
DECLARE v_admin uuid:=auth.uid();v_request jsonb:=jsonb_build_object('kind','create_bots','values',p_values,'reason',p_reason);v_result jsonb;v_names text[];v_quotas integer[];v_count integer;v_batch uuid;v_uid uuid;v_name text;v_cap integer;v_idx integer:=0;v_j integer;v_k integer;v_n integer;v_titles integer;v_chests integer;v_games integer;v_wins integer;v_top integer;v_pool text[];v_available text[];v_title text;v_instance uuid;v_round uuid;v_target bigint;v_funding bigint;v_current bigint;v_bet bigint;v_win boolean;v_side text;v_chest public.ct_chest_types;v_weights integer[];v_sizes integer[];v_left integer;v_r integer;v_roll integer;
v_balance_min bigint;v_balance_max bigint;v_title_min integer;v_title_max integer;v_chest_min integer;v_chest_max integer;v_game_min integer;v_game_max integer;v_win_percent integer;v_ids jsonb:='[]';
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 IF p_reason IS NULL OR length(trim(p_reason)) NOT BETWEEN 8 AND 1000 THEN RAISE EXCEPTION 'Justification required';END IF;
 PERFORM pg_advisory_xact_lock(173,4);v_result:=public.ct_replay(v_admin,p_operation_id,v_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 SELECT array_agg(trim(x)) INTO v_names FROM jsonb_array_elements_text(p_values->'names')x;v_count:=cardinality(v_names);
 SELECT array_agg(x::integer) INTO v_quotas FROM jsonb_array_elements_text(p_values->'rarity_counts')x;
 v_balance_min:=(p_values->>'balance_min')::bigint;v_balance_max:=(p_values->>'balance_max')::bigint;v_title_min:=(p_values->>'titles_min')::integer;v_title_max:=(p_values->>'titles_max')::integer;v_top:=(p_values->>'top_titles')::integer;
 v_chest_min:=(p_values->>'chests_min')::integer;v_chest_max:=(p_values->>'chests_max')::integer;v_game_min:=(p_values->>'games_min')::integer;v_game_max:=(p_values->>'games_max')::integer;v_win_percent:=(p_values->>'win_percent')::integer;v_bet:=(p_values->>'bet')::bigint;
 IF v_count IS NULL OR v_count NOT BETWEEN 1 AND 25 OR cardinality(v_quotas) IS DISTINCT FROM 8 OR array_position(v_quotas,NULL) IS NOT NULL OR NOT(0<=ALL(v_quotas)) OR(SELECT sum(q) FROM unnest(v_quotas)q)<>v_count THEN RAISE EXCEPTION 'Choisissez 1 à 25 pseudos et une répartition exacte des raretés';END IF;
 IF EXISTS(SELECT 1 FROM unnest(v_names)n WHERE n!~'^[a-zA-Z0-9_]{3,24}$') OR(SELECT count(DISTINCT lower(n)) FROM unnest(v_names)n)<>v_count THEN RAISE EXCEPTION 'Pseudos invalides ou présents plusieurs fois';END IF;
 IF EXISTS(SELECT 1 FROM public.ct_profiles p JOIN unnest(v_names)n ON lower(p.username)=lower(n)) THEN RAISE EXCEPTION 'Un pseudo est déjà utilisé. Modifiez votre liste avant de créer le lot.';END IF;
 IF (SELECT count(*) FROM public.ct_bots)+v_count>5000 THEN RAISE EXCEPTION 'Limite de 5 000 bots atteinte';END IF;
 IF v_balance_min IS NULL OR v_balance_max IS NULL OR v_title_min IS NULL OR v_title_max IS NULL OR v_top IS NULL OR v_chest_min IS NULL OR v_chest_max IS NULL OR v_game_min IS NULL OR v_game_max IS NULL OR v_win_percent IS NULL OR v_bet IS NULL THEN RAISE EXCEPTION 'Configuration incomplète';END IF;
 IF v_balance_min<0 OR v_balance_max<v_balance_min OR v_balance_max>100000000 OR v_title_min<1 OR v_title_max<v_title_min OR v_title_max>100 OR v_top NOT BETWEEN 1 AND 5 OR v_top>v_title_min OR v_chest_min<0 OR v_chest_max<v_chest_min OR v_chest_max>100 OR v_game_min<0 OR v_game_max<v_game_min OR v_game_max>200 OR v_win_percent NOT BETWEEN 0 AND 100 OR v_bet NOT BETWEEN 20 AND 10000 OR v_bet%20<>0 THEN RAISE EXCEPTION 'Configuration hors limites';END IF;
 IF v_count*(v_title_max+v_chest_max+2*v_game_max)>4000 THEN RAISE EXCEPTION 'Lot trop volumineux. Réduisez le nombre de bots ou de simulations.';END IF;
 SELECT * INTO v_chest FROM public.ct_chest_types WHERE id=(p_values->>'chest_id')::smallint AND active AND category='standard' FOR SHARE;
 IF NOT FOUND OR v_chest.version IS DISTINCT FROM(p_values->>'chest_version')::bigint OR v_chest.price IS DISTINCT FROM(p_values->>'chest_price')::bigint THEN RAISE EXCEPTION 'Le coffre a changé. Actualisez la sélection.';END IF;
 SELECT array_agg(id ORDER BY id) INTO v_available FROM public.ct_titles WHERE available AND rarity<=7 AND(NOT(p_values?'title_pool') OR p_values->'title_pool'='null'::jsonb OR jsonb_array_length(p_values->'title_pool')=0 OR id IN(SELECT jsonb_array_elements_text(p_values->'title_pool')));
 FOR v_cap IN 1..7 LOOP IF v_quotas[v_cap+1]>0 THEN
 IF(SELECT count(*) FROM public.ct_titles WHERE id=ANY(v_available) AND rarity=v_cap)<(CASE WHEN v_cap=1 THEN v_title_max ELSE v_top END) OR(v_cap>1 AND(SELECT count(*) FROM public.ct_titles WHERE id=ANY(v_available) AND rarity<v_cap)<v_title_max-v_top) THEN RAISE EXCEPTION 'Le catalogue sélectionné ne couvre pas la rareté % et le nombre maximal de titres demandé',v_cap;END IF;
 END IF;END LOOP;
 INSERT INTO public.ct_bot_batches(admin_id,config) VALUES(v_admin,p_values) RETURNING id INTO v_batch;
 FOR v_cap IN 0..7 LOOP
 FOR v_j IN 1..v_quotas[v_cap+1] LOOP
  v_idx:=v_idx+1;v_name:=v_names[v_idx];v_uid:=gen_random_uuid();v_titles:=CASE WHEN v_cap=0 THEN 0 ELSE v_title_min+public.ct_random_below(v_title_max-v_title_min+1) END;
  v_chests:=CASE WHEN v_cap=0 THEN 0 ELSE v_chest_min+public.ct_random_below(v_chest_max-v_chest_min+1) END;v_games:=v_game_min+public.ct_random_below(v_game_max-v_game_min+1);v_wins:=floor(v_games*v_win_percent/100.0);v_target:=v_balance_min+public.ct_random_below((v_balance_max-v_balance_min+1)::integer);
  v_pool:='{}';
  IF v_cap>0 THEN
   SELECT array_agg(id) INTO v_pool FROM(SELECT id FROM public.ct_titles WHERE id=ANY(v_available) AND rarity=v_cap ORDER BY public.ct_random_below(1000000000),id LIMIT CASE WHEN v_cap=1 THEN v_titles ELSE v_top END)x;
   IF coalesce(cardinality(v_pool),0)<>(CASE WHEN v_cap=1 THEN v_titles ELSE v_top END) THEN RAISE EXCEPTION 'Pas assez de titres dans la rareté maximale % pour ce lot',v_cap;END IF;
   IF v_cap>1 THEN SELECT v_pool||coalesce(array_agg(id),'{}') INTO v_pool FROM(SELECT id FROM public.ct_titles WHERE id=ANY(v_available) AND rarity<v_cap ORDER BY public.ct_random_below(1000000000),id LIMIT v_titles-v_top)x;END IF;
   IF cardinality(v_pool)<>v_titles THEN RAISE EXCEPTION 'Pas assez de titres éligibles dans la sélection';END IF;
  END IF;
  INSERT INTO public.ct_profiles(id,username,avatar,is_bot) VALUES(v_uid,v_name,coalesce(nullif(p_values->>'avatar',''),'🤖'),true);
  INSERT INTO public.ct_bots(user_id,batch_id,max_rarity) VALUES(v_uid,v_batch,v_cap);
  INSERT INTO public.ct_wallets(user_id,balance) VALUES(v_uid,0);
  INSERT INTO public.ct_preferences(user_id,leaderboard_hidden) VALUES(v_uid,coalesce((p_values->>'hidden')::boolean,false));
  v_funding:=v_target+v_chests*v_chest.price+v_games*v_bet;
  IF v_funding>0 THEN PERFORM public.ct_post_credit(v_uid,v_funding,'bot_funding','bot-fund:'||v_batch::text);END IF;
  FOREACH v_title IN ARRAY v_pool LOOP INSERT INTO public.ct_player_titles(user_id,title_id,source) VALUES(v_uid,v_title,'bot:seed');END LOOP;
  -- Exact sampling weights of this bot's configured collection, never the live casino odds.
  v_weights:=ARRAY[0,0,0,0,0,0,0,0];v_sizes:=v_weights;v_left:=10000;
  FOR v_r IN 1..7 LOOP SELECT count(*) INTO v_n FROM public.ct_titles WHERE id=ANY(v_pool) AND rarity=v_r;v_sizes[v_r]:=v_n;END LOOP;
  IF v_titles>0 THEN FOR v_r IN 1..7 LOOP v_weights[v_r]:=floor(10000.0*v_sizes[v_r]/v_titles);v_left:=v_left-v_weights[v_r];END LOOP;v_weights[v_cap]:=v_weights[v_cap]+v_left;END IF;
  FOR v_k IN 1..v_chests LOOP
   v_roll:=public.ct_rarity_for_roll(v_weights,public.ct_random_below(10000));SELECT id INTO v_title FROM public.ct_titles WHERE id=ANY(v_pool) AND rarity=v_roll ORDER BY id OFFSET public.ct_random_below(v_sizes[v_roll]) LIMIT 1;
   PERFORM public.ct_post_credit(v_uid,-v_chest.price,'bot_chest','bot-chest:'||v_batch::text||':'||v_k);
   INSERT INTO public.ct_player_titles(user_id,title_id,source) VALUES(v_uid,v_title,'bot:chest') RETURNING id INTO v_instance;
   INSERT INTO public.ct_chest_openings(user_id,chest_id,player_title_id,price_paid,base_price,weights,operation_id,simulated) VALUES(v_uid,v_chest.id,v_instance,v_chest.price,v_chest.price,v_weights,gen_random_uuid(),true);
  END LOOP;
  -- Explicitly simulated Coinflip results: configured win count, shuffled chronology, exact settlements.
  FOR v_k IN 1..v_games LOOP
   v_win:=public.ct_random_below(v_games-v_k+1)<v_wins;IF v_win THEN v_wins:=v_wins-1;END IF;v_side:=CASE WHEN public.ct_random_below(2)=0 THEN 'pile' ELSE 'face' END;v_round:=gen_random_uuid();
   PERFORM public.ct_post_credit(v_uid,-v_bet,'bot_wager','bot-wager:'||v_round::text);
   IF v_win THEN PERFORM public.ct_post_credit(v_uid,2*v_bet,'bot_payout','bot-payout:'||v_round::text);END IF;
   INSERT INTO public.ct_game_rounds(id,user_id,game,bet,payout,status,choice,state,result,simulated) VALUES(v_round,v_uid,'coinflip',v_bet,CASE WHEN v_win THEN 2*v_bet ELSE 0 END,'settled',jsonb_build_object('side',CASE WHEN v_win THEN v_side WHEN v_side='pile' THEN 'face' ELSE 'pile' END),'{}',jsonb_build_object('game','coinflip','side',v_side,'outcome',CASE WHEN v_win THEN 'win' ELSE 'loss' END,'bet',v_bet,'payout',CASE WHEN v_win THEN 2*v_bet ELSE 0 END,'simulated',true),true);
  END LOOP;
  SELECT balance INTO v_current FROM public.ct_wallets WHERE user_id=v_uid;
  IF v_current<>v_target THEN PERFORM public.ct_post_credit(v_uid,v_target-v_current,'bot_balance_adjustment','bot-final:'||v_batch::text);END IF;
  IF v_titles>0 THEN SELECT i.id INTO v_instance FROM public.ct_player_titles i JOIN public.ct_titles t ON t.id=i.title_id WHERE i.user_id=v_uid ORDER BY t.rarity DESC,i.id LIMIT 1;INSERT INTO public.ct_equipped_titles(user_id,player_title_id) VALUES(v_uid,v_instance);END IF;
  v_ids:=v_ids||jsonb_build_object('id',v_uid,'username',v_name,'balance',v_target,'titles',v_titles,'chests',v_chests,'games',v_games,'max_rarity',v_cap);
 END LOOP;END LOOP;
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(v_admin,'bot_batch',v_batch::text,p_reason,jsonb_build_object('count',v_count,'config',p_values));
 v_result:=jsonb_build_object('batch_id',v_batch,'count',v_count,'bots',v_ids);INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(v_admin,p_operation_id,v_request,v_result);RETURN v_result;
END $$;

CREATE FUNCTION public.ct_admin_bots(p_search text DEFAULT '',p_offset integer DEFAULT 0) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_rows jsonb;v_total bigint;
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 IF p_offset IS NULL OR p_offset NOT BETWEEN 0 AND 5000 OR length(coalesce(p_search,''))>32 THEN RAISE EXCEPTION 'Invalid filters';END IF;
 SELECT count(*) INTO v_total FROM public.ct_bots b JOIN public.ct_profiles p ON p.id=b.user_id WHERE position(lower(coalesce(p_search,'')) IN lower(p.username))>0;
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC,x.id DESC),'[]') INTO v_rows FROM(
 SELECT p.id,p.username,p.avatar,p.created_at,b.active,b.version,coalesce((SELECT max(t.rarity) FROM public.ct_player_titles i JOIN public.ct_titles t ON t.id=i.title_id WHERE i.user_id=p.id AND i.revoked_at IS NULL),0) max_rarity,b.batch_id,w.balance,coalesce(pr.leaderboard_hidden,false) hidden,
 (SELECT count(DISTINCT title_id) FROM public.ct_player_titles WHERE user_id=p.id AND revoked_at IS NULL) titles,
 (SELECT count(*) FROM public.ct_chest_openings WHERE user_id=p.id) chests,
 (SELECT count(*) FROM public.ct_game_rounds WHERE user_id=p.id AND status='settled') games,
 (SELECT count(*) FROM public.ct_game_rounds WHERE user_id=p.id AND status='settled' AND payout>bet) wins
 FROM public.ct_bots b JOIN public.ct_profiles p ON p.id=b.user_id JOIN public.ct_wallets w ON w.user_id=p.id LEFT JOIN public.ct_preferences pr ON pr.user_id=p.id
 WHERE position(lower(coalesce(p_search,'')) IN lower(p.username))>0 ORDER BY p.created_at DESC,p.id DESC LIMIT 50 OFFSET p_offset)x;
 RETURN jsonb_build_object('bots',v_rows,'found',v_total,'total',(SELECT count(*) FROM public.ct_bots),'active',(SELECT count(*) FROM public.ct_bots WHERE active),'balances',(SELECT coalesce(sum(w.balance),0) FROM public.ct_wallets w JOIN public.ct_bots b ON b.user_id=w.user_id));
END $$;
CREATE FUNCTION public.ct_admin_update_bot(p_operation_id uuid,p_user_id uuid,p_values jsonb,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_admin uuid:=auth.uid();v_request jsonb:=jsonb_build_object('kind','update_bot','user',p_user_id,'values',p_values,'reason',p_reason);v_result jsonb;v_balance bigint;v_target bigint:=(p_values->>'balance')::bigint;b public.ct_bots;v_active boolean:=(p_values->>'active')::boolean;v_hidden boolean:=(p_values->>'hidden')::boolean;
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 IF p_reason IS NULL OR length(trim(p_reason)) NOT BETWEEN 8 AND 1000 OR v_target IS NULL OR v_target NOT BETWEEN 0 AND 100000000 OR v_active IS NULL OR v_hidden IS NULL THEN RAISE EXCEPTION 'Invalid bot changes';END IF;
 PERFORM pg_advisory_xact_lock(173,4);v_result:=public.ct_replay(v_admin,p_operation_id,v_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 SELECT balance INTO v_balance FROM public.ct_wallets WHERE user_id=p_user_id FOR UPDATE;SELECT * INTO b FROM public.ct_bots WHERE user_id=p_user_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Bot not found';END IF;
 IF (p_values->>'version')::bigint IS DISTINCT FROM b.version OR (p_values->>'expected_balance')::bigint IS DISTINCT FROM v_balance THEN RAISE EXCEPTION 'Bot modifié. Actualisez sa fiche.';END IF;
 UPDATE public.ct_profiles SET username=trim(p_values->>'username'),avatar=coalesce(nullif(p_values->>'avatar',''),'🤖') WHERE id=p_user_id;
 IF v_target<>v_balance THEN PERFORM public.ct_post_credit(p_user_id,v_target-v_balance,'bot_balance_adjustment','bot-edit:'||p_operation_id::text);END IF;
 UPDATE public.ct_bots SET active=v_active,version=version+1 WHERE user_id=p_user_id;
 INSERT INTO public.ct_preferences(user_id,leaderboard_hidden) VALUES(p_user_id,v_hidden) ON CONFLICT(user_id) DO UPDATE SET leaderboard_hidden=EXCLUDED.leaderboard_hidden,updated_at=now();
 IF NOT v_active THEN INSERT INTO public.ct_suspensions(user_id,reason) VALUES(p_user_id,'Bot archivé') ON CONFLICT(user_id) DO NOTHING;
 ELSE DELETE FROM public.ct_suspensions WHERE user_id=p_user_id AND reason='Bot archivé';END IF;
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(v_admin,'bot_update',p_user_id::text,p_reason,p_values);
 v_result:='{"ok":true}'::jsonb;INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(v_admin,p_operation_id,v_request,v_result);RETURN v_result;
END $$;
REVOKE ALL ON FUNCTION public.ct_admin_create_bots(uuid,jsonb,text),public.ct_admin_bots(text,integer),public.ct_admin_update_bot(uuid,uuid,jsonb,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_admin_create_bots(uuid,jsonb,text),public.ct_admin_bots(text,integer),public.ct_admin_update_bot(uuid,uuid,jsonb,text) TO authenticated;

ALTER FUNCTION public.ct_rankings(text,text) RENAME TO ct_rankings_before_bots;
REVOKE ALL ON FUNCTION public.ct_rankings_before_bots(text,text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_rankings(p_metric text DEFAULT 'credits',p_period text DEFAULT 'all') RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(e.row||jsonb_build_object('is_bot',p.is_bot) ORDER BY e.ord),'[]'::jsonb) FROM jsonb_array_elements(public.ct_rankings_before_bots(p_metric,p_period)) WITH ORDINALITY e(row,ord) JOIN public.ct_profiles p ON p.id=(e.row->>'id')::uuid;
$$;
CREATE OR REPLACE FUNCTION public.ct_public_profile(p_user_id uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('id',p.id,'username',p.username,'avatar',p.avatar,'created_at',p.created_at,'is_bot',p.is_bot,
 'equipped_title',(SELECT to_jsonb(t) FROM public.ct_equipped_titles e JOIN public.ct_player_titles i ON i.id=e.player_title_id JOIN public.ct_titles t ON t.id=i.title_id WHERE e.user_id=p.id AND i.revoked_at IS NULL),
 'unique_titles',(SELECT count(DISTINCT title_id) FROM public.ct_player_titles WHERE user_id=p.id AND revoked_at IS NULL),
 'chests',(SELECT count(*) FROM public.ct_chest_openings WHERE user_id=p.id),'games',(SELECT count(*) FROM public.ct_game_rounds WHERE user_id=p.id AND status='settled'),
 'wins',(SELECT count(*) FROM public.ct_game_rounds WHERE user_id=p.id AND status='settled' AND payout>bet),
 'bot_balance',CASE WHEN p.is_bot THEN(SELECT balance FROM public.ct_wallets WHERE user_id=p.id) ELSE NULL END)
 FROM public.ct_profiles p WHERE p.id=p_user_id AND(NOT p.is_bot OR EXISTS(SELECT 1 FROM public.ct_bots WHERE user_id=p.id AND active));
$$;
CREATE OR REPLACE FUNCTION public.ct_find_players(p_search text) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) FROM(SELECT p.id,p.username,p.avatar,p.is_bot,public.ct_public_profile(p.id)->'equipped_title' equipped_title,(public.ct_public_profile(p.id)->>'unique_titles')::integer unique_titles FROM public.ct_profiles p WHERE length(trim(p_search)) BETWEEN 2 AND 32 AND position(lower(trim(p_search)) IN lower(p.username))>0 AND NOT EXISTS(SELECT 1 FROM public.ct_suspensions s WHERE s.user_id=p.id) AND(NOT p.is_bot OR EXISTS(SELECT 1 FROM public.ct_bots WHERE user_id=p.id AND active)) ORDER BY CASE WHEN lower(p.username)=lower(trim(p_search)) THEN 0 ELSE 1 END,lower(p.username),p.id LIMIT 30)x;
$$;
CREATE OR REPLACE FUNCTION public.ct_title_statistics() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) FROM(SELECT t.id title_id,count(DISTINCT i.user_id) FILTER(WHERE s.user_id IS NULL) owners,count(DISTINCT i.user_id) FILTER(WHERE s.user_id IS NULL AND p.is_bot) bots FROM public.ct_titles t LEFT JOIN public.ct_player_titles i ON i.title_id=t.id AND i.revoked_at IS NULL LEFT JOIN public.ct_profiles p ON p.id=i.user_id LEFT JOIN public.ct_suspensions s ON s.user_id=i.user_id GROUP BY t.id)x;
$$;
ALTER FUNCTION public.ct_admin_economy(integer,bigint,text) RENAME TO ct_admin_economy_before_bots;
REVOKE ALL ON FUNCTION public.ct_admin_economy_before_bots(integer,bigint,text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_admin_economy(p_days integer DEFAULT 30,p_before bigint DEFAULT NULL,p_reason text DEFAULT '') RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT public.ct_admin_economy_before_bots(p_days,p_before,p_reason)||jsonb_build_object('bot_balances',(SELECT coalesce(sum(w.balance),0) FROM public.ct_wallets w JOIN public.ct_profiles p ON p.id=w.user_id WHERE p.is_bot));
$$;
REVOKE ALL ON FUNCTION public.ct_admin_economy(integer,bigint,text),public.ct_rankings(text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_admin_economy(integer,bigint,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ct_rankings(text,text) TO anon,authenticated;


ALTER FUNCTION public.ct_public_collection(uuid) RENAME TO ct_public_collection_before_bots;
REVOKE ALL ON FUNCTION public.ct_public_collection_before_bots(uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_public_collection(p_user_id uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT CASE WHEN EXISTS(SELECT 1 FROM public.ct_profiles p WHERE p.id=p_user_id AND(NOT p.is_bot OR EXISTS(SELECT 1 FROM public.ct_bots WHERE user_id=p.id AND active))) THEN public.ct_public_collection_before_bots(p_user_id) ELSE '[]'::jsonb END;
$$;
REVOKE ALL ON FUNCTION public.ct_public_collection(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_public_collection(uuid) TO anon,authenticated;

COMMIT;
