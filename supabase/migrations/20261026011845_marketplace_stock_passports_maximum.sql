BEGIN;
CREATE FUNCTION public.ct_diamond_maximum(p_mode text DEFAULT 'simulated') RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid:=auth.uid();d jsonb;c jsonb;budget numeric;rate numeric;balance bigint;headroom bigint;lo integer:=0;hi integer:=10000;mid integer;n integer:=0;cost bigint:=0;
BEGIN
 IF u IS NULL OR NOT EXISTS(SELECT 1 FROM public.ct_profiles WHERE id=u AND NOT is_bot) OR EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=u) THEN RAISE EXCEPTION 'Compte joueur actif requis';END IF;
 SELECT 9000000000000-coalesce((SELECT dw.balance FROM public.ct_diamond_wallets dw WHERE dw.user_id=u),0) INTO headroom;hi:=least(10000,headroom);
 IF p_mode='credits' THEN
  c:=public.ct_conversion_access();rate:=(c->>'rate')::numeric;SELECT w.balance INTO balance FROM public.ct_wallets w WHERE w.user_id=u;
  IF(c->>'global_enabled')::boolean AND(c->>'allowed')::boolean AND(c->>'active')::boolean AND NOT(c->>'frozen')::boolean AND(c->>'market_enabled')::boolean THEN n:=least(hi,floor(balance/rate))::integer;cost:=(n*rate)::bigint;END IF;
 ELSIF p_mode='simulated' THEN
  d:=public.ct_card_details(u);rate:=(d->>'eur_per_diamond')::numeric;
  IF(d->>'purchases_enabled')::boolean AND NOT(d->>'wallets_frozen')::boolean AND NOT(d->>'total_cap_reached')::boolean THEN
   budget:=least((d->>'max_purchase_cents')::numeric,(d->>'daily_user_cents')::numeric-(d->>'spent_today_cents')::numeric,coalesce((d->>'weekly_cents')::numeric-(d->>'spent_week_cents')::numeric,9000000000000),(SELECT coalesce(s.total_cap_cents-(SELECT coalesce(sum(total_cents),0) FROM public.ct_simulated_diamond_purchases),9000000000000) FROM public.ct_market_settings s WHERE s.id));
   WHILE lo<hi LOOP mid:=(lo+hi+1)/2;IF round(mid*rate*100)<=budget THEN lo:=mid;ELSE hi:=mid-1;END IF;END LOOP;
   n:=lo;cost:=round(n*rate*100)::bigint;IF cost<coalesce((d->>'min_purchase_cents')::bigint,1) THEN n:=0;cost:=0;END IF;
  END IF;
 ELSE RAISE EXCEPTION 'Invalid filters';END IF;
 RETURN jsonb_build_object('quantity',greatest(0,n),'total',cost,'mode',p_mode);
END $$;
ALTER TABLE public.ct_pm_listings ADD COLUMN tiers jsonb NOT NULL DEFAULT '[]';
CREATE FUNCTION public.ct_pm_validate_tiers(p_tiers jsonb) RETURNS jsonb LANGUAGE plpgsql SET search_path='' AS $$
DECLARE j jsonb:=coalesce(p_tiers,'[]');x jsonb;last_n integer:=1;last_p integer:=0;n integer;p integer;
BEGIN IF jsonb_typeof(j)<>'array' OR jsonb_array_length(j)>8 THEN RAISE EXCEPTION 'Paliers de remise invalides';END IF;
 FOR x IN SELECT value FROM jsonb_array_elements(j) LOOP n:=(x->>'min')::integer;p:=(x->>'percent')::integer;IF n IS NULL OR p IS NULL OR n<=last_n OR n>100 OR p NOT BETWEEN 1 AND 5 OR p<last_p THEN RAISE EXCEPTION USING MESSAGE='Paliers croissants, remise de 1 à 5 % maximum';END IF;last_n:=n;last_p:=p;END LOOP;RETURN j;END $$;
