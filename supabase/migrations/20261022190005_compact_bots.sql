BEGIN;
ALTER TABLE public.ct_player_titles ADD COLUMN quantity integer NOT NULL DEFAULT 1 CHECK(quantity BETWEEN 1 AND 1000000);
-- Quantity is internal; real-player acquisitions still represent one instance each.
CREATE TABLE public.ct_bot_summaries(user_id uuid PRIMARY KEY REFERENCES public.ct_bots(user_id) ON DELETE CASCADE,games integer NOT NULL CHECK(games>=0),wins integer NOT NULL CHECK(wins BETWEEN 0 AND games),chests integer NOT NULL CHECK(chests>=0),chest_spending bigint NOT NULL CHECK(chest_spending>=0),bet bigint NOT NULL CHECK(bet>0),created_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.ct_bot_summaries ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ct_bot_summaries FROM PUBLIC,anon,authenticated;
CREATE INDEX ct_bots_batch_idx ON public.ct_bots(batch_id);
CREATE OR REPLACE FUNCTION public.ct_admin_create_bots(p_operation_id uuid,p_values jsonb,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET statement_timeout='25s' AS $$
DECLARE v_admin uuid:=auth.uid();v_request jsonb:=jsonb_build_object('kind','create_bots','values',p_values,'reason',p_reason);v_result jsonb;v_names text[];v_quotas integer[];v_count integer;v_batch uuid;v_uid uuid;v_name text;v_cap integer;v_idx integer:=0;v_j integer;v_k integer;v_n integer;v_titles integer;v_chests integer;v_games integer;v_wins integer;v_top integer;v_pool text[];v_available text[];v_title text;v_instance uuid;v_round uuid;v_target bigint;v_funding bigint;v_current bigint;v_bet bigint;v_win boolean;v_side text;v_chest public.ct_chest_types;v_weights integer[];v_sizes integer[];v_left integer;v_r integer;v_roll integer;
v_balance_min bigint;v_balance_max bigint;v_title_min integer;v_title_max integer;v_chest_min integer;v_chest_max integer;v_game_min integer;v_game_max integer;v_win_percent integer;v_win_min integer;v_win_max integer;v_compact boolean:=coalesce((p_values->>'compact')::boolean,false);v_ids jsonb:='[]';
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 IF p_reason IS NULL OR length(trim(p_reason)) NOT BETWEEN 8 AND 1000 THEN RAISE EXCEPTION 'Justification required';END IF;
 PERFORM pg_advisory_xact_lock(173,4);v_result:=public.ct_replay(v_admin,p_operation_id,v_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 SELECT array_agg(trim(x)) INTO v_names FROM jsonb_array_elements_text(p_values->'names')x;v_count:=cardinality(v_names);
 SELECT array_agg(x::integer) INTO v_quotas FROM jsonb_array_elements_text(p_values->'rarity_counts')x;
 v_balance_min:=(p_values->>'balance_min')::bigint;v_balance_max:=(p_values->>'balance_max')::bigint;v_title_min:=(p_values->>'titles_min')::integer;v_title_max:=(p_values->>'titles_max')::integer;v_top:=(p_values->>'top_titles')::integer;
 v_chest_min:=(p_values->>'chests_min')::integer;v_chest_max:=(p_values->>'chests_max')::integer;v_game_min:=(p_values->>'games_min')::integer;v_game_max:=(p_values->>'games_max')::integer;v_win_min:=coalesce((p_values->>'win_percent_min')::integer,(p_values->>'win_percent')::integer);v_win_max:=coalesce((p_values->>'win_percent_max')::integer,(p_values->>'win_percent')::integer);v_win_percent:=v_win_min;v_bet:=(p_values->>'bet')::bigint;
 IF v_count IS NULL OR v_count NOT BETWEEN 1 AND (CASE WHEN v_compact THEN 250 ELSE 25 END) OR cardinality(v_quotas) IS DISTINCT FROM 8 OR array_position(v_quotas,NULL) IS NOT NULL OR NOT(0<=ALL(v_quotas)) OR(SELECT sum(q) FROM unnest(v_quotas)q)<>v_count THEN RAISE EXCEPTION 'Choisissez jusqu’à 250 pseudos en mode compact et une répartition exacte des raretés';END IF;
 IF EXISTS(SELECT 1 FROM unnest(v_names)n WHERE n!~'^[a-zA-Z0-9_]{3,24}$') OR(SELECT count(DISTINCT lower(n)) FROM unnest(v_names)n)<>v_count THEN RAISE EXCEPTION 'Pseudos invalides ou présents plusieurs fois';END IF;
 IF EXISTS(SELECT 1 FROM public.ct_profiles p JOIN unnest(v_names)n ON lower(p.username)=lower(n)) THEN RAISE EXCEPTION 'Un pseudo est déjà utilisé. Modifiez votre liste avant de créer le lot.';END IF;
 IF (SELECT count(*) FROM public.ct_bots)+v_count>(CASE WHEN v_compact THEN 50000 ELSE 5000 END) THEN RAISE EXCEPTION 'Limite de bots atteinte';END IF;
 IF ((p_values?'win_percent_min')<>(p_values?'win_percent_max')) OR v_win_min IS NULL OR v_win_max IS NULL OR v_win_min<0 OR v_win_max>100 OR v_win_max<v_win_min THEN RAISE EXCEPTION 'Fourchette de victoires invalide (0 à 100 %%)';END IF;
 IF v_balance_min IS NULL OR v_balance_max IS NULL OR v_title_min IS NULL OR v_title_max IS NULL OR v_top IS NULL OR v_chest_min IS NULL OR v_chest_max IS NULL OR v_game_min IS NULL OR v_game_max IS NULL OR v_win_percent IS NULL OR v_bet IS NULL THEN RAISE EXCEPTION 'Configuration incomplète';END IF;
 IF v_balance_min<0 OR v_balance_max<v_balance_min OR v_balance_max>100000000 OR v_title_min<1 OR v_title_max<v_title_min OR v_title_max>100 OR v_top NOT BETWEEN 1 AND 5 OR v_top>v_title_min OR v_chest_min<0 OR v_chest_max<v_chest_min OR v_chest_max>100 OR v_game_min<0 OR v_game_max<v_game_min OR v_game_max>200 OR v_win_percent NOT BETWEEN 0 AND 100 OR v_bet NOT BETWEEN 20 AND 10000 OR v_bet%20<>0 THEN RAISE EXCEPTION 'Configuration hors limites';END IF;
 IF pg_database_size(current_database())>350000000 THEN RAISE EXCEPTION 'Création suspendue : seuil prudent de 350 Mo atteint dans la base';END IF;
 IF v_compact AND v_count*v_title_max>5000 THEN RAISE EXCEPTION 'Limitez le lot à 5 000 titres uniques au total';END IF;
 IF NOT v_compact AND v_count*(v_title_max+v_chest_max+2*v_game_max)>4000 THEN RAISE EXCEPTION 'Lot trop volumineux. Réduisez le nombre de bots ou de simulations.';END IF;
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
  IF v_compact THEN
   -- One stored summary instead of one row per fictitious round/opening.
   INSERT INTO public.ct_bot_summaries(user_id,games,wins,chests,chest_spending,bet) VALUES(v_uid,v_games,v_wins,v_chests,v_chests*v_chest.price,v_bet);
   IF v_chests>0 THEN
    UPDATE public.ct_player_titles i SET quantity=i.quantity+x.n FROM(SELECT v_pool[1+public.ct_random_below(v_titles)] title_id,count(*)::integer n FROM generate_series(1,v_chests) GROUP BY 1)x WHERE i.user_id=v_uid AND i.title_id=x.title_id AND i.revoked_at IS NULL;
    PERFORM public.ct_post_credit(v_uid,-v_chests*v_chest.price,'bot_chest_summary','bot-chests:'||v_batch::text);
   END IF;
   IF v_games>0 THEN PERFORM public.ct_post_credit(v_uid,-v_games*v_bet,'bot_wager_summary','bot-wagers:'||v_batch::text);END IF;
   IF v_wins>0 THEN PERFORM public.ct_post_credit(v_uid,2*v_wins*v_bet,'bot_payout_summary','bot-payouts:'||v_batch::text);END IF;
  ELSE
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
  END IF;
  SELECT balance INTO v_current FROM public.ct_wallets WHERE user_id=v_uid;
  IF v_current<>v_target THEN PERFORM public.ct_post_credit(v_uid,v_target-v_current,'bot_balance_adjustment','bot-final:'||v_batch::text);END IF;
  IF v_titles>0 THEN SELECT i.id INTO v_instance FROM public.ct_player_titles i JOIN public.ct_titles t ON t.id=i.title_id WHERE i.user_id=v_uid ORDER BY t.rarity DESC,i.id LIMIT 1;INSERT INTO public.ct_equipped_titles(user_id,player_title_id) VALUES(v_uid,v_instance);END IF;
  v_ids:=v_ids||jsonb_build_object('id',v_uid,'username',v_name,'balance',v_target,'titles',v_titles,'chests',v_chests,'games',v_games,'max_rarity',v_cap);
 END LOOP;END LOOP;
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(v_admin,'bot_batch',v_batch::text,p_reason,jsonb_build_object('count',v_count,'config',p_values));
 v_result:=jsonb_build_object('batch_id',v_batch,'count',v_count,'bots',v_ids);INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(v_admin,p_operation_id,v_request,v_result);RETURN v_result;
END $$;



CREATE FUNCTION public.ct_solo_statistics(p_user_id uuid) RETURNS jsonb LANGUAGE sql STABLE SET search_path='' AS $$
 WITH rounds AS(SELECT payout,CASE WHEN game='blackjack' AND jsonb_typeof(state->'hands')='array' THEN coalesce((SELECT sum((h->>'bet')::bigint) FROM jsonb_array_elements(state->'hands') h),bet) ELSE bet END stake FROM public.ct_game_rounds WHERE user_id=p_user_id AND status='settled'), totals AS(
 SELECT count(*) games,count(*) FILTER(WHERE payout>stake) wins,count(*) FILTER(WHERE payout<stake) losses,count(*) FILTER(WHERE payout=stake) draws,coalesce(sum(stake),0) wagered,coalesce(sum(payout),0) returned,coalesce(sum(greatest(payout-stake,0)),0) gains,coalesce(sum(greatest(stake-payout,0)),0) loss_amount,coalesce(max(stake),0) biggest_bet,coalesce(max(greatest(payout-stake,0)),0) biggest_win FROM rounds
 UNION ALL SELECT games,wins,games-wins,0,games*bet,2*wins*bet,wins*bet,(games-wins)*bet,CASE WHEN games>0 THEN bet ELSE 0 END,CASE WHEN wins>0 THEN bet ELSE 0 END FROM public.ct_bot_summaries WHERE user_id=p_user_id), s AS(SELECT sum(games) games,sum(wins) wins,sum(losses) losses,sum(draws) draws,sum(wagered) wagered,sum(returned) returned,sum(gains) gains,sum(loss_amount) loss_amount,max(biggest_bet) biggest_bet,max(biggest_win) biggest_win FROM totals)
 SELECT to_jsonb(s)||jsonb_build_object('net',returned-wagered,'win_percent',wins*100.0/nullif(games,0),'win_loss_ratio',wins::numeric/nullif(losses,0),'return_percent',returned*100.0/nullif(wagered,0)) FROM s;
$$;
REVOKE ALL ON FUNCTION public.ct_solo_statistics(uuid) FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.ct_public_profile(p_user_id uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT (public.ct_public_profile_internal(p_user_id)-'is_bot'-'bot_balance')||jsonb_build_object('chests',coalesce((SELECT count(*) FROM public.ct_chest_openings WHERE user_id=p_user_id),0)+coalesce(s.chests,0),'games',coalesce((SELECT count(*) FROM public.ct_game_rounds WHERE user_id=p_user_id AND status='settled'),0)+coalesce(s.games,0),'wins',coalesce((SELECT count(*) FROM public.ct_game_rounds WHERE user_id=p_user_id AND status='settled' AND payout>bet),0)+coalesce(s.wins,0)) FROM (SELECT 1) base LEFT JOIN public.ct_bot_summaries s ON s.user_id=p_user_id;
$$;
CREATE OR REPLACE FUNCTION public.ct_public_profile_details(p_user_id uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_profile jsonb;v_stats jsonb;v_positions jsonb;v_hidden boolean;
BEGIN
 IF EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=p_user_id) THEN RETURN NULL;END IF;
 v_profile:=public.ct_public_profile(p_user_id);IF v_profile IS NULL THEN RETURN NULL;END IF;
 SELECT public.ct_solo_statistics(p_user_id) INTO v_stats;
 SELECT coalesce((SELECT leaderboard_hidden FROM public.ct_preferences WHERE user_id=p_user_id),false) INTO v_hidden;
 IF v_hidden THEN v_positions:='[]'::jsonb;ELSE
 SELECT coalesce(jsonb_agg(jsonb_build_object('metric',metric,'period',period,'rank',r.ordinality) ORDER BY r.ordinality,metric,period),'[]'::jsonb) INTO v_positions FROM unnest(ARRAY['credits','wins','titles','chests','cosmic']) metric CROSS JOIN unnest(ARRAY['all','week']) period CROSS JOIN LATERAL jsonb_array_elements(public.ct_rankings(metric,period)) WITH ORDINALITY r(item,ordinality) WHERE r.item->>'id'=p_user_id::text;
 END IF;
 RETURN v_profile || jsonb_build_object('balance',(SELECT balance FROM public.ct_wallets WHERE user_id=p_user_id),'statistics',v_stats,'positions',v_positions,'leaderboard_hidden',v_hidden,'chest_spending',((SELECT coalesce(sum(price_paid),0) FROM public.ct_chest_openings WHERE user_id=p_user_id)+coalesce((SELECT chest_spending FROM public.ct_bot_summaries WHERE user_id=p_user_id),0)),'title_copies',(SELECT coalesce(sum(quantity),0) FROM public.ct_player_titles WHERE user_id=p_user_id AND revoked_at IS NULL));
END $$;
CREATE OR REPLACE FUNCTION public.ct_title_statistics() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 WITH population AS (SELECT p.id,p.is_bot FROM public.ct_profiles p WHERE NOT EXISTS(SELECT 1 FROM public.ct_suspensions s WHERE s.user_id=p.id) AND (NOT p.is_bot OR EXISTS(SELECT 1 FROM public.ct_bots b WHERE b.user_id=p.id AND b.active))), totals AS(SELECT count(*) n FROM population), counts AS(SELECT i.title_id,sum(i.quantity) copies,count(DISTINCT i.user_id) owners,count(DISTINCT i.user_id) FILTER(WHERE p.is_bot) bots FROM public.ct_player_titles i JOIN population p ON p.id=i.user_id WHERE i.revoked_at IS NULL GROUP BY i.title_id)
 SELECT coalesce(jsonb_agg(jsonb_build_object('title_id',t.id,'copies',coalesce(c.copies,0),'owners',coalesce(c.owners,0),'population',n,'percentage',CASE WHEN n=0 THEN 0 ELSE coalesce(c.owners,0)*100.0/n END) ORDER BY t.id),'[]'::jsonb) FROM public.ct_titles t CROSS JOIN totals LEFT JOIN counts c ON c.title_id=t.id;
$$;
CREATE OR REPLACE FUNCTION public.ct_public_collection_before_bots(p_user_id uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.rarity DESC,x.name),'[]'::jsonb) FROM(SELECT t.id,t.name,t.rarity,t.description,t.effect,sum(i.quantity) copies FROM public.ct_player_titles i JOIN public.ct_titles t ON t.id=i.title_id WHERE i.user_id=p_user_id AND i.revoked_at IS NULL AND NOT EXISTS(SELECT 1 FROM public.ct_suspensions s WHERE s.user_id=p_user_id) GROUP BY t.id)x;
$$;
CREATE OR REPLACE FUNCTION public.ct_admin_bots(p_search text DEFAULT '',p_offset integer DEFAULT 0) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_rows jsonb;v_total bigint;
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 IF p_offset IS NULL OR p_offset NOT BETWEEN 0 AND 50000 OR length(coalesce(p_search,''))>32 THEN RAISE EXCEPTION 'Invalid filters';END IF;
 SELECT count(*) INTO v_total FROM public.ct_bots b JOIN public.ct_profiles p ON p.id=b.user_id WHERE position(lower(coalesce(p_search,'')) IN lower(p.username))>0;
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC,x.id DESC),'[]') INTO v_rows FROM(
 SELECT p.id,p.username,p.avatar,p.created_at,b.active,b.version,coalesce((SELECT max(t.rarity) FROM public.ct_player_titles i JOIN public.ct_titles t ON t.id=i.title_id WHERE i.user_id=p.id AND i.revoked_at IS NULL),0) max_rarity,b.batch_id,w.balance,coalesce(pr.leaderboard_hidden,false) hidden,
 (SELECT count(DISTINCT title_id) FROM public.ct_player_titles WHERE user_id=p.id AND revoked_at IS NULL) titles,
 ((SELECT count(*) FROM public.ct_chest_openings WHERE user_id=p.id)+coalesce((SELECT chests FROM public.ct_bot_summaries WHERE user_id=p.id),0)) chests,
 ((SELECT count(*) FROM public.ct_game_rounds WHERE user_id=p.id AND status='settled')+coalesce((SELECT games FROM public.ct_bot_summaries WHERE user_id=p.id),0)) games,
 ((SELECT count(*) FROM public.ct_game_rounds WHERE user_id=p.id AND status='settled' AND payout>bet)+coalesce((SELECT wins FROM public.ct_bot_summaries WHERE user_id=p.id),0)) wins
 FROM public.ct_bots b JOIN public.ct_profiles p ON p.id=b.user_id JOIN public.ct_wallets w ON w.user_id=p.id LEFT JOIN public.ct_preferences pr ON pr.user_id=p.id
 WHERE position(lower(coalesce(p_search,'')) IN lower(p.username))>0 ORDER BY p.created_at DESC,p.id DESC LIMIT 50 OFFSET p_offset)x;
 RETURN jsonb_build_object('bots',v_rows,'found',v_total,'total',(SELECT count(*) FROM public.ct_bots),'active',(SELECT count(*) FROM public.ct_bots WHERE active),'balances',(SELECT coalesce(sum(w.balance),0) FROM public.ct_wallets w JOIN public.ct_bots b ON b.user_id=w.user_id));
END $$;

CREATE FUNCTION public.ct_admin_bot_storage() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 RETURN jsonb_build_object('database_bytes',pg_database_size(current_database()),'creation_guard_bytes',350000000,'compact_bots',(SELECT count(*) FROM public.ct_bot_summaries),'bots',(SELECT count(*) FROM public.ct_bots),'batch_limit',250,'bot_limit',50000);
END $$;
REVOKE ALL ON FUNCTION public.ct_admin_bot_storage() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_admin_bot_storage() TO authenticated;
CREATE OR REPLACE FUNCTION public.ct_rankings(p_metric text DEFAULT 'credits',p_period text DEFAULT 'all') RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_since timestamptz;v_result jsonb;
BEGIN
 IF p_metric IS NULL OR p_metric NOT IN('credits','wins','titles','chests','cosmic') OR p_period IS NULL OR p_period NOT IN('all','week') THEN RAISE EXCEPTION 'Invalid ranking';END IF;
 v_since:=CASE WHEN p_period='week' THEN date_trunc('week',now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' ELSE '-infinity'::timestamptz END;
 WITH metrics AS(
 SELECT user_id,balance::numeric score FROM public.ct_wallets WHERE p_metric='credits' AND p_period='all'
 UNION ALL SELECT user_id,sum(amount) FROM public.ct_wallet_transactions WHERE p_metric='credits' AND p_period='week' AND created_at>=v_since GROUP BY user_id
 UNION ALL SELECT user_id,count(*) FROM public.ct_game_rounds WHERE p_metric='wins' AND status='settled' AND payout>bet AND updated_at>=v_since GROUP BY user_id
 UNION ALL SELECT user_id,wins FROM public.ct_bot_summaries WHERE p_metric='wins' AND created_at>=v_since
 UNION ALL SELECT user_id,count(DISTINCT title_id) FROM public.ct_player_titles WHERE p_metric='titles' AND revoked_at IS NULL AND acquired_at>=v_since GROUP BY user_id
 UNION ALL SELECT user_id,count(*) FROM public.ct_chest_openings WHERE p_metric='chests' AND created_at>=v_since GROUP BY user_id
 UNION ALL SELECT user_id,chests FROM public.ct_bot_summaries WHERE p_metric='chests' AND created_at>=v_since
 UNION ALL SELECT i.user_id,sum(i.quantity) FROM public.ct_player_titles i JOIN public.ct_titles t ON t.id=i.title_id WHERE p_metric='cosmic' AND i.revoked_at IS NULL AND t.rarity=8 AND i.acquired_at>=v_since GROUP BY i.user_id
 ),scores AS(SELECT user_id,sum(score) score FROM metrics GROUP BY user_id),top_players AS(
 SELECT p.id,p.username,p.avatar,coalesce(s.score,0) score FROM public.ct_profiles p JOIN public.ct_wallets w ON w.user_id=p.id LEFT JOIN scores s ON s.user_id=p.id
 WHERE NOT EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=p.id) AND NOT EXISTS(SELECT 1 FROM public.ct_preferences WHERE user_id=p.id AND leaderboard_hidden) AND(NOT p.is_bot OR EXISTS(SELECT 1 FROM public.ct_bots WHERE user_id=p.id AND active)) ORDER BY score DESC,p.username,p.id LIMIT 50)
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.score DESC,x.username,x.id),'[]'::jsonb) INTO v_result FROM(
 SELECT p.*, (SELECT to_jsonb(t) FROM public.ct_equipped_titles e JOIN public.ct_player_titles i ON i.id=e.player_title_id JOIN public.ct_titles t ON t.id=i.title_id WHERE e.user_id=p.id AND i.revoked_at IS NULL) equipped_title FROM top_players p)x;
 RETURN v_result;
