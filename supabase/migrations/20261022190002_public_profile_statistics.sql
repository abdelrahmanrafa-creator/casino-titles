BEGIN;
CREATE OR REPLACE FUNCTION public.ct_title_statistics() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 WITH population AS (SELECT p.id,p.is_bot FROM public.ct_profiles p WHERE NOT EXISTS(SELECT 1 FROM public.ct_suspensions s WHERE s.user_id=p.id) AND (NOT p.is_bot OR EXISTS(SELECT 1 FROM public.ct_bots b WHERE b.user_id=p.id AND b.active))), totals AS(SELECT count(*) n FROM population), counts AS(SELECT i.title_id,count(*) copies,count(DISTINCT i.user_id) owners,count(DISTINCT i.user_id) FILTER(WHERE p.is_bot) bots FROM public.ct_player_titles i JOIN population p ON p.id=i.user_id WHERE i.revoked_at IS NULL GROUP BY i.title_id)
 SELECT coalesce(jsonb_agg(jsonb_build_object('title_id',t.id,'copies',coalesce(c.copies,0),'owners',coalesce(c.owners,0),'population',n,'percentage',CASE WHEN n=0 THEN 0 ELSE coalesce(c.owners,0)*100.0/n END) ORDER BY t.id),'[]'::jsonb) FROM public.ct_titles t CROSS JOIN totals LEFT JOIN counts c ON c.title_id=t.id;
$$;
CREATE OR REPLACE FUNCTION public.ct_public_collection(p_user_id uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(item || jsonb_build_object('owners',stat->'owners','global_copies',stat->'copies','population',stat->'population','percentage',stat->'percentage') ORDER BY (item->>'rarity')::int DESC,item->>'name'),'[]'::jsonb)
 FROM jsonb_array_elements(public.ct_public_collection_before_bots(p_user_id)) item JOIN jsonb_array_elements(public.ct_title_statistics()) stat ON stat->>'title_id'=item->>'id'
 WHERE EXISTS(SELECT 1 FROM public.ct_profiles p WHERE p.id=p_user_id AND(NOT p.is_bot OR EXISTS(SELECT 1 FROM public.ct_bots b WHERE b.user_id=p.id AND b.active)));
$$;
CREATE FUNCTION public.ct_public_profile_details(p_user_id uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_profile jsonb;v_stats jsonb;v_positions jsonb;v_hidden boolean;
BEGIN
 IF EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=p_user_id) THEN RETURN NULL;END IF;
 v_profile:=public.ct_public_profile(p_user_id);IF v_profile IS NULL THEN RETURN NULL;END IF;
 WITH rounds AS(SELECT payout,CASE WHEN game='blackjack' AND jsonb_typeof(state->'hands')='array' THEN coalesce((SELECT sum((h->>'bet')::bigint) FROM jsonb_array_elements(state->'hands') h),bet) ELSE bet END stake FROM public.ct_game_rounds WHERE user_id=p_user_id AND status='settled')
 SELECT jsonb_build_object('games',count(*),'wins',count(*) FILTER(WHERE payout>stake),'losses',count(*) FILTER(WHERE payout<stake),'draws',count(*) FILTER(WHERE payout=stake),'wagered',coalesce(sum(stake),0),'returned',coalesce(sum(payout),0),'net',coalesce(sum(payout-stake),0),'gains',coalesce(sum(greatest(payout-stake,0)),0),'loss_amount',coalesce(sum(greatest(stake-payout,0)),0),'biggest_bet',coalesce(max(stake),0),'biggest_win',coalesce(max(greatest(payout-stake,0)),0),'win_percent',CASE WHEN count(*)=0 THEN NULL ELSE count(*) FILTER(WHERE payout>stake)*100.0/count(*) END,'win_loss_ratio',count(*) FILTER(WHERE payout>stake)::numeric/nullif(count(*) FILTER(WHERE payout<stake),0),'return_percent',sum(payout)*100.0/nullif(sum(stake),0)) INTO v_stats FROM rounds;
 SELECT coalesce((SELECT leaderboard_hidden FROM public.ct_preferences WHERE user_id=p_user_id),false) INTO v_hidden;
 IF v_hidden THEN v_positions:='[]'::jsonb;ELSE
 SELECT coalesce(jsonb_agg(jsonb_build_object('metric',metric,'period',period,'rank',r.ordinality) ORDER BY r.ordinality,metric,period),'[]'::jsonb) INTO v_positions FROM unnest(ARRAY['credits','wins','titles','chests','cosmic']) metric CROSS JOIN unnest(ARRAY['all','week']) period CROSS JOIN LATERAL jsonb_array_elements(public.ct_rankings(metric,period)) WITH ORDINALITY r(item,ordinality) WHERE r.item->>'id'=p_user_id::text;
 END IF;
 RETURN v_profile || jsonb_build_object('balance',(SELECT balance FROM public.ct_wallets WHERE user_id=p_user_id),'statistics',v_stats,'positions',v_positions,'leaderboard_hidden',v_hidden,'chest_spending',(SELECT coalesce(sum(price_paid),0) FROM public.ct_chest_openings WHERE user_id=p_user_id),'title_copies',(SELECT count(*) FROM public.ct_player_titles WHERE user_id=p_user_id AND revoked_at IS NULL));
END $$;
REVOKE ALL ON FUNCTION public.ct_public_profile_details(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_public_profile_details(uuid) TO anon,authenticated;

-- Simulation flags are administrative information, including direct table access.
REVOKE SELECT ON public.ct_profiles FROM anon,authenticated;
GRANT SELECT(id,username,avatar,created_at) ON public.ct_profiles TO anon,authenticated;
ALTER FUNCTION public.ct_public_profile(uuid) RENAME TO ct_public_profile_internal;
REVOKE ALL ON FUNCTION public.ct_public_profile_internal(uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_public_profile(p_user_id uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$ SELECT public.ct_public_profile_internal(p_user_id)-'is_bot'-'bot_balance' $$;
REVOKE ALL ON FUNCTION public.ct_public_profile(uuid) FROM PUBLIC;GRANT EXECUTE ON FUNCTION public.ct_public_profile(uuid) TO anon,authenticated;
ALTER FUNCTION public.ct_find_players(text) RENAME TO ct_find_players_internal;
REVOKE ALL ON FUNCTION public.ct_find_players_internal(text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_find_players(p_search text) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$ SELECT coalesce(jsonb_agg(x-'is_bot'),'[]'::jsonb) FROM jsonb_array_elements(public.ct_find_players_internal(p_search)) x $$;
REVOKE ALL ON FUNCTION public.ct_find_players(text) FROM PUBLIC;GRANT EXECUTE ON FUNCTION public.ct_find_players(text) TO anon,authenticated;
ALTER FUNCTION public.ct_rankings(text,text) RENAME TO ct_rankings_internal;
REVOKE ALL ON FUNCTION public.ct_rankings_internal(text,text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_rankings(p_metric text DEFAULT 'credits',p_period text DEFAULT 'all') RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$ SELECT coalesce(jsonb_agg(x-'is_bot'),'[]'::jsonb) FROM jsonb_array_elements(public.ct_rankings_internal(p_metric,p_period)) x $$;
REVOKE ALL ON FUNCTION public.ct_rankings(text,text) FROM PUBLIC;GRANT EXECUTE ON FUNCTION public.ct_rankings(text,text) TO anon,authenticated;
COMMIT;
