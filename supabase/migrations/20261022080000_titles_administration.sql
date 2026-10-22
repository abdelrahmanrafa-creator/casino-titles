BEGIN;
CREATE TABLE public.ct_admins(user_id uuid PRIMARY KEY REFERENCES public.ct_profiles(id) ON DELETE CASCADE);
CREATE TABLE public.ct_suspensions(user_id uuid PRIMARY KEY REFERENCES public.ct_profiles(id) ON DELETE CASCADE,reason text NOT NULL,created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.ct_admin_audit_logs(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),admin_id uuid NOT NULL REFERENCES public.ct_profiles(id),action text NOT NULL,target text NOT NULL,reason text NOT NULL,details jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.ct_admins ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ct_suspensions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ct_admin_audit_logs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ct_admins,public.ct_suspensions,public.ct_admin_audit_logs FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.ct_suspensions TO service_role;
CREATE FUNCTION public.ct_is_admin() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM public.ct_admins WHERE user_id=auth.uid());
$$;
CREATE OR REPLACE FUNCTION public.ct_lock_wallet() RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid:=auth.uid();
BEGIN
 IF v_uid IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501';END IF;
 PERFORM 1 FROM public.ct_wallets WHERE user_id=v_uid FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Profile required';END IF;
 IF EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=v_uid) THEN RAISE EXCEPTION 'Account suspended' USING ERRCODE='42501';END IF;
 RETURN v_uid;
END $$;
CREATE FUNCTION public.ct_admin_overview(p_search text DEFAULT '') RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 RETURN jsonb_build_object('players',(SELECT count(*) FROM public.ct_profiles),'credits',(SELECT coalesce(sum(balance),0) FROM public.ct_wallets),
 'rounds',(SELECT count(*) FROM public.ct_game_rounds),'chests',(SELECT count(*) FROM public.ct_chest_openings),
 'results',coalesce((SELECT jsonb_agg(to_jsonb(p)) FROM (SELECT p.*,w.balance,EXISTS(SELECT 1 FROM public.ct_suspensions s WHERE s.user_id=p.id) suspended
 FROM public.ct_profiles p JOIN public.ct_wallets w ON w.user_id=p.id WHERE position(lower(left(coalesce(p_search,''),50)) in lower(p.username))>0 ORDER BY p.created_at DESC LIMIT 25) p),'[]'::jsonb),
 'audit',coalesce((SELECT jsonb_agg(to_jsonb(a)) FROM(SELECT * FROM public.ct_admin_audit_logs ORDER BY created_at DESC LIMIT 30)a),'[]'::jsonb));
