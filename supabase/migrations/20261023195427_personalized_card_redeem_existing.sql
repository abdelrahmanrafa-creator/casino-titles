BEGIN;
CREATE OR REPLACE FUNCTION public.ct_circle_redeem(p_operation_id uuid,p_code text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;h text:=encode(sha256(convert_to(upper(trim(coalesce(p_code,''))),'UTF8')),'hex');q jsonb;c public.ct_circle_codes;BEGIN
 q:=jsonb_build_object('kind','circle_redeem','hash',h);PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;PERFORM public.ct_check_rate(u);
 IF EXISTS(SELECT 1 FROM public.ct_demo_cards WHERE user_id=u) AND NOT public.ct_circle_member(u) THEN RAISE EXCEPTION 'Votre carte est suspendue ou inactive. Contactez un administrateur.';END IF;
 SELECT * INTO c FROM public.ct_circle_codes WHERE code_hash=h AND active AND expires_at>now() AND uses<max_uses AND EXISTS(SELECT 1 FROM public.ct_demo_card_tiers t WHERE t.id=tier_id AND t.active) FOR UPDATE;
 IF c.id IS NOT NULL AND c.custom='{}'::jsonb AND EXISTS(SELECT 1 FROM public.ct_demo_cards WHERE user_id=u) THEN RAISE EXCEPTION 'Vous avez déjà une carte. Seul un code de carte personnalisée peut la remplacer.';END IF;
 IF c.id IS NULL OR length(p_code)>64 OR EXISTS(SELECT 1 FROM public.ct_circle_claims WHERE user_id=u AND code_id=c.id) THEN r:='{"ok":false,"message":"Code invalide, expiré ou épuisé."}';
 ELSE
 INSERT INTO public.ct_demo_cards(user_id,tier_id,version,credit_conversion_allowed,custom) VALUES(u,c.tier_id,(SELECT version+1 FROM public.ct_market_settings WHERE id),c.credit_conversion_allowed,public.ct_validate_card_custom(c.custom,c.tier_id)) ON CONFLICT(user_id) DO UPDATE SET tier_id=EXCLUDED.tier_id,version=EXCLUDED.version,custom=EXCLUDED.custom,credit_conversion_allowed=EXCLUDED.credit_conversion_allowed,updated_at=now();
 UPDATE public.ct_market_settings SET version=version+1 WHERE id;UPDATE public.ct_circle_codes SET uses=uses+1 WHERE id=c.id;INSERT INTO public.ct_circle_claims VALUES(u,c.id);
 UPDATE public.ct_circle_applications SET status='approved',note='Accès obtenu par code.' WHERE user_id=u AND status='pending';r:=jsonb_build_object('ok',true,'tier_id',c.tier_id);END IF;
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;END $$;

COMMIT;
