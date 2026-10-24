BEGIN;
-- Credits leave the spendable wallet while listed; the treasury mirror holds
-- their counter-entry, and the admin view subtracts this player-owned escrow.
CREATE TABLE public.ct_credit_offers(
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 seller_id uuid NOT NULL REFERENCES public.ct_profiles(id),
 amount bigint NOT NULL CHECK(amount BETWEEN 1 AND 1000000000),
 price bigint NOT NULL CHECK(price BETWEEN 1 AND 1000000000),
 target_id uuid REFERENCES public.ct_profiles(id),
 buyer_id uuid REFERENCES public.ct_profiles(id),
 status text NOT NULL DEFAULT 'active' CHECK(status IN('active','sold','cancelled')),
 created_at timestamptz NOT NULL DEFAULT now(),
 expires_at timestamptz NOT NULL DEFAULT now()+interval '7 days',
 CHECK(target_id IS NULL OR target_id<>seller_id)
);
CREATE INDEX ct_credit_offers_seller ON public.ct_credit_offers(seller_id,id DESC);
CREATE INDEX ct_credit_offers_buyer ON public.ct_credit_offers(buyer_id,id DESC) WHERE buyer_id IS NOT NULL;
CREATE INDEX ct_credit_offers_active ON public.ct_credit_offers(id DESC) WHERE status='active';
CREATE INDEX ct_credit_offers_target ON public.ct_credit_offers(target_id) WHERE target_id IS NOT NULL;
ALTER TABLE public.ct_credit_offers ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ct_credit_offers FROM PUBLIC,anon,authenticated;
REVOKE ALL ON SEQUENCE public.ct_credit_offers_id_seq FROM PUBLIC,anon,authenticated;

-- Always leave room for returning every active reservation, including expired
-- offers. This covers rewards, admin grants and all other wallet credit paths.
CREATE FUNCTION public.ct_credit_escrow_capacity() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NEW.balance+(SELECT coalesce(sum(amount),0) FROM public.ct_credit_offers WHERE seller_id=NEW.user_id AND status='active')>9000000000000 THEN
  RAISE EXCEPTION 'Plafond du portefeuille atteint, crédits réservés compris';
 END IF;RETURN NEW;
END $$;
CREATE TRIGGER ct_credit_escrow_capacity BEFORE UPDATE OF balance ON public.ct_wallets FOR EACH ROW EXECUTE FUNCTION public.ct_credit_escrow_capacity();
REVOKE ALL ON FUNCTION public.ct_credit_escrow_capacity() FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.ct_credit_market(p_view text DEFAULT 'browse',p_before bigint DEFAULT NULL,p_search text DEFAULT '') RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid:=auth.uid();rows jsonb;
BEGIN
 IF u IS NULL THEN RAISE EXCEPTION 'Authentication required';END IF;
 IF p_view IS NULL OR p_view NOT IN('browse','mine','history','admin') THEN RAISE EXCEPTION 'Invalid filters';END IF;
 IF p_view='admin' AND NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required';END IF;
 IF p_view='browse' AND (NOT public.ct_circle_member(u) OR EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=u)) THEN RAISE EXCEPTION 'Carte active requise';END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.id DESC),'[]'::jsonb) INTO rows FROM(
  SELECT o.*,p.username seller,t.username target,b.username buyer
  FROM public.ct_credit_offers o JOIN public.ct_profiles p ON p.id=o.seller_id
  LEFT JOIN public.ct_profiles t ON t.id=o.target_id LEFT JOIN public.ct_profiles b ON b.id=o.buyer_id
  WHERE (p_before IS NULL OR o.id<p_before) AND (p.username ILIKE '%'||left(coalesce(p_search,''),50)||'%') AND
   CASE p_view WHEN 'admin' THEN true WHEN 'mine' THEN o.seller_id=u
    WHEN 'history' THEN o.status='sold' AND(u=o.seller_id OR u=o.buyer_id)
    ELSE o.status='active' AND o.expires_at>now() AND(o.target_id IS NULL OR o.target_id=u OR o.seller_id=u)
     AND public.ct_circle_member(o.seller_id) AND NOT EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=o.seller_id) END
  ORDER BY o.id DESC LIMIT 30)x;
 RETURN jsonb_build_object('offers',rows,'balance',(SELECT balance FROM public.ct_wallets WHERE user_id=u),
  'diamonds',coalesce((SELECT balance FROM public.ct_diamond_wallets WHERE user_id=u),0)-public.ct_direct_diamonds(u),
  'reserved',(SELECT coalesce(sum(amount),0) FROM public.ct_credit_offers WHERE seller_id=u AND status='active'),
  'paused',EXISTS(SELECT 1 FROM public.ct_market_settings WHERE id AND(NOT market_enabled OR wallets_frozen)),'server_time',now());
END $$;

