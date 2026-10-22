BEGIN;
ALTER TABLE public.ct_quests ADD COLUMN reward_chest_id smallint REFERENCES public.ct_chest_types(id),ADD COLUMN reward_chest_count integer NOT NULL DEFAULT 1 CHECK(reward_chest_count BETWEEN 1 AND 5);
ALTER TABLE public.ct_promos ADD COLUMN reward_chest_id smallint REFERENCES public.ct_chest_types(id),ADD COLUMN reward_chest_count integer NOT NULL DEFAULT 1 CHECK(reward_chest_count BETWEEN 1 AND 5);
CREATE INDEX ct_quests_reward_chest ON public.ct_quests(reward_chest_id);
CREATE INDEX ct_promos_reward_chest ON public.ct_promos(reward_chest_id);
DO $$ DECLARE c record;BEGIN
 FOR c IN SELECT conname FROM pg_constraint WHERE conrelid='public.ct_quests'::regclass AND contype='c' AND pg_get_constraintdef(oid) LIKE '%reward > 0%' LOOP EXECUTE format('ALTER TABLE public.ct_quests DROP CONSTRAINT %I',c.conname);END LOOP;
 FOR c IN SELECT conname FROM pg_constraint WHERE conrelid='public.ct_promos'::regclass AND contype='c' AND pg_get_constraintdef(oid) LIKE '%credits > 0%' AND pg_get_constraintdef(oid) LIKE '%title_id%' LOOP EXECUTE format('ALTER TABLE public.ct_promos DROP CONSTRAINT %I',c.conname);END LOOP;
END $$;
ALTER TABLE public.ct_quests ADD CONSTRAINT ct_quest_reward_nonempty CHECK(reward>=0 AND(reward>0 OR reward_chest_id IS NOT NULL));
ALTER TABLE public.ct_promos ADD CONSTRAINT ct_promo_reward_nonempty CHECK(credits>0 OR title_id IS NOT NULL OR reward_chest_id IS NOT NULL);
CREATE FUNCTION public.ct_grant_sealed(p_user uuid,p_chest smallint,p_count integer) RETURNS jsonb LANGUAGE plpgsql SET search_path='' AS $$
DECLARE c public.ct_chest_types;ids text[];v_id uuid;v_result jsonb:='[]';r integer;k integer;
BEGIN
 IF p_count IS NULL OR p_count NOT BETWEEN 1 AND 5 THEN RAISE EXCEPTION 'Choisissez 1 à 5 coffres';END IF;
 SELECT * INTO c FROM public.ct_chest_types WHERE id=p_chest AND active AND category='standard' AND stock_limit IS NULL AND per_player_limit IS NULL AND(starts_at IS NULL OR starts_at<=now()) AND(ends_at IS NULL OR ends_at>now()) FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Coffre de récompense indisponible';END IF;
 PERFORM id FROM public.ct_titles WHERE available AND(NOT exclusive OR c.allow_exclusive) AND(c.title_pool IS NULL OR id=ANY(c.title_pool)) ORDER BY id FOR SHARE;
 SELECT array_agg(id ORDER BY id) INTO ids FROM public.ct_titles WHERE available AND(NOT exclusive OR c.allow_exclusive) AND(c.title_pool IS NULL OR id=ANY(c.title_pool));
 FOR r IN 1..8 LOOP IF c.weights[r]>0 AND NOT EXISTS(SELECT 1 FROM public.ct_titles WHERE id=ANY(ids) AND rarity=r) THEN RAISE EXCEPTION 'Catalogue du coffre incomplet';END IF;END LOOP;
 FOR k IN 1..p_count LOOP INSERT INTO public.ct_sealed_chests(user_id,chest_id,name,rarity,weights,title_ids) VALUES(p_user,c.id,c.name,c.rarity,c.weights,ids) RETURNING id INTO v_id;v_result:=v_result||jsonb_build_array(jsonb_build_object('id',v_id,'name',c.name));END LOOP;
 RETURN v_result;