CREATE OR REPLACE FUNCTION public.ct_pm_quote(p_listing bigint,p_quantity integer DEFAULT 1) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE l public.ct_pm_listings;cost bigint;fee bigint;discount integer;unit bigint;BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required';END IF;
 SELECT * INTO l FROM public.ct_pm_listings WHERE id=p_listing AND status='active' AND NOT EXISTS(SELECT 1 FROM public.ct_pm_seller_blocks WHERE user_id=seller_id) AND NOT EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=seller_id);
 IF l.id IS NULL OR p_quantity IS NULL OR p_quantity NOT BETWEEN 1 AND l.remaining THEN RAISE EXCEPTION 'Offre ou quantité indisponible';END IF;
 SELECT coalesce(max((x->>'percent')::integer),0) INTO discount FROM jsonb_array_elements(l.tiers)x WHERE(x->>'min')::integer<=p_quantity;unit:=greatest(1,round(l.unit_price::numeric*(100-discount)/100));cost:=unit*p_quantity;fee:=(cost+9)/10;
 RETURN to_jsonb(l)||jsonb_build_object('quantity',p_quantity,'effective_unit_price',unit,'discount_percent',discount,'subtotal',cost,'fee',fee,'total',cost,'seller_net',cost-fee,'token',md5(jsonb_build_array(l.id,l.version,l.tiers,p_quantity,cost,fee)::text));END $$;

CREATE TABLE public.ct_chest_provenance(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,chest_id uuid NOT NULL,event_key text NOT NULL UNIQUE,event text NOT NULL CHECK(event IN('created','issued','purchase','transfer')),from_user uuid,to_user uuid,from_name text,to_name text,source text NOT NULL,order_number text,created_at timestamptz NOT NULL,transaction_id bigint);
CREATE INDEX ct_chest_provenance_chest ON public.ct_chest_provenance(chest_id,id DESC);
ALTER TABLE public.ct_chest_provenance ENABLE ROW LEVEL SECURITY;REVOKE ALL ON public.ct_chest_provenance FROM PUBLIC,anon,authenticated;REVOKE ALL ON SEQUENCE public.ct_chest_provenance_id_seq FROM PUBLIC,anon,authenticated;
INSERT INTO public.ct_chest_provenance(chest_id,event_key,event,source,created_at) SELECT id,'creation:'||id,'created','inventory',created_at FROM public.ct_sealed_chests;
INSERT INTO public.ct_chest_provenance(chest_id,event_key,event,to_user,to_name,source,created_at) SELECT p.asset_id,'shop:'||p.id,'purchase',p.user_id,pr.username,'shop',p.created_at FROM public.ct_chest_purchases p LEFT JOIN public.ct_profiles pr ON pr.id=p.user_id;
INSERT INTO public.ct_chest_provenance(chest_id,event_key,event,from_user,to_user,from_name,to_name,source,created_at) SELECT l.asset_id,'black-trade:'||t.id,'purchase',t.seller_id,t.buyer_id,s.username,b.username,'black',t.created_at FROM public.ct_market_trades t JOIN public.ct_market_listings l ON l.id=t.listing_id LEFT JOIN public.ct_profiles s ON s.id=t.seller_id LEFT JOIN public.ct_profiles b ON b.id=t.buyer_id WHERE t.offered_kind='chest';
INSERT INTO public.ct_chest_provenance(chest_id,event_key,event,from_user,to_user,from_name,to_name,source,created_at) SELECT a,'stock-trade:'||t.id||':'||a,'purchase',t.seller_id,t.buyer_id,s.username,b.username,'black',t.created_at FROM public.ct_wholesale_trades t CROSS JOIN LATERAL unnest(t.asset_ids)a LEFT JOIN public.ct_profiles s ON s.id=t.seller_id LEFT JOIN public.ct_profiles b ON b.id=t.buyer_id;
INSERT INTO public.ct_chest_provenance(chest_id,event_key,event,from_user,to_user,from_name,to_name,source,order_number,created_at) SELECT (a->>'received_asset')::uuid,'pm-order:'||o.id||':'||(a->>'received_asset'),'purchase',o.seller_id,o.buyer_id,o.seller_name,o.buyer_name,'player',o.order_number,o.created_at FROM public.ct_orders o CROSS JOIN LATERAL jsonb_array_elements(coalesce(o.proof->'assets','[]'))a WHERE o.market='player' AND o.item_kind='chest';
CREATE FUNCTION public.ct_chest_track() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN IF TG_OP='INSERT' THEN INSERT INTO public.ct_chest_provenance(chest_id,event_key,event,to_user,to_name,source,created_at,transaction_id) VALUES(NEW.id,'creation:'||NEW.id,'issued',NEW.user_id,(SELECT username FROM public.ct_profiles WHERE id=NEW.user_id),'inventory',NEW.created_at,txid_current());
 ELSIF NEW.user_id IS DISTINCT FROM OLD.user_id THEN INSERT INTO public.ct_chest_provenance(chest_id,event_key,event,from_user,to_user,from_name,to_name,source,created_at,transaction_id) VALUES(NEW.id,'transfer:'||gen_random_uuid(),'transfer',OLD.user_id,NEW.user_id,(SELECT username FROM public.ct_profiles WHERE id=OLD.user_id),(SELECT username FROM public.ct_profiles WHERE id=NEW.user_id),'trade',clock_timestamp(),txid_current());END IF;RETURN NEW;END $$;
