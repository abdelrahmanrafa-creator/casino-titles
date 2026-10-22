-- Transactional verification on the live schema; every temporary change is rolled back.
BEGIN;
UPDATE public.ct_market_settings SET credit_conversion_enabled=true;
DO $$
DECLARE a uuid;b uuid;v_title uuid;l bigint;r jsonb;c public.ct_chest_types;v_sealed uuid;v_key text:=gen_random_uuid()::text;
BEGIN
 SELECT user_id INTO a FROM public.ct_admins ORDER BY user_id LIMIT 1;
 SELECT id INTO b FROM public.ct_profiles WHERE NOT is_bot AND id<>a AND NOT EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=id) ORDER BY id LIMIT 1;
 IF a IS NULL OR b IS NULL THEN RAISE EXCEPTION 'Two real profiles, including an administrator, required for rolled-back verification';END IF;
 PERFORM public.ct_post_credit(a,10000,'admin_adjustment','market-qa-a:'||v_key);PERFORM public.ct_post_credit(b,10000,'admin_adjustment','market-qa-b:'||v_key);
 PERFORM set_config('request.jwt.claim.sub',b::text,true);PERFORM public.ct_market_command(gen_random_uuid(),'convert','{"diamonds":2}');
 PERFORM set_config('request.jwt.claim.sub',a::text,true);
 INSERT INTO public.ct_player_titles(user_id,title_id,source) SELECT a,id,'market:rollback-verification' FROM public.ct_titles WHERE rarity=1 ORDER BY id LIMIT 1 RETURNING id INTO v_title;
 r:=public.ct_market_command(gen_random_uuid(),'list',jsonb_build_object('asset_kind','title','asset_id',v_title,'price',1));l:=(r->>'listing_id')::bigint;
 PERFORM set_config('request.jwt.claim.sub',b::text,true);PERFORM public.ct_market_command(gen_random_uuid(),'accept',jsonb_build_object('listing_id',l));
 IF NOT EXISTS(SELECT 1 FROM public.ct_market_listings WHERE id=l AND status='sold' AND buyer_id=b) OR NOT EXISTS(SELECT 1 FROM public.ct_player_titles WHERE id=v_title AND revoked_at IS NOT NULL) THEN RAISE EXCEPTION 'Title transfer failed';END IF;
 SELECT * INTO c FROM public.ct_chest_types WHERE active AND category='standard' AND stock_limit IS NULL AND per_player_limit IS NULL ORDER BY id LIMIT 1;
 r:=public.ct_market_command(gen_random_uuid(),'buy_sealed',jsonb_build_object('chest_id',c.id,'price',c.price,'version',c.version));v_sealed:=(r->>'sealed_id')::uuid;
 r:=public.ct_market_command(gen_random_uuid(),'open_sealed',jsonb_build_object('asset_id',v_sealed));IF r->'title' IS NULL THEN RAISE EXCEPTION 'Sealed opening failed';END IF;
 IF(SELECT coalesce(sum(balance),0) FROM public.ct_diamond_wallets)<>(SELECT coalesce(sum(amount),0) FROM public.ct_diamond_ledger) THEN RAISE EXCEPTION 'Diamond ledger mismatch';END IF;
 PERFORM set_config('request.jwt.claim.sub',a::text,true);r:=public.ct_admin_economy(30,NULL,'');IF(r->>'difference')::numeric<>0 OR(r->>'ledger_difference')::numeric<>0 THEN RAISE EXCEPTION 'Treasury mismatch';END IF;
END $$;
ROLLBACK;
SELECT true AS market_rollback_verification_passed;
