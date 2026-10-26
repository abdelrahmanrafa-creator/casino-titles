BEGIN;
CREATE TABLE public.ct_pm_listings(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,seller_id uuid NOT NULL REFERENCES public.ct_profiles(id) ON DELETE CASCADE,kind text NOT NULL CHECK(kind IN('title','chest')),definition_id text NOT NULL,name text NOT NULL,rarity smallint NOT NULL,unit_price bigint NOT NULL CHECK(unit_price BETWEEN 1 AND 1000000000),remaining integer NOT NULL CHECK(remaining BETWEEN 0 AND 100),status text NOT NULL DEFAULT 'active' CHECK(status IN('active','sold','cancelled')),version bigint NOT NULL DEFAULT 1,created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.ct_pm_assets(listing_id bigint NOT NULL REFERENCES public.ct_pm_listings(id) ON DELETE CASCADE,kind text NOT NULL,asset_id uuid NOT NULL,sold boolean NOT NULL DEFAULT false,PRIMARY KEY(listing_id,asset_id));
CREATE UNIQUE INDEX ct_pm_reserved_asset ON public.ct_pm_assets(kind,asset_id) WHERE NOT sold;
CREATE INDEX ct_pm_assets_listing ON public.ct_pm_assets(listing_id);
CREATE INDEX ct_pm_seller ON public.ct_pm_listings(seller_id,id DESC);
CREATE INDEX ct_pm_active ON public.ct_pm_listings(kind,unit_price,id) WHERE status='active';
CREATE TABLE public.ct_pm_seller_blocks(user_id uuid PRIMARY KEY REFERENCES public.ct_profiles(id) ON DELETE CASCADE,reason text NOT NULL,created_at timestamptz NOT NULL DEFAULT now());
-- Order snapshots deliberately have no profile, listing or inventory foreign keys.
-- Deleting an account or withdrawing a listing must never erase a receipt.
CREATE TABLE public.ct_orders(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,order_number text NOT NULL UNIQUE,source_key text NOT NULL UNIQUE,market text NOT NULL CHECK(market IN('player','black')),currency text NOT NULL CHECK(currency IN('credits','diamonds')),buyer_id uuid NOT NULL,seller_id uuid NOT NULL,buyer_name text NOT NULL,seller_name text NOT NULL,item_kind text NOT NULL,item_name text NOT NULL,definition_id text,rarity smallint NOT NULL DEFAULT 1,quantity integer NOT NULL CHECK(quantity>0),subtotal bigint NOT NULL CHECK(subtotal>=0),fee bigint NOT NULL CHECK(fee>=0),total bigint NOT NULL CHECK(total>=0),seller_net bigint NOT NULL CHECK(seller_net>=0),fee_side text NOT NULL CHECK(fee_side IN('buyer','seller')),lines jsonb NOT NULL,proof jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),CHECK(buyer_id<>seller_id));
CREATE INDEX ct_orders_buyer ON public.ct_orders(buyer_id,created_at DESC,id DESC);
CREATE INDEX ct_orders_seller ON public.ct_orders(seller_id,market,id DESC);
CREATE INDEX ct_orders_product ON public.ct_orders(market,item_kind,definition_id);
CREATE TABLE public.ct_pm_reviews(order_id bigint PRIMARY KEY REFERENCES public.ct_orders(id),buyer_id uuid NOT NULL,seller_id uuid NOT NULL,rating smallint NOT NULL CHECK(rating BETWEEN 1 AND 5),comment text NOT NULL CHECK(length(comment)<=1000),hidden boolean NOT NULL DEFAULT false,created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX ct_pm_reviews_seller ON public.ct_pm_reviews(seller_id,created_at DESC);
CREATE TABLE public.ct_order_disputes(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,order_id bigint NOT NULL REFERENCES public.ct_orders(id),user_id uuid NOT NULL,issue text NOT NULL CHECK(issue IN('missing','wrong','payment','seller','other')),ticket_id bigint UNIQUE REFERENCES public.ct_support_tickets(id) ON DELETE SET NULL,created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(order_id,user_id));
CREATE INDEX ct_order_disputes_order ON public.ct_order_disputes(order_id);
CREATE TABLE public.ct_order_corrections(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,order_id bigint NOT NULL REFERENCES public.ct_orders(id),admin_id uuid NOT NULL,target_id uuid NOT NULL,currency text NOT NULL,amount bigint NOT NULL CHECK(amount<>0),reason text NOT NULL,transaction_ref text NOT NULL,created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX ct_order_corrections_order ON public.ct_order_corrections(order_id);
DO $$ DECLARE t text;BEGIN FOREACH t IN ARRAY ARRAY['ct_pm_listings','ct_pm_assets','ct_pm_seller_blocks','ct_orders','ct_pm_reviews','ct_order_disputes','ct_order_corrections'] LOOP EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC,anon,authenticated',t);END LOOP;END $$;
REVOKE ALL ON SEQUENCE public.ct_pm_listings_id_seq,public.ct_orders_id_seq,public.ct_order_disputes_id_seq,public.ct_order_corrections_id_seq FROM PUBLIC,anon,authenticated;

ALTER FUNCTION public.ct_direct_reserved(text,uuid,uuid) RENAME TO ct_direct_reserved_before_player_market;
CREATE FUNCTION public.ct_direct_reserved(p_kind text,p_asset uuid,p_except uuid DEFAULT NULL) RETURNS boolean LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT public.ct_direct_reserved_before_player_market(p_kind,p_asset,p_except) OR EXISTS(SELECT 1 FROM public.ct_pm_assets a JOIN public.ct_pm_listings l ON l.id=a.listing_id WHERE a.kind=p_kind AND a.asset_id=p_asset AND NOT a.sold AND l.status='active');
$$;
REVOKE ALL ON FUNCTION public.ct_direct_reserved(text,uuid,uuid),public.ct_direct_reserved_before_player_market(text,uuid,uuid) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.ct_order_insert(p_source text,p_market text,p_buyer uuid,p_seller uuid,p_kind text,p_name text,p_definition text,p_rarity smallint,p_quantity integer,p_subtotal bigint,p_fee bigint,p_lines jsonb,p_proof jsonb,p_date timestamptz DEFAULT now()) RETURNS bigint LANGUAGE plpgsql SET search_path='' AS $$
DECLARE n bigint;bn text;sn text;
BEGIN
 SELECT id INTO n FROM public.ct_orders WHERE source_key=p_source;IF n IS NOT NULL THEN RETURN n;END IF;
 SELECT username INTO bn FROM public.ct_profiles WHERE id=p_buyer;SELECT username INTO sn FROM public.ct_profiles WHERE id=p_seller;
 n:=nextval('public.ct_orders_id_seq');
 INSERT INTO public.ct_orders(id,order_number,source_key,market,currency,buyer_id,seller_id,buyer_name,seller_name,item_kind,item_name,definition_id,rarity,quantity,subtotal,fee,total,seller_net,fee_side,lines,proof,created_at) OVERRIDING SYSTEM VALUE
 VALUES(n,CASE WHEN p_market='player' THEN 'MK-' ELSE 'BM-' END||to_char(p_date AT TIME ZONE 'UTC','YYYY')||'-'||lpad(n::text,6,'0'),p_source,p_market,CASE WHEN p_market='player' THEN 'credits' ELSE 'diamonds' END,p_buyer,p_seller,coalesce(bn,'Compte supprimé'),coalesce(sn,'Compte supprimé'),p_kind,p_name,p_definition,p_rarity,p_quantity,p_subtotal,p_fee,CASE WHEN p_market='player' THEN p_subtotal ELSE p_subtotal+p_fee END,CASE WHEN p_market='player' THEN p_subtotal-p_fee ELSE p_subtotal END,CASE WHEN p_market='player' THEN 'seller' ELSE 'buyer' END,p_lines,p_proof,p_date);RETURN n;
END $$;
-- Capture completed Black Market operations without changing their prices or fees.
CREATE FUNCTION public.ct_black_order(p_operation uuid,p_buyer uuid,p_group_quote jsonb DEFAULT NULL) RETURNS bigint LANGUAGE plpgsql SET search_path='' AS $$
DECLARE op public.ct_operations;l public.ct_market_listings;w public.ct_wholesale_offers;c public.ct_credit_offers;seller uuid;kind text;name text;definition text;rar smallint:=1;qty integer:=1;subtotal bigint;charge bigint:=0;key text;proof jsonb;lines jsonb;oid bigint;pay public.ct_diamond_ledger;sale public.ct_diamond_ledger;
BEGIN
 SELECT id INTO oid FROM public.ct_orders WHERE source_key='black:'||p_buyer||':'||p_operation;IF oid IS NOT NULL THEN RETURN oid;END IF;
 SELECT * INTO op FROM public.ct_operations WHERE user_id=p_buyer AND operation_id=p_operation;IF op.operation_id IS NULL THEN RETURN NULL;END IF;
 IF op.request->>'kind'='market' AND op.request->>'action'='accept' THEN
  SELECT * INTO l FROM public.ct_market_listings WHERE id=(op.request->'values'->>'listing_id')::bigint AND status='sold' AND buyer_id=p_buyer;IF l.id IS NULL THEN RETURN NULL;END IF;
  seller:=l.seller_id;kind:=l.asset_kind;name:=l.name;definition:=l.definition_id;rar:=l.rarity;subtotal:=l.price;key:='market:'||p_operation;proof:=jsonb_build_object('listing_id',l.id,'source_asset',l.asset_id,'barter_kind',l.wanted_kind,'barter_definition',l.wanted_id,'payment_asset',op.request->'values'->'payment_asset_id');
 ELSIF op.request->>'kind'='wholesale' AND op.request->>'action'='buy' THEN
  SELECT * INTO w FROM public.ct_wholesale_offers WHERE id=(op.request->'values'->>'id')::uuid;IF w.id IS NULL THEN RETURN NULL;END IF;
  seller:=w.seller_id;kind:='chest';name:=w.name;definition:=w.chest_id::text;rar:=w.rarity;qty:=(op.request->'values'->>'quantity')::integer;subtotal:=(op.result->>'total')::bigint;key:='wholesale:'||p_operation;proof:=jsonb_build_object('stock_id',w.id,'version',op.request->'values'->'version');
 ELSIF op.request->>'kind'='credit_market' AND op.request->>'action'='buy' THEN
  SELECT * INTO c FROM public.ct_credit_offers WHERE id=(op.request->'values'->>'id')::bigint AND status='sold' AND buyer_id=p_buyer;IF c.id IS NULL THEN RETURN NULL;END IF;
  seller:=c.seller_id;kind:='credits';name:='Lot de crédits';qty:=c.amount;subtotal:=c.price;key:='credit-market:'||p_operation;proof:=jsonb_build_object('credit_offer',c.id,'credits',c.amount);
 ELSIF op.request->>'kind'='market_chest_group' THEN
  key:='market-group:'||p_operation;SELECT * INTO sale FROM public.ct_diamond_ledger WHERE operation_key=key AND reason='market_sale' AND amount>0;IF sale.id IS NULL THEN RETURN NULL;END IF;
  seller:=sale.user_id;kind:='chest';qty:=(op.request->>'quantity')::integer;subtotal:=sale.amount;name:=coalesce(p_group_quote->>'name',(SELECT offered_name FROM public.ct_market_trades WHERE buyer_id=p_buyer AND seller_id=seller AND created_at=op.created_at ORDER BY id LIMIT 1),(SELECT o.name FROM public.ct_wholesale_trades t JOIN public.ct_wholesale_offers o ON o.id=t.offer_id WHERE t.buyer_id=p_buyer AND t.seller_id=seller AND t.created_at=op.created_at ORDER BY t.id LIMIT 1),'Lot de coffres');proof:=jsonb_build_object('group_key',op.request->>'group','parts',p_group_quote->'parts');
  SELECT ml.rarity,ml.definition_id INTO rar,definition FROM public.ct_market_trades mt JOIN public.ct_market_listings ml ON ml.id=mt.listing_id WHERE mt.buyer_id=p_buyer AND mt.seller_id=seller AND mt.created_at=op.created_at ORDER BY mt.id LIMIT 1;IF rar IS NULL THEN SELECT wo.rarity,wo.chest_id::text INTO rar,definition FROM public.ct_wholesale_trades wt JOIN public.ct_wholesale_offers wo ON wo.id=wt.offer_id WHERE wt.buyer_id=p_buyer AND wt.seller_id=seller AND wt.created_at=op.created_at ORDER BY wt.id LIMIT 1;END IF;rar:=coalesce(rar,1);
 ELSE RETURN NULL;END IF;
 SELECT * INTO pay FROM public.ct_diamond_ledger WHERE user_id=p_buyer AND operation_key=key AND reason='market_purchase';
 IF subtotal>0 AND(pay.id IS NULL OR -pay.amount<>subtotal) THEN RETURN NULL;END IF;
 SELECT coalesce(-amount,0) INTO charge FROM public.ct_diamond_ledger WHERE user_id=p_buyer AND operation_key=key||':fee' AND reason='market_fee';charge:=coalesce(charge,0);
 IF sale.id IS NULL THEN SELECT * INTO sale FROM public.ct_diamond_ledger WHERE user_id=seller AND operation_key=key AND reason='market_sale';END IF;
 IF subtotal>0 AND(sale.id IS NULL OR sale.amount<>subtotal) THEN RETURN NULL;END IF;
 lines:=jsonb_build_array(jsonb_build_object('kind',kind,'name',name,'quantity',qty,'subtotal',subtotal));
 IF l.wanted_kind IS NOT NULL THEN lines:=lines||jsonb_build_object('kind',l.wanted_kind,'role','barter_payment','quantity',1,'name',coalesce((SELECT name FROM public.ct_titles WHERE l.wanted_kind='title' AND id=l.wanted_id),(SELECT name FROM public.ct_chest_types WHERE l.wanted_kind='chest' AND id::text=l.wanted_id),l.wanted_id));END IF;
 RETURN public.ct_order_insert('black:'||p_buyer||':'||p_operation,'black',p_buyer,seller,kind,name,definition,rar,qty,subtotal,charge,lines,proof||jsonb_build_object('operation_id',p_operation,'payment_ledger',pay.id,'seller_ledger',sale.id,'payment_key',key),op.created_at);
END $$;

CREATE FUNCTION public.ct_pm_inventory(p_kind text DEFAULT 'chest',p_after uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid:=auth.uid();BEGIN
 IF u IS NULL THEN RAISE EXCEPTION 'Authentication required';END IF;
 IF p_kind NOT IN('title','chest') OR p_kind IS NULL THEN RAISE EXCEPTION 'Objet demandé invalide';END IF;
 RETURN coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY id) FROM(
 SELECT i.id,'title' kind,t.id definition_id,t.name,t.rarity,t.id signature FROM public.ct_player_titles i JOIN public.ct_titles t ON t.id=i.title_id WHERE p_kind='title' AND i.user_id=u AND i.quantity=1 AND i.revoked_at IS NULL AND NOT public.ct_direct_reserved('title',i.id) AND NOT EXISTS(SELECT 1 FROM public.ct_market_listings WHERE asset_kind='title' AND asset_id=i.id AND status='active' AND expires_at>now()) AND(p_after IS NULL OR i.id>p_after)
 UNION ALL SELECT s.id,'chest',s.chest_id::text,s.name,s.rarity,md5(jsonb_build_array(s.weights,s.title_ids)::text) FROM public.ct_sealed_chests s WHERE p_kind='chest' AND s.user_id=u AND s.opened_at IS NULL AND NOT public.ct_direct_reserved('chest',s.id) AND NOT EXISTS(SELECT 1 FROM public.ct_market_listings WHERE asset_kind='chest' AND asset_id=s.id AND status='active' AND expires_at>now()) AND(p_after IS NULL OR s.id>p_after)
 ORDER BY id LIMIT 100)x),'[]'::jsonb);