CREATE TRIGGER ct_chest_track AFTER INSERT OR UPDATE OF user_id ON public.ct_sealed_chests FOR EACH ROW EXECUTE FUNCTION public.ct_chest_track();
CREATE FUNCTION public.ct_chest_shop_track() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN INSERT INTO public.ct_chest_provenance(chest_id,event_key,event,to_user,to_name,source,created_at,transaction_id) VALUES(NEW.asset_id,'shop:'||NEW.id,'purchase',NEW.user_id,(SELECT username FROM public.ct_profiles WHERE id=NEW.user_id),'shop',NEW.created_at,txid_current());RETURN NEW;END $$;
CREATE TRIGGER ct_chest_shop_track AFTER INSERT ON public.ct_chest_purchases FOR EACH ROW EXECUTE FUNCTION public.ct_chest_shop_track();
CREATE FUNCTION public.ct_chest_order_track() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NEW.item_kind='chest' THEN UPDATE public.ct_chest_provenance SET event='purchase',source=NEW.market,order_number=NEW.order_number WHERE transaction_id=txid_current() AND from_user=NEW.seller_id AND to_user=NEW.buyer_id AND event='transfer';END IF;RETURN NEW;
END $$;
CREATE TRIGGER ct_chest_order_track AFTER INSERT ON public.ct_orders FOR EACH ROW EXECUTE FUNCTION public.ct_chest_order_track();
CREATE FUNCTION public.ct_chest_passport(p_chest uuid,p_before bigint DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE s public.ct_sealed_chests;u uuid:=auth.uid();BEGIN
 IF u IS NULL THEN RAISE EXCEPTION 'Authentication required';END IF;SELECT * INTO s FROM public.ct_sealed_chests WHERE id=p_chest;
 IF s.id IS NULL OR NOT(s.user_id=u OR public.ct_is_admin() OR EXISTS(SELECT 1 FROM public.ct_pm_assets a JOIN public.ct_pm_listings l ON l.id=a.listing_id WHERE a.asset_id=s.id AND NOT a.sold AND l.status='active' AND NOT EXISTS(SELECT 1 FROM public.ct_pm_seller_blocks WHERE user_id=l.seller_id) AND NOT EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=l.seller_id)) OR(public.ct_circle_member(u) AND(EXISTS(SELECT 1 FROM public.ct_market_listings WHERE asset_kind='chest' AND asset_id=s.id AND status='active' AND expires_at>now() AND(target_id IS NULL OR target_id=u)) OR EXISTS(SELECT 1 FROM public.ct_wholesale_assets a JOIN public.ct_wholesale_offers o ON o.id=a.offer_id WHERE a.asset_id=s.id AND NOT a.sold AND o.status='active' AND o.expires_at>now())))) THEN RAISE EXCEPTION 'Coffre introuvable';END IF;
 RETURN jsonb_build_object('id',s.id,'name',s.name,'rarity',s.rarity,'created_at',s.created_at,'opened_at',s.opened_at,'history',coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC,x.id DESC) FROM(SELECT id,event,from_name,to_name,source,order_number,created_at FROM public.ct_chest_provenance WHERE chest_id=s.id AND(p_before IS NULL OR id<p_before) ORDER BY id DESC LIMIT 20)x),'[]'::jsonb));END $$;
