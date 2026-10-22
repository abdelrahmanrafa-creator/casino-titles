BEGIN;
CREATE TABLE public.ct_diamond_wallets(user_id uuid PRIMARY KEY REFERENCES public.ct_profiles(id) ON DELETE CASCADE,balance bigint NOT NULL DEFAULT 0 CHECK(balance BETWEEN 0 AND 9000000000000));
CREATE TABLE public.ct_diamond_ledger(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,user_id uuid NOT NULL REFERENCES public.ct_profiles(id) ON DELETE CASCADE,amount bigint NOT NULL CHECK(amount<>0),balance_after bigint NOT NULL CHECK(balance_after>=0),reason text NOT NULL,operation_key text NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(user_id,operation_key));
CREATE INDEX ct_diamond_history ON public.ct_diamond_ledger(user_id,created_at DESC,id DESC);
CREATE TABLE public.ct_sealed_chests(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),user_id uuid NOT NULL REFERENCES public.ct_profiles(id),chest_id smallint NOT NULL REFERENCES public.ct_chest_types(id),name text NOT NULL,rarity smallint NOT NULL,weights integer[] NOT NULL,title_ids text[] NOT NULL,opened_at timestamptz,created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX ct_sealed_owner ON public.ct_sealed_chests(user_id,created_at DESC);
CREATE TABLE public.ct_market_listings(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,seller_id uuid NOT NULL REFERENCES public.ct_profiles(id),asset_kind text NOT NULL CHECK(asset_kind IN('title','chest')),asset_id uuid NOT NULL,name text NOT NULL,rarity smallint NOT NULL,definition_id text NOT NULL,price bigint NOT NULL CHECK(price BETWEEN 0 AND 1000000000),wanted_kind text CHECK(wanted_kind IN('title','chest')),wanted_id text,target_id uuid REFERENCES public.ct_profiles(id),status text NOT NULL DEFAULT 'active' CHECK(status IN('active','sold','cancelled')),buyer_id uuid REFERENCES public.ct_profiles(id),created_at timestamptz NOT NULL DEFAULT now(),expires_at timestamptz NOT NULL DEFAULT now()+interval '7 days',CHECK((wanted_kind IS NULL AND wanted_id IS NULL AND price>0) OR(wanted_kind IS NOT NULL AND wanted_id IS NOT NULL)),CHECK(target_id IS NULL OR target_id<>seller_id));
CREATE UNIQUE INDEX ct_market_reserved ON public.ct_market_listings(asset_kind,asset_id) WHERE status='active';
CREATE INDEX ct_market_seller ON public.ct_market_listings(seller_id,id DESC);
CREATE INDEX ct_market_target ON public.ct_market_listings(target_id) WHERE target_id IS NOT NULL;
CREATE INDEX ct_market_buyer ON public.ct_market_listings(buyer_id) WHERE buyer_id IS NOT NULL;
CREATE TABLE public.ct_market_trades(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,listing_id bigint NOT NULL UNIQUE REFERENCES public.ct_market_listings(id),seller_id uuid NOT NULL REFERENCES public.ct_profiles(id),buyer_id uuid NOT NULL REFERENCES public.ct_profiles(id),diamonds bigint NOT NULL,offered_kind text NOT NULL,offered_name text NOT NULL,wanted_kind text,wanted_id text,created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX ct_market_trade_seller ON public.ct_market_trades(seller_id,id DESC);
CREATE INDEX ct_market_trade_buyer ON public.ct_market_trades(buyer_id,id DESC);
ALTER TABLE public.ct_diamond_wallets ENABLE ROW LEVEL SECURITY;ALTER TABLE public.ct_diamond_ledger ENABLE ROW LEVEL SECURITY;ALTER TABLE public.ct_sealed_chests ENABLE ROW LEVEL SECURITY;ALTER TABLE public.ct_market_listings ENABLE ROW LEVEL SECURITY;ALTER TABLE public.ct_market_trades ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ct_diamond_wallets,public.ct_diamond_ledger,public.ct_sealed_chests,public.ct_market_listings,public.ct_market_trades FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_post_diamond(p_uid uuid,p_delta bigint,p_reason text,p_key text) RETURNS void LANGUAGE plpgsql SET search_path='' AS $$
DECLARE v_balance bigint;
BEGIN IF p_delta IS NULL OR p_delta=0 OR abs(p_delta::numeric)>9000000000000 THEN RAISE EXCEPTION 'Invalid diamond amount';END IF;
 INSERT INTO public.ct_diamond_wallets(user_id) VALUES(p_uid) ON CONFLICT DO NOTHING;
 UPDATE public.ct_diamond_wallets SET balance=balance+p_delta WHERE user_id=p_uid RETURNING balance INTO v_balance;
 INSERT INTO public.ct_diamond_ledger(user_id,amount,balance_after,reason,operation_key) VALUES(p_uid,p_delta,v_balance,p_reason,p_key);
END $$;
CREATE FUNCTION public.ct_market_asset(p_uid uuid,p_kind text,p_asset uuid) RETURNS jsonb LANGUAGE plpgsql SET search_path='' AS $$
DECLARE v_result jsonb;
BEGIN
 IF p_kind='title' THEN
  SELECT jsonb_build_object('name',t.name,'rarity',t.rarity,'definition_id',t.id) INTO v_result FROM public.ct_player_titles i JOIN public.ct_titles t ON t.id=i.title_id WHERE i.id=p_asset AND i.user_id=p_uid AND i.revoked_at IS NULL AND i.quantity=1 FOR UPDATE OF i;
 ELSIF p_kind='chest' THEN
  SELECT jsonb_build_object('name',name,'rarity',rarity,'definition_id',chest_id::text) INTO v_result FROM public.ct_sealed_chests WHERE id=p_asset AND user_id=p_uid AND opened_at IS NULL FOR UPDATE;
 END IF;
 IF v_result IS NULL THEN RAISE EXCEPTION 'Objet indisponible ou non possédé';END IF;RETURN v_result;
END $$;
CREATE FUNCTION public.ct_market_transfer(p_from uuid,p_to uuid,p_kind text,p_asset uuid) RETURNS void LANGUAGE plpgsql SET search_path='' AS $$
DECLARE t text;
BEGIN
 PERFORM public.ct_market_asset(p_from,p_kind,p_asset);
 IF p_kind='title' THEN
  SELECT title_id INTO t FROM public.ct_player_titles WHERE id=p_asset;
  DELETE FROM public.ct_equipped_titles WHERE player_title_id=p_asset;
  UPDATE public.ct_player_titles SET revoked_at=now() WHERE id=p_asset;
  INSERT INTO public.ct_player_titles(user_id,title_id,source) VALUES(p_to,t,'market:trade');
 ELSE UPDATE public.ct_sealed_chests SET user_id=p_to WHERE id=p_asset;
 END IF;
END $$;
CREATE FUNCTION public.ct_market_equip_guard() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN IF EXISTS(SELECT 1 FROM public.ct_market_listings WHERE asset_kind='title' AND asset_id=NEW.player_title_id AND status='active' AND expires_at>now()) THEN RAISE EXCEPTION 'Ce titre est réservé au marché. Annulez son annonce avant de l’équiper.';END IF;RETURN NEW;END $$;
CREATE TRIGGER ct_market_equip_guard BEFORE INSERT OR UPDATE ON public.ct_equipped_titles FOR EACH ROW EXECUTE FUNCTION public.ct_market_equip_guard();
REVOKE ALL ON FUNCTION public.ct_post_diamond(uuid,bigint,text,text),public.ct_market_asset(uuid,text,uuid),public.ct_market_transfer(uuid,uuid,text,uuid),public.ct_market_equip_guard() FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_diamond_balance() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('balance',coalesce((SELECT balance FROM public.ct_diamond_wallets WHERE user_id=auth.uid()),0),'credits_per_diamond',1000);
$$;
CREATE FUNCTION public.ct_market_command(p_operation_id uuid,p_action text,p_values jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;v_request jsonb:=jsonb_build_object('kind','market','action',p_action,'values',p_values);v_result jsonb;v_amount bigint;v_id bigint;v_asset uuid;v_kind text;v_info jsonb;v_target uuid;l public.ct_market_listings;c public.ct_chest_types;s public.ct_sealed_chests;v_title public.ct_titles;v_titles text[];v_rarity smallint;v_count integer;v_instance uuid;v_other jsonb;v_other_asset uuid;v_wanted_kind text;v_wanted_id text;
BEGIN
 PERFORM pg_advisory_xact_lock(173,8);
 u:=public.ct_lock_wallet();v_result:=public.ct_replay(u,p_operation_id,v_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;PERFORM public.ct_check_rate(u);
 IF p_action='convert' THEN
  v_amount:=(p_values->>'diamonds')::bigint;IF v_amount IS NULL OR v_amount NOT BETWEEN 1 AND 10000 THEN RAISE EXCEPTION 'Choisissez 1 à 10 000 diamants';END IF;
  PERFORM public.ct_post_credit(u,-v_amount*1000,'diamond_conversion','diamond-convert:'||p_operation_id::text);
  PERFORM public.ct_post_diamond(u,v_amount,'conversion','convert:'||p_operation_id::text);
 ELSIF p_action='buy_sealed' THEN
  SELECT * INTO c FROM public.ct_chest_types WHERE id=(p_values->>'chest_id')::smallint FOR UPDATE;
  IF NOT FOUND OR NOT c.active OR c.category<>'standard' OR c.stock_limit IS NOT NULL OR c.per_player_limit IS NOT NULL OR(c.starts_at IS NOT NULL AND c.starts_at>now()) OR(c.ends_at IS NOT NULL AND c.ends_at<=now()) THEN RAISE EXCEPTION 'Ce coffre ne peut pas être acheté scellé';END IF;
  IF c.price IS DISTINCT FROM(p_values->>'price')::bigint OR c.version IS DISTINCT FROM(p_values->>'version')::bigint THEN RAISE EXCEPTION 'Prix du coffre modifié. Actualisez le marché.';END IF;
  SELECT array_agg(id ORDER BY id) INTO v_titles FROM public.ct_titles WHERE available AND(NOT exclusive OR c.allow_exclusive) AND(c.title_pool IS NULL OR id=ANY(c.title_pool));
  FOR v_rarity IN 1..8 LOOP IF c.weights[v_rarity]>0 AND NOT EXISTS(SELECT 1 FROM public.ct_titles WHERE id=ANY(v_titles) AND rarity=v_rarity) THEN RAISE EXCEPTION 'Catalogue incomplet pour ce coffre';END IF;END LOOP;
  PERFORM public.ct_post_credit(u,-c.price,'sealed_chest','sealed-buy:'||p_operation_id::text);
  INSERT INTO public.ct_sealed_chests(user_id,chest_id,name,rarity,weights,title_ids) VALUES(u,c.id,c.name,c.rarity,c.weights,v_titles) RETURNING id INTO v_asset;
  UPDATE public.ct_chest_types SET stock_used=stock_used+1 WHERE id=c.id;
  v_result:=jsonb_build_object('sealed_id',v_asset);
 ELSIF p_action='open_sealed' THEN
  v_asset:=(p_values->>'asset_id')::uuid;PERFORM public.ct_market_asset(u,'chest',v_asset);
  IF EXISTS(SELECT 1 FROM public.ct_market_listings WHERE asset_kind='chest' AND asset_id=v_asset AND status='active' AND expires_at>now()) THEN RAISE EXCEPTION 'Annulez l’annonce avant d’ouvrir ce coffre';END IF;
  SELECT * INTO s FROM public.ct_sealed_chests WHERE id=v_asset FOR UPDATE;
  v_rarity:=public.ct_rarity_for_roll(s.weights,public.ct_random_below(10000));
  SELECT count(*) INTO v_count FROM public.ct_titles WHERE id=ANY(s.title_ids) AND rarity=v_rarity;
  IF v_count=0 THEN RAISE EXCEPTION 'Contenu du coffre indisponible';END IF;
  SELECT * INTO v_title FROM public.ct_titles WHERE id=ANY(s.title_ids) AND rarity=v_rarity ORDER BY id OFFSET public.ct_random_below(v_count) LIMIT 1;
  INSERT INTO public.ct_player_titles(user_id,title_id,source) VALUES(u,v_title.id,'sealed:'||s.name) RETURNING id INTO v_instance;
  INSERT INTO public.ct_chest_openings(user_id,chest_id,player_title_id,price_paid,base_price,weights,operation_id) VALUES(u,s.chest_id,v_instance,0,0,s.weights,p_operation_id);
  UPDATE public.ct_sealed_chests SET opened_at=now() WHERE id=s.id;
  v_result:=jsonb_build_object('title',to_jsonb(v_title),'player_title_id',v_instance);
 ELSIF p_action='list' THEN
  v_kind:=p_values->>'asset_kind';v_asset:=(p_values->>'asset_id')::uuid;v_amount:=(p_values->>'price')::bigint;
  IF v_amount IS NULL OR v_amount NOT BETWEEN 0 AND 1000000000 THEN RAISE EXCEPTION 'Prix en diamants invalide';END IF;
  IF(SELECT count(*) FROM public.ct_market_listings WHERE seller_id=u AND status='active' AND expires_at>now())>=20 THEN RAISE EXCEPTION '20 annonces actives maximum';END IF;
  v_info:=public.ct_market_asset(u,v_kind,v_asset);
  IF nullif(trim(p_values->>'target_username'),'') IS NOT NULL THEN
   SELECT p.id INTO v_target FROM public.ct_profiles p WHERE lower(p.username)=lower(trim(p_values->>'target_username')) AND NOT p.is_bot AND NOT EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=p.id);
   IF v_target IS NULL OR v_target=u THEN RAISE EXCEPTION 'Destinataire indisponible';END IF;
  END IF;
  v_wanted_kind:=nullif(p_values->>'wanted_kind','');v_wanted_id:=nullif(p_values->>'wanted_id','');
  IF v_wanted_kind IS NOT NULL THEN
   IF v_wanted_kind='title' THEN IF NOT EXISTS(SELECT 1 FROM public.ct_titles WHERE id=v_wanted_id) THEN RAISE EXCEPTION 'Titre demandé introuvable';END IF;
   ELSIF v_wanted_kind='chest' THEN IF NOT EXISTS(SELECT 1 FROM public.ct_chest_types WHERE id::text=v_wanted_id) THEN RAISE EXCEPTION 'Coffre demandé introuvable';END IF;
   ELSE RAISE EXCEPTION 'Objet demandé invalide';END IF;
  END IF;
  -- Expired reservations can be safely closed before relisting the same asset.
  UPDATE public.ct_market_listings SET status='cancelled' WHERE asset_kind=v_kind AND asset_id=v_asset AND status='active' AND expires_at<=now();
  INSERT INTO public.ct_market_listings(seller_id,asset_kind,asset_id,name,rarity,definition_id,price,wanted_kind,wanted_id,target_id) VALUES(u,v_kind,v_asset,v_info->>'name',(v_info->>'rarity')::smallint,v_info->>'definition_id',v_amount,v_wanted_kind,v_wanted_id,v_target) RETURNING id INTO v_id;
  IF v_kind='title' THEN DELETE FROM public.ct_equipped_titles WHERE player_title_id=v_asset;END IF;
  v_result:=jsonb_build_object('listing_id',v_id);
 ELSIF p_action IN('cancel','accept') THEN
  SELECT * INTO l FROM public.ct_market_listings WHERE id=(p_values->>'listing_id')::bigint FOR UPDATE;
  IF NOT FOUND OR l.status<>'active' THEN RAISE EXCEPTION 'Annonce déjà traitée ou indisponible';END IF;
  IF p_action='cancel' THEN
   IF l.seller_id<>u AND NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Seul le vendeur peut annuler cette annonce';END IF;
   UPDATE public.ct_market_listings SET status='cancelled' WHERE id=l.id;
  ELSE
   IF l.seller_id=u OR l.expires_at<=now() OR(l.target_id IS NOT NULL AND l.target_id<>u) THEN RAISE EXCEPTION 'Vous ne pouvez pas accepter cette annonce';END IF;
   IF EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=l.seller_id) THEN RAISE EXCEPTION 'Vendeur indisponible';END IF;
   PERFORM 1 FROM public.ct_wallets WHERE user_id=l.seller_id FOR UPDATE;
   PERFORM public.ct_market_asset(l.seller_id,l.asset_kind,l.asset_id);
   IF l.wanted_kind IS NOT NULL THEN
    v_other_asset:=(p_values->>'payment_asset_id')::uuid;v_other:=public.ct_market_asset(u,l.wanted_kind,v_other_asset);
    IF v_other->>'definition_id' IS DISTINCT FROM l.wanted_id OR EXISTS(SELECT 1 FROM public.ct_market_listings WHERE asset_kind=l.wanted_kind AND asset_id=v_other_asset AND status='active' AND expires_at>now()) THEN RAISE EXCEPTION 'L’objet proposé ne correspond pas ou est déjà réservé';END IF;
   END IF;
   IF l.price>0 THEN
    IF coalesce((SELECT balance FROM public.ct_diamond_wallets WHERE user_id=u),0)<l.price THEN RAISE EXCEPTION 'Solde de diamants insuffisant';END IF;
    PERFORM public.ct_post_diamond(u,-l.price,'market_purchase','market:'||p_operation_id::text);
    PERFORM public.ct_post_diamond(l.seller_id,l.price,'market_sale','market:'||p_operation_id::text);
   END IF;
   UPDATE public.ct_market_listings SET status='sold',buyer_id=u WHERE id=l.id;
   PERFORM public.ct_market_transfer(l.seller_id,u,l.asset_kind,l.asset_id);
   IF l.wanted_kind IS NOT NULL THEN PERFORM public.ct_market_transfer(u,l.seller_id,l.wanted_kind,v_other_asset);END IF;
   INSERT INTO public.ct_market_trades(listing_id,seller_id,buyer_id,diamonds,offered_kind,offered_name,wanted_kind,wanted_id) VALUES(l.id,l.seller_id,u,l.price,l.asset_kind,l.name,l.wanted_kind,l.wanted_id);
  END IF;
 ELSE RAISE EXCEPTION 'Action inconnue';END IF;
 v_result:=coalesce(v_result,'{}')||jsonb_build_object('ok',true,'diamonds',coalesce((SELECT balance FROM public.ct_diamond_wallets WHERE user_id=u),0));
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,v_request,v_result);RETURN v_result;
END $$;
REVOKE ALL ON FUNCTION public.ct_diamond_balance(),public.ct_market_command(uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_diamond_balance(),public.ct_market_command(uuid,text,jsonb) TO authenticated;
CREATE FUNCTION public.ct_market_snapshot(p_search text DEFAULT '',p_before bigint DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid:=auth.uid();v_result jsonb;
BEGIN
 IF u IS NULL OR NOT EXISTS(SELECT 1 FROM public.ct_profiles WHERE id=u AND NOT is_bot) OR EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=u) THEN RAISE EXCEPTION 'Compte joueur actif requis' USING ERRCODE='42501';END IF;
 IF length(coalesce(p_search,''))>50 OR(p_before IS NOT NULL AND p_before<1) THEN RAISE EXCEPTION 'Recherche invalide';END IF;
 SELECT jsonb_build_object('diamonds',coalesce((SELECT balance FROM public.ct_diamond_wallets WHERE user_id=u),0),'credits_per_diamond',1000,
 'listings',coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.id DESC) FROM(SELECT l.*,p.username seller,coalesce(t.name,c.name) wanted_name FROM public.ct_market_listings l JOIN public.ct_profiles p ON p.id=l.seller_id LEFT JOIN public.ct_titles t ON l.wanted_kind='title' AND t.id=l.wanted_id LEFT JOIN public.ct_chest_types c ON l.wanted_kind='chest' AND c.id::text=l.wanted_id WHERE l.status='active' AND l.expires_at>now() AND(l.target_id IS NULL OR l.target_id=u OR l.seller_id=u) AND NOT EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=l.seller_id) AND(p_before IS NULL OR l.id<p_before) AND position(lower(coalesce(p_search,'')) IN lower(l.name||' '||p.username))>0 ORDER BY l.id DESC LIMIT 50)x),'[]'::jsonb),
 'mine',coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.id DESC) FROM(SELECT l.*,p.username target_username FROM public.ct_market_listings l LEFT JOIN public.ct_profiles p ON p.id=l.target_id WHERE l.seller_id=u ORDER BY l.id DESC LIMIT 50)x),'[]'::jsonb),
 'assets',coalesce((SELECT jsonb_agg(x) FROM(
 SELECT jsonb_build_object('id',i.id,'kind','title','definition_id',t.id,'name',t.name,'rarity',t.rarity,'effect',t.effect,'reserved',EXISTS(SELECT 1 FROM public.ct_market_listings WHERE asset_kind='title' AND asset_id=i.id AND status='active' AND expires_at>now())) x FROM public.ct_player_titles i JOIN public.ct_titles t ON t.id=i.title_id WHERE i.user_id=u AND i.revoked_at IS NULL AND i.quantity=1
 UNION ALL SELECT jsonb_build_object('id',s.id,'kind','chest','definition_id',s.chest_id::text,'name',s.name,'rarity',s.rarity,'weights',s.weights,'reserved',EXISTS(SELECT 1 FROM public.ct_market_listings WHERE asset_kind='chest' AND asset_id=s.id AND status='active' AND expires_at>now())) FROM public.ct_sealed_chests s WHERE s.user_id=u AND s.opened_at IS NULL)x),'[]'::jsonb),
 'sealed_shop',coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'name',name,'rarity',rarity,'price',price,'version',version,'weights',weights) ORDER BY id) FROM public.ct_chest_types WHERE active AND category='standard' AND stock_limit IS NULL AND per_player_limit IS NULL AND(starts_at IS NULL OR starts_at<=now()) AND(ends_at IS NULL OR ends_at>now())),'[]'::jsonb),
 'history',coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.id DESC) FROM(SELECT tr.*,p.username counterparty FROM public.ct_market_trades tr JOIN public.ct_profiles p ON p.id=CASE WHEN tr.seller_id=u THEN tr.buyer_id ELSE tr.seller_id END WHERE tr.seller_id=u OR tr.buyer_id=u ORDER BY tr.id DESC LIMIT 30)x),'[]'::jsonb),
 'transactions',coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.id DESC) FROM(SELECT id,amount,balance_after,reason,created_at FROM public.ct_diamond_ledger WHERE user_id=u ORDER BY id DESC LIMIT 30)x),'[]'::jsonb)) INTO v_result;
 RETURN v_result;
