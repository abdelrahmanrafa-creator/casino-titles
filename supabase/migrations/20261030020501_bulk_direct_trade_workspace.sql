-- Retain the existing atomic settlement, card checks, idempotency and receipt wrappers.
CREATE OR REPLACE FUNCTION public.ct_trade_command_before_circle(p_operation_id uuid,p_action text,p_values jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;t public.ct_direct_trades;v_target uuid;r jsonb;q jsonb:=jsonb_build_object('kind','direct_trade','action',p_action,'values',p_values);v_items jsonb;v_item jsonb;v_kind text;v_asset uuid;v_amount bigint;v_rec record;v_count integer;
BEGIN
 PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;PERFORM public.ct_check_rate(u);
 UPDATE public.ct_direct_trades SET status='cancelled' WHERE status IN('pending','open') AND expires_at<=now();DELETE FROM public.ct_direct_assets WHERE trade_id IN(SELECT id FROM public.ct_direct_trades WHERE status IN('cancelled','completed'));
 IF p_action='invite' THEN
  IF NOT(SELECT market_enabled FROM public.ct_market_settings WHERE id) THEN RAISE EXCEPTION 'Échanges suspendus';END IF;
  SELECT p.id INTO v_target FROM public.ct_profiles p WHERE lower(username)=lower(trim(p_values->>'username')) AND NOT is_bot AND NOT EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=p.id);
  IF v_target IS NULL OR v_target=u THEN RAISE EXCEPTION 'Joueur indisponible pour cet échange';END IF;
  IF(SELECT count(*) FROM public.ct_direct_trades WHERE status IN('pending','open') AND(a=u OR b=u))>=5 OR(SELECT count(*) FROM public.ct_direct_trades WHERE status IN('pending','open') AND(a=v_target OR b=v_target))>=5 THEN RAISE EXCEPTION 'Cinq échanges en attente maximum par joueur';END IF;
  IF EXISTS(SELECT 1 FROM public.ct_direct_trades WHERE status IN('pending','open') AND((a=u AND b=v_target) OR(a=v_target AND b=u))) THEN RAISE EXCEPTION 'Un échange est déjà en cours avec ce joueur';END IF;
  INSERT INTO public.ct_direct_trades(a,b) VALUES(u,v_target) RETURNING * INTO t;
 ELSE
  SELECT * INTO t FROM public.ct_direct_trades WHERE id=(p_values->>'trade_id')::uuid FOR UPDATE;
  IF NOT FOUND OR u NOT IN(t.a,t.b) THEN RAISE EXCEPTION 'Échange introuvable' USING ERRCODE='42501';END IF;
  IF t.status NOT IN('pending','open') OR t.expires_at<=now() THEN RAISE EXCEPTION 'Échange terminé ou expiré';END IF;
  IF p_action='cancel' THEN
   UPDATE public.ct_direct_trades SET status='cancelled',version=version+1 WHERE id=t.id;DELETE FROM public.ct_direct_assets WHERE trade_id=t.id;
  ELSE
   IF NOT(SELECT market_enabled AND NOT wallets_frozen FROM public.ct_market_settings WHERE id) THEN RAISE EXCEPTION 'Échanges temporairement suspendus ou figés';END IF;
   IF EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id IN(t.a,t.b)) THEN RAISE EXCEPTION 'Un participant est suspendu';END IF;
   IF(p_values->>'version')::bigint IS DISTINCT FROM t.version THEN RAISE EXCEPTION 'L’offre a changé. Relisez les objets avant de confirmer.';END IF;
   IF p_action='accept' AND t.status='pending' AND t.b=u THEN
    UPDATE public.ct_direct_trades SET status='open',version=version+1,expires_at=now()+interval '30 minutes' WHERE id=t.id;
   ELSIF p_action='offer' AND t.status='open' THEN
    v_items:=coalesce(p_values->'items','[]');IF jsonb_typeof(v_items)<>'array' OR jsonb_array_length(v_items)>1000 THEN RAISE EXCEPTION 'Mille objets maximum par offre';END IF;
    v_amount:=(p_values->>'diamonds')::bigint;
    IF v_amount IS NULL OR v_amount NOT BETWEEN 0 AND 1000000000 OR v_amount>coalesce((SELECT balance FROM public.ct_diamond_wallets WHERE user_id=u),0)-public.ct_direct_diamonds(u,t.id) THEN RAISE EXCEPTION 'Diamants disponibles insuffisants';END IF;
    DELETE FROM public.ct_direct_assets WHERE trade_id=t.id AND owner_id=u;
    FOR v_item IN SELECT * FROM jsonb_array_elements(v_items) LOOP
     v_kind:=v_item->>'kind';v_asset:=(v_item->>'id')::uuid;PERFORM public.ct_market_asset(u,v_kind,v_asset);
     IF public.ct_direct_reserved(v_kind,v_asset,t.id) OR EXISTS(SELECT 1 FROM public.ct_market_listings WHERE asset_kind=v_kind AND asset_id=v_asset AND status='active' AND expires_at>now()) THEN RAISE EXCEPTION 'Objet déjà réservé';END IF;
     INSERT INTO public.ct_direct_assets(trade_id,owner_id,kind,asset_id) VALUES(t.id,u,v_kind,v_asset);
     IF v_kind='title' THEN DELETE FROM public.ct_equipped_titles WHERE player_title_id=v_asset;END IF;
    END LOOP;
    UPDATE public.ct_direct_trades SET a_diamonds=CASE WHEN u=a THEN v_amount ELSE a_diamonds END,b_diamonds=CASE WHEN u=b THEN v_amount ELSE b_diamonds END,a_confirmed=false,b_confirmed=false,version=version+1 WHERE id=t.id;
   ELSIF p_action='confirm' AND t.status='open' THEN
    IF NOT EXISTS(SELECT 1 FROM public.ct_direct_assets WHERE trade_id=t.id) AND t.a_diamonds=0 AND t.b_diamonds=0 THEN RAISE EXCEPTION 'Ajoutez au moins un objet ou des diamants';END IF;
    UPDATE public.ct_direct_trades SET a_confirmed=CASE WHEN u=a THEN true ELSE a_confirmed END,b_confirmed=CASE WHEN u=b THEN true ELSE b_confirmed END WHERE id=t.id RETURNING * INTO t;
    IF t.a_confirmed AND t.b_confirmed THEN
     PERFORM 1 FROM public.ct_wallets WHERE user_id IN(t.a,t.b) ORDER BY user_id FOR UPDATE;
     IF coalesce((SELECT balance FROM public.ct_diamond_wallets WHERE user_id=t.a),0)-public.ct_direct_diamonds(t.a,t.id)<t.a_diamonds OR coalesce((SELECT balance FROM public.ct_diamond_wallets WHERE user_id=t.b),0)-public.ct_direct_diamonds(t.b,t.id)<t.b_diamonds THEN RAISE EXCEPTION 'Les diamants proposés ne sont plus disponibles';END IF;
     FOR v_rec IN SELECT * FROM public.ct_direct_assets WHERE trade_id=t.id LOOP PERFORM public.ct_market_asset(v_rec.owner_id,v_rec.kind,v_rec.asset_id);END LOOP;
     UPDATE public.ct_direct_trades SET status='completed',final_offer=jsonb_build_object('version',t.version,'a_diamonds',t.a_diamonds,'b_diamonds',t.b_diamonds,'items',(SELECT coalesce(jsonb_agg(jsonb_build_object('id',i.asset_id,'kind',i.kind,'owner_id',i.owner_id,'name',coalesce(x.name,s.name),'rarity',coalesce(x.rarity,s.rarity))),'[]'::jsonb) FROM public.ct_direct_assets i LEFT JOIN public.ct_player_titles p ON i.kind='title' AND p.id=i.asset_id LEFT JOIN public.ct_titles x ON x.id=p.title_id LEFT JOIN public.ct_sealed_chests s ON i.kind='chest' AND s.id=i.asset_id WHERE i.trade_id=t.id)) WHERE id=t.id;
     FOR v_rec IN SELECT * FROM public.ct_direct_assets WHERE trade_id=t.id LOOP PERFORM public.ct_market_transfer(v_rec.owner_id,CASE WHEN v_rec.owner_id=t.a THEN t.b ELSE t.a END,v_rec.kind,v_rec.asset_id);END LOOP;
     IF t.a_diamonds>0 THEN PERFORM public.ct_post_diamond(t.a,-t.a_diamonds,'direct_trade','direct-a:'||t.id::text);PERFORM public.ct_post_diamond(t.b,t.a_diamonds,'direct_trade','direct-a:'||t.id::text);END IF;
     IF t.b_diamonds>0 THEN PERFORM public.ct_post_diamond(t.b,-t.b_diamonds,'direct_trade','direct-b:'||t.id::text);PERFORM public.ct_post_diamond(t.a,t.b_diamonds,'direct_trade','direct-b:'||t.id::text);END IF;
     DELETE FROM public.ct_direct_assets WHERE trade_id=t.id;
    END IF;
   ELSE RAISE EXCEPTION 'Action impossible dans cet état';END IF;
  END IF;
 END IF;
 SELECT jsonb_build_object('ok',true,'trade_id',id,'status',status,'version',version) INTO r FROM public.ct_direct_trades WHERE id=t.id;
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;
END $$;