END $$;
CREATE FUNCTION public.ct_admin_command(p_operation_id uuid,p_action text,p_target text,p_value jsonb,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid:=auth.uid();v_request jsonb:=jsonb_build_object('kind','admin','action',p_action,'target',p_target,'value',p_value,'reason',p_reason);
 v_result jsonb;v_target uuid;v_amount bigint;
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(v_uid::text||p_operation_id::text,93));
 v_result:=public.ct_replay(v_uid,p_operation_id,v_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 IF p_reason IS NULL OR length(trim(p_reason)) NOT BETWEEN 8 AND 1000 THEN RAISE EXCEPTION 'Justification required (8-1000 characters)';END IF;
 IF p_action IN('credit','grant_title','revoke_title','suspend','unsuspend') THEN
  v_target:=p_target::uuid;PERFORM 1 FROM public.ct_wallets WHERE user_id=v_target FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Player not found';END IF;
  IF p_action='credit' THEN v_amount:=(p_value->>'amount')::bigint;
   IF v_amount IS NULL OR v_amount=0 OR abs(v_amount::numeric)>10000000 THEN RAISE EXCEPTION 'Invalid adjustment';END IF;
   v_result:=public.ct_post_credit(v_target,v_amount,'admin','admin:'||p_operation_id::text);
  ELSIF p_action='grant_title' THEN
   INSERT INTO public.ct_player_titles(user_id,title_id,source) VALUES(v_target,p_value->>'title_id','admin');
  ELSIF p_action='revoke_title' THEN
   DELETE FROM public.ct_player_titles WHERE id=(p_value->>'instance_id')::uuid AND user_id=v_target;
   IF NOT FOUND THEN RAISE EXCEPTION 'Owned title not found';END IF;
  ELSIF p_action='suspend' THEN INSERT INTO public.ct_suspensions(user_id,reason) VALUES(v_target,p_reason) ON CONFLICT(user_id) DO UPDATE SET reason=EXCLUDED.reason;
  ELSE DELETE FROM public.ct_suspensions WHERE user_id=v_target;END IF;
 ELSIF p_action='title_price' THEN
  UPDATE public.ct_titles SET shop_price=(p_value->>'price')::bigint WHERE id=p_target;
  IF NOT FOUND THEN RAISE EXCEPTION 'Title not found';END IF;
 ELSIF p_action='chest_config' THEN
  UPDATE public.ct_chest_types SET price=(p_value->>'price')::bigint,weights=ARRAY(SELECT value::integer FROM jsonb_array_elements_text(p_value->'weights')),
  active=(p_value->>'active')::boolean WHERE id=p_target::smallint;
  IF NOT FOUND THEN RAISE EXCEPTION 'Chest not found';END IF;
 ELSE RAISE EXCEPTION 'Unsupported administrative command';END IF;
 v_result:=coalesce(v_result,'{}'::jsonb)||jsonb_build_object('ok',true);
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(v_uid,p_action,p_target,p_reason,p_value);
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(v_uid,p_operation_id,v_request,v_result);RETURN v_result;
END $$;
CREATE FUNCTION public.ct_rankings(p_metric text DEFAULT 'credits',p_period text DEFAULT 'all') RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_since timestamptz;v_result jsonb;
BEGIN
 IF p_metric IS NULL OR p_metric NOT IN('credits','wins','titles','chests','cosmic') OR p_period IS NULL OR p_period NOT IN('all','week') THEN RAISE EXCEPTION 'Invalid ranking';END IF;
 v_since:=CASE WHEN p_period='week' THEN date_trunc('week',now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' ELSE '-infinity'::timestamptz END;
 SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.score DESC,r.username,r.id),'[]'::jsonb) INTO v_result FROM(
 SELECT p.id,p.username,p.avatar,(public.ct_public_profile(p.id))->'equipped_title' equipped_title,
 CASE p_metric WHEN 'credits' THEN CASE WHEN p_period='all' THEN w.balance ELSE
  (SELECT coalesce(sum(amount),0) FROM public.ct_wallet_transactions WHERE user_id=p.id AND created_at>=v_since) END
 WHEN 'wins' THEN(SELECT count(*) FROM public.ct_game_rounds WHERE user_id=p.id AND status='settled' AND payout>bet AND updated_at>=v_since)
 WHEN 'titles' THEN(SELECT count(DISTINCT title_id) FROM public.ct_player_titles WHERE user_id=p.id AND acquired_at>=v_since)
 WHEN 'chests' THEN(SELECT count(*) FROM public.ct_chest_openings WHERE user_id=p.id AND created_at>=v_since)
 ELSE(SELECT count(*) FROM public.ct_player_titles i JOIN public.ct_titles t ON t.id=i.title_id WHERE i.user_id=p.id AND t.rarity=8 AND i.acquired_at>=v_since) END score
 FROM public.ct_profiles p JOIN public.ct_wallets w ON w.user_id=p.id
 WHERE NOT EXISTS(SELECT 1 FROM public.ct_suspensions s WHERE s.user_id=p.id)
 ORDER BY score DESC,p.username,p.id LIMIT 50) r;
 RETURN v_result;
END $$;
-- Additional missions are evaluated only against server-recorded rounds.
INSERT INTO public.ct_quests VALUES('three_games','Le rythme du cercle','Terminez trois parties.','games',3,500),('variety','À toutes les tables','Jouez à trois jeux différents.','variety',3,750),('card_win','La main heureuse','Gagnez au Blackjack ou au Baccarat.','card_win',1,500);
CREATE OR REPLACE FUNCTION public.ct_quest_progress(p_uid uuid,p_kind text) RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT CASE p_kind WHEN 'profile' THEN(SELECT count(*) FROM public.ct_profiles WHERE id=p_uid)
 WHEN 'titles' THEN(SELECT count(DISTINCT title_id) FROM public.ct_player_titles WHERE user_id=p_uid)
 WHEN 'chests' THEN(SELECT count(*) FROM public.ct_chest_openings WHERE user_id=p_uid)
 WHEN 'games' THEN(SELECT count(*) FROM public.ct_game_rounds WHERE user_id=p_uid AND status='settled')
 WHEN 'variety' THEN(SELECT count(DISTINCT game) FROM public.ct_game_rounds WHERE user_id=p_uid AND status='settled')
 WHEN 'card_win' THEN(SELECT count(*) FROM public.ct_game_rounds WHERE user_id=p_uid AND game IN('blackjack','baccarat') AND status='settled' AND payout>bet) ELSE 0 END;
$$;
REVOKE ALL ON FUNCTION public.ct_is_admin(),public.ct_admin_overview(text),public.ct_admin_command(uuid,text,text,jsonb,text),public.ct_rankings(text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_is_admin(),public.ct_admin_overview(text),public.ct_admin_command(uuid,text,text,jsonb,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ct_rankings(text,text) TO anon,authenticated;
COMMIT;