CREATE FUNCTION public.ct_pm_chest_serials(p_listing bigint) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN PERFORM public.ct_pm_quote(p_listing,1);RETURN coalesce((SELECT jsonb_agg(asset_id ORDER BY asset_id) FROM public.ct_pm_assets WHERE listing_id=p_listing AND kind='chest' AND NOT sold),'[]'::jsonb);END $$;
REVOKE ALL ON FUNCTION public.ct_diamond_maximum(text),public.ct_pm_validate_tiers(jsonb),public.ct_chest_track(),public.ct_chest_shop_track(),public.ct_chest_order_track(),public.ct_chest_passport(uuid,bigint),public.ct_pm_chest_serials(bigint) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_diamond_maximum(text),public.ct_chest_passport(uuid,bigint),public.ct_pm_chest_serials(bigint) TO authenticated;

CREATE OR REPLACE FUNCTION public.ct_pm_command(p_operation_id uuid,p_action text,p_values jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;request jsonb:=jsonb_build_object('kind','player_market','action',p_action,'values',p_values);l public.ct_pm_listings;a uuid;ids uuid[];info jsonb;first_info jsonb;c public.ct_sealed_chests;cost bigint;fee bigint;price bigint;oid bigint;n integer;quote jsonb;buyer_tx jsonb;seller_tx jsonb;new_asset uuid;received jsonb:='[]';t text;
BEGIN
 PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,request);IF r IS NOT NULL THEN RETURN r;END IF;PERFORM public.ct_check_rate(u);
 IF p_action='create' THEN
  IF EXISTS(SELECT 1 FROM public.ct_pm_seller_blocks WHERE user_id=u) THEN RAISE EXCEPTION 'Votre boutique est suspendue';END IF;
  IF(SELECT count(*) FROM public.ct_pm_listings WHERE seller_id=u AND status='active')>=100 THEN RAISE EXCEPTION '100 annonces actives maximum';END IF;
  IF jsonb_typeof(p_values->'asset_ids') IS DISTINCT FROM 'array' OR jsonb_array_length(p_values->'asset_ids') NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Choisissez 1 à 100 objets';END IF;
  SELECT array_agg(x::uuid) INTO ids FROM jsonb_array_elements_text(p_values->'asset_ids')x;
  IF cardinality(ids)<>(SELECT count(DISTINCT x) FROM unnest(ids)x) THEN RAISE EXCEPTION 'Exemplaire en double';END IF;
  IF p_values->>'kind' NOT IN('title','chest') OR(p_values->>'kind'='title' AND cardinality(ids)<>1) THEN RAISE EXCEPTION 'Objet demandé invalide';END IF;
  price:=(p_values->>'price')::bigint;IF price IS NULL OR price NOT BETWEEN 1 AND 1000000000 THEN RAISE EXCEPTION 'Prix en crédits invalide';END IF;
  FOREACH a IN ARRAY ids LOOP
   IF public.ct_direct_reserved(p_values->>'kind',a) OR EXISTS(SELECT 1 FROM public.ct_market_listings WHERE asset_kind=p_values->>'kind' AND asset_id=a AND status='active' AND expires_at>now()) THEN RAISE EXCEPTION 'Objet déjà réservé';END IF;
   info:=public.ct_market_asset(u,p_values->>'kind',a);IF first_info IS NULL THEN first_info:=info;ELSIF info<>first_info THEN RAISE EXCEPTION 'Choisissez des objets identiques pour ce lot';END IF;
   IF p_values->>'kind'='chest' THEN IF c.id IS NULL THEN SELECT * INTO c FROM public.ct_sealed_chests WHERE id=a;ELSIF NOT EXISTS(SELECT 1 FROM public.ct_sealed_chests WHERE id=a AND weights=c.weights AND title_ids=c.title_ids) THEN RAISE EXCEPTION 'Choisissez des objets identiques pour ce lot';END IF;END IF;
  END LOOP;
  INSERT INTO public.ct_pm_listings(seller_id,kind,definition_id,name,rarity,unit_price,remaining,tiers) VALUES(u,p_values->>'kind',first_info->>'definition_id',first_info->>'name',(first_info->>'rarity')::smallint,price,cardinality(ids),public.ct_pm_validate_tiers(p_values->'tiers')) RETURNING * INTO l;
  INSERT INTO public.ct_pm_assets(listing_id,kind,asset_id) SELECT l.id,l.kind,x FROM unnest(ids)x;
  IF l.kind='title' THEN DELETE FROM public.ct_equipped_titles WHERE player_title_id=ANY(ids);END IF;
 ELSIF p_action IN('cancel','price') THEN
  SELECT * INTO l FROM public.ct_pm_listings WHERE id=(p_values->>'id')::bigint FOR UPDATE;
  IF l.id IS NULL OR l.seller_id<>u OR l.status<>'active' THEN RAISE EXCEPTION 'Annonce indisponible';END IF;
  IF l.version IS DISTINCT FROM(p_values->>'version')::bigint THEN RAISE EXCEPTION 'Annonce modifiée. Actualisez.';END IF;
  IF p_action='cancel' THEN UPDATE public.ct_pm_listings SET status='cancelled',version=version+1 WHERE id=l.id;DELETE FROM public.ct_pm_assets WHERE listing_id=l.id AND NOT sold;
  ELSE price:=(p_values->>'price')::bigint;IF price IS NULL OR price NOT BETWEEN 1 AND 1000000000 THEN RAISE EXCEPTION 'Prix en crédits invalide';END IF;UPDATE public.ct_pm_listings SET unit_price=price,version=version+1 WHERE id=l.id;END IF;
 ELSIF p_action='buy' THEN
  SELECT * INTO l FROM public.ct_pm_listings WHERE id=(p_values->>'id')::bigint FOR UPDATE;
  IF l.seller_id=u THEN RAISE EXCEPTION 'Vous ne pouvez pas acheter votre propre annonce';END IF;
  n:=(p_values->>'quantity')::integer;quote:=public.ct_pm_quote(l.id,n);cost:=(quote->>'total')::bigint;fee:=(quote->>'fee')::bigint;
  IF p_values->>'token' IS DISTINCT FROM quote->>'token' OR(p_values->>'total')::bigint IS DISTINCT FROM cost THEN RAISE EXCEPTION 'Stock ou prix modifié. Vérifiez le nouveau total';END IF;
  PERFORM 1 FROM public.ct_wallets WHERE user_id=l.seller_id FOR UPDATE;
  SELECT array_agg(asset_id ORDER BY asset_id) INTO ids FROM(SELECT asset_id FROM public.ct_pm_assets WHERE listing_id=l.id AND NOT sold ORDER BY asset_id LIMIT n FOR UPDATE)x;
  IF cardinality(ids) IS DISTINCT FROM n THEN RAISE EXCEPTION 'Stock réservé indisponible';END IF;
  buyer_tx:=public.ct_post_credit(u,-cost,'player_market_purchase','pm-buy:'||p_operation_id::text);
  IF cost-fee>0 THEN seller_tx:=public.ct_post_credit(l.seller_id,cost-fee,'player_market_sale','pm-sale:'||p_operation_id::text);END IF;
  UPDATE public.ct_pm_assets SET sold=true WHERE listing_id=l.id AND asset_id=ANY(ids);
  UPDATE public.ct_pm_listings SET remaining=remaining-n,version=version+1,status=CASE WHEN remaining=n THEN 'sold' ELSE 'active' END WHERE id=l.id;
  FOREACH a IN ARRAY ids LOOP
   PERFORM public.ct_market_asset(l.seller_id,l.kind,a);
   IF l.kind='title' THEN SELECT title_id INTO t FROM public.ct_player_titles WHERE id=a;DELETE FROM public.ct_equipped_titles WHERE player_title_id=a;UPDATE public.ct_player_titles SET revoked_at=now() WHERE id=a;INSERT INTO public.ct_player_titles(user_id,title_id,source) VALUES(u,t,'player-market:'||l.id) RETURNING id INTO new_asset;
   ELSE UPDATE public.ct_sealed_chests SET user_id=u WHERE id=a;new_asset:=a;END IF;
   received:=received||jsonb_build_object('from_asset',a,'received_asset',new_asset);
  END LOOP;
  oid:=public.ct_order_insert('pm:'||u||':'||p_operation_id,'player',u,l.seller_id,l.kind,l.name,l.definition_id,l.rarity,n,cost,fee,jsonb_build_array(jsonb_build_object('name',l.name,'kind',l.kind,'quantity',n,'unit_price',(quote->>'effective_unit_price')::bigint,'subtotal',cost)),jsonb_build_object('operation_id',p_operation_id,'listing_id',l.id,'buyer_transaction',buyer_tx,'seller_transaction',seller_tx,'assets',received));
 ELSE RAISE EXCEPTION 'Action inconnue';END IF;
 r:=jsonb_build_object('ok',true,'listing_id',l.id,'order_id',oid);INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,request,r);RETURN r;
