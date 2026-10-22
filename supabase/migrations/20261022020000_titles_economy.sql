BEGIN;
ALTER TABLE public.ct_wallets ADD COLUMN version bigint NOT NULL DEFAULT 0;
ALTER TABLE public.ct_wallets ADD CONSTRAINT ct_wallet_safe_integer CHECK (balance <= 9000000000000);
ALTER TABLE public.ct_wallet_transactions ADD COLUMN balance_after bigint;
ALTER TABLE public.ct_wallet_transactions ADD COLUMN wallet_version bigint;
-- The only pre-existing entries are welcome grants; never infer balances for other entries.
UPDATE public.ct_wallet_transactions SET balance_after=5000,wallet_version=0
 WHERE reason='welcome' AND idempotency_key='welcome:v1';
CREATE INDEX ct_wallet_history ON public.ct_wallet_transactions(user_id,created_at DESC,id DESC);
CREATE TABLE public.ct_operations (
 user_id uuid NOT NULL REFERENCES public.ct_profiles(id) ON DELETE CASCADE,
 operation_id uuid NOT NULL,
 request jsonb NOT NULL,
 result jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(user_id,operation_id)
);
CREATE TABLE public.ct_daily_rewards (
 user_id uuid NOT NULL REFERENCES public.ct_profiles(id) ON DELETE CASCADE,
 reward_day date NOT NULL,
 amount bigint NOT NULL CHECK(amount=750),
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(user_id,reward_day)
);
CREATE TABLE public.ct_request_limits (
 user_id uuid PRIMARY KEY REFERENCES public.ct_profiles(id) ON DELETE CASCADE,
 window_start timestamptz NOT NULL DEFAULT now(),
 requests integer NOT NULL DEFAULT 0
);
ALTER TABLE public.ct_operations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ct_daily_rewards ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ct_request_limits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ct_operations,public.ct_daily_rewards,public.ct_request_limits FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.ct_operations,public.ct_daily_rewards TO authenticated;
CREATE POLICY ct_operations_owner ON public.ct_operations FOR SELECT TO authenticated USING(user_id=auth.uid());
CREATE POLICY ct_rewards_owner ON public.ct_daily_rewards FOR SELECT TO authenticated USING(user_id=auth.uid());

-- Internal helpers: no execute grants to API roles. All commands lock the wallet first.
CREATE FUNCTION public.ct_lock_wallet() RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid:=auth.uid();
BEGIN
 IF v_uid IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501'; END IF;
 PERFORM 1 FROM public.ct_wallets WHERE user_id=v_uid FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Profile required'; END IF;
 RETURN v_uid;