END $$;
CREATE FUNCTION public.ct_admin_diamonds(p_operation_id uuid,p_username text,p_delta bigint,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;v_uid uuid;v_result jsonb;v_request jsonb:=jsonb_build_object('kind','admin_diamonds','username',p_username,'delta',p_delta,'reason',p_reason);
BEGIN
 PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 v_result:=public.ct_replay(u,p_operation_id,v_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 IF p_delta IS NULL OR p_delta=0 OR abs(p_delta::numeric)>1000000000 OR p_reason IS NULL OR length(trim(p_reason)) NOT BETWEEN 8 AND 1000 THEN RAISE EXCEPTION 'Montant ou justification invalide';END IF;
 SELECT id INTO v_uid FROM public.ct_profiles WHERE lower(username)=lower(trim(p_username)) AND NOT is_bot;IF v_uid IS NULL THEN RAISE EXCEPTION 'Joueur introuvable';END IF;
 PERFORM public.ct_post_diamond(v_uid,p_delta,'admin_adjustment','admin:'||p_operation_id::text);
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(u,'diamond_adjustment',v_uid::text,p_reason,jsonb_build_object('amount',p_delta));
 v_result:=jsonb_build_object('ok',true);INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,v_request,v_result);RETURN v_result;
END $$;
REVOKE ALL ON FUNCTION public.ct_market_snapshot(text,bigint),public.ct_admin_diamonds(uuid,text,bigint,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_market_snapshot(text,bigint),public.ct_admin_diamonds(uuid,text,bigint,text) TO authenticated;
CREATE FUNCTION public.ct_sealed_catalog_guard() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF TG_OP='DELETE' OR NEW.rarity IS DISTINCT FROM OLD.rarity THEN
  IF EXISTS(SELECT 1 FROM public.ct_sealed_chests WHERE opened_at IS NULL AND OLD.id=ANY(title_ids)) THEN RAISE EXCEPTION 'Ce titre appartient à des coffres scellés : sa rareté et son existence sont réservées jusqu’à leur ouverture';END IF;
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD;END IF;RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.ct_sealed_catalog_guard() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER ct_sealed_catalog_guard BEFORE DELETE OR UPDATE OF rarity ON public.ct_titles FOR EACH ROW EXECUTE FUNCTION public.ct_sealed_catalog_guard();
COMMIT;
