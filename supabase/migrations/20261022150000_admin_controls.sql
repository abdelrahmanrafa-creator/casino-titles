BEGIN;
ALTER TABLE public.ct_quests ADD COLUMN active boolean NOT NULL DEFAULT true;
CREATE TABLE public.ct_game_controls(game text PRIMARY KEY CHECK(game IN('blackjack','coinflip','roulette','baccarat','slots','poker','chromatic')),active boolean NOT NULL DEFAULT true,min_bet bigint NOT NULL,max_bet bigint NOT NULL,
 CHECK(min_bet>0 AND max_bet>=min_bet AND max_bet<=1000000),
 CHECK((game IN('poker','chromatic') AND min_bet>=100 AND max_bet<=100000 AND min_bet%100=0 AND max_bet%100=0) OR(game NOT IN('poker','chromatic') AND min_bet>=20 AND min_bet%20=0 AND max_bet%20=0)));
INSERT INTO public.ct_game_controls SELECT game,true,20,1000000 FROM unnest(ARRAY['blackjack','coinflip','roulette','baccarat','slots'])game;
INSERT INTO public.ct_game_controls VALUES('poker',true,100,100000),('chromatic',true,100,100000);
ALTER TABLE public.ct_game_controls ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ct_game_controls FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.ct_game_controls TO anon,authenticated;
CREATE POLICY ct_public_game_controls ON public.ct_game_controls FOR SELECT USING(true);
CREATE FUNCTION public.ct_admin_game_control(p_operation_id uuid,p_game text,p_active boolean,p_min_bet bigint,p_max_bet bigint,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid:=auth.uid();v_request jsonb:=jsonb_build_object('kind','game_control','game',p_game,'active',p_active,'min',p_min_bet,'max',p_max_bet,'reason',p_reason);v_result jsonb;
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator unlock required' USING ERRCODE='42501';END IF;
 IF p_reason IS NULL OR length(trim(p_reason))<8 THEN RAISE EXCEPTION 'Justification required';END IF;
 PERFORM pg_advisory_xact_lock(173,2);v_result:=public.ct_replay(v_uid,p_operation_id,v_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 UPDATE public.ct_game_controls SET active=p_active,min_bet=p_min_bet,max_bet=p_max_bet WHERE game=p_game;IF NOT FOUND THEN RAISE EXCEPTION 'Unknown game';END IF;
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(v_uid,'game_control',p_game,p_reason,jsonb_build_object('active',p_active,'min_bet',p_min_bet,'max_bet',p_max_bet));
 v_result:='{"ok":true}'::jsonb;INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(v_uid,p_operation_id,v_request,v_result);RETURN v_result;
END $$;
CREATE FUNCTION public.ct_admin_save_quest(p_operation_id uuid,p_values jsonb,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid:=auth.uid();v_request jsonb:=jsonb_build_object('kind','save_quest','values',p_values,'reason',p_reason);v_result jsonb;v_id text:=p_values->>'id';
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator unlock required' USING ERRCODE='42501';END IF;
 IF p_reason IS NULL OR length(trim(p_reason))<8 THEN RAISE EXCEPTION 'Justification required';END IF;
 IF v_id IS NULL OR v_id!~'^[a-zA-Z0-9_-]{1,80}$' OR p_values->>'kind' NOT IN('profile','games','chests','titles','variety','card_win') OR (p_values->>'reward')::bigint NOT BETWEEN 1 AND 100000 OR length(trim(coalesce(p_values->>'name','')))<2 THEN RAISE EXCEPTION 'Invalid quest';END IF;
 PERFORM pg_advisory_xact_lock(173,2);v_result:=public.ct_replay(v_uid,p_operation_id,v_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 INSERT INTO public.ct_quests(id,name,description,kind,target,reward,active) VALUES(v_id,p_values->>'name',p_values->>'description',p_values->>'kind',(p_values->>'target')::integer,(p_values->>'reward')::bigint,coalesce((p_values->>'active')::boolean,true))
 ON CONFLICT(id) DO UPDATE SET name=EXCLUDED.name,description=EXCLUDED.description,kind=EXCLUDED.kind,target=EXCLUDED.target,reward=EXCLUDED.reward,active=EXCLUDED.active;
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(v_uid,'save_quest',v_id,p_reason,p_values);
 v_result:='{"ok":true}'::jsonb;INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(v_uid,p_operation_id,v_request,v_result);RETURN v_result;
END $$;
CREATE FUNCTION public.ct_admin_audit(p_cursor timestamptz DEFAULT NULL,p_cursor_id uuid DEFAULT NULL,p_search text DEFAULT '') RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_result jsonb;
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator unlock required' USING ERRCODE='42501';END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC,x.id DESC),'[]'::jsonb) INTO v_result FROM(
 SELECT a.*,p.username admin_name FROM public.ct_admin_audit_logs a JOIN public.ct_profiles p ON p.id=a.admin_id
 WHERE (p_cursor IS NULL OR (a.created_at,a.id)<(p_cursor,p_cursor_id)) AND position(lower(left(coalesce(p_search,''),100)) IN lower(a.action||' '||a.target||' '||a.reason||' '||p.username))>0
 ORDER BY a.created_at DESC,a.id DESC LIMIT 50)x;
 RETURN v_result;
END $$;
ALTER FUNCTION public.ct_admin_dashboard() RENAME TO ct_admin_dashboard_v1;
REVOKE ALL ON FUNCTION public.ct_admin_dashboard_v1() FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_admin_dashboard() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT public.ct_admin_dashboard_v1()||jsonb_build_object('controls',(SELECT jsonb_agg(to_jsonb(c) ORDER BY game) FROM public.ct_game_controls c),'rarities',(SELECT jsonb_agg(to_jsonb(r) ORDER BY id) FROM public.ct_rarities r));
$$;
ALTER FUNCTION public.ct_play_game(uuid,text,bigint,jsonb) RENAME TO ct_play_game_v1;
REVOKE ALL ON FUNCTION public.ct_play_game_v1(uuid,text,bigint,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_play_game(p_operation_id uuid,p_game text,p_bet bigint,p_choice jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid;v_result jsonb;
BEGIN
 v_uid:=public.ct_lock_wallet();v_result:=public.ct_replay(v_uid,p_operation_id,jsonb_build_object('kind','game','game',p_game,'bet',p_bet,'choice',p_choice));IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 IF NOT EXISTS(SELECT 1 FROM public.ct_game_controls WHERE game=p_game AND active AND p_bet BETWEEN min_bet AND max_bet) THEN RAISE EXCEPTION 'Game paused or stake outside configured limits';END IF;
 RETURN public.ct_play_game_v1(p_operation_id,p_game,p_bet,p_choice);
END $$;
ALTER FUNCTION public.ct_blackjack_start(uuid,bigint,jsonb) RENAME TO ct_blackjack_start_v2;
REVOKE ALL ON FUNCTION public.ct_blackjack_start_v2(uuid,bigint,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_blackjack_start(p_operation_id uuid,p_bet bigint,p_expected_rules jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid;v_result jsonb;
BEGIN
 v_uid:=public.ct_lock_wallet();v_result:=public.ct_replay(v_uid,p_operation_id,jsonb_build_object('kind','blackjack_start','bet',p_bet));IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 IF NOT EXISTS(SELECT 1 FROM public.ct_game_controls WHERE game='blackjack' AND active AND p_bet BETWEEN min_bet AND max_bet) THEN RAISE EXCEPTION 'Blackjack paused or stake outside configured limits';END IF;
 RETURN public.ct_blackjack_start_v2(p_operation_id,p_bet,p_expected_rules);
END $$;
ALTER FUNCTION public.ct_create_room(uuid,uuid,jsonb,text,text,boolean,bigint,jsonb) RENAME TO ct_create_room_v1;
REVOKE ALL ON FUNCTION public.ct_create_room_v1(uuid,uuid,jsonb,text,text,boolean,bigint,jsonb) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.ct_create_room(p_user_id uuid,p_operation_id uuid,p_request jsonb,p_game text,p_code text,p_private boolean,p_buy_in bigint,p_state jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_result jsonb;
BEGIN
 v_result:=public.ct_replay(p_user_id,p_operation_id,p_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 IF NOT EXISTS(SELECT 1 FROM public.ct_game_controls WHERE game=p_game AND active AND p_buy_in BETWEEN min_bet AND max_bet) THEN RAISE EXCEPTION 'Table game paused or buy-in outside configured limits';END IF;
 RETURN public.ct_create_room_v1(p_user_id,p_operation_id,p_request,p_game,p_code,p_private,p_buy_in,p_state);
END $$;
ALTER FUNCTION public.ct_commit_room(uuid,uuid,jsonb,uuid,bigint,jsonb,text) RENAME TO ct_commit_room_v1;
REVOKE ALL ON FUNCTION public.ct_commit_room_v1(uuid,uuid,jsonb,uuid,bigint,jsonb,text) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.ct_commit_room(p_user_id uuid,p_operation_id uuid,p_request jsonb,p_room_id uuid,p_expected_version bigint,p_state jsonb,p_command text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_result jsonb;
BEGIN
 v_result:=public.ct_replay(p_user_id,p_operation_id,p_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 IF p_command='join' AND NOT EXISTS(SELECT 1 FROM public.ct_rooms r JOIN public.ct_game_controls c ON c.game=r.game WHERE r.id=p_room_id AND c.active AND r.buy_in BETWEEN c.min_bet AND c.max_bet) THEN RAISE EXCEPTION 'Table game paused or buy-in outside configured limits';END IF;
 RETURN public.ct_commit_room_v1(p_user_id,p_operation_id,p_request,p_room_id,p_expected_version,p_state,p_command);
END $$;
CREATE OR REPLACE FUNCTION public.ct_my_quests() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(to_jsonb(q)||jsonb_build_object('progress',public.ct_quest_progress(auth.uid(),q.kind),'claimed',EXISTS(SELECT 1 FROM public.ct_quest_claims WHERE user_id=auth.uid() AND quest_id=q.id)) ORDER BY q.reward),'[]'::jsonb) FROM public.ct_quests q WHERE active;
$$;
ALTER FUNCTION public.ct_claim_quest(uuid,text) RENAME TO ct_claim_quest_v1;
REVOKE ALL ON FUNCTION public.ct_claim_quest_v1(uuid,text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_claim_quest(p_operation_id uuid,p_quest_id text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid;v_result jsonb;
BEGIN
 v_uid:=public.ct_lock_wallet();v_result:=public.ct_replay(v_uid,p_operation_id,jsonb_build_object('kind','quest','quest_id',p_quest_id));IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 IF NOT EXISTS(SELECT 1 FROM public.ct_quests WHERE id=p_quest_id AND active) THEN RAISE EXCEPTION 'Mission inactive';END IF;
 RETURN public.ct_claim_quest_v1(p_operation_id,p_quest_id);
END $$;
REVOKE ALL ON FUNCTION public.ct_claim_quest(uuid,text),public.ct_admin_dashboard(),public.ct_admin_game_control(uuid,text,boolean,bigint,bigint,text),public.ct_admin_save_quest(uuid,jsonb,text),public.ct_admin_audit(timestamptz,uuid,text),public.ct_play_game(uuid,text,bigint,jsonb),public.ct_blackjack_start(uuid,bigint,jsonb),public.ct_create_room(uuid,uuid,jsonb,text,text,boolean,bigint,jsonb),public.ct_commit_room(uuid,uuid,jsonb,uuid,bigint,jsonb,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_claim_quest(uuid,text),public.ct_admin_dashboard(),public.ct_admin_game_control(uuid,text,boolean,bigint,bigint,text),public.ct_admin_save_quest(uuid,jsonb,text),public.ct_admin_audit(timestamptz,uuid,text),public.ct_play_game(uuid,text,bigint,jsonb),public.ct_blackjack_start(uuid,bigint,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ct_create_room(uuid,uuid,jsonb,text,text,boolean,bigint,jsonb),public.ct_commit_room(uuid,uuid,jsonb,uuid,bigint,jsonb,text) TO service_role;
COMMIT;
