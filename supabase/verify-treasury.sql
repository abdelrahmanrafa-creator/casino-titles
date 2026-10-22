-- Run after 20261022190000_treasury_privacy.sql. Read-only, no player identities returned.
SELECT
 (SELECT coalesce(sum(amount),0) FROM public.ct_treasury_entries)+(SELECT coalesce(sum(balance),0) FROM public.ct_wallets)=0 AS capital_conserved,
 (SELECT coalesce(sum(amount),0) FROM public.ct_treasury_entries)+(SELECT coalesce(sum(amount),0) FROM public.ct_wallet_transactions)=0 AS ledger_conserved,
 NOT EXISTS(SELECT 1 FROM public.ct_wallet_transactions w LEFT JOIN public.ct_treasury_entries e ON e.wallet_transaction_id=w.id WHERE e.id IS NULL OR e.amount<>-w.amount OR e.user_id<>w.user_id OR e.reason<>w.reason) AS every_transaction_mirrored,
 NOT has_table_privilege('authenticated','public.ct_treasury_entries','INSERT') AS no_client_treasury_writes,
 NOT has_table_privilege('anon','public.ct_treasury_entries','SELECT') AS no_public_treasury_reads,
 NOT has_function_privilege('anon','public.ct_admin_economy(integer,bigint,text)','EXECUTE') AS no_anonymous_economy,
 EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='ct_wallet_treasury' AND tgenabled='O') AS treasury_trigger_enabled,
 EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='ct_preferences' AND column_name='leaderboard_hidden') AS ranking_privacy_installed;
