-- Read-only checks; bot generation is tested separately inside a rolled-back transaction.
SELECT
 NOT EXISTS(SELECT 1 FROM public.ct_profiles WHERE (is_bot AND auth_user_id IS NOT NULL) OR(NOT is_bot AND auth_user_id IS DISTINCT FROM id)) AS valid_profile_identities,
 NOT EXISTS(SELECT 1 FROM public.ct_profiles p JOIN auth.users a ON a.id=p.id WHERE p.is_bot) AS bots_have_no_auth_account,
 NOT EXISTS(SELECT 1 FROM public.ct_player_titles i JOIN public.ct_profiles p ON p.id=i.user_id JOIN public.ct_titles t ON t.id=i.title_id WHERE p.is_bot AND t.rarity=8) AS no_cosmic_bot_titles,
 NOT EXISTS(SELECT 1 FROM public.ct_admins a JOIN public.ct_profiles p ON p.id=a.user_id WHERE p.is_bot) AS no_bot_administrators,
 NOT EXISTS(SELECT 1 FROM public.ct_room_members m JOIN public.ct_profiles p ON p.id=m.user_id WHERE p.is_bot) AS no_bots_at_real_tables,
 NOT has_table_privilege('authenticated','public.ct_bots','UPDATE') AS no_client_bot_writes,
 NOT has_function_privilege('anon','public.ct_admin_create_bots(uuid,jsonb,text)','EXECUTE') AS no_anonymous_creation,
 NOT has_function_privilege('authenticated','public.ct_rankings_before_bots(text,text)','EXECUTE') AS no_old_ranking_bypass,
 (SELECT coalesce(sum(amount),0) FROM public.ct_treasury_entries)+(SELECT coalesce(sum(balance),0) FROM public.ct_wallets)=0 AS capital_conserved;