END $$;
CREATE FUNCTION public.ct_admin_seed_pm_stock(p_operation_id uuid,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;request jsonb:=jsonb_build_object('kind','player_market_stock_v1','reason',p_reason);batch uuid;npc uuid;vendor text;base text;names text[]:=ARRAY['Aether','Sable','Rune','Wisp','Fable','Lumen','Cinder','Dusk','Zephyr','Vex','Nyx','Riven','Frost','Solace','Vanta','Echo','Flint','Vale','Onyx','Cove','Rook','Serein','Oriel','Haze','Cairn','Fennec','Vireo','Morrow','Nacre','Lucent','Thorne','Silvan','Kairo','Eon','Talon','Eldric','Alaris','Vesper','Halcyon','Ashen','Astral','Briar','Nox','Wren','Aerith','Esker','Viridian','Umber','Kestrel','Sonder'];i integer;j integer;k integer;rar integer;n integer;price bigint;base_price bigint;t public.ct_titles;c public.ct_chest_types;asset uuid;listing bigint;pool text[];offers integer:=0;chests integer:=0;
BEGIN
 PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required';END IF;r:=public.ct_replay(u,p_operation_id,request);IF r IS NOT NULL THEN RETURN r;END IF;
 IF length(trim(coalesce(p_reason,''))) NOT BETWEEN 8 AND 1000 THEN RAISE EXCEPTION 'Justification administrateur requise';END IF;
 SELECT id INTO batch FROM public.ct_bot_batches WHERE config->>'player_market_stock'='v1' ORDER BY created_at LIMIT 1;
 IF batch IS NOT NULL THEN r:=jsonb_build_object('ok',true,'already_seeded',true,'batch_id',batch);
 ELSE
  INSERT INTO public.ct_bot_batches(admin_id,config) VALUES(u,'{"player_market_stock":"v1","finite_stock":true,"seller_count":50,"reviews_generated":false,"trades_generated":false}') RETURNING id INTO batch;
  FOR i IN 1..50 LOOP
   base:=names[i];vendor:=base;WHILE EXISTS(SELECT 1 FROM public.ct_profiles WHERE lower(username)=lower(vendor)) LOOP vendor:=base||'_'||substr(replace(gen_random_uuid()::text,'-',''),1,4);END LOOP;
   npc:=gen_random_uuid();INSERT INTO public.ct_profiles(id,username,avatar,is_bot) VALUES(npc,vendor,(ARRAY['✦','♛','♠','🌙','🦊'])[1+(i%5)],true);
   INSERT INTO public.ct_wallets(user_id,balance) VALUES(npc,0);INSERT INTO public.ct_bots(user_id,batch_id,max_rarity) VALUES(npc,batch,7);INSERT INTO public.ct_bot_summaries(user_id,games,wins,chests,chest_spending,bet) VALUES(npc,0,0,0,0,100);INSERT INTO public.ct_preferences(user_id,leaderboard_hidden) VALUES(npc,true);
   FOR j IN 1..12 LOOP
    rar:=(ARRAY[1,2,2,3,3,3,4,4,5,5,6,3])[j];IF j=12 AND i%10=0 THEN rar:=7;END IF;
    SELECT * INTO t FROM public.ct_titles WHERE available AND NOT exclusive AND rarity=rar ORDER BY md5(id||':'||i||':'||j) LIMIT 1;IF t.id IS NULL THEN RAISE EXCEPTION 'Catalogue incomplet';END IF;
    SELECT coalesce(t.shop_price,(SELECT min(shop_price) FROM public.ct_titles WHERE rarity=rar AND shop_price IS NOT NULL),CASE rar WHEN 1 THEN 1200 WHEN 2 THEN 4000 WHEN 3 THEN 15000 WHEN 4 THEN 75000 WHEN 5 THEN 200000 WHEN 6 THEN 800000 ELSE 3000000 END) INTO base_price;
    price:=greatest(1,base_price*(96+((i+j)%4))/100);
    INSERT INTO public.ct_player_titles(user_id,title_id,source) VALUES(npc,t.id,'admin:player_market_stock') RETURNING id INTO asset;
    INSERT INTO public.ct_pm_listings(seller_id,kind,definition_id,name,rarity,unit_price,remaining) VALUES(npc,'title',t.id,t.name,t.rarity,price,1) RETURNING id INTO listing;
    INSERT INTO public.ct_pm_assets(listing_id,kind,asset_id) VALUES(listing,'title',asset);offers:=offers+1;
   END LOOP;
   FOR j IN 1..3 LOOP
    SELECT * INTO c FROM public.ct_chest_types WHERE active AND category='standard' AND rarity BETWEEN 1 AND 7 ORDER BY id OFFSET((i+j)%7) LIMIT 1;IF c.id IS NULL THEN RAISE EXCEPTION 'Coffre indisponible';END IF;
    SELECT array_agg(id ORDER BY id) INTO pool FROM public.ct_titles WHERE available AND(NOT exclusive OR c.allow_exclusive) AND(c.title_pool IS NULL OR id=ANY(c.title_pool));
    FOR k IN 1..8 LOOP IF c.weights[k]>0 AND NOT EXISTS(SELECT 1 FROM public.ct_titles WHERE id=ANY(pool) AND rarity=k) THEN RAISE EXCEPTION 'Catalogue du coffre incomplet';END IF;END LOOP;
    n:=12+((i*7+j*3)%29);price:=greatest(1,c.price*(96+((i+j)%4))/100);
    INSERT INTO public.ct_pm_listings(seller_id,kind,definition_id,name,rarity,unit_price,remaining,tiers) VALUES(npc,'chest',c.id::text,c.name,c.rarity,price,n,'[{"min":10,"percent":1},{"min":25,"percent":2},{"min":40,"percent":3}]') RETURNING id INTO listing;
    FOR k IN 1..n LOOP INSERT INTO public.ct_sealed_chests(user_id,chest_id,name,rarity,weights,title_ids,purchase_price) VALUES(npc,c.id,c.name,c.rarity,c.weights,pool,0) RETURNING id INTO asset;INSERT INTO public.ct_pm_assets(listing_id,kind,asset_id) VALUES(listing,'chest',asset);END LOOP;
    offers:=offers+1;chests:=chests+n;
   END LOOP;
  END LOOP;
  INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(u,'player_market_stock',batch::text,p_reason,jsonb_build_object('sellers',50,'title_offers',600,'chest_offers',150,'chest_instances',chests,'offers',offers));
  r:=jsonb_build_object('ok',true,'already_seeded',false,'batch_id',batch,'sellers',50,'title_offers',600,'chest_offers',150,'chest_instances',chests);
 END IF;
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,request,r);RETURN r;
END $$;
REVOKE ALL ON FUNCTION public.ct_admin_seed_pm_stock(uuid,text) FROM PUBLIC,anon,authenticated;GRANT EXECUTE ON FUNCTION public.ct_admin_seed_pm_stock(uuid,text) TO authenticated;
COMMIT;

