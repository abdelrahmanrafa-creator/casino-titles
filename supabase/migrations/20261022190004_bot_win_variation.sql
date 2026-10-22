BEGIN;
CREATE OR REPLACE FUNCTION public.ct_admin_create_bots(p_operation_id uuid,p_values jsonb,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET statement_timeout='25s' AS $$
DECLARE v_admin uuid:=auth.uid();v_request jsonb:=jsonb_build_object('kind','create_bots','values',p_values,'reason',p_reason);v_result jsonb;v_names text[];v_quotas integer[];v_count integer;v_batch uuid;v_uid uuid;v_name text;v_cap integer;v_idx integer:=0;v_j integer;v_k integer;v_n integer;v_titles integer;v_chests integer;v_games integer;v_wins integer;v_top integer;v_pool text[];v_available text[];v_title text;v_instance uuid;v_round uuid;v_target bigint;v_funding bigint;v_current bigint;v_bet bigint;v_win boolean;v_side text;v_chest public.ct_chest_types;v_weights integer[];v_sizes integer[];v_left integer;v_r integer;v_roll integer;
v_balance_min bigint;v_balance_max bigint;v_title_min integer;v_title_max integer;v_chest_min integer;v_chest_max integer;v_game_min integer;v_game_max integer;v_win_percent integer;v_win_min integer;v_win_max integer;v_ids jsonb:='[]';
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 IF p_reason IS NULL OR length(trim(p_reason)) NOT BETWEEN 8 AND 1000 THEN RAISE EXCEPTION 'Justification required';END IF;
 PERFORM pg_advisory_xact_lock(173,4);v_result:=public.ct_replay(v_admin,p_operation_id,v_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 SELECT array_agg(trim(x)) INTO v_names FROM jsonb_array_elements_text(p_values->'names')x;v_count:=cardinality(v_names);
 SELECT array_agg(x::integer) INTO v_quotas FROM jsonb_array_elements_text(p_values->'rarity_counts')x;
 v_balance_min:=(p_values->>'balance_min')::bigint;v_balance_max:=(p_values->>'balance_max')::bigint;v_title_min:=(p_values->>'titles_min')::integer;v_title_max:=(p_values->>'titles_max')::integer;v_top:=(p_values->>'top_titles')::integer;
 v_chest_min:=(p_values->>'chests_min')::integer;v_chest_max:=(p_values->>'chests_max')::integer;v_game_min:=(p_values->>'games_min')::integer;v_game_max:=(p_values->>'games_max')::integer;v_win_min:=coalesce((p_values->>'win_percent_min')::integer,(p_values->>'win_percent')::integer);v_win_max:=coalesce((p_values->>'win_percent_max')::integer,(p_values->>'win_percent')::integer);v_win_percent:=v_win_min;v_bet:=(p_values->>'bet')::bigint;
 IF v_count IS NULL OR v_count NOT BETWEEN 1 AND 25 OR cardinality(v_quotas) IS DISTINCT FROM 8 OR array_position(v_quotas,NULL) IS NOT NULL OR NOT(0<=ALL(v_quotas)) OR(SELECT sum(q) FROM unnest(v_quotas)q)<>v_count THEN RAISE EXCEPTION 'Choisissez 1 à 25 pseudos et une répartition exacte des raretés';END IF;
 IF EXISTS(SELECT 1 FROM unnest(v_names)n WHERE n!~'^[a-zA-Z0-9_]{3,24}$') OR(SELECT count(DISTINCT lower(n)) FROM unnest(v_names)n)<>v_count THEN RAISE EXCEPTION 'Pseudos invalides ou présents plusieurs fois';END IF;
 IF EXISTS(SELECT 1 FROM public.ct_profiles p JOIN unnest(v_names)n ON lower(p.username)=lower(n)) THEN RAISE EXCEPTION 'Un pseudo est déjà utilisé. Modifiez votre liste avant de créer le lot.';END IF;
 IF (SELECT count(*) FROM public.ct_bots)+v_count>5000 THEN RAISE EXCEPTION 'Limite de 5 000 bots atteinte';END IF;
 IF ((p_values?'win_percent_min')<>(p_values?'win_percent_max')) OR v_win_min IS NULL OR v_win_max IS NULL OR v_win_min<0 OR v_win_max>100 OR v_win_max<v_win_min THEN RAISE EXCEPTION 'Fourchette de victoires invalide (0 à 100 %%)';END IF;
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
  v_chests:=CASE WHEN v_cap=0 THEN 0 ELSE v_chest_min+public.ct_random_below(v_chest_max-v_chest_min+1) END;v_games:=v_game_min+public.ct_random_below(v_game_max-v_game_min+1);v_win_percent:=v_win_min+public.ct_random_below(v_win_max-v_win_min+1);v_wins:=floor(v_games*v_win_percent/100.0);v_target:=v_balance_min+public.ct_random_below((v_balance_max-v_balance_min+1)::integer);
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


-- Private maintenance helper: edits simulated Coinflip only; never real games.
CREATE FUNCTION public.ct_vary_bot_results(p_user_id uuid,p_min integer,p_max integer) RETURNS jsonb LANGUAGE plpgsql SET search_path='' AS $$
DECLARE b record;r record;v_games integer;v_wins integer;v_remaining integer;v_before bigint;v_delta bigint:=0;v_payout bigint;v_win boolean;v_rate integer;v_key text:=gen_random_uuid()::text;v_admin uuid;
BEGIN
 IF p_min IS NULL OR p_max IS NULL OR p_min<0 OR p_max>100 OR p_max<p_min THEN RAISE EXCEPTION 'Invalid win range';END IF;
 SELECT * INTO b FROM public.ct_bots WHERE user_id=p_user_id FOR UPDATE;IF NOT FOUND THEN RAISE EXCEPTION 'Bot required';END IF;
 SELECT balance INTO v_before FROM public.ct_wallets WHERE user_id=p_user_id FOR UPDATE;
 SELECT count(*) INTO v_games FROM public.ct_game_rounds WHERE user_id=p_user_id AND simulated AND game='coinflip' AND status='settled';
 IF v_games=0 THEN RETURN jsonb_build_object('games',0);END IF;
 v_rate:=p_min+public.ct_random_below(p_max-p_min+1);v_wins:=floor(v_games*v_rate/100.0);v_remaining:=v_games;
 FOR r IN SELECT * FROM public.ct_game_rounds WHERE user_id=p_user_id AND simulated AND game='coinflip' AND status='settled' ORDER BY id FOR UPDATE LOOP
  v_win:=public.ct_random_below(v_remaining)<v_wins;IF v_win THEN v_wins:=v_wins-1;END IF;v_remaining:=v_remaining-1;v_payout:=CASE WHEN v_win THEN 2*r.bet ELSE 0 END;v_delta:=v_delta+v_payout-r.payout;
  UPDATE public.ct_game_rounds SET payout=v_payout,result=result||jsonb_build_object('payout',v_payout,'outcome',CASE WHEN v_win THEN 'win' ELSE 'loss' END,'side',CASE WHEN v_win THEN r.choice->>'side' WHEN r.choice->>'side'='pile' THEN 'face' ELSE 'pile' END),updated_at=now() WHERE id=r.id;
 END LOOP;
 -- Record the settlement correction and opposite frozen-balance adjustment together.
 IF v_delta>0 THEN
  PERFORM public.ct_post_credit(p_user_id,v_delta,'bot_statistics_correction','bot-stats:'||v_key);
  PERFORM public.ct_post_credit(p_user_id,-v_delta,'bot_balance_adjustment','bot-freeze:'||v_key);
 ELSIF v_delta<0 THEN
  PERFORM public.ct_post_credit(p_user_id,-v_delta,'bot_balance_adjustment','bot-freeze:'||v_key);
  PERFORM public.ct_post_credit(p_user_id,v_delta,'bot_statistics_correction','bot-stats:'||v_key);
 END IF;
 IF (SELECT balance FROM public.ct_wallets WHERE user_id=p_user_id)<>v_before THEN RAISE EXCEPTION 'Frozen balance mismatch';END IF;
 UPDATE public.ct_bots SET version=version+1 WHERE user_id=p_user_id;
 SELECT admin_id INTO v_admin FROM public.ct_bot_batches WHERE id=b.batch_id;
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(v_admin,'bot_statistics_variation',p_user_id::text,'Variation des résultats simulés demandée par le propriétaire',jsonb_build_object('source','migration_20261022190004','min',p_min,'max',p_max,'sampled_percent',v_rate,'games',v_games,'payout_correction',v_delta,'balance_preserved',v_before));
 RETURN jsonb_build_object('games',v_games,'sampled_percent',v_rate,'payout_correction',v_delta);
END $$;
REVOKE ALL ON FUNCTION public.ct_vary_bot_results(uuid,integer,integer) FROM PUBLIC,anon,authenticated;
DO $$ DECLARE b record;BEGIN
 PERFORM pg_advisory_xact_lock(173,4);
 FOR b IN SELECT user_id FROM public.ct_bots WHERE active ORDER BY user_id LOOP PERFORM public.ct_vary_bot_results(b.user_id,35,68);END LOOP;
END $$;

COMMIT;
