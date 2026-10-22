-- Regenerate with scripts/active-titles.mjs.
BEGIN;
ALTER TABLE public.ct_wallet_transactions ALTER COLUMN balance_after SET NOT NULL;
ALTER TABLE public.ct_wallet_transactions ALTER COLUMN wallet_version SET NOT NULL;
ALTER TABLE public.ct_wallet_transactions ADD CONSTRAINT ct_ledger_valid_balance CHECK(balance_after BETWEEN 0 AND 9000000000000 AND wallet_version>=0);
ALTER TABLE public.ct_wallet_transactions ADD CONSTRAINT ct_ledger_one_version UNIQUE(user_id,wallet_version);
CREATE OR REPLACE FUNCTION public.ct_public_profile(p_user_id uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('id',p.id,'username',p.username,'avatar',p.avatar,'created_at',p.created_at,
 'equipped_title',(SELECT to_jsonb(t) FROM public.ct_equipped_titles e JOIN public.ct_player_titles i ON i.id=e.player_title_id
 JOIN public.ct_titles t ON t.id=i.title_id WHERE e.user_id=p.id),
 'unique_titles',(SELECT count(DISTINCT title_id) FROM public.ct_player_titles WHERE user_id=p.id AND revoked_at IS NULL))
 FROM public.ct_profiles p WHERE p.id=p_user_id;
$$;
CREATE OR REPLACE FUNCTION public.ct_quest_progress(p_uid uuid,p_kind text) RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT CASE p_kind WHEN 'profile' THEN(SELECT count(*) FROM public.ct_profiles WHERE id=p_uid)
 WHEN 'titles' THEN(SELECT count(DISTINCT title_id) FROM public.ct_player_titles WHERE user_id=p_uid AND revoked_at IS NULL)
 WHEN 'chests' THEN(SELECT count(*) FROM public.ct_chest_openings WHERE user_id=p_uid)
 WHEN 'games' THEN(SELECT count(*) FROM public.ct_game_rounds WHERE user_id=p_uid AND status='settled')
 WHEN 'variety' THEN(SELECT count(DISTINCT game) FROM public.ct_game_rounds WHERE user_id=p_uid AND status='settled')
 WHEN 'card_win' THEN(SELECT count(*) FROM public.ct_game_rounds WHERE user_id=p_uid AND game IN('blackjack','baccarat') AND status='settled' AND payout>bet) ELSE 0 END;
$$;
CREATE OR REPLACE FUNCTION public.ct_rankings(p_metric text DEFAULT 'credits',p_period text DEFAULT 'all') RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_since timestamptz;v_result jsonb;
BEGIN
 IF p_metric IS NULL OR p_metric NOT IN('credits','wins','titles','chests','cosmic') OR p_period IS NULL OR p_period NOT IN('all','week') THEN RAISE EXCEPTION 'Invalid ranking';END IF;
 v_since:=CASE WHEN p_period='week' THEN date_trunc('week',now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' ELSE '-infinity'::timestamptz END;
 SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.score DESC,r.username,r.id),'[]'::jsonb) INTO v_result FROM(
 SELECT p.id,p.username,p.avatar,(public.ct_public_profile(p.id))->'equipped_title' equipped_title,
 CASE p_metric WHEN 'credits' THEN CASE WHEN p_period='all' THEN w.balance ELSE
  (SELECT coalesce(sum(amount),0) FROM public.ct_wallet_transactions WHERE user_id=p.id AND created_at>=v_since) END
 WHEN 'wins' THEN(SELECT count(*) FROM public.ct_game_rounds WHERE user_id=p.id AND status='settled' AND payout>bet AND updated_at>=v_since)
 WHEN 'titles' THEN(SELECT count(DISTINCT title_id) FROM public.ct_player_titles WHERE user_id=p.id AND revoked_at IS NULL AND acquired_at>=v_since)
 WHEN 'chests' THEN(SELECT count(*) FROM public.ct_chest_openings WHERE user_id=p.id AND created_at>=v_since)
 ELSE(SELECT count(*) FROM public.ct_player_titles i JOIN public.ct_titles t ON t.id=i.title_id WHERE i.user_id=p.id AND i.revoked_at IS NULL AND t.rarity=8 AND i.acquired_at>=v_since) END score
 FROM public.ct_profiles p JOIN public.ct_wallets w ON w.user_id=p.id
 WHERE NOT EXISTS(SELECT 1 FROM public.ct_suspensions s WHERE s.user_id=p.id)
 ORDER BY score DESC,p.username,p.id LIMIT 50) r;
 RETURN v_result;
END $$;
COMMIT;
