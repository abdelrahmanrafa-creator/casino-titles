BEGIN;
ALTER FUNCTION public.ct_market_command(uuid,text,jsonb) RENAME TO ct_market_command_before_orders;
CREATE FUNCTION public.ct_market_command(p_operation_id uuid,p_action text,p_values jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r jsonb;n bigint;BEGIN r:=public.ct_market_command_before_orders(p_operation_id,p_action,p_values);IF p_action='accept' THEN n:=public.ct_black_order(p_operation_id,auth.uid());IF n IS NOT NULL THEN r:=r||jsonb_build_object('order_id',n);END IF;END IF;RETURN r;END $$;
ALTER FUNCTION public.ct_wholesale_command(uuid,text,jsonb) RENAME TO ct_wholesale_command_before_orders;
CREATE FUNCTION public.ct_wholesale_command(p_operation_id uuid,p_action text,p_values jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r jsonb;n bigint;BEGIN r:=public.ct_wholesale_command_before_orders(p_operation_id,p_action,p_values);IF p_action='buy' THEN n:=public.ct_black_order(p_operation_id,auth.uid());IF n IS NOT NULL THEN r:=r||jsonb_build_object('order_id',n);END IF;END IF;RETURN r;END $$;
ALTER FUNCTION public.ct_credit_market_command(uuid,text,jsonb) RENAME TO ct_credit_market_command_before_orders;
CREATE FUNCTION public.ct_credit_market_command(p_operation_id uuid,p_action text,p_values jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r jsonb;n bigint;BEGIN r:=public.ct_credit_market_command_before_orders(p_operation_id,p_action,p_values);IF p_action='buy' THEN n:=public.ct_black_order(p_operation_id,auth.uid());IF n IS NOT NULL THEN r:=r||jsonb_build_object('order_id',n);END IF;END IF;RETURN r;END $$;
ALTER FUNCTION public.ct_buy_market_chest_group(uuid,text,integer,bigint,text) RENAME TO ct_buy_market_chest_group_before_orders;
CREATE FUNCTION public.ct_buy_market_chest_group(p_operation_id uuid,p_group text,p_quantity integer,p_expected_total bigint,p_quote_token text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r jsonb;q jsonb;n bigint;BEGIN PERFORM pg_advisory_xact_lock(173,8);IF NOT EXISTS(SELECT 1 FROM public.ct_operations WHERE user_id=auth.uid() AND operation_id=p_operation_id) THEN q:=public.ct_market_chest_group_quote(p_group,p_quantity);END IF;r:=public.ct_buy_market_chest_group_before_orders(p_operation_id,p_group,p_quantity,p_expected_total,p_quote_token);n:=public.ct_black_order(p_operation_id,auth.uid(),q);RETURN r||jsonb_build_object('order_id',n);END $$;
REVOKE ALL ON FUNCTION public.ct_market_command_before_orders(uuid,text,jsonb),public.ct_wholesale_command_before_orders(uuid,text,jsonb),public.ct_credit_market_command_before_orders(uuid,text,jsonb),public.ct_buy_market_chest_group_before_orders(uuid,text,integer,bigint,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.ct_market_command(uuid,text,jsonb),public.ct_wholesale_command(uuid,text,jsonb),public.ct_credit_market_command(uuid,text,jsonb),public.ct_buy_market_chest_group(uuid,text,integer,bigint,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_market_command(uuid,text,jsonb),public.ct_wholesale_command(uuid,text,jsonb),public.ct_credit_market_command(uuid,text,jsonb),public.ct_buy_market_chest_group(uuid,text,integer,bigint,text) TO authenticated;

CREATE FUNCTION public.ct_direct_orders(p_trade uuid,p_date timestamptz DEFAULT now()) RETURNS bigint LANGUAGE plpgsql SET search_path='' AS $$
DECLARE t public.ct_direct_trades;b uuid;s uuid;price bigint;side integer;n bigint;items jsonb;qty integer;item_name text;BEGIN
 SELECT * INTO t FROM public.ct_direct_trades WHERE id=p_trade AND status='completed';IF t.id IS NULL THEN RETURN NULL;END IF;
 FOR side IN 1..2 LOOP b:=CASE WHEN side=1 THEN t.a ELSE t.b END;s:=CASE WHEN side=1 THEN t.b ELSE t.a END;price:=CASE WHEN side=1 THEN t.a_diamonds ELSE t.b_diamonds END;
  SELECT coalesce(jsonb_agg(x),'[]'::jsonb),count(*) INTO items,qty FROM jsonb_array_elements(t.final_offer->'items')x WHERE(x->>'owner_id')::uuid=s;
  IF qty=0 AND price=0 THEN CONTINUE;END IF;item_name:=CASE WHEN qty=1 THEN items->0->>'name' ELSE 'Échange direct' END;
  n:=public.ct_order_insert('direct:'||t.id||':'||side,'black',b,s,'trade',coalesce(item_name,'Échange direct'),NULL,1::smallint,greatest(1,qty),price,0,items,jsonb_build_object('trade_id',t.id,'final_offer',t.final_offer,'payment_key',CASE WHEN side=1 THEN 'direct-a:' ELSE 'direct-b:' END||t.id),p_date);
 END LOOP;RETURN n;
END $$;
ALTER FUNCTION public.ct_trade_command(uuid,text,jsonb) RENAME TO ct_trade_command_before_orders;
CREATE FUNCTION public.ct_trade_command(p_operation_id uuid,p_action text,p_values jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r jsonb;n bigint;BEGIN r:=public.ct_trade_command_before_orders(p_operation_id,p_action,p_values);IF p_action='confirm' THEN n:=public.ct_direct_orders((p_values->>'trade_id')::uuid);IF n IS NOT NULL THEN r:=r||jsonb_build_object('order_id',(SELECT id FROM public.ct_orders WHERE source_key LIKE 'direct:'||(p_values->>'trade_id')||':%' AND(buyer_id=auth.uid() OR seller_id=auth.uid()) ORDER BY(buyer_id=auth.uid()) DESC LIMIT 1));END IF;END IF;RETURN r;END $$;
REVOKE ALL ON FUNCTION public.ct_direct_orders(uuid,timestamptz),public.ct_trade_command_before_orders(uuid,text,jsonb),public.ct_trade_command(uuid,text,jsonb) FROM PUBLIC,anon,authenticated;GRANT EXECUTE ON FUNCTION public.ct_trade_command(uuid,text,jsonb) TO authenticated;

CREATE FUNCTION public.ct_order_status(p_id bigint) RETURNS text LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT CASE WHEN EXISTS(SELECT 1 FROM public.ct_order_disputes d JOIN public.ct_support_tickets t ON t.id=d.ticket_id WHERE d.order_id=p_id AND t.status<>'closed') THEN 'disputed' WHEN EXISTS(SELECT 1 FROM public.ct_order_disputes WHERE order_id=p_id) THEN 'resolved' ELSE 'completed' END;
$$;
CREATE FUNCTION public.ct_orders_list(p_filters jsonb DEFAULT '{}',p_admin boolean DEFAULT false) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid:=auth.uid();pg integer:=coalesce((p_filters->>'page')::integer,1);v text:=coalesce(p_filters->>'view','all');m text:=coalesce(p_filters->>'market','all');s text:=coalesce(p_filters->>'status','all');result jsonb;
BEGIN
 IF u IS NULL THEN RAISE EXCEPTION 'Authentication required';END IF;IF p_admin AND NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required';END IF;
 IF p_admin IS NULL OR pg NOT BETWEEN 1 AND 10000 OR v NOT IN('all','purchases','sales') OR m NOT IN('all','player','black') OR s NOT IN('all','completed','disputed','resolved') THEN RAISE EXCEPTION 'Invalid filters';END IF;
 WITH eligible AS MATERIALIZED(SELECT o.*,public.ct_order_status(o.id) status FROM public.ct_orders o WHERE(p_admin OR CASE v WHEN 'purchases' THEN buyer_id=u WHEN 'sales' THEN seller_id=u ELSE buyer_id=u OR seller_id=u END) AND(m='all' OR market=m)
 AND position(lower(left(coalesce(p_filters->>'search',''),80)) IN lower(order_number||' '||buyer_name||' '||seller_name))>0
 AND(nullif(p_filters->>'from','') IS NULL OR created_at>=((p_filters->>'from')::date::timestamp AT TIME ZONE 'UTC')) AND(nullif(p_filters->>'to','') IS NULL OR created_at<(((p_filters->>'to')::date+1)::timestamp AT TIME ZONE 'UTC'))),filtered AS MATERIALIZED(SELECT * FROM eligible WHERE s='all' OR status=s),ranked AS(SELECT *,row_number() OVER(ORDER BY id DESC) rn FROM filtered)
 SELECT jsonb_build_object('orders',coalesce((SELECT jsonb_agg(to_jsonb(x)-'proof'-'lines'-'rn' ORDER BY rn) FROM ranked x WHERE rn>(pg-1)*20 AND rn<=pg*20),'[]'::jsonb),'total',(SELECT count(*) FROM filtered),'pages',greatest(1,ceil((SELECT count(*) FROM filtered)/20.0)),'page',pg) INTO result;RETURN result;
END $$;
CREATE FUNCTION public.ct_order_detail(p_order bigint,p_admin boolean DEFAULT false) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE o public.ct_orders;u uuid:=auth.uid();result jsonb;BEGIN
 IF u IS NULL THEN RAISE EXCEPTION 'Authentication required';END IF;IF p_admin IS NULL OR(p_admin AND NOT public.ct_is_admin()) THEN RAISE EXCEPTION 'Administrator required';END IF;
 SELECT * INTO o FROM public.ct_orders WHERE id=p_order AND(p_admin OR buyer_id=u OR seller_id=u);IF o.id IS NULL THEN RAISE EXCEPTION 'Commande introuvable';END IF;
 result:=to_jsonb(o);IF NOT p_admin THEN result:=result-'proof';END IF;
 RETURN result||jsonb_build_object('status',public.ct_order_status(o.id),'review',(SELECT to_jsonb(r) FROM public.ct_pm_reviews r WHERE order_id=o.id AND(p_admin OR NOT hidden OR buyer_id=u)),'disputes',coalesce((SELECT jsonb_agg(jsonb_build_object('id',d.id,'issue',d.issue,'ticket_id',d.ticket_id,'status',t.status,'user_id',d.user_id)) FROM public.ct_order_disputes d JOIN public.ct_support_tickets t ON t.id=d.ticket_id WHERE d.order_id=o.id AND(p_admin OR d.user_id=u)),'[]'::jsonb),'corrections',coalesce((SELECT jsonb_agg(to_jsonb(c)-'admin_id') FROM public.ct_order_corrections c WHERE c.order_id=o.id),'[]'::jsonb));
END $$;
CREATE FUNCTION public.ct_order_action(p_operation_id uuid,p_action text,p_order bigint,p_values jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;request jsonb:=jsonb_build_object('kind','order_action','action',p_action,'order',p_order,'values',p_values);o public.ct_orders;ticket bigint;result jsonb;rating integer;issue text;who uuid;
BEGIN
 PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,request);IF r IS NOT NULL THEN RETURN r;END IF;PERFORM public.ct_check_rate(u);
 IF p_action='report_seller' THEN
  IF length(trim(coalesce(p_values->>'body',''))) NOT BETWEEN 1 AND 3000 THEN RAISE EXCEPTION 'Précisez le motif et votre réclamation';END IF;who:=(p_values->>'seller')::uuid;IF who=u OR NOT EXISTS(SELECT 1 FROM public.ct_profiles WHERE id=who) THEN RAISE EXCEPTION 'Destinataire indisponible';END IF;
  result:=public.ct_support_command(md5(p_operation_id||':ticket')::uuid,'create',jsonb_build_object('subject','Signalement de boutique','category','market','body','Boutique : '||who||E'\n'||left(p_values->>'body',3000)));ticket:=(result->>'id')::bigint;
 ELSE
  SELECT * INTO o FROM public.ct_orders WHERE id=p_order AND(buyer_id=u OR seller_id=u) FOR UPDATE;IF o.id IS NULL THEN RAISE EXCEPTION 'Commande introuvable';END IF;
  IF p_action='review' THEN
   IF o.market<>'player' OR o.buyer_id<>u THEN RAISE EXCEPTION 'Seul l’acheteur peut évaluer cette vente';END IF;
   rating:=(p_values->>'rating')::integer;IF rating IS NULL OR rating NOT BETWEEN 1 AND 5 OR length(coalesce(p_values->>'comment',''))>1000 THEN RAISE EXCEPTION 'Avis invalide : note de 1 à 5 et 1 000 caractères maximum';END IF;
   IF EXISTS(SELECT 1 FROM public.ct_pm_reviews WHERE order_id=o.id) THEN RAISE EXCEPTION 'Cette commande possède déjà un avis';END IF;
   INSERT INTO public.ct_pm_reviews(order_id,buyer_id,seller_id,rating,comment) VALUES(o.id,u,o.seller_id,rating,coalesce(p_values->>'comment',''));
  ELSIF p_action='dispute' THEN
   issue:=p_values->>'issue';IF issue IS NULL OR issue NOT IN('missing','wrong','payment','seller','other') OR length(trim(coalesce(p_values->>'body',''))) NOT BETWEEN 1 AND 3000 THEN RAISE EXCEPTION 'Précisez le motif et votre réclamation';END IF;
   SELECT ticket_id INTO ticket FROM public.ct_order_disputes WHERE order_id=o.id AND user_id=u;
   IF ticket IS NULL THEN
    result:=public.ct_support_command(md5(p_operation_id||':ticket')::uuid,'create',jsonb_build_object('subject','Commande '||o.order_number,'category','market','body','Commande : '||o.order_number||E'\n'||'Motif : '||CASE issue WHEN 'missing' THEN 'Objet non reçu' WHEN 'wrong' THEN 'Mauvais objet' WHEN 'payment' THEN 'Problème de paiement' WHEN 'seller' THEN 'Réclamation vendeur' ELSE 'Autre problème' END||E'\n'||(p_values->>'body')));ticket:=(result->>'id')::bigint;
    INSERT INTO public.ct_order_disputes(order_id,user_id,issue,ticket_id) VALUES(o.id,u,issue,ticket);
   END IF;
  ELSE RAISE EXCEPTION 'Action inconnue';END IF;
 END IF;
 r:=jsonb_build_object('ok',true,'order_id',p_order,'ticket_id',ticket);INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,request,r);RETURN r;
END $$;

CREATE FUNCTION public.ct_admin_pm(p_search text DEFAULT '',p_page integer DEFAULT 1) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required';END IF;IF p_page IS NULL OR p_page NOT BETWEEN 1 AND 10000 THEN RAISE EXCEPTION 'Invalid filters';END IF;
 RETURN jsonb_build_object('stats',(SELECT jsonb_build_object('orders',count(*),'volume',coalesce(sum(total),0),'commission',coalesce(sum(fee),0),'sellers',count(DISTINCT seller_id)) FROM public.ct_orders WHERE market='player'),'active',(SELECT count(*) FROM public.ct_pm_listings WHERE status='active'),'reviews',coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM(SELECT r.*,o.order_number,o.seller_name,o.buyer_name FROM public.ct_pm_reviews r JOIN public.ct_orders o ON o.id=r.order_id WHERE position(lower(left(coalesce(p_search,''),80)) IN lower(o.seller_name||' '||o.buyer_name||' '||r.comment))>0 ORDER BY r.order_id DESC LIMIT 20 OFFSET(p_page-1)*20)x),'[]'::jsonb),'disputes',coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM(SELECT d.*,o.order_number,o.market,o.buyer_name,o.seller_name,t.status,t.subject,(SELECT body FROM public.ct_support_messages WHERE ticket_id=t.id ORDER BY id LIMIT 1) body FROM public.ct_order_disputes d JOIN public.ct_orders o ON o.id=d.order_id JOIN public.ct_support_tickets t ON t.id=d.ticket_id WHERE position(lower(left(coalesce(p_search,''),80)) IN lower(o.order_number||' '||o.buyer_name||' '||o.seller_name))>0 ORDER BY d.id DESC LIMIT 20 OFFSET(p_page-1)*20)x),'[]'::jsonb),'blocked',coalesce((SELECT jsonb_agg(jsonb_build_object('id',b.user_id,'username',p.username,'reason',b.reason)) FROM public.ct_pm_seller_blocks b JOIN public.ct_profiles p ON p.id=b.user_id),'[]'::jsonb));
END $$;
CREATE FUNCTION public.ct_admin_order_action(p_operation_id uuid,p_action text,p_order bigint,p_values jsonb,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;request jsonb:=jsonb_build_object('kind','admin_orders','action',p_action,'order',p_order,'values',p_values,'reason',p_reason);o public.ct_orders;target uuid;amount bigint;tx jsonb;ref text;currency text;
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required';END IF;
 PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,request);IF r IS NOT NULL THEN RETURN r;END IF;PERFORM public.ct_check_rate(u);
 IF length(trim(coalesce(p_reason,''))) NOT BETWEEN 8 AND 1000 THEN RAISE EXCEPTION 'Justification administrateur requise';END IF;
 IF p_action='cancel_listing' THEN
  UPDATE public.ct_pm_listings SET status='cancelled',version=version+1 WHERE id=(p_values->>'id')::bigint AND status='active';IF NOT FOUND THEN RAISE EXCEPTION 'Annonce indisponible';END IF;DELETE FROM public.ct_pm_assets WHERE listing_id=(p_values->>'id')::bigint AND NOT sold;
 ELSIF p_action='block_seller' THEN
  target:=(p_values->>'seller')::uuid;IF target=u THEN RAISE EXCEPTION 'Vous ne pouvez pas suspendre votre propre boutique';END IF;
  IF(p_values->>'blocked')::boolean THEN INSERT INTO public.ct_pm_seller_blocks(user_id,reason) VALUES(target,p_reason) ON CONFLICT(user_id) DO UPDATE SET reason=EXCLUDED.reason;ELSE DELETE FROM public.ct_pm_seller_blocks WHERE user_id=target;END IF;
 ELSIF p_action='moderate_review' THEN
  UPDATE public.ct_pm_reviews SET hidden=(p_values->>'hidden')::boolean WHERE order_id=p_order;IF NOT FOUND THEN RAISE EXCEPTION 'Avis introuvable';END IF;
 ELSIF p_action='close_dispute' THEN
  UPDATE public.ct_support_tickets SET status='closed',version=version+1,updated_at=now() WHERE id=(p_values->>'ticket_id')::bigint AND id IN(SELECT ticket_id FROM public.ct_order_disputes WHERE order_id=p_order);IF NOT FOUND THEN RAISE EXCEPTION 'Réclamation introuvable';END IF;
  INSERT INTO public.ct_support_messages(ticket_id,author_id,is_admin,body) VALUES((p_values->>'ticket_id')::bigint,u,true,p_reason);
 ELSIF p_action='correction' THEN
  SELECT * INTO o FROM public.ct_orders WHERE id=p_order FOR UPDATE;IF o.id IS NULL OR NOT EXISTS(SELECT 1 FROM public.ct_order_disputes WHERE order_id=o.id) THEN RAISE EXCEPTION 'Une réclamation est requise avant correction';END IF;
  target:=(p_values->>'target')::uuid;amount:=(p_values->>'amount')::bigint;currency:=p_values->>'currency';
  IF target NOT IN(o.buyer_id,o.seller_id) OR amount IS NULL OR amount=0 OR abs(amount)>1000000000 OR currency IS DISTINCT FROM o.currency THEN RAISE EXCEPTION 'Correction invalide';END IF;
  IF currency='credits' THEN tx:=public.ct_post_credit(target,amount,'order_correction','order-correction:'||p_operation_id);ref:=tx->>'transaction_id';
  ELSE IF amount<0 AND coalesce((SELECT balance FROM public.ct_diamond_wallets WHERE user_id=target),0)-public.ct_direct_diamonds(target)<-amount THEN RAISE EXCEPTION 'Diamants disponibles insuffisants';END IF;PERFORM public.ct_post_diamond(target,amount,'order_correction','order-correction:'||p_operation_id);SELECT id::text INTO ref FROM public.ct_diamond_ledger WHERE user_id=target AND operation_key='order-correction:'||p_operation_id;END IF;
  INSERT INTO public.ct_order_corrections(order_id,admin_id,target_id,currency,amount,reason,transaction_ref) VALUES(o.id,u,target,currency,amount,p_reason,ref);
 ELSE RAISE EXCEPTION 'Action inconnue';END IF;
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(u,'orders_'||p_action,coalesce(p_order::text,target::text,p_values->>'id'),p_reason,p_values||jsonb_build_object('order_id',p_order));
 r:=jsonb_build_object('ok',true,'order_id',p_order);INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,request,r);RETURN r;
END $$;
REVOKE ALL ON FUNCTION public.ct_order_status(bigint),public.ct_orders_list(jsonb,boolean),public.ct_order_detail(bigint,boolean),public.ct_order_action(uuid,text,bigint,jsonb),public.ct_admin_pm(text,integer),public.ct_admin_order_action(uuid,text,bigint,jsonb,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_orders_list(jsonb,boolean),public.ct_order_detail(bigint,boolean),public.ct_order_action(uuid,text,bigint,jsonb),public.ct_admin_pm(text,integer),public.ct_admin_order_action(uuid,text,bigint,jsonb,text) TO authenticated;
-- Backfill from immutable operation receipts and actual matching payment ledgers only.
DO $$ DECLARE op record;t record;BEGIN
 FOR op IN SELECT user_id,operation_id FROM public.ct_operations WHERE(request->>'kind' IN('market','wholesale','credit_market') AND request->>'action' IN('accept','buy')) OR request->>'kind'='market_chest_group' ORDER BY created_at LOOP PERFORM public.ct_black_order(op.operation_id,op.user_id);END LOOP;
 FOR t IN SELECT id,created_at FROM public.ct_direct_trades WHERE status='completed' LOOP PERFORM public.ct_direct_orders(t.id,coalesce((SELECT max(created_at) FROM public.ct_diamond_ledger WHERE operation_key IN('direct-a:'||t.id,'direct-b:'||t.id)),(SELECT max(created_at) FROM public.ct_operations WHERE request->>'kind'='direct_trade' AND request->>'action'='confirm' AND request->'values'->>'trade_id'=t.id::text),t.created_at));END LOOP;
END $$;
COMMIT;
