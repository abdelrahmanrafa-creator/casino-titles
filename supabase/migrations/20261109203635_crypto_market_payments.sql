ALTER TABLE public.ct_pm_listings ADD COLUMN crypto_symbols text[] NOT NULL DEFAULT '{}';
ALTER TABLE public.ct_market_listings ADD COLUMN crypto_symbols text[] NOT NULL DEFAULT '{}';
ALTER TABLE public.ct_wholesale_offers ADD COLUMN crypto_symbols text[] NOT NULL DEFAULT '{}';
ALTER TABLE public.ct_credit_offers ADD COLUMN crypto_symbols text[] NOT NULL DEFAULT '{}';
ALTER TABLE public.ct_orders ADD COLUMN crypto_payment jsonb;
CREATE TABLE public.ct_crypto_treasury(symbol text PRIMARY KEY REFERENCES public.ct_crypto_assets(symbol),atoms bigint NOT NULL DEFAULT 0 CHECK(atoms>=0));
CREATE TABLE public.ct_crypto_payment_ledger(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,order_id bigint NOT NULL REFERENCES public.ct_orders(id),user_id uuid REFERENCES public.ct_profiles(id),symbol text NOT NULL REFERENCES public.ct_crypto_assets(symbol),side text NOT NULL CHECK(side IN('buyer','seller','server')),atoms bigint NOT NULL,cost_basis_delta bigint NOT NULL DEFAULT 0,realized_delta bigint NOT NULL DEFAULT 0,created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(order_id,side));
CREATE INDEX ct_crypto_payment_user ON public.ct_crypto_payment_ledger(user_id,id DESC);
CREATE INDEX ct_crypto_payment_symbol ON public.ct_crypto_payment_ledger(symbol,id DESC);
ALTER TABLE public.ct_crypto_treasury ENABLE ROW LEVEL SECURITY;ALTER TABLE public.ct_crypto_payment_ledger ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ct_crypto_treasury,public.ct_crypto_payment_ledger FROM PUBLIC,anon,authenticated;
REVOKE ALL ON SEQUENCE public.ct_crypto_payment_ledger_id_seq FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.ct_crypto_accept_symbols(p_value jsonb) RETURNS text[] LANGUAGE plpgsql STABLE SET search_path='' AS $$
DECLARE a text[];BEGIN
 IF p_value IS NULL OR NOT coalesce((p_value->>'enabled')::boolean,false) THEN RETURN '{}'::text[];END IF;
 IF coalesce((p_value->>'all')::boolean,false) THEN SELECT array_agg(symbol ORDER BY symbol) INTO a FROM public.ct_crypto_assets;RETURN a;END IF;
 IF jsonb_typeof(p_value->'symbols') IS DISTINCT FROM 'array' OR jsonb_array_length(p_value->'symbols') NOT BETWEEN 1 AND 32 THEN RAISE EXCEPTION 'Choisissez au moins une crypto acceptée';END IF;
 SELECT array_agg(DISTINCT x ORDER BY x) INTO a FROM jsonb_array_elements_text(p_value->'symbols')x;
 IF EXISTS(SELECT 1 FROM unnest(a)x WHERE NOT EXISTS(SELECT 1 FROM public.ct_crypto_assets WHERE symbol=x)) THEN RAISE EXCEPTION 'Crypto acceptée invalide';END IF;RETURN a;