-- Stable group identity keeps custom chests with different contents separate.
CREATE FUNCTION public.ct_trade_group_key(k text,d text,n text,r integer,w jsonb DEFAULT NULL,ids jsonb DEFAULT NULL,e text DEFAULT NULL) RETURNS text LANGUAGE sql IMMUTABLE SET search_path='' AS $$
 SELECT md5(jsonb_build_array(k,d,n,r,w,ids,e)::text)
$$;
REVOKE ALL ON FUNCTION public.ct_trade_group_key(text,text,text,integer,jsonb,jsonb,text) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.ct_trade_inventory_rows(u uuid,t uuid) RETURNS TABLE(asset_id uuid,kind text,group_key text,name text,rarity integer) LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT p.id,'title',public.ct_trade_group_key('title',x.id,x.name,x.rarity::integer),x.name,x.rarity::integer
 FROM public.ct_player_titles p JOIN public.ct_titles x ON x.id=p.title_id
 WHERE p.user_id=u AND p.revoked_at IS NULL AND p.quantity=1 AND NOT public.ct_direct_reserved('title',p.id,t)
 AND NOT EXISTS(SELECT 1 FROM public.ct_market_listings WHERE asset_kind='title' AND asset_id=p.id AND status='active' AND expires_at>now())
 UNION ALL
 SELECT s.id,'chest',public.ct_trade_group_key('chest',s.chest_id::text,s.name,s.rarity::integer,to_jsonb(s.weights),to_jsonb(s.title_ids),s.event_key),s.name,s.rarity::integer
 FROM public.ct_sealed_chests s WHERE s.user_id=u AND s.opened_at IS NULL AND NOT public.ct_direct_reserved('chest',s.id,t)
 AND NOT EXISTS(SELECT 1 FROM public.ct_market_listings WHERE asset_kind='chest' AND asset_id=s.id AND status='active' AND expires_at>now())