END $$;
CREATE FUNCTION public.ct_pm_quote(p_listing bigint,p_quantity integer DEFAULT 1) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE l public.ct_pm_listings;cost bigint;fee bigint;BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required';END IF;
 SELECT * INTO l FROM public.ct_pm_listings WHERE id=p_listing AND status='active' AND NOT EXISTS(SELECT 1 FROM public.ct_pm_seller_blocks WHERE user_id=seller_id) AND NOT EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=seller_id);
 IF l.id IS NULL OR p_quantity IS NULL OR p_quantity NOT BETWEEN 1 AND l.remaining THEN RAISE EXCEPTION 'Offre ou quantité indisponible';END IF;
 cost:=l.unit_price*p_quantity;fee:=(cost+9)/10;
 RETURN to_jsonb(l)||jsonb_build_object('quantity',p_quantity,'subtotal',cost,'fee',fee,'total',cost,'seller_net',cost-fee,'token',md5(jsonb_build_array(l.id,l.version,p_quantity,cost,fee)::text));
END $$;
CREATE FUNCTION public.ct_pm_command(p_operation_id uuid,p_action text,p_values jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
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
  INSERT INTO public.ct_pm_listings(seller_id,kind,definition_id,name,rarity,unit_price,remaining) VALUES(u,p_values->>'kind',first_info->>'definition_id',first_info->>'name',(first_info->>'rarity')::smallint,price,cardinality(ids)) RETURNING * INTO l;
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
  oid:=public.ct_order_insert('pm:'||u||':'||p_operation_id,'player',u,l.seller_id,l.kind,l.name,l.definition_id,l.rarity,n,cost,fee,jsonb_build_array(jsonb_build_object('name',l.name,'kind',l.kind,'quantity',n,'unit_price',l.unit_price,'subtotal',cost)),jsonb_build_object('operation_id',p_operation_id,'listing_id',l.id,'buyer_transaction',buyer_tx,'seller_transaction',seller_tx,'assets',received));
 ELSE RAISE EXCEPTION 'Action inconnue';END IF;
 r:=jsonb_build_object('ok',true,'listing_id',l.id,'order_id',oid);INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,request,r);RETURN r;