END $$;
CREATE FUNCTION public.ct_check_rate(p_uid uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_count integer;
BEGIN
 INSERT INTO public.ct_request_limits(user_id,requests) VALUES(p_uid,1)
 ON CONFLICT(user_id) DO UPDATE SET
 requests=CASE WHEN ct_request_limits.window_start <= now()-interval '1 minute' THEN 1 ELSE ct_request_limits.requests+1 END,
 window_start=CASE WHEN ct_request_limits.window_start <= now()-interval '1 minute' THEN now() ELSE ct_request_limits.window_start END
 RETURNING requests INTO v_count;
 IF v_count>30 THEN RAISE EXCEPTION 'Too many operations. Retry in one minute.'; END IF;
END $$;
CREATE FUNCTION public.ct_replay(p_uid uuid,p_id uuid,p_request jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_operation public.ct_operations;
BEGIN
 IF p_id IS NULL THEN RAISE EXCEPTION 'Operation ID required'; END IF;
 SELECT * INTO v_operation FROM public.ct_operations WHERE user_id=p_uid AND operation_id=p_id;
 IF NOT FOUND THEN RETURN NULL; END IF;
 IF v_operation.request IS DISTINCT FROM p_request THEN RAISE EXCEPTION 'Operation ID reused with different payload'; END IF;
 RETURN v_operation.result;
END $$;
CREATE FUNCTION public.ct_post_credit(p_uid uuid,p_delta bigint,p_reason text,p_key text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_wallet public.ct_wallets; v_id uuid;
BEGIN
 IF p_delta IS NULL OR p_delta=0 OR abs(p_delta::numeric)>9000000000000 THEN RAISE EXCEPTION 'Invalid credit amount'; END IF;
 UPDATE public.ct_wallets SET balance=balance+p_delta,version=version+1
 WHERE user_id=p_uid AND balance+p_delta BETWEEN 0 AND 9000000000000 RETURNING * INTO v_wallet;
 IF NOT FOUND THEN RAISE EXCEPTION 'Insufficient credits or wallet limit reached'; END IF;
 INSERT INTO public.ct_wallet_transactions(user_id,amount,reason,idempotency_key,balance_after,wallet_version)
 VALUES(p_uid,p_delta,p_reason,p_key,v_wallet.balance,v_wallet.version) RETURNING id INTO v_id;
 RETURN jsonb_build_object('transaction_id',v_id,'balance',v_wallet.balance,'version',v_wallet.version,'amount',p_delta);
END $$;
CREATE FUNCTION public.ct_claim_daily(p_operation_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid; v_result jsonb; v_day date:=(now() AT TIME ZONE 'UTC')::date;
 v_request jsonb:=jsonb_build_object('kind','daily');
BEGIN
 v_uid:=public.ct_lock_wallet();
 v_result:=public.ct_replay(v_uid,p_operation_id,v_request);
 IF v_result IS NOT NULL THEN RETURN v_result; END IF;
 PERFORM public.ct_check_rate(v_uid);
 IF EXISTS(SELECT 1 FROM public.ct_daily_rewards WHERE user_id=v_uid AND reward_day=v_day) THEN
  v_result:=jsonb_build_object('already_claimed',true,'reward_day',v_day,'amount',0);
 ELSE
  INSERT INTO public.ct_daily_rewards(user_id,reward_day,amount) VALUES(v_uid,v_day,750);
  v_result:=public.ct_post_credit(v_uid,750,'daily','daily:'||v_day::text)||jsonb_build_object('already_claimed',false,'reward_day',v_day);
 END IF;
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(v_uid,p_operation_id,v_request,v_result);
 RETURN v_result;
END $$;
-- One SQL statement = one MVCC snapshot: balance and journal never come from different revisions.
CREATE FUNCTION public.ct_economy_snapshot() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('wallet',to_jsonb(w),
 'transactions',coalesce((SELECT jsonb_agg(to_jsonb(t) ORDER BY t.created_at DESC,t.id DESC) FROM
  (SELECT * FROM public.ct_wallet_transactions WHERE user_id=auth.uid() ORDER BY created_at DESC,id DESC LIMIT 50) t),'[]'::jsonb),
 'daily_claimed',EXISTS(SELECT 1 FROM public.ct_daily_rewards WHERE user_id=auth.uid() AND reward_day=(now() AT TIME ZONE 'UTC')::date),
 'next_daily_at',((now() AT TIME ZONE 'UTC')::date+1)::timestamp AT TIME ZONE 'UTC',
 'server_time',now())
 FROM public.ct_wallets w WHERE w.user_id=auth.uid();
$$;
REVOKE ALL ON FUNCTION public.ct_lock_wallet(),public.ct_check_rate(uuid),public.ct_replay(uuid,uuid,jsonb),public.ct_post_credit(uuid,bigint,text,text),public.ct_claim_daily(uuid),public.ct_economy_snapshot() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_claim_daily(uuid),public.ct_economy_snapshot() TO authenticated;

-- New registrations retain an auditable initial journal balance.
CREATE OR REPLACE FUNCTION public.ct_initialize_profile(p_username text)
RETURNS public.ct_profiles LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_id uuid:=auth.uid(); v_profile public.ct_profiles;
BEGIN
 IF v_id IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501'; END IF;
 IF NOT EXISTS(SELECT 1 FROM auth.users WHERE id=v_id AND email_confirmed_at IS NOT NULL)
 THEN RAISE EXCEPTION 'Verified email required' USING ERRCODE='42501'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(v_id::text,42));
 SELECT * INTO v_profile FROM public.ct_profiles WHERE id=v_id;
 IF FOUND THEN RETURN v_profile; END IF;
 INSERT INTO public.ct_profiles(id,username) VALUES(v_id,trim(p_username)) RETURNING * INTO v_profile;
 INSERT INTO public.ct_wallets(user_id,balance) VALUES(v_id,5000);
 INSERT INTO public.ct_wallet_transactions(user_id,amount,reason,idempotency_key,balance_after,wallet_version)
 VALUES(v_id,5000,'welcome','welcome:v1',5000,0);
 RETURN v_profile;
END $$;
COMMIT;
