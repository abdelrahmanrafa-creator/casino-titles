BEGIN;
DO $$
DECLARE a uuid;r jsonb;s public.ct_market_settings;v_total bigint;v_balance bigint;v_op uuid:=gen_random_uuid();v_cents bigint;v_blocked boolean:=false;
BEGIN
 SELECT user_id INTO a FROM public.ct_admins ORDER BY user_id LIMIT 1;IF a IS NULL THEN RAISE EXCEPTION 'Administrator profile required';END IF;PERFORM set_config('request.jwt.claim.sub',a::text,true);
 SELECT * INTO s FROM public.ct_market_settings WHERE id;
 IF NOT s.purchases_enabled OR s.wallets_frozen THEN RAISE EXCEPTION 'Live store paused; perform verification locally';END IF;
 SELECT coalesce(sum(total_cents),0) INTO v_total FROM public.ct_simulated_diamond_purchases;SELECT balance INTO v_balance FROM public.ct_wallets WHERE user_id=a;v_cents:=round(3*s.eur_per_diamond*100)::bigint;
 r:=public.ct_buy_diamonds_simulated(v_op,3,s.version,v_cents,'demo_card');IF NOT(r->>'simulated')::boolean OR(r->>'total_cents')::bigint<>v_cents THEN RAISE EXCEPTION 'Simulation mismatch';END IF;
 PERFORM public.ct_buy_diamonds_simulated(v_op,3,s.version,v_cents,'demo_card');IF(SELECT sum(total_cents) FROM public.ct_simulated_diamond_purchases)<>v_total+v_cents THEN RAISE EXCEPTION 'Duplicate simulation';END IF;
 IF(SELECT balance FROM public.ct_wallets WHERE user_id=a)<>v_balance THEN RAISE EXCEPTION 'Credit wallet changed during fictional payment';END IF;
 r:=public.ct_admin_market_data('',NULL);IF(r->'revenue'->>'real_revenue_cents')::bigint<>0 THEN RAISE EXCEPTION 'Real revenue must be zero';END IF;
 PERFORM public.ct_admin_market_update(gen_random_uuid(),'settings',to_jsonb(s)||jsonb_build_object('purchases_enabled',false),'Vérification temporaire de suspension des achats fictifs');
 BEGIN PERFORM public.ct_buy_diamonds_simulated(gen_random_uuid(),1,s.version,round(s.eur_per_diamond*100)::bigint,'demo_card');EXCEPTION WHEN OTHERS THEN IF position('suspendus' IN SQLERRM)>0 THEN v_blocked:=true;ELSE RAISE;END IF;END;
 IF NOT v_blocked THEN RAISE EXCEPTION 'Pause bypassed';END IF;
 -- A committed receipt is safe to replay even after the store is paused.
 PERFORM public.ct_buy_diamonds_simulated(v_op,3,s.version,v_cents,'demo_card');
END $$;
ROLLBACK;
SELECT true simulated_checkout_rollback_verification_passed;