END $$;
REVOKE ALL ON FUNCTION public.ct_grant_sealed(uuid,smallint,integer) FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.ct_admin_save_quest(p_operation_id uuid,p_values jsonb,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid:=auth.uid();v_request jsonb:=jsonb_build_object('kind','save_quest','values',p_values,'reason',p_reason);v_result jsonb;v_id text:=p_values->>'id';
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator unlock required' USING ERRCODE='42501';END IF;
 IF p_reason IS NULL OR length(trim(p_reason))<8 THEN RAISE EXCEPTION 'Justification required';END IF;
 IF v_id IS NULL OR v_id!~'^[a-zA-Z0-9_-]{1,80}$' OR p_values->>'kind' NOT IN('profile','games','chests','titles','variety','card_win') OR (p_values->>'reward')::bigint NOT BETWEEN 0 AND 100000 OR length(trim(coalesce(p_values->>'name','')))<2 THEN RAISE EXCEPTION 'Invalid quest';END IF;
 PERFORM pg_advisory_xact_lock(173,2);v_result:=public.ct_replay(v_uid,p_operation_id,v_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 INSERT INTO public.ct_quests(id,name,description,kind,target,reward,active,reward_chest_id,reward_chest_count) VALUES(v_id,p_values->>'name',p_values->>'description',p_values->>'kind',(p_values->>'target')::integer,(p_values->>'reward')::bigint,coalesce((p_values->>'active')::boolean,true),nullif(p_values->>'reward_chest_id','')::smallint,coalesce((p_values->>'reward_chest_count')::integer,1))
 ON CONFLICT(id) DO UPDATE SET name=EXCLUDED.name,description=EXCLUDED.description,kind=EXCLUDED.kind,target=EXCLUDED.target,reward=EXCLUDED.reward,active=EXCLUDED.active,reward_chest_id=EXCLUDED.reward_chest_id,reward_chest_count=EXCLUDED.reward_chest_count;
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(v_uid,'save_quest',v_id,p_reason,p_values);
 v_result:='{"ok":true}'::jsonb;INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(v_uid,p_operation_id,v_request,v_result);RETURN v_result;
END $$;
CREATE OR REPLACE FUNCTION public.ct_admin_save_promo(p_operation_id uuid,p_values jsonb,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid:=auth.uid();v_request jsonb:=jsonb_build_object('kind','save_promo','values',p_values,'reason',p_reason);v_result jsonb;v_code text:=upper(trim(p_values->>'code'));v_existing public.ct_promos;
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 IF p_reason IS NULL OR length(trim(p_reason))<8 THEN RAISE EXCEPTION 'Justification required';END IF;
 PERFORM pg_advisory_xact_lock(173,3);v_result:=public.ct_replay(v_uid,p_operation_id,v_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 SELECT * INTO v_existing FROM public.ct_promos WHERE code=v_code FOR UPDATE;
 IF FOUND AND (p_values->>'version')::bigint IS DISTINCT FROM v_existing.version THEN RAISE EXCEPTION 'Code modifié depuis son affichage';END IF;
 INSERT INTO public.ct_promos(code,name,credits,title_id,active,starts_at,ends_at,max_uses,reward_chest_id,reward_chest_count) VALUES(v_code,p_values->>'name',(p_values->>'credits')::bigint,nullif(p_values->>'title_id',''),(p_values->>'active')::boolean,(p_values->>'starts_at')::timestamptz,(p_values->>'ends_at')::timestamptz,(p_values->>'max_uses')::integer,nullif(p_values->>'reward_chest_id','')::smallint,coalesce((p_values->>'reward_chest_count')::integer,1))
 ON CONFLICT(code) DO UPDATE SET name=EXCLUDED.name,credits=EXCLUDED.credits,title_id=EXCLUDED.title_id,active=EXCLUDED.active,starts_at=EXCLUDED.starts_at,ends_at=EXCLUDED.ends_at,max_uses=EXCLUDED.max_uses,version=ct_promos.version+1,reward_chest_id=EXCLUDED.reward_chest_id,reward_chest_count=EXCLUDED.reward_chest_count;
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(v_uid,'save_promo',v_code,p_reason,p_values);
 v_result:='{"ok":true}'::jsonb;INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(v_uid,p_operation_id,v_request,v_result);RETURN v_result;
END $$;
CREATE OR REPLACE FUNCTION public.ct_claim_quest_v1(p_operation_id uuid,p_quest_id text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid;v_request jsonb:=jsonb_build_object('kind','quest','quest_id',p_quest_id);v_result jsonb;q public.ct_quests;
BEGIN
 v_uid:=public.ct_lock_wallet();v_result:=public.ct_replay(v_uid,p_operation_id,v_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 PERFORM public.ct_check_rate(v_uid);SELECT * INTO q FROM public.ct_quests WHERE id=p_quest_id FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown quest';END IF;
 IF EXISTS(SELECT 1 FROM public.ct_quest_claims WHERE user_id=v_uid AND quest_id=q.id) THEN RAISE EXCEPTION 'Quest already claimed';END IF;
 IF public.ct_quest_progress(v_uid,q.kind)<q.target THEN RAISE EXCEPTION 'Quest not completed';END IF;
 INSERT INTO public.ct_quest_claims(user_id,quest_id) VALUES(v_uid,q.id);
 IF q.reward>0 THEN v_result:=public.ct_post_credit(v_uid,q.reward,'quest','quest:'||q.id);ELSE v_result:=jsonb_build_object('amount',0);END IF;
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(v_uid,p_operation_id,v_request,v_result);RETURN v_result;
END $$;
ALTER FUNCTION public.ct_claim_quest(uuid,text) RENAME TO ct_claim_quest_before_chests;
REVOKE ALL ON FUNCTION public.ct_claim_quest_before_chests(uuid,text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_claim_quest(p_operation_id uuid,p_quest_id text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;v_chest smallint;v_count integer;
BEGIN PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,jsonb_build_object('kind','quest','quest_id',p_quest_id));IF r IS NOT NULL THEN RETURN r;END IF;
 r:=public.ct_claim_quest_before_chests(p_operation_id,p_quest_id);
 SELECT reward_chest_id,reward_chest_count INTO v_chest,v_count FROM public.ct_quests WHERE id=p_quest_id FOR SHARE;
 IF v_chest IS NOT NULL THEN r:=r||jsonb_build_object('sealed_chests',public.ct_grant_sealed(u,v_chest,v_count));UPDATE public.ct_operations SET result=r WHERE user_id=u AND operation_id=p_operation_id;END IF;RETURN r;END $$;
REVOKE ALL ON FUNCTION public.ct_claim_quest(uuid,text) FROM PUBLIC,anon,authenticated;GRANT EXECUTE ON FUNCTION public.ct_claim_quest(uuid,text) TO authenticated;
ALTER FUNCTION public.ct_redeem_promo(uuid,text) RENAME TO ct_redeem_promo_before_chests;
REVOKE ALL ON FUNCTION public.ct_redeem_promo_before_chests(uuid,text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_redeem_promo(p_operation_id uuid,p_code text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;v_chest smallint;v_count integer;
BEGIN PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,jsonb_build_object('kind','promo','code',upper(trim(p_code))));IF r IS NOT NULL THEN RETURN r;END IF;
 r:=public.ct_redeem_promo_before_chests(p_operation_id,p_code);
 SELECT reward_chest_id,reward_chest_count INTO v_chest,v_count FROM public.ct_promos WHERE code=upper(trim(p_code)) FOR SHARE;
 IF v_chest IS NOT NULL THEN r:=r||jsonb_build_object('sealed_chests',public.ct_grant_sealed(u,v_chest,v_count));UPDATE public.ct_operations SET result=r WHERE user_id=u AND operation_id=p_operation_id;END IF;RETURN r;END $$;
REVOKE ALL ON FUNCTION public.ct_redeem_promo(uuid,text) FROM PUBLIC,anon,authenticated;GRANT EXECUTE ON FUNCTION public.ct_redeem_promo(uuid,text) TO authenticated;
ALTER FUNCTION public.ct_my_quests() RENAME TO ct_my_quests_before_chests;
REVOKE ALL ON FUNCTION public.ct_my_quests_before_chests() FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_my_quests() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$ SELECT coalesce(jsonb_agg(q||jsonb_build_object('reward_chest_name',(SELECT name FROM public.ct_chest_types WHERE id=(q->>'reward_chest_id')::smallint))),'[]'::jsonb) FROM jsonb_array_elements(public.ct_my_quests_before_chests()) q $$;
REVOKE ALL ON FUNCTION public.ct_my_quests() FROM PUBLIC,anon,authenticated;GRANT EXECUTE ON FUNCTION public.ct_my_quests() TO authenticated;
-- New free chest quests use stable catalogue identifiers resolved from eligible chests.
INSERT INTO public.ct_quests(id,name,description,kind,target,reward,reward_chest_id) SELECT 'sealed-welcome','Un secret à conserver','Créez votre profil et recevez un coffre scellé.','profile',1,0,id FROM public.ct_chest_types WHERE active AND category='standard' AND stock_limit IS NULL AND per_player_limit IS NULL ORDER BY price,id LIMIT 1;
INSERT INTO public.ct_quests(id,name,description,kind,target,reward,reward_chest_id) SELECT 'sealed-collection','Cinq signatures, un secret','Collectionnez cinq titres uniques.','titles',5,0,id FROM public.ct_chest_types WHERE active AND category='standard' AND stock_limit IS NULL AND per_player_limit IS NULL ORDER BY price,id LIMIT 1;
INSERT INTO public.ct_quests(id,name,description,kind,target,reward,reward_chest_id) SELECT 'sealed-explorer','Dix parties, un coffre','Terminez dix parties solo.','games',10,0,id FROM public.ct_chest_types WHERE active AND category='standard' AND stock_limit IS NULL AND per_player_limit IS NULL ORDER BY price,id LIMIT 1;
CREATE TABLE public.ct_direct_trades(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),a uuid NOT NULL REFERENCES public.ct_profiles(id),b uuid NOT NULL REFERENCES public.ct_profiles(id),status text NOT NULL DEFAULT 'pending' CHECK(status IN('pending','open','completed','cancelled')),version bigint NOT NULL DEFAULT 1,a_diamonds bigint NOT NULL DEFAULT 0 CHECK(a_diamonds BETWEEN 0 AND 1000000000),b_diamonds bigint NOT NULL DEFAULT 0 CHECK(b_diamonds BETWEEN 0 AND 1000000000),a_confirmed boolean NOT NULL DEFAULT false,b_confirmed boolean NOT NULL DEFAULT false,final_offer jsonb,created_at timestamptz NOT NULL DEFAULT now(),expires_at timestamptz NOT NULL DEFAULT now()+interval '15 minutes',CHECK(a<>b));
CREATE INDEX ct_direct_a ON public.ct_direct_trades(a,created_at DESC);CREATE INDEX ct_direct_b ON public.ct_direct_trades(b,created_at DESC);CREATE INDEX ct_direct_expiry ON public.ct_direct_trades(expires_at) WHERE status IN('pending','open');
CREATE TABLE public.ct_direct_assets(trade_id uuid NOT NULL REFERENCES public.ct_direct_trades(id) ON DELETE CASCADE,owner_id uuid NOT NULL REFERENCES public.ct_profiles(id),kind text NOT NULL CHECK(kind IN('title','chest')),asset_id uuid NOT NULL,PRIMARY KEY(kind,asset_id));
CREATE INDEX ct_direct_assets_trade ON public.ct_direct_assets(trade_id);CREATE INDEX ct_direct_assets_owner ON public.ct_direct_assets(owner_id);
ALTER TABLE public.ct_direct_trades ENABLE ROW LEVEL SECURITY;ALTER TABLE public.ct_direct_assets ENABLE ROW LEVEL SECURITY;REVOKE ALL ON public.ct_direct_trades,public.ct_direct_assets FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_direct_reserved(p_kind text,p_asset uuid,p_except uuid DEFAULT NULL) RETURNS boolean LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM public.ct_direct_assets i JOIN public.ct_direct_trades t ON t.id=i.trade_id WHERE i.kind=p_kind AND i.asset_id=p_asset AND t.status='open' AND t.expires_at>now() AND(p_except IS NULL OR t.id<>p_except));
$$;
CREATE FUNCTION public.ct_direct_diamonds(p_user uuid,p_except uuid DEFAULT NULL) RETURNS bigint LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT coalesce(sum(CASE WHEN a=p_user THEN a_diamonds ELSE b_diamonds END),0)::bigint FROM public.ct_direct_trades WHERE status='open' AND expires_at>now() AND(a=p_user OR b=p_user) AND(p_except IS NULL OR id<>p_except);
$$;
REVOKE ALL ON FUNCTION public.ct_direct_reserved(text,uuid,uuid),public.ct_direct_diamonds(uuid,uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_trade_command(p_operation_id uuid,p_action text,p_values jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
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
    v_items:=coalesce(p_values->'items','[]');IF jsonb_typeof(v_items)<>'array' OR jsonb_array_length(v_items)>10 THEN RAISE EXCEPTION 'Dix objets maximum par offre';END IF;
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
CREATE FUNCTION public.ct_trade_inbox() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC),'[]'::jsonb) FROM(SELECT t.id,t.status,t.version,t.a,t.b,t.a_confirmed,t.b_confirmed,t.expires_at,t.created_at,p.username other_username FROM public.ct_direct_trades t JOIN public.ct_profiles p ON p.id=CASE WHEN t.a=auth.uid() THEN t.b ELSE t.a END WHERE auth.uid() IN(t.a,t.b) AND t.expires_at>now() AND t.status IN('pending','open') ORDER BY t.created_at DESC LIMIT 10)x;
$$;
CREATE FUNCTION public.ct_trade_room(p_trade_id uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid:=auth.uid();t public.ct_direct_trades;
BEGIN
 SELECT * INTO t FROM public.ct_direct_trades WHERE id=p_trade_id AND u IN(a,b);IF NOT FOUND THEN RAISE EXCEPTION 'Échange introuvable' USING ERRCODE='42501';END IF;
 RETURN to_jsonb(t)||jsonb_build_object('a_name',(SELECT username FROM public.ct_profiles WHERE id=t.a),'b_name',(SELECT username FROM public.ct_profiles WHERE id=t.b),'my_balance',coalesce((SELECT balance FROM public.ct_diamond_wallets WHERE user_id=u),0),'my_reserved',public.ct_direct_diamonds(u,t.id),
 'items',coalesce((SELECT jsonb_agg(jsonb_build_object('id',i.asset_id,'kind',i.kind,'owner_id',i.owner_id,'name',coalesce(x.name,s.name),'rarity',coalesce(x.rarity,s.rarity))) FROM public.ct_direct_assets i LEFT JOIN public.ct_player_titles p ON i.kind='title' AND p.id=i.asset_id LEFT JOIN public.ct_titles x ON x.id=p.title_id LEFT JOIN public.ct_sealed_chests s ON i.kind='chest' AND s.id=i.asset_id WHERE i.trade_id=t.id),t.final_offer->'items','[]'::jsonb),
 'assets',coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM(
 SELECT p.id,'title' kind,tit.name,tit.rarity FROM public.ct_player_titles p JOIN public.ct_titles tit ON tit.id=p.title_id WHERE p.user_id=u AND p.revoked_at IS NULL AND p.quantity=1 AND NOT public.ct_direct_reserved('title',p.id,t.id) AND NOT EXISTS(SELECT 1 FROM public.ct_market_listings WHERE asset_kind='title' AND asset_id=p.id AND status='active' AND expires_at>now())
 UNION ALL SELECT s.id,'chest',s.name,s.rarity FROM public.ct_sealed_chests s WHERE s.user_id=u AND s.opened_at IS NULL AND NOT public.ct_direct_reserved('chest',s.id,t.id) AND NOT EXISTS(SELECT 1 FROM public.ct_market_listings WHERE asset_kind='chest' AND asset_id=s.id AND status='active' AND expires_at>now()))x),'[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.ct_trade_command(uuid,text,jsonb),public.ct_trade_inbox(),public.ct_trade_room(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_trade_command(uuid,text,jsonb),public.ct_trade_inbox(),public.ct_trade_room(uuid) TO authenticated;
ALTER FUNCTION public.ct_market_command(uuid,text,jsonb) RENAME TO ct_market_command_before_direct;
REVOKE ALL ON FUNCTION public.ct_market_command_before_direct(uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_market_command(p_operation_id uuid,p_action text,p_values jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;l public.ct_market_listings;
BEGIN
 PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,jsonb_build_object('kind','market','action',p_action,'values',p_values));IF r IS NOT NULL THEN RETURN r;END IF;
 IF p_action IN('list','open_sealed') AND public.ct_direct_reserved(CASE WHEN p_action='open_sealed' THEN 'chest' ELSE p_values->>'asset_kind' END,(p_values->>'asset_id')::uuid) THEN RAISE EXCEPTION 'Objet réservé dans un échange direct';END IF;
 IF p_action='accept' THEN
  SELECT * INTO l FROM public.ct_market_listings WHERE id=(p_values->>'listing_id')::bigint;
  IF public.ct_direct_reserved(l.asset_kind,l.asset_id) OR(l.wanted_kind IS NOT NULL AND public.ct_direct_reserved(l.wanted_kind,(p_values->>'payment_asset_id')::uuid)) THEN RAISE EXCEPTION 'Objet réservé dans un échange direct';END IF;
  IF l.status='active' AND public.ct_direct_diamonds(u)>0 AND l.price>coalesce((SELECT balance FROM public.ct_diamond_wallets WHERE user_id=u),0)-public.ct_direct_diamonds(u) THEN RAISE EXCEPTION 'Diamants réservés dans un échange direct';END IF;
 END IF;
 RETURN public.ct_market_command_before_direct(p_operation_id,p_action,p_values);
END $$;
CREATE OR REPLACE FUNCTION public.ct_market_equip_guard() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN IF public.ct_direct_reserved('title',NEW.player_title_id) OR EXISTS(SELECT 1 FROM public.ct_market_listings WHERE asset_kind='title' AND asset_id=NEW.player_title_id AND status='active' AND expires_at>now()) THEN RAISE EXCEPTION 'Ce titre est réservé à un échange';END IF;RETURN NEW;END $$;
REVOKE ALL ON FUNCTION public.ct_market_command(uuid,text,jsonb) FROM PUBLIC,anon,authenticated;GRANT EXECUTE ON FUNCTION public.ct_market_command(uuid,text,jsonb) TO authenticated;
CREATE FUNCTION public.ct_sealed_inventory() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',s.id,'chest_id',s.chest_id,'name',s.name,'rarity',s.rarity,'weights',s.weights,'created_at',s.created_at)||jsonb_build_object('reserved',public.ct_direct_reserved('chest',s.id) OR EXISTS(SELECT 1 FROM public.ct_market_listings WHERE asset_kind='chest' AND asset_id=s.id AND status='active' AND expires_at>now())) ORDER BY s.created_at DESC),'[]'::jsonb) FROM public.ct_sealed_chests s WHERE user_id=auth.uid() AND opened_at IS NULL;
$$;
REVOKE ALL ON FUNCTION public.ct_sealed_inventory() FROM PUBLIC,anon,authenticated;GRANT EXECUTE ON FUNCTION public.ct_sealed_inventory() TO authenticated;
CREATE OR REPLACE FUNCTION public.ct_market_snapshot(p_search text DEFAULT '',p_before bigint DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE r jsonb;
BEGIN r:=public.ct_market_snapshot_before_checkout(p_search,p_before);RETURN r||jsonb_build_object('credits_per_diamond',(SELECT credits_per_diamond FROM public.ct_market_settings WHERE id),'diamonds_reserved',public.ct_direct_diamonds(auth.uid()),'assets',(SELECT coalesce(jsonb_agg(a||jsonb_build_object('reserved',coalesce((a->>'reserved')::boolean,false) OR public.ct_direct_reserved(a->>'kind',(a->>'id')::uuid))),'[]'::jsonb) FROM jsonb_array_elements(r->'assets') a));END $$;
COMMIT;