END $$;
CREATE OR REPLACE FUNCTION public.ct_admin_overview(p_search text DEFAULT '') RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 RETURN jsonb_build_object('players',(SELECT count(*) FROM public.ct_profiles),'credits',(SELECT coalesce(sum(balance),0) FROM public.ct_wallets),
 'rounds',((SELECT count(*) FROM public.ct_game_rounds)+(SELECT coalesce(sum(games),0) FROM public.ct_bot_summaries)),'chests',((SELECT count(*) FROM public.ct_chest_openings)+(SELECT coalesce(sum(chests),0) FROM public.ct_bot_summaries)),
 'results',coalesce((SELECT jsonb_agg(to_jsonb(p)) FROM (SELECT p.*,w.balance,EXISTS(SELECT 1 FROM public.ct_suspensions s WHERE s.user_id=p.id) suspended
 FROM public.ct_profiles p JOIN public.ct_wallets w ON w.user_id=p.id WHERE position(lower(left(coalesce(p_search,''),50)) in lower(p.username))>0 ORDER BY p.created_at DESC LIMIT 25) p),'[]'::jsonb),
 'audit',coalesce((SELECT jsonb_agg(to_jsonb(a)) FROM(SELECT * FROM public.ct_admin_audit_logs ORDER BY created_at DESC LIMIT 30)a),'[]'::jsonb));
END $$;
COMMIT;
