BEGIN;
ALTER TABLE public.ct_preferences ADD COLUMN leaderboard_hidden boolean NOT NULL DEFAULT false;
CREATE FUNCTION public.ct_set_leaderboard_visibility(p_hidden boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid;
BEGIN v_uid:=public.ct_lock_wallet();IF p_hidden IS NULL THEN RAISE EXCEPTION 'Visibility required';END IF;
 INSERT INTO public.ct_preferences(user_id,leaderboard_hidden) VALUES(v_uid,p_hidden) ON CONFLICT(user_id) DO UPDATE SET leaderboard_hidden=EXCLUDED.leaderboard_hidden,updated_at=now();END $$;
REVOKE ALL ON FUNCTION public.ct_set_leaderboard_visibility(boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_set_leaderboard_visibility(boolean) TO authenticated;
CREATE OR REPLACE FUNCTION public.ct_rankings(p_metric text DEFAULT 'credits',p_period text DEFAULT 'all') RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_since timestamptz;v_result jsonb;
BEGIN
 IF p_metric IS NULL OR p_metric NOT IN('credits','wins','titles','chests','cosmic') OR p_period IS NULL OR p_period NOT IN('all','week') THEN RAISE EXCEPTION 'Invalid ranking';END IF;
 v_since:=CASE WHEN p_period='week' THEN date_trunc('week',now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' ELSE '-infinity'::timestamptz END;
 SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.score DESC,r.username,r.id),'[]'::jsonb) INTO v_result FROM(
 SELECT p.id,p.username,p.avatar,(public.ct_public_profile(p.id))->'equipped_title' equipped_title,
 CASE p_metric WHEN 'credits' THEN CASE WHEN p_period='all' THEN w.balance ELSE
 (SELECT coalesce(sum(amount),0) FROM public.ct_wallet_transactions t WHERE t.user_id=p.id AND t.created_at>=v_since) END
 WHEN 'wins' THEN(SELECT count(*) FROM public.ct_game_rounds WHERE user_id=p.id AND status='settled' AND payout>bet AND updated_at>=v_since)
 WHEN 'titles' THEN(SELECT count(DISTINCT title_id) FROM public.ct_player_titles WHERE user_id=p.id AND revoked_at IS NULL AND acquired_at>=v_since)
 WHEN 'chests' THEN(SELECT count(*) FROM public.ct_chest_openings WHERE user_id=p.id AND created_at>=v_since)
 ELSE(SELECT count(*) FROM public.ct_player_titles i JOIN public.ct_titles t ON t.id=i.title_id WHERE i.user_id=p.id AND i.revoked_at IS NULL AND t.rarity=8 AND i.acquired_at>=v_since) END score
 FROM public.ct_profiles p JOIN public.ct_wallets w ON w.user_id=p.id
 WHERE NOT EXISTS(SELECT 1 FROM public.ct_suspensions s WHERE s.user_id=p.id)
 AND NOT EXISTS(SELECT 1 FROM public.ct_preferences pref WHERE pref.user_id=p.id AND pref.leaderboard_hidden)
 ORDER BY score DESC,p.username,p.id LIMIT 50)r;RETURN v_result;
END $$;

-- One counter-entry for EVERY wallet ledger insert, including welcome grants and escrow.
LOCK TABLE public.ct_wallet_transactions IN SHARE ROW EXCLUSIVE MODE;
CREATE TABLE public.ct_treasury(id boolean PRIMARY KEY DEFAULT true CHECK(id),initial_capital bigint NOT NULL DEFAULT 100000000 CHECK(initial_capital=100000000),created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.ct_treasury_entries(id bigserial PRIMARY KEY,wallet_transaction_id uuid UNIQUE REFERENCES public.ct_wallet_transactions(id) ON DELETE SET NULL,user_id uuid NOT NULL,amount bigint NOT NULL CHECK(amount<>0),reason text NOT NULL,created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX ct_treasury_timeline ON public.ct_treasury_entries(created_at DESC,id DESC);
CREATE INDEX ct_treasury_reason ON public.ct_treasury_entries(reason,id DESC);
ALTER TABLE public.ct_treasury ENABLE ROW LEVEL SECURITY;ALTER TABLE public.ct_treasury_entries ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ct_treasury,public.ct_treasury_entries FROM PUBLIC,anon,authenticated;
REVOKE ALL ON SEQUENCE public.ct_treasury_entries_id_seq FROM PUBLIC,anon,authenticated;
INSERT INTO public.ct_treasury(id) VALUES(true);
INSERT INTO public.ct_treasury_entries(wallet_transaction_id,user_id,amount,reason,created_at)
 SELECT id,user_id,-amount,reason,created_at FROM public.ct_wallet_transactions ORDER BY created_at,id;
CREATE FUNCTION public.ct_mirror_treasury() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 INSERT INTO public.ct_treasury_entries(wallet_transaction_id,user_id,amount,reason,created_at) VALUES(NEW.id,NEW.user_id,-NEW.amount,NEW.reason,NEW.created_at);
 RETURN NEW;
END $$;
CREATE TRIGGER ct_wallet_treasury AFTER INSERT ON public.ct_wallet_transactions FOR EACH ROW EXECUTE FUNCTION public.ct_mirror_treasury();
-- Account deletion returns its remaining credits; retained treasury history survives cascade cleanup.
CREATE FUNCTION public.ct_close_wallet_treasury() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF OLD.balance>0 THEN
 INSERT INTO public.ct_treasury_entries(user_id,amount,reason) VALUES(OLD.user_id,OLD.balance,'account_closed');
 END IF;RETURN OLD;
END $$;
CREATE TRIGGER ct_wallet_close_treasury BEFORE DELETE ON public.ct_wallets FOR EACH ROW EXECUTE FUNCTION public.ct_close_wallet_treasury();
REVOKE ALL ON FUNCTION public.ct_mirror_treasury(),public.ct_close_wallet_treasury() FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_admin_economy(p_days integer DEFAULT 30,p_before bigint DEFAULT NULL,p_reason text DEFAULT '') RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_capital bigint;v_treasury bigint;v_wallets bigint;v_reserved bigint;v_since timestamptz;v_rows jsonb;v_groups jsonb;v_daily jsonb;
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 IF p_days IS NULL OR p_days NOT IN(7,30,90) OR length(coalesce(p_reason,''))>80 THEN RAISE EXCEPTION 'Invalid filters';END IF;
 v_since:=((now() AT TIME ZONE 'UTC')::date-(p_days-1))::timestamp AT TIME ZONE 'UTC';
 SELECT initial_capital INTO v_capital FROM public.ct_treasury WHERE id;
 SELECT v_capital+coalesce(sum(amount),0) INTO v_treasury FROM public.ct_treasury_entries;
 SELECT coalesce(sum(balance),0) INTO v_wallets FROM public.ct_wallets;
 SELECT coalesce(sum(buy_in),0) INTO v_reserved FROM public.ct_room_members WHERE NOT paid;
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.id DESC),'[]'::jsonb) INTO v_rows FROM(
 SELECT e.id,e.user_id,p.username,e.amount,e.reason,e.created_at,e.wallet_transaction_id FROM public.ct_treasury_entries e LEFT JOIN public.ct_profiles p ON p.id=e.user_id
 WHERE e.created_at>=v_since AND(p_before IS NULL OR e.id<p_before) AND(coalesce(p_reason,'')='' OR e.reason=p_reason) ORDER BY e.id DESC LIMIT 50)x;
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.received+x.distributed DESC),'[]'::jsonb) INTO v_groups FROM(
 SELECT reason,count(*) operations,coalesce(sum(amount) FILTER(WHERE amount>0),0) received,-coalesce(sum(amount) FILTER(WHERE amount<0),0) distributed FROM public.ct_treasury_entries WHERE created_at>=v_since GROUP BY reason)x;
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.day),'[]'::jsonb) INTO v_daily FROM(
 SELECT d::date AS "day",coalesce(sum(e.amount) FILTER(WHERE e.amount>0),0) received,-coalesce(sum(e.amount) FILTER(WHERE e.amount<0),0) distributed
 FROM generate_series((now() AT TIME ZONE 'UTC')::date-(p_days-1),(now() AT TIME ZONE 'UTC')::date,interval '1 day')d LEFT JOIN public.ct_treasury_entries e ON(e.created_at AT TIME ZONE 'UTC')::date=d::date GROUP BY d)x;
 RETURN jsonb_build_object('initial_capital',v_capital,'treasury_gross',v_treasury,'treasury_available',v_treasury-v_reserved,'player_balances',v_wallets,'reserved_tables',v_reserved,'total',v_treasury+v_wallets,'difference',v_treasury+v_wallets-v_capital,
 'ledger_difference',v_treasury-v_capital+(SELECT coalesce(sum(amount),0) FROM public.ct_wallet_transactions),
 'unmirrored',(SELECT count(*) FROM public.ct_wallet_transactions w LEFT JOIN public.ct_treasury_entries e ON e.wallet_transaction_id=w.id WHERE e.id IS NULL OR e.amount<>-w.amount),
 'received',(SELECT coalesce(sum(amount),0) FROM public.ct_treasury_entries WHERE amount>0 AND created_at>=v_since),
 'distributed',(SELECT -coalesce(sum(amount),0) FROM public.ct_treasury_entries WHERE amount<0 AND created_at>=v_since),'groups',v_groups,'daily',v_daily,'entries',v_rows,'server_time',now());
END $$;
REVOKE ALL ON FUNCTION public.ct_admin_economy(integer,bigint,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_admin_economy(integer,bigint,text) TO authenticated;
COMMIT;

