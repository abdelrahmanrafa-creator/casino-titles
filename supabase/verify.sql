-- All checks must be true. Read-only, no profile contents returned.
SELECT
 NOT EXISTS(SELECT 1 FROM public.ct_wallets WHERE balance<0 OR balance>9000000000000) AS nonnegative_safe_wallets,
 NOT EXISTS(SELECT 1 FROM public.ct_wallets w WHERE balance<>(SELECT coalesce(sum(amount),0) FROM public.ct_wallet_transactions t WHERE t.user_id=w.user_id)) AS ledger_reconciles,
 (SELECT count(*)=8 FROM public.ct_rarities) AS eight_rarities,
 (SELECT count(*)>=320 FROM public.ct_titles) AS complete_catalog,
 NOT EXISTS(SELECT 1 FROM public.ct_chest_types WHERE NOT public.ct_valid_weights(weights)) AS exact_probabilities,
 NOT has_table_privilege('authenticated','public.ct_wallets','UPDATE') AS no_client_wallet_writes,
 NOT has_table_privilege('authenticated','public.ct_wallet_transactions','INSERT') AS no_client_ledger_inserts,
 NOT has_table_privilege('authenticated','public.ct_rooms','SELECT') AS no_private_room_reads,
 NOT has_table_privilege('authenticated','public.ct_game_rounds','SELECT') AS no_private_deck_reads,
 NOT has_function_privilege('authenticated','public.ct_post_credit(uuid,bigint,text,text)','EXECUTE') AS no_client_credit_helper,
 NOT has_function_privilege('authenticated','public.ct_commit_room(uuid,uuid,jsonb,uuid,bigint,jsonb,text)','EXECUTE') AS no_client_room_commit,
 NOT EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname LIKE 'ct_%' AND c.relkind='r' AND NOT c.relrowsecurity) AS all_tables_rls;
