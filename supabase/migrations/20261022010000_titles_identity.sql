-- Isolated foundation: never copies legacy passwords, balances or administrator roles.
BEGIN;
CREATE TABLE public.ct_profiles (
 id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
 username text NOT NULL CHECK (username ~ '^[a-zA-Z0-9_]{3,24}$'),
 avatar text NOT NULL DEFAULT '🎲',
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX ct_profiles_username_unique ON public.ct_profiles(lower(username));
CREATE TABLE public.ct_wallets (
 user_id uuid PRIMARY KEY REFERENCES public.ct_profiles(id) ON DELETE CASCADE,
 balance bigint NOT NULL DEFAULT 5000 CHECK (balance >= 0)
);
CREATE TABLE public.ct_wallet_transactions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 user_id uuid NOT NULL REFERENCES public.ct_profiles(id) ON DELETE CASCADE,
 amount bigint NOT NULL,
 reason text NOT NULL,
 idempotency_key text NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(user_id, idempotency_key)
);
ALTER TABLE public.ct_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ct_wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ct_wallet_transactions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ct_profiles, public.ct_wallets, public.ct_wallet_transactions FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.ct_profiles TO anon, authenticated;
GRANT SELECT ON public.ct_wallets, public.ct_wallet_transactions TO authenticated;
GRANT UPDATE(username, avatar) ON public.ct_profiles TO authenticated;
CREATE POLICY ct_public_profiles ON public.ct_profiles FOR SELECT USING (true);
CREATE POLICY ct_own_profile ON public.ct_profiles FOR UPDATE TO authenticated
 USING (id = auth.uid()) WITH CHECK (id = auth.uid());
CREATE POLICY ct_own_wallet ON public.ct_wallets FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY ct_own_transactions ON public.ct_wallet_transactions FOR SELECT TO authenticated USING (user_id = auth.uid());

-- Called after email verification, not by an auth trigger: legacy registration remains unaffected.
CREATE FUNCTION public.ct_initialize_profile(p_username text)
RETURNS public.ct_profiles LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := auth.uid(); v_profile public.ct_profiles;
BEGIN
 IF v_id IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501'; END IF;
 IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id=v_id AND email_confirmed_at IS NOT NULL)
 THEN RAISE EXCEPTION 'Verified email required' USING ERRCODE = '42501'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(v_id::text, 42));
 SELECT * INTO v_profile FROM public.ct_profiles WHERE id=v_id;
 IF FOUND THEN RETURN v_profile; END IF;
 INSERT INTO public.ct_profiles(id,username) VALUES (v_id,trim(p_username)) RETURNING * INTO v_profile;
 INSERT INTO public.ct_wallets(user_id,balance) VALUES(v_id,5000);
 INSERT INTO public.ct_wallet_transactions(user_id,amount,reason,idempotency_key)
 VALUES(v_id,5000,'welcome','welcome:v1');
 RETURN v_profile;
END $$;
REVOKE ALL ON FUNCTION public.ct_initialize_profile(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ct_initialize_profile(text) TO authenticated;
COMMIT;
