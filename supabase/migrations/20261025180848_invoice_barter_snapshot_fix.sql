BEGIN;
CREATE OR REPLACE FUNCTION public.ct_black_order(p_operation uuid,p_buyer uuid,p_group_quote jsonb DEFAULT NULL) RETURNS bigint LANGUAGE plpgsql SET search_path='' AS $$
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
 IF l.wanted_kind IS NOT NULL THEN lines:=lines||jsonb_build_object('kind',l.wanted_kind,'role','barter_payment','quantity',1,'name',coalesce((SELECT bt.name FROM public.ct_titles bt WHERE l.wanted_kind='title' AND bt.id=l.wanted_id),(SELECT bc.name FROM public.ct_chest_types bc WHERE l.wanted_kind='chest' AND bc.id::text=l.wanted_id),l.wanted_id));END IF;
 RETURN public.ct_order_insert('black:'||p_buyer||':'||p_operation,'black',p_buyer,seller,kind,name,definition,rar,qty,subtotal,charge,lines,proof||jsonb_build_object('operation_id',p_operation,'payment_ledger',pay.id,'seller_ledger',sale.id,'payment_key',key),op.created_at);
END $$;
REVOKE ALL ON FUNCTION public.ct_black_order(uuid,uuid,jsonb) FROM PUBLIC,anon,authenticated;
COMMIT;