CREATE FUNCTION public.ct_credit_market_command(p_operation_id uuid,p_action text,p_values jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;q jsonb:=jsonb_build_object('kind','credit_market','action',p_action,'values',p_values);o public.ct_credit_offers;amount bigint;price bigint;target uuid;offer_id bigint;
BEGIN
 PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;PERFORM public.ct_check_rate(u);
 IF p_action='cancel' THEN
  SELECT * INTO o FROM public.ct_credit_offers WHERE id=(p_values->>'id')::bigint FOR UPDATE;
  IF o.id IS NULL OR(o.seller_id<>u AND NOT public.ct_is_admin()) THEN RAISE EXCEPTION 'Offre introuvable';END IF;
  IF o.seller_id<>u AND length(trim(coalesce(p_values->>'reason','')))<8 THEN RAISE EXCEPTION 'Justification requise';END IF;
  IF o.status='sold' THEN RAISE EXCEPTION 'Cette vente est déjà conclue';END IF;
  IF o.status='active' THEN
   UPDATE public.ct_credit_offers SET status='cancelled' WHERE id=o.id;
   PERFORM public.ct_post_credit(o.seller_id,o.amount,'market_credit_return','credit-return:'||o.id::text);
   IF o.seller_id<>u THEN INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(u,'credit_market_cancel',o.id::text,left(p_values->>'reason',1000),jsonb_build_object('credits',o.amount,'seller_id',o.seller_id));END IF;
  END IF;offer_id:=o.id;
 ELSE
  IF NOT public.ct_circle_member(u) THEN RAISE EXCEPTION 'Carte active requise';END IF;
  IF EXISTS(SELECT 1 FROM public.ct_market_settings WHERE id AND(NOT market_enabled OR wallets_frozen)) THEN RAISE EXCEPTION 'Le marché est suspendu ou figé';END IF;
  IF p_action='create' THEN
   amount:=(p_values->>'amount')::bigint;price:=(p_values->>'price')::bigint;
   IF amount IS NULL OR amount NOT BETWEEN 1 AND 1000000000 OR price IS NULL OR price NOT BETWEEN 1 AND 1000000000 THEN RAISE EXCEPTION 'Choisissez 1 à 1 000 000 000 crédits et diamants';END IF;
   IF (SELECT count(*) FROM public.ct_credit_offers WHERE seller_id=u AND status='active')>=20 THEN RAISE EXCEPTION 'Maximum 20 offres de crédits actives. Annulez vos anciennes offres';END IF;
   IF nullif(trim(p_values->>'target_username'),'') IS NOT NULL THEN
    SELECT id INTO target FROM public.ct_profiles WHERE lower(username)=lower(trim(p_values->>'target_username'));
    IF target IS NULL OR target=u OR NOT public.ct_circle_member(target) OR EXISTS(SELECT 1 FROM public.ct_profiles WHERE id=target AND is_bot) OR EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=target) THEN RAISE EXCEPTION 'Destinataire indisponible ou carte inactive';END IF;
   END IF;
   PERFORM public.ct_post_credit(u,-amount,'market_credit_reserve','credit-reserve:'||p_operation_id::text);
   INSERT INTO public.ct_credit_offers(seller_id,amount,price,target_id) VALUES(u,amount,price,target) RETURNING id INTO offer_id;
  ELSIF p_action='buy' THEN
   SELECT * INTO o FROM public.ct_credit_offers WHERE id=(p_values->>'id')::bigint FOR UPDATE;
   IF o.id IS NULL OR o.status<>'active' OR o.expires_at<=now() OR o.seller_id=u OR(o.target_id IS NOT NULL AND o.target_id<>u) OR NOT public.ct_circle_member(o.seller_id) OR EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=o.seller_id) THEN RAISE EXCEPTION 'Offre de crédits indisponible';END IF;
   IF o.amount IS DISTINCT FROM(p_values->>'amount')::bigint OR o.price IS DISTINCT FROM(p_values->>'price')::bigint THEN RAISE EXCEPTION 'Offre modifiée. Vérifiez le montant et le prix';END IF;
   IF coalesce((SELECT balance FROM public.ct_diamond_wallets WHERE user_id=u),0)-public.ct_direct_diamonds(u)<o.price THEN RAISE EXCEPTION 'Diamants disponibles insuffisants';END IF;
   UPDATE public.ct_credit_offers SET status='sold',buyer_id=u WHERE id=o.id;
   PERFORM public.ct_post_diamond(u,-o.price,'market_purchase','credit-market:'||p_operation_id::text);
   PERFORM public.ct_post_diamond(o.seller_id,o.price,'market_sale','credit-market:'||p_operation_id::text);
   PERFORM public.ct_post_credit(u,o.amount,'market_credit_purchase','credit-purchase:'||p_operation_id::text);
   offer_id:=o.id;
  ELSE RAISE EXCEPTION 'Unknown action';END IF;
 END IF;
 r:=jsonb_build_object('ok',true,'id',offer_id);INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;
END $$;
REVOKE ALL ON FUNCTION public.ct_credit_market(text,bigint,text),public.ct_credit_market_command(uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_credit_market(text,bigint,text),public.ct_credit_market_command(uuid,text,jsonb) TO authenticated;

ALTER FUNCTION public.ct_admin_economy(integer,bigint,text) RENAME TO ct_admin_economy_before_credit_market;
REVOKE ALL ON FUNCTION public.ct_admin_economy_before_credit_market(integer,bigint,text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_admin_economy(p_days integer DEFAULT 30,p_before bigint DEFAULT NULL,p_reason text DEFAULT '') RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE r jsonb;reserved bigint;
BEGIN
 r:=public.ct_admin_economy_before_credit_market(p_days,p_before,p_reason);
 SELECT coalesce(sum(amount),0) INTO reserved FROM public.ct_credit_offers WHERE status='active';
 RETURN r||jsonb_build_object('reserved_credit_market',reserved,'treasury_available',(r->>'treasury_available')::bigint-reserved);
END $$;
REVOKE ALL ON FUNCTION public.ct_admin_economy(integer,bigint,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_admin_economy(integer,bigint,text) TO authenticated;
COMMIT;