END $$;
ALTER FUNCTION public.ct_pm_command(uuid,text,jsonb) RENAME TO ct_pm_command_before_crypto;
CREATE FUNCTION public.ct_pm_command(p_operation_id uuid,p_action text,p_values jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r jsonb;a text[];old boolean;BEGIN
 PERFORM pg_advisory_xact_lock(173,8);old:=EXISTS(SELECT 1 FROM public.ct_operations WHERE user_id=auth.uid() AND operation_id=p_operation_id);
 IF NOT old AND p_action IN('create','price') AND p_values?'crypto' THEN a:=public.ct_crypto_accept_symbols(p_values->'crypto');END IF;
 r:=public.ct_pm_command_before_crypto(p_operation_id,p_action,p_values);
 IF NOT old AND p_action IN('create','price') AND p_values?'crypto' THEN UPDATE public.ct_pm_listings SET crypto_symbols=a,version=version+1 WHERE id=(r->>'listing_id')::bigint AND seller_id=auth.uid();END IF;RETURN r;
END $$;
ALTER FUNCTION public.ct_market_command(uuid,text,jsonb) RENAME TO ct_market_command_before_crypto;
CREATE FUNCTION public.ct_market_command(p_operation_id uuid,p_action text,p_values jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r jsonb;a text[];old boolean;BEGIN
 PERFORM pg_advisory_xact_lock(173,8);old:=EXISTS(SELECT 1 FROM public.ct_operations WHERE user_id=auth.uid() AND operation_id=p_operation_id);
 IF NOT old AND p_action IN('list','list_many') AND p_values?'crypto' THEN a:=public.ct_crypto_accept_symbols(p_values->'crypto');IF cardinality(a)>0 AND nullif(p_values->>'wanted_kind','') IS NOT NULL THEN RAISE EXCEPTION 'Le paiement crypto exige une vente sans troc';END IF;END IF;
 r:=public.ct_market_command_before_crypto(p_operation_id,p_action,p_values);
 IF NOT old AND p_action IN('list','list_many') AND p_values?'crypto' THEN UPDATE public.ct_market_listings SET crypto_symbols=a WHERE seller_id=auth.uid() AND status='active' AND (asset_id=nullif(p_values->>'asset_id','')::uuid OR asset_id IN(SELECT value::uuid FROM jsonb_array_elements_text(coalesce(p_values->'asset_ids','[]'))));END IF;RETURN r;
END $$;
ALTER FUNCTION public.ct_wholesale_command(uuid,text,jsonb) RENAME TO ct_wholesale_command_before_crypto;
CREATE FUNCTION public.ct_wholesale_command(p_operation_id uuid,p_action text,p_values jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r jsonb;a text[];old boolean;BEGIN
 PERFORM pg_advisory_xact_lock(173,8);old:=EXISTS(SELECT 1 FROM public.ct_operations WHERE user_id=auth.uid() AND operation_id=p_operation_id);
 IF NOT old AND p_action='create' AND p_values?'crypto' THEN a:=public.ct_crypto_accept_symbols(p_values->'crypto');END IF;
 r:=public.ct_wholesale_command_before_crypto(p_operation_id,p_action,p_values);
 IF NOT old AND p_action='create' AND p_values?'crypto' THEN UPDATE public.ct_wholesale_offers SET crypto_symbols=a,version=version+1 WHERE id=(r->>'id')::uuid AND seller_id=auth.uid();END IF;RETURN r;
END $$;

ALTER FUNCTION public.ct_credit_market_command(uuid,text,jsonb) RENAME TO ct_credit_market_command_before_crypto;
CREATE FUNCTION public.ct_credit_market_command(p_operation_id uuid,p_action text,p_values jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r jsonb;a text[];old boolean;BEGIN
 PERFORM pg_advisory_xact_lock(173,8);old:=EXISTS(SELECT 1 FROM public.ct_operations WHERE user_id=auth.uid() AND operation_id=p_operation_id);
 IF NOT old AND p_action='create' AND p_values?'crypto' THEN a:=public.ct_crypto_accept_symbols(p_values->'crypto');END IF;
 r:=public.ct_credit_market_command_before_crypto(p_operation_id,p_action,p_values);
 IF NOT old AND p_action='create' AND p_values?'crypto' THEN UPDATE public.ct_credit_offers SET crypto_symbols=a WHERE id=(r->>'id')::bigint AND seller_id=auth.uid();END IF;RETURN r;
END $$;
REVOKE ALL ON FUNCTION public.ct_credit_market_command_before_crypto(uuid,text,jsonb),public.ct_credit_market_command(uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_credit_market_command(uuid,text,jsonb) TO authenticated;

-- Internal offer snapshot: shared by options, quote and execution. Includes exact
-- reserved copies so changing stock/acceptance invalidates a signed quote.
CREATE FUNCTION public.ct_crypto_offer(p_market text,p_kind text,p_key text,p_quantity integer) RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path='' AS $$
DECLARE u uuid:=auth.uid();l public.ct_pm_listings;bl public.ct_market_listings;s public.ct_wholesale_offers;co public.ct_credit_offers;q jsonb;part jsonb;d jsonb:='[]';symbols text[];accepted text[];ids uuid[];lids bigint[];n integer;who uuid;nm text;rar smallint;def text;k text;policy jsonb:='[]';
BEGIN
 IF u IS NULL OR NOT EXISTS(SELECT 1 FROM public.ct_profiles WHERE id=u AND NOT is_bot) OR EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=u) THEN RAISE EXCEPTION 'Compte joueur actif requis';END IF;
 IF p_quantity IS NULL OR p_quantity NOT BETWEEN 1 AND 1000 THEN RAISE EXCEPTION 'Quantité de paiement invalide';END IF;
 SELECT array_agg(symbol ORDER BY symbol) INTO symbols FROM public.ct_crypto_assets;
 IF p_market='player' AND p_kind='listing' THEN
  q:=public.ct_pm_quote(p_key::bigint,p_quantity);SELECT * INTO l FROM public.ct_pm_listings WHERE id=p_key::bigint;
  who:=l.seller_id;nm:=l.name;rar:=l.rarity;def:=l.definition_id;k:=l.kind;symbols:=l.crypto_symbols;
  SELECT array_agg(asset_id ORDER BY asset_id) INTO ids FROM(SELECT asset_id FROM public.ct_pm_assets WHERE listing_id=l.id AND NOT sold ORDER BY asset_id LIMIT p_quantity)x;
  IF cardinality(ids) IS DISTINCT FROM p_quantity THEN RAISE EXCEPTION 'Stock réservé indisponible';END IF;
  d:=jsonb_build_array(jsonb_build_object('source','player','id',p_key,'asset_ids',ids,'quantity',p_quantity));
 ELSIF p_market='black' THEN
  IF NOT public.ct_circle_member(u) THEN RAISE EXCEPTION 'Carte active requise';END IF;
  IF EXISTS(SELECT 1 FROM public.ct_market_settings WHERE id AND(NOT market_enabled OR wallets_frozen)) THEN RAISE EXCEPTION 'Le marché est suspendu ou figé';END IF;
  IF p_kind='credits' THEN
   SELECT * INTO co FROM public.ct_credit_offers WHERE id=p_key::bigint AND status='active' AND expires_at>now() AND(target_id IS NULL OR target_id=u);
   IF co.id IS NULL OR p_quantity<>1 THEN RAISE EXCEPTION 'Offre ou quantité indisponible';END IF;
   who:=co.seller_id;nm:='Lot de crédits';rar:=1;k:='credits';symbols:=co.crypto_symbols;q:=public.ct_market_payment(co.price)||jsonb_build_object('amount',co.amount);
   d:=jsonb_build_array(jsonb_build_object('source','credits','id',co.id,'amount',co.amount,'quantity',1));
  ELSIF p_kind='listing' THEN
   SELECT * INTO bl FROM public.ct_market_listings WHERE id=p_key::bigint AND status='active' AND expires_at>now() AND wanted_kind IS NULL AND(target_id IS NULL OR target_id=u);
   IF bl.id IS NULL OR p_quantity<>1 OR bl.price<=0 THEN RAISE EXCEPTION 'Offre ou quantité indisponible';END IF;
   IF public.ct_direct_reserved(bl.asset_kind,bl.asset_id) THEN RAISE EXCEPTION 'Objet déjà réservé';END IF;who:=bl.seller_id;nm:=bl.name;rar:=bl.rarity;def:=bl.definition_id;k:=bl.asset_kind;symbols:=bl.crypto_symbols;
   q:=public.ct_market_payment(bl.price)||jsonb_build_object('version',bl.id,'price',bl.price);
   d:=jsonb_build_array(jsonb_build_object('source','listing','id',bl.id,'asset_ids',jsonb_build_array(bl.asset_id),'quantity',1));
  ELSIF p_kind IN('group','stock') THEN
   IF p_kind='stock' THEN SELECT * INTO s FROM public.ct_wholesale_offers WHERE id=p_key::uuid AND status='active' AND expires_at>now() AND remaining>=p_quantity;IF s.id IS NULL THEN RAISE EXCEPTION 'Offre ou quantité indisponible';END IF;
    SELECT coalesce((SELECT(t->>'price')::bigint FROM jsonb_array_elements(s.tiers)t WHERE(t->>'min')::int<=p_quantity ORDER BY(t->>'min')::int DESC LIMIT 1),s.base_price) INTO n;
    q:=public.ct_market_payment(n::bigint*p_quantity)||jsonb_build_object('parts',jsonb_build_array(jsonb_build_object('source','stock','id',p_key,'quantity',p_quantity,'unit_price',n,'version',s.version)));who:=s.seller_id;nm:=s.name;rar:=s.rarity;def:=s.chest_id::text;
   ELSE q:=public.ct_market_chest_group_quote(p_key,p_quantity);who:=(q->>'seller_id')::uuid;nm:=q->>'name';END IF;k:='chest';
   FOR part IN SELECT value FROM jsonb_array_elements(q->'parts') LOOP
    n:=(part->>'quantity')::integer;
    IF part->>'source'='stock' THEN
     SELECT * INTO s FROM public.ct_wholesale_offers WHERE id=(part->>'id')::uuid;accepted:=s.crypto_symbols;rar:=s.rarity;def:=s.chest_id::text;
     SELECT array_agg(asset_id ORDER BY asset_id) INTO ids FROM(SELECT wa.asset_id FROM public.ct_wholesale_assets wa JOIN public.ct_sealed_chests sc ON sc.id=wa.asset_id WHERE wa.offer_id=s.id AND NOT wa.sold AND sc.user_id=who AND sc.opened_at IS NULL ORDER BY wa.asset_id LIMIT n)x;
     SELECT coalesce(array_agg(x ORDER BY x),'{}') INTO symbols FROM unnest(symbols)x WHERE x=ANY(accepted);
     d:=d||jsonb_build_object('source','stock','id',s.id,'asset_ids',ids,'quantity',n,'version',s.version);
    ELSE
     SELECT array_agg(x.asset_id ORDER BY x.id),array_agg(x.id ORDER BY x.id) INTO ids,lids FROM(SELECT ml.asset_id,ml.id FROM public.ct_market_listings ml JOIN public.ct_sealed_chests sc ON sc.id=ml.asset_id AND sc.user_id=ml.seller_id AND sc.opened_at IS NULL WHERE ml.seller_id=who AND ml.asset_kind='chest' AND ml.status='active' AND ml.expires_at>now() AND ml.wanted_kind IS NULL AND ml.target_id IS NULL AND NOT public.ct_direct_reserved('chest',sc.id) AND md5(jsonb_build_array(ml.seller_id,sc.chest_id,ml.name,ml.rarity,ml.price,sc.weights,sc.title_ids)::text)=p_key ORDER BY ml.id LIMIT n)x;
     FOR bl IN SELECT * FROM public.ct_market_listings WHERE id=ANY(lids) LOOP SELECT coalesce(array_agg(x ORDER BY x),'{}') INTO symbols FROM unnest(symbols)x WHERE x=ANY(bl.crypto_symbols);rar:=bl.rarity;def:=bl.definition_id;END LOOP;
     d:=d||jsonb_build_object('source','listings','listing_ids',lids,'asset_ids',ids,'quantity',n);
    END IF;
    IF cardinality(ids) IS DISTINCT FROM n THEN RAISE EXCEPTION 'Stock réservé indisponible';END IF;
   END LOOP;
  ELSE RAISE EXCEPTION 'Offre crypto invalide';END IF;
  IF NOT public.ct_circle_member(who) OR EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=who) THEN RAISE EXCEPTION 'Vendeur indisponible';END IF;
 ELSE RAISE EXCEPTION 'Offre crypto invalide';END IF;
 IF who=u THEN RAISE EXCEPTION 'Vous ne pouvez pas acheter votre propre annonce';END IF;
 RETURN jsonb_build_object('seller_id',who,'name',nm,'rarity',rar,'definition_id',def,'item_kind',k,'quantity',p_quantity,'quote',q,'delivery',d,'symbols',coalesce(to_jsonb(symbols),'[]'));
END $$;
CREATE FUNCTION public.ct_crypto_payment_options(p_market text,p_kind text,p_key text,p_quantity integer DEFAULT 1) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE o jsonb;BEGIN o:=public.ct_crypto_offer(p_market,p_kind,p_key,p_quantity);RETURN jsonb_build_object('symbols',o->'symbols','simulated',true);END $$;
CREATE FUNCTION public.ct_crypto_payment_quote(p_market text,p_kind text,p_key text,p_quantity integer,p_symbol text) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE o jsonb;q jsonb;c public.ct_crypto_settings;a public.ct_crypto_assets;b bigint:=floor(extract(epoch FROM now())/60);price bigint;rate bigint:=1;sub numeric;f numeric;total numeric;net numeric;base bigint;fee bigint;payload jsonb;
BEGIN
 o:=public.ct_crypto_offer(p_market,p_kind,p_key,p_quantity);
 IF NOT(o->'symbols' ? p_symbol) THEN RAISE EXCEPTION 'Cette crypto n’est pas acceptée pour ce lot';END IF;
 SELECT * INTO c FROM public.ct_crypto_settings WHERE id;IF NOT c.sell_enabled THEN RAISE EXCEPTION 'Transactions crypto temporairement suspendues';END IF;
 SELECT * INTO a FROM public.ct_crypto_assets WHERE symbol=p_symbol;IF NOT FOUND THEN RAISE EXCEPTION 'Crypto acceptée invalide';END IF;
 price:=public.ct_crypto_mark(p_symbol,b);q:=o->'quote';base:=(q->>'subtotal')::bigint;fee:=(q->>'fee')::bigint;
 IF p_market='black' THEN SELECT credits_per_diamond INTO rate FROM public.ct_market_settings WHERE id;END IF;
 IF base::numeric*rate>9000000000000 THEN RAISE EXCEPTION 'Montant crypto hors limites';END IF;
 sub:=ceil(base::numeric*rate*1000000000000/price);f:=ceil(fee::numeric*rate*1000000000000/price);
 total:=CASE WHEN p_market='player' THEN sub ELSE sub+f END;net:=CASE WHEN p_market='player' THEN sub-f ELSE sub END;
 IF total<=0 OR total>9000000000000000000 OR net<0 THEN RAISE EXCEPTION 'Montant crypto hors limites';END IF;
 payload:=jsonb_build_object('market',p_market,'kind',p_kind,'key',p_key,'quantity',p_quantity,'symbol',p_symbol,'seller_id',o->'seller_id','name',o->'name','price_e6',price::text,'subtotal_atoms',sub::bigint::text,'fee_atoms',f::bigint::text,'total_atoms',total::bigint::text,'seller_atoms',net::bigint::text,'base_subtotal',base,'base_fee',fee,'base_currency',CASE WHEN p_market='player' THEN 'credits' ELSE 'diamonds' END,'credits_per_diamond',rate,'fee_side',CASE WHEN p_market='player' THEN 'seller' ELSE 'buyer' END,'fee_bps',CASE WHEN p_market='player' THEN 1000 ELSE(q->>'fee_bps')::integer END,'bucket',b,'asset_version',a.version,'settings_version',c.version,'offer_token',encode(sha256(convert_to(o::text,'UTF8')),'hex'),'expires_at',least(floor(extract(epoch FROM now()))::bigint+20,(b+1)*60));
 RETURN payload||jsonb_build_object('available_atoms',coalesce((SELECT atoms::text FROM public.ct_crypto_positions WHERE user_id=auth.uid() AND symbol=p_symbol),'0'),'token',encode(sha256(convert_to('payment:'||auth.uid()::text||payload::text||c.secret,'UTF8')),'hex'));
END $$;

CREATE FUNCTION public.ct_crypto_payment_buy(p_operation_id uuid,p_quote jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;request jsonb:=jsonb_build_object('kind','crypto_market_payment','quote',p_quote);fresh jsonb;o jsonb;payload jsonb;secret text;p public.ct_crypto_positions;total bigint;net bigint;fee bigint;removed bigint;seller_basis bigint;gain bigint;who uuid;oid bigint;part jsonb;ids uuid[];lids bigint[];a uuid;n integer;src text;itemkind text;asset_info jsonb;received jsonb:='[]';new_asset uuid;title_id text;
BEGIN
 PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,request);IF r IS NOT NULL THEN RETURN r;END IF;PERFORM public.ct_check_rate(u);
 SELECT s.secret INTO secret FROM public.ct_crypto_settings s WHERE id;payload:=p_quote-'token'-'available_atoms';
 IF p_quote->>'token' IS DISTINCT FROM encode(sha256(convert_to('payment:'||u::text||payload::text||secret,'UTF8')),'hex') THEN RAISE EXCEPTION 'Devis de paiement crypto invalide';END IF;
 IF(p_quote->>'expires_at')::bigint<extract(epoch FROM now()) THEN RAISE EXCEPTION 'Devis crypto expiré. Actualisez le prix';END IF;
 fresh:=public.ct_crypto_payment_quote(p_quote->>'market',p_quote->>'kind',p_quote->>'key',(p_quote->>'quantity')::integer,p_quote->>'symbol');
 IF(payload-'expires_at') IS DISTINCT FROM(fresh-'token'-'available_atoms'-'expires_at') THEN RAISE EXCEPTION 'Stock, crypto ou prix modifié. Actualisez le devis';END IF;
 o:=public.ct_crypto_offer(p_quote->>'market',p_quote->>'kind',p_quote->>'key',(p_quote->>'quantity')::integer);who:=(o->>'seller_id')::uuid;total:=(p_quote->>'total_atoms')::bigint;net:=(p_quote->>'seller_atoms')::bigint;fee:=(p_quote->>'fee_atoms')::bigint;
 SELECT * INTO p FROM public.ct_crypto_positions WHERE user_id=u AND symbol=p_quote->>'symbol' FOR UPDATE;
 IF p.atoms IS NULL OR p.atoms<total THEN RAISE EXCEPTION 'Solde crypto insuffisant';END IF;
 removed:=CASE WHEN p.atoms=total THEN p.cost_basis ELSE floor(p.cost_basis::numeric*total/p.atoms)::bigint END;
 seller_basis:=floor(net::numeric*(p_quote->>'price_e6')::bigint/1000000000000)::bigint;
 gain:=floor((CASE WHEN p_quote->>'fee_side'='buyer' THEN total-fee ELSE total END)::numeric*(p_quote->>'price_e6')::bigint/1000000000000)::bigint-removed;
 UPDATE public.ct_crypto_positions SET atoms=atoms-total,cost_basis=cost_basis-removed,realized=realized+gain WHERE user_id=u AND symbol=p_quote->>'symbol';
 INSERT INTO public.ct_crypto_positions(user_id,symbol,atoms,cost_basis) VALUES(who,p_quote->>'symbol',net,seller_basis) ON CONFLICT(user_id,symbol) DO UPDATE SET atoms=ct_crypto_positions.atoms+excluded.atoms,cost_basis=ct_crypto_positions.cost_basis+excluded.cost_basis;
 INSERT INTO public.ct_crypto_treasury(symbol,atoms) VALUES(p_quote->>'symbol',fee) ON CONFLICT(symbol) DO UPDATE SET atoms=ct_crypto_treasury.atoms+excluded.atoms;
 itemkind:=o->>'item_kind';
 FOR part IN SELECT value FROM jsonb_array_elements(o->'delivery') LOOP
  SELECT array_agg(value::uuid) INTO ids FROM jsonb_array_elements_text(part->'asset_ids');src:=part->>'source';n:=(part->>'quantity')::integer;
  IF src='credits' THEN
   UPDATE public.ct_credit_offers SET status='sold',buyer_id=u WHERE id=(part->>'id')::bigint;
   PERFORM public.ct_post_credit(u,(part->>'amount')::bigint,'market_credit_purchase','crypto-credits:'||p_operation_id);
  ELSIF src='player' THEN
   UPDATE public.ct_pm_assets SET sold=true WHERE listing_id=(part->>'id')::bigint AND asset_id=ANY(ids) AND NOT sold;
   UPDATE public.ct_pm_listings SET remaining=remaining-n,version=version+1,status=CASE WHEN remaining=n THEN 'sold' ELSE 'active' END WHERE id=(part->>'id')::bigint;
  ELSIF src='stock' THEN
   UPDATE public.ct_wholesale_assets SET sold=true WHERE offer_id=(part->>'id')::uuid AND asset_id=ANY(ids) AND NOT sold;
   UPDATE public.ct_wholesale_offers SET remaining=remaining-n,version=version+1,status=CASE WHEN remaining=n THEN 'sold' ELSE 'active' END WHERE id=(part->>'id')::uuid;
  ELSIF src='listing' THEN UPDATE public.ct_market_listings SET status='sold',buyer_id=u WHERE id=(part->>'id')::bigint;
  ELSE SELECT array_agg(value::bigint) INTO lids FROM jsonb_array_elements_text(part->'listing_ids');UPDATE public.ct_market_listings SET status='sold',buyer_id=u WHERE id=ANY(lids);END IF;
  FOREACH a IN ARRAY coalesce(ids,'{}'::uuid[]) LOOP
   asset_info:=public.ct_market_asset(who,itemkind,a);
   IF itemkind='title' THEN SELECT t.title_id INTO title_id FROM public.ct_player_titles t WHERE id=a;DELETE FROM public.ct_equipped_titles WHERE player_title_id=a;UPDATE public.ct_player_titles SET revoked_at=now() WHERE id=a;INSERT INTO public.ct_player_titles(user_id,title_id,source) VALUES(u,title_id,'crypto-market:'||p_operation_id) RETURNING id INTO new_asset;
   ELSE UPDATE public.ct_sealed_chests SET user_id=u WHERE id=a;new_asset:=a;END IF;
   received:=received||jsonb_build_object('from_asset',a,'received_asset',new_asset);
  END LOOP;
 END LOOP;
 oid:=public.ct_order_insert('crypto:'||u||':'||p_operation_id,p_quote->>'market',u,who,itemkind,o->>'name',o->>'definition_id',(o->>'rarity')::smallint,CASE WHEN itemkind='credits' THEN(o->'delivery'->0->>'amount')::integer ELSE(o->>'quantity')::integer END,(p_quote->>'base_subtotal')::bigint,(p_quote->>'base_fee')::bigint,jsonb_build_array(jsonb_build_object('name',o->>'name','kind',itemkind,'quantity',(o->>'quantity')::integer,'subtotal',(p_quote->>'base_subtotal')::bigint)),jsonb_build_object('operation_id',p_operation_id,'assets',received,'crypto_payment',payload));
 INSERT INTO public.ct_crypto_payment_ledger(order_id,user_id,symbol,side,atoms,cost_basis_delta,realized_delta) VALUES(oid,u,p_quote->>'symbol','buyer',-total,-removed,gain),(oid,who,p_quote->>'symbol','seller',net,seller_basis,0),(oid,NULL,p_quote->>'symbol','server',fee,0,0);
 PERFORM public.ct_live_notify('ct:live:admin','admin');
 r:=jsonb_build_object('ok',true,'order_id',oid,'symbol',p_quote->>'symbol','total_atoms',total::text);INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,request,r);RETURN r;
END $$;

CREATE FUNCTION public.ct_crypto_order_snapshot() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$ BEGIN NEW.crypto_payment:=NEW.proof->'crypto_payment';RETURN NEW;END $$;
CREATE TRIGGER ct_crypto_order_snapshot BEFORE INSERT ON public.ct_orders FOR EACH ROW EXECUTE FUNCTION public.ct_crypto_order_snapshot();
CREATE OR REPLACE FUNCTION public.ct_notify_order() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE who uuid;role_name text;BEGIN FOREACH who IN ARRAY ARRAY[NEW.buyer_id,NEW.seller_id] LOOP
 IF NOT EXISTS(SELECT 1 FROM public.ct_profiles WHERE id=who AND NOT is_bot) THEN CONTINUE;END IF;role_name:=CASE WHEN who=NEW.buyer_id THEN 'purchase' ELSE 'sale' END;
 INSERT INTO public.ct_inbox_messages(sender_name,recipient_id,subject,body,system_payload) VALUES('Casino & Titles',who,CASE WHEN role_name='purchase' THEN 'Achat confirmé : votre facture' ELSE 'Vente confirmée : votre facture' END,NEW.item_name,jsonb_build_object('kind','order','role',role_name,'item_kind',NEW.item_kind,'order_id',NEW.id,'order_number',NEW.order_number,'name',NEW.item_name,'rarity',NEW.rarity,'quantity',NEW.quantity,'amount',CASE WHEN role_name='purchase' THEN NEW.total ELSE NEW.seller_net END,'currency',NEW.currency,'crypto_payment',NEW.crypto_payment));
 END LOOP;RETURN NEW;END $$;
ALTER FUNCTION public.ct_admin_order_action(uuid,text,bigint,jsonb,text) RENAME TO ct_admin_order_action_before_crypto;
CREATE FUNCTION public.ct_admin_order_action(p_operation_id uuid,p_action text,p_order bigint,p_values jsonb,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN IF p_action='correction' AND EXISTS(SELECT 1 FROM public.ct_orders WHERE id=p_order AND crypto_payment IS NOT NULL) THEN RAISE EXCEPTION 'Une commande crypto ne peut pas être corrigée en crédits ou diamants';END IF;RETURN public.ct_admin_order_action_before_crypto(p_operation_id,p_action,p_order,p_values,p_reason);END $$;
ALTER FUNCTION public.ct_admin_crypto() RENAME TO ct_admin_crypto_before_payments;
CREATE FUNCTION public.ct_admin_crypto() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$ BEGIN RETURN public.ct_admin_crypto_before_payments()||jsonb_build_object('market_fees',coalesce((SELECT jsonb_agg(jsonb_build_object('symbol',symbol,'atoms',atoms::text)) FROM public.ct_crypto_treasury),'[]'),'market_payments',(SELECT count(DISTINCT order_id) FROM public.ct_crypto_payment_ledger));END $$;
REVOKE ALL ON FUNCTION public.ct_pm_command_before_crypto(uuid,text,jsonb),public.ct_market_command_before_crypto(uuid,text,jsonb),public.ct_wholesale_command_before_crypto(uuid,text,jsonb),public.ct_admin_order_action_before_crypto(uuid,text,bigint,jsonb,text),public.ct_admin_crypto_before_payments(),public.ct_crypto_accept_symbols(jsonb),public.ct_crypto_offer(text,text,text,integer),public.ct_crypto_order_snapshot() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.ct_pm_command(uuid,text,jsonb),public.ct_market_command(uuid,text,jsonb),public.ct_wholesale_command(uuid,text,jsonb),public.ct_admin_order_action(uuid,text,bigint,jsonb,text),public.ct_admin_crypto(),public.ct_crypto_payment_options(text,text,text,integer),public.ct_crypto_payment_quote(text,text,text,integer,text),public.ct_crypto_payment_buy(uuid,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_pm_command(uuid,text,jsonb),public.ct_market_command(uuid,text,jsonb),public.ct_wholesale_command(uuid,text,jsonb),public.ct_admin_order_action(uuid,text,bigint,jsonb,text),public.ct_admin_crypto(),public.ct_crypto_payment_options(text,text,text,integer),public.ct_crypto_payment_quote(text,text,text,integer,text),public.ct_crypto_payment_buy(uuid,jsonb) TO authenticated;