END $$;

CREATE FUNCTION public.ct_pm_browse(p_filters jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid:=auth.uid();pg integer:=coalesce((p_filters->>'page')::integer,1);view text:=coalesce(p_filters->>'view','browse');sorting text:=coalesce(p_filters->>'sort','newest');result jsonb;
BEGIN
 IF u IS NULL THEN RAISE EXCEPTION 'Authentication required';END IF;
 IF pg NOT BETWEEN 1 AND 10000 OR view NOT IN('browse','mine','admin','sold') OR sorting NOT IN('newest','oldest','price_asc','price_desc','sales','rating') THEN RAISE EXCEPTION 'Invalid filters';END IF;
 IF view='admin' AND NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required';END IF;
 WITH stats AS MATERIALIZED(SELECT seller_id,count(*) sales FROM public.ct_orders WHERE market='player' GROUP BY seller_id),ratings AS MATERIALIZED(SELECT seller_id,avg(rating) rating,count(*) reviews FROM public.ct_pm_reviews WHERE NOT hidden GROUP BY seller_id),products AS MATERIALIZED(SELECT item_kind,definition_id,sum(quantity) sold FROM public.ct_orders WHERE market='player' GROUP BY item_kind,definition_id),items AS MATERIALIZED(
 SELECT l.*,p.username seller,p.avatar,coalesce(s.sales,0) sales,coalesce(r.rating,0) rating,coalesce(r.reviews,0) reviews,coalesce(pr.sold,0) product_sales FROM public.ct_pm_listings l JOIN public.ct_profiles p ON p.id=l.seller_id LEFT JOIN stats s ON s.seller_id=l.seller_id LEFT JOIN ratings r ON r.seller_id=l.seller_id LEFT JOIN products pr ON pr.item_kind=l.kind AND pr.definition_id=l.definition_id
 WHERE CASE view WHEN 'admin' THEN true WHEN 'mine' THEN l.seller_id=u WHEN 'sold' THEN l.status='sold' ELSE l.status='active' AND NOT EXISTS(SELECT 1 FROM public.ct_pm_seller_blocks WHERE user_id=l.seller_id) AND NOT EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=l.seller_id) END
 AND(coalesce(p_filters->>'kind','all')='all' OR l.kind=p_filters->>'kind') AND(nullif(p_filters->>'seller','') IS NULL OR l.seller_id=(p_filters->>'seller')::uuid)
 AND(position(lower(left(coalesce(p_filters->>'search',''),80)) IN lower(l.name||' '||p.username))>0 OR(nullif(p_filters->>'alias','') IS NOT NULL AND position(lower(left(p_filters->>'alias',80)) IN lower(l.name))>0))
 AND(nullif(p_filters->>'min','') IS NULL OR l.unit_price>=(p_filters->>'min')::bigint) AND(nullif(p_filters->>'max','') IS NULL OR l.unit_price<=(p_filters->>'max')::bigint)
 ),ranked AS(SELECT *,row_number() OVER(ORDER BY CASE WHEN sorting='price_asc' THEN unit_price END ASC,CASE WHEN sorting='price_desc' THEN unit_price END DESC,CASE WHEN sorting='oldest' THEN id END ASC,CASE WHEN sorting='rating' THEN rating END DESC,CASE WHEN sorting='sales' THEN product_sales END DESC,id DESC) rn FROM items)
 SELECT jsonb_build_object('items',coalesce((SELECT jsonb_agg(to_jsonb(x)-'rn' ORDER BY rn) FROM ranked x WHERE rn>(pg-1)*12 AND rn<=pg*12),'[]'::jsonb),'total',(SELECT count(*) FROM items),'pages',greatest(1,ceil((SELECT count(*) FROM items)/12.0)),'page',pg) INTO result;RETURN result;