$$;
REVOKE ALL ON FUNCTION public.ct_trade_inventory_rows(uuid,uuid) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.ct_trade_workspace(p_trade_id uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid:=auth.uid();t public.ct_direct_trades;offers jsonb;inventory jsonb;
BEGIN
 SELECT * INTO t FROM public.ct_direct_trades WHERE id=p_trade_id AND u IN(a,b);
 IF NOT FOUND THEN RAISE EXCEPTION 'Échange introuvable' USING ERRCODE='42501';END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(g) ORDER BY g.kind,g.rarity DESC,g.name,g.key),'[]') INTO inventory FROM(
  SELECT group_key key,kind,name,rarity,count(*)::integer available FROM public.ct_trade_inventory_rows(u,t.id) GROUP BY group_key,kind,name,rarity
 )g;
 WITH rows AS(
  SELECT i.owner_id,i.kind,coalesce(x.name,s.name) name,coalesce(x.rarity,s.rarity)::integer rarity,
   public.ct_trade_group_key(i.kind,coalesce(x.id,s.chest_id::text),coalesce(x.name,s.name),coalesce(x.rarity,s.rarity)::integer,CASE WHEN i.kind='chest' THEN to_jsonb(s.weights) END,CASE WHEN i.kind='chest' THEN to_jsonb(s.title_ids) END,s.event_key) key
  FROM public.ct_direct_assets i LEFT JOIN public.ct_player_titles p ON i.kind='title' AND p.id=i.asset_id LEFT JOIN public.ct_titles x ON x.id=p.title_id LEFT JOIN public.ct_sealed_chests s ON i.kind='chest' AND s.id=i.asset_id WHERE i.trade_id=t.id
  UNION ALL
  SELECT (j->>'owner_id')::uuid,j->>'kind',j->>'name',(j->>'rarity')::integer,md5(jsonb_build_array(j->>'kind',j->>'name',j->>'rarity')::text)
  FROM jsonb_array_elements(coalesce(t.final_offer->'items','[]')) j WHERE t.status='completed'
 ) SELECT coalesce(jsonb_agg(to_jsonb(g) ORDER BY g.owner_id,g.kind,g.rarity DESC,g.name),'[]') INTO offers FROM(
  SELECT owner_id,kind,name,rarity,key,count(*)::integer quantity FROM rows GROUP BY owner_id,kind,name,rarity,key
 )g;
 RETURN (to_jsonb(t)-'final_offer')||jsonb_build_object('a_name',(SELECT username FROM public.ct_profiles WHERE id=t.a),'b_name',(SELECT username FROM public.ct_profiles WHERE id=t.b),'my_balance',coalesce((SELECT balance FROM public.ct_diamond_wallets WHERE user_id=u),0),'my_reserved',public.ct_direct_diamonds(u,t.id),'groups',inventory,'offers',offers,'max_items',1000);