END $$;
CREATE FUNCTION public.ct_pm_shop(p_seller uuid,p_page integer DEFAULT 1) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required';END IF;IF p_page IS NULL OR p_page NOT BETWEEN 1 AND 10000 THEN RAISE EXCEPTION 'Invalid filters';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.ct_profiles WHERE id=p_seller) THEN RAISE EXCEPTION 'Boutique introuvable';END IF;
 RETURN jsonb_build_object('profile',(SELECT jsonb_build_object('id',id,'username',username,'avatar',avatar,'created_at',created_at,'blocked',EXISTS(SELECT 1 FROM public.ct_pm_seller_blocks WHERE user_id=id)) FROM public.ct_profiles WHERE id=p_seller),'sales',(SELECT count(*) FROM public.ct_orders WHERE market='player' AND seller_id=p_seller),'rating',(SELECT coalesce(avg(rating),0) FROM public.ct_pm_reviews WHERE seller_id=p_seller AND NOT hidden),'review_count',(SELECT count(*) FROM public.ct_pm_reviews WHERE seller_id=p_seller AND NOT hidden),'reviews',coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC) FROM(SELECT r.rating,r.comment,r.created_at,o.buyer_name FROM public.ct_pm_reviews r JOIN public.ct_orders o ON o.id=r.order_id WHERE r.seller_id=p_seller AND NOT r.hidden ORDER BY r.created_at DESC,r.order_id DESC LIMIT 20 OFFSET(p_page-1)*20)x),'[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.ct_order_insert(text,text,uuid,uuid,text,text,text,smallint,integer,bigint,bigint,jsonb,jsonb,timestamptz),public.ct_black_order(uuid,uuid,jsonb),public.ct_pm_inventory(text,uuid),public.ct_pm_quote(bigint,integer),public.ct_pm_command(uuid,text,jsonb),public.ct_pm_browse(jsonb),public.ct_pm_shop(uuid,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_pm_inventory(text,uuid),public.ct_pm_quote(bigint,integer),public.ct_pm_command(uuid,text,jsonb),public.ct_pm_browse(jsonb),public.ct_pm_shop(uuid,integer) TO authenticated;
COMMIT;