END $$;
REVOKE ALL ON FUNCTION public.ct_trade_workspace(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_trade_workspace(uuid) TO authenticated;

CREATE FUNCTION public.ct_trade_bulk_offer(p_operation_id uuid,p_values jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;t public.ct_direct_trades;r jsonb;q jsonb:=jsonb_build_object('kind','bulk_direct_trade','values',p_values);groups jsonb:=coalesce(p_values->'groups','[]');g jsonb;n integer;total integer:=0;items jsonb:='[]';chosen uuid[];existing uuid[];amount bigint;
BEGIN
 PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;
 SELECT * INTO t FROM public.ct_direct_trades WHERE id=(p_values->>'trade_id')::uuid AND u IN(a,b) FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Échange introuvable' USING ERRCODE='42501';END IF;
 IF t.status<>'open' OR t.expires_at<=now() THEN RAISE EXCEPTION 'Échange terminé ou expiré';END IF;
 IF (p_values->>'version')::bigint IS DISTINCT FROM t.version THEN RAISE EXCEPTION 'L’offre a changé. Relisez les objets avant de confirmer.';END IF;
 IF NOT public.ct_circle_member(t.a) OR NOT public.ct_circle_member(t.b) THEN RAISE EXCEPTION 'Carte active requise pour les deux joueurs';END IF;
 IF NOT(SELECT market_enabled AND NOT wallets_frozen FROM public.ct_market_settings WHERE id) OR EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id IN(t.a,t.b)) THEN RAISE EXCEPTION 'Échanges temporairement suspendus ou figés';END IF;
 IF jsonb_typeof(groups)<>'array' OR jsonb_array_length(groups)>1000 THEN RAISE EXCEPTION 'Sélection d’objets invalide';END IF;
 IF (SELECT count(DISTINCT value->>'key') FROM jsonb_array_elements(groups))<>jsonb_array_length(groups) THEN RAISE EXCEPTION 'Un groupe ne peut apparaître qu’une fois';END IF;
 amount:=(p_values->>'diamonds')::bigint;
 IF amount IS NULL OR amount NOT BETWEEN 0 AND 1000000000 OR amount>coalesce((SELECT balance FROM public.ct_diamond_wallets WHERE user_id=u),0)-public.ct_direct_diamonds(u,t.id) THEN RAISE EXCEPTION 'Diamants disponibles insuffisants';END IF;
 FOR g IN SELECT value FROM jsonb_array_elements(groups) LOOP
  IF jsonb_typeof(g->'quantity') IS DISTINCT FROM 'number' OR (g->>'quantity') !~ '^[0-9]+$' OR length(g->>'quantity')>4 THEN RAISE EXCEPTION 'Quantité d’échange invalide';END IF;
  n:=(g->>'quantity')::integer;total:=total+n;
  IF n<1 OR total>1000 THEN RAISE EXCEPTION 'Mille objets maximum par offre';END IF;
 END LOOP;
 -- Scan the available inventory once, even when selecting hundreds of different titles.
 WITH wanted AS(SELECT value->>'key' key,(value->>'quantity')::integer quantity FROM jsonb_array_elements(groups)),ranked AS(
  SELECT a.*,w.quantity,row_number() OVER(PARTITION BY a.group_key ORDER BY EXISTS(SELECT 1 FROM public.ct_direct_assets d WHERE d.trade_id=t.id AND d.owner_id=u AND d.asset_id=a.asset_id AND d.kind=a.kind) DESC,a.asset_id) rn
  FROM public.ct_trade_inventory_rows(u,t.id) a JOIN wanted w ON w.key=a.group_key
 ) SELECT coalesce(jsonb_agg(jsonb_build_object('id',asset_id,'kind',kind) ORDER BY asset_id),'[]') INTO items FROM ranked WHERE rn<=quantity;
 IF jsonb_array_length(items)<>total THEN RAISE EXCEPTION 'La quantité demandée n’est plus disponible';END IF;
 SELECT coalesce(array_agg((j->>'id')::uuid ORDER BY j->>'id'),'{}') INTO chosen FROM jsonb_array_elements(items) j;
 SELECT coalesce(array_agg(asset_id ORDER BY asset_id::text),'{}') INTO existing FROM public.ct_direct_assets WHERE trade_id=t.id AND owner_id=u;
 IF chosen=existing AND amount=(CASE WHEN u=t.a THEN t.a_diamonds ELSE t.b_diamonds END) THEN
  PERFORM public.ct_check_rate(u);
  r:=jsonb_build_object('ok',true,'trade_id',t.id,'status',t.status,'version',t.version);
 ELSE
  r:=public.ct_trade_command(gen_random_uuid(),'offer',jsonb_build_object('trade_id',t.id,'version',t.version,'diamonds',amount,'items',items));
 END IF;
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;
END $$;
REVOKE ALL ON FUNCTION public.ct_trade_bulk_offer(uuid,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_trade_bulk_offer(uuid,jsonb) TO authenticated;

-- Inventory keeps the actual stored contents and separates custom pools when stacking.
CREATE OR REPLACE FUNCTION public.ct_sealed_inventory() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(x.item||jsonb_build_object('edition_number',s.edition_number,'event_key',s.event_key,'pool_key',public.ct_trade_group_key('chest',s.chest_id::text,s.name,s.rarity::integer,to_jsonb(s.weights),to_jsonb(s.title_ids),s.event_key),'custom_pool',s.title_ids IS NOT NULL,'pool_size',cardinality(s.title_ids),'purchase_price',s.purchase_price) ORDER BY x.n),'[]'::jsonb)
 FROM jsonb_array_elements(public.ct_sealed_inventory_before_editions()) WITH ORDINALITY x(item,n) JOIN public.ct_sealed_chests s ON s.id=(x.item->>'id')::uuid WHERE s.user_id=auth.uid();
$$;
REVOKE ALL ON FUNCTION public.ct_sealed_inventory() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_sealed_inventory() TO authenticated;
