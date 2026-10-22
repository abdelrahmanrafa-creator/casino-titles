BEGIN;
CREATE TABLE public.ct_guest_limits(bucket text NOT NULL,hour timestamptz NOT NULL,requests integer NOT NULL DEFAULT 1,PRIMARY KEY(bucket,hour));
ALTER TABLE public.ct_guest_limits ENABLE ROW LEVEL SECURITY;REVOKE ALL ON public.ct_guest_limits FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_guest_quota(p_bucket text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE n integer;BEGIN IF p_bucket!~'^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'Invalid quota';END IF;PERFORM pg_advisory_xact_lock(173,10);DELETE FROM public.ct_guest_limits WHERE hour<now()-interval '2 days';
 IF coalesce((SELECT sum(requests) FROM public.ct_guest_limits WHERE hour=date_trunc('hour',now())),0)>=100 THEN RAISE EXCEPTION 'Entrées invité temporairement limitées. Réessayez plus tard.';END IF;
 INSERT INTO public.ct_guest_limits(bucket,hour) VALUES(p_bucket,date_trunc('hour',now())) ON CONFLICT(bucket,hour) DO UPDATE SET requests=ct_guest_limits.requests+1 RETURNING requests INTO n;
 IF n>10 THEN RAISE EXCEPTION 'Trop de connexions invité. Réessayez dans une heure.';END IF;END $$;
REVOKE ALL ON FUNCTION public.ct_guest_quota(text) FROM PUBLIC,anon,authenticated;GRANT EXECUTE ON FUNCTION public.ct_guest_quota(text) TO service_role;
CREATE TABLE public.ct_player_edits(user_id uuid PRIMARY KEY REFERENCES public.ct_profiles(id) ON DELETE CASCADE,version bigint NOT NULL DEFAULT 1,deltas jsonb NOT NULL DEFAULT '{}',baseline jsonb NOT NULL DEFAULT '{}',edited_at timestamptz NOT NULL DEFAULT now(),chest_delta bigint NOT NULL DEFAULT 0);
ALTER TABLE public.ct_player_edits ENABLE ROW LEVEL SECURITY;REVOKE ALL ON public.ct_player_edits FROM PUBLIC,anon,authenticated;
ALTER FUNCTION public.ct_solo_statistics(uuid) RENAME TO ct_solo_statistics_original;
CREATE FUNCTION public.ct_solo_statistics(p_user_id uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path='' AS $$
DECLARE s jsonb:=public.ct_solo_statistics_original(p_user_id);e public.ct_player_edits;k text;v numeric;new_bet bigint;new_win bigint;BEGIN SELECT * INTO e FROM public.ct_player_edits WHERE user_id=p_user_id;IF NOT FOUND THEN RETURN s;END IF;
 FOREACH k IN ARRAY ARRAY['games','wins','losses','draws','wagered','returned','gains','loss_amount'] LOOP s:=jsonb_set(s,ARRAY[k],to_jsonb(greatest(0,coalesce((s->>k)::bigint,0)+coalesce((e.deltas->>k)::bigint,0))));END LOOP;
 IF e.baseline<>'{}'::jsonb THEN SELECT coalesce(max(stake),0),coalesce(max(greatest(payout-stake,0)),0) INTO new_bet,new_win FROM(SELECT payout,CASE WHEN game='blackjack' AND jsonb_typeof(state->'hands')='array' THEN coalesce((SELECT sum((h->>'bet')::bigint) FROM jsonb_array_elements(state->'hands') h),bet) ELSE bet END stake FROM public.ct_game_rounds WHERE user_id=p_user_id AND status='settled' AND updated_at>e.edited_at)x;
 s:=s||jsonb_build_object('biggest_bet',greatest(new_bet,(e.baseline->>'biggest_bet')::bigint+(e.deltas->>'biggest_bet')::bigint),'biggest_win',greatest(new_win,(e.baseline->>'biggest_win')::bigint+(e.deltas->>'biggest_win')::bigint));END IF;
 RETURN s||jsonb_build_object('net',(s->>'returned')::bigint-(s->>'wagered')::bigint,'win_percent',(s->>'wins')::numeric*100/nullif((s->>'games')::numeric,0),'win_loss_ratio',(s->>'wins')::numeric/nullif((s->>'losses')::numeric,0),'return_percent',(s->>'returned')::numeric*100/nullif((s->>'wagered')::numeric,0));END $$;
REVOKE ALL ON FUNCTION public.ct_solo_statistics(uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_admin_edit_player(p_operation_id uuid,p_user_id uuid,p_action text,p_values jsonb,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;q jsonb:=jsonb_build_object('kind','edit_player','user',p_user_id,'action',p_action,'values',p_values,'reason',p_reason);e public.ct_player_edits;s jsonb;v jsonb;d jsonb:='{}';k text;cd bigint;
BEGIN PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;
 IF length(trim(coalesce(p_reason,''))) NOT BETWEEN 8 AND 1000 THEN RAISE EXCEPTION 'Justification requise';END IF;
 PERFORM 1 FROM public.ct_profiles WHERE id=p_user_id FOR UPDATE;IF NOT FOUND THEN RAISE EXCEPTION 'Joueur introuvable';END IF;
 SELECT * INTO e FROM public.ct_player_edits WHERE user_id=p_user_id;
 IF coalesce(e.version,0) IS DISTINCT FROM(p_values->>'version')::bigint THEN RAISE EXCEPTION 'Fiche modifiée. Actualisez.';END IF;
 IF p_action='profile' THEN
  IF p_values->>'username' IS NULL OR(p_values->>'username')!~'^[a-zA-Z0-9_]{3,24}$' THEN RAISE EXCEPTION 'Pseudo invalide';END IF;
  UPDATE public.ct_profiles SET username=trim(p_values->>'username') WHERE id=p_user_id;
  INSERT INTO public.ct_player_edits(user_id) VALUES(p_user_id) ON CONFLICT(user_id) DO UPDATE SET version=ct_player_edits.version+1;
 ELSIF p_action='statistics' THEN
  s:=public.ct_solo_statistics_original(p_user_id);v:=p_values->'statistics';
  FOREACH k IN ARRAY ARRAY['wins','losses','draws','wagered','returned','biggest_bet','biggest_win','chests'] LOOP IF (v->>k) IS NULL OR(v->>k)::bigint NOT BETWEEN 0 AND 1000000000 THEN RAISE EXCEPTION 'Statistique invalide : %',k;END IF;END LOOP;
  v:=v||jsonb_build_object('games',(v->>'wins')::bigint+(v->>'losses')::bigint+(v->>'draws')::bigint,'gains',greatest((v->>'returned')::bigint-(v->>'wagered')::bigint,(v->>'biggest_win')::bigint,0),'loss_amount',greatest((v->>'returned')::bigint-(v->>'wagered')::bigint,(v->>'biggest_win')::bigint,0)-((v->>'returned')::bigint-(v->>'wagered')::bigint));
  IF (v->>'biggest_bet')::bigint>(v->>'wagered')::bigint OR(v->>'biggest_win')::bigint>(v->>'gains')::bigint THEN RAISE EXCEPTION 'Plus grosse mise ou gain incohérent';END IF;
  FOREACH k IN ARRAY ARRAY['games','wins','losses','draws','wagered','returned','gains','loss_amount','biggest_bet','biggest_win'] LOOP d:=d||jsonb_build_object(k,(v->>k)::bigint-(s->>k)::bigint);END LOOP;
  cd:=(v->>'chests')::bigint-((SELECT count(*) FROM public.ct_chest_openings WHERE user_id=p_user_id)+coalesce((SELECT chests FROM public.ct_bot_summaries WHERE user_id=p_user_id),0));
  INSERT INTO public.ct_player_edits(user_id,deltas,baseline,chest_delta) VALUES(p_user_id,d,s,cd) ON CONFLICT(user_id) DO UPDATE SET deltas=d,baseline=s,chest_delta=cd,edited_at=now(),version=ct_player_edits.version+1;
 ELSE RAISE EXCEPTION 'Action inconnue';END IF;
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(u,'player_'||p_action,p_user_id::text,p_reason,p_values);
 r:='{"ok":true}';INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;END $$;
CREATE TABLE public.ct_account_jobs(admin_id uuid NOT NULL REFERENCES public.ct_profiles(id),operation_id uuid NOT NULL,target_id uuid NOT NULL REFERENCES public.ct_profiles(id),action text NOT NULL CHECK(action IN('email','reset')),request jsonb NOT NULL,status text NOT NULL DEFAULT 'processing',result jsonb,created_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(admin_id,operation_id));
CREATE INDEX ct_account_jobs_target ON public.ct_account_jobs(target_id,created_at DESC);
ALTER TABLE public.ct_account_jobs ENABLE ROW LEVEL SECURITY;REVOKE ALL ON public.ct_account_jobs FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_account_job(p_operation_id uuid,p_user_id uuid,p_action text,p_values jsonb,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r public.ct_account_jobs;q jsonb:=jsonb_build_object('target',p_user_id,'action',p_action,'values',p_values,'reason',p_reason);BEGIN
 u:=public.ct_lock_wallet();IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;PERFORM pg_advisory_xact_lock(hashtextextended(p_user_id::text,123));
 SELECT * INTO r FROM public.ct_account_jobs WHERE admin_id=u AND operation_id=p_operation_id;
 IF FOUND THEN IF r.request<>q THEN RAISE EXCEPTION 'Operation has different payload';END IF;IF r.status='processing' AND r.created_at<now()-interval '5 minutes' THEN UPDATE public.ct_account_jobs SET status='failed',result='{"error":"Opération interrompue. Actualisez la fiche avant de recommencer.","definitive":true}'::jsonb WHERE admin_id=u AND operation_id=p_operation_id RETURNING * INTO r;END IF;RETURN jsonb_build_object('replay',true,'status',r.status,'result',r.result);END IF;
 IF p_action NOT IN('email','reset') OR length(trim(coalesce(p_reason,''))) NOT BETWEEN 8 AND 1000 OR NOT EXISTS(SELECT 1 FROM public.ct_profiles WHERE id=p_user_id AND NOT is_bot) THEN RAISE EXCEPTION 'Opération de compte invalide';END IF;
 IF EXISTS(SELECT 1 FROM public.ct_account_jobs WHERE target_id=p_user_id AND status='processing' AND created_at>now()-interval '5 minutes') THEN RAISE EXCEPTION 'Une opération est déjà en cours sur ce compte';END IF;
 PERFORM public.ct_check_rate(u);INSERT INTO public.ct_account_jobs(admin_id,operation_id,target_id,action,request) VALUES(u,p_operation_id,p_user_id,p_action,q);
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(u,'account_'||p_action||'_requested',p_user_id::text,p_reason,p_values);
 RETURN '{"replay":false}'::jsonb;END $$;
CREATE FUNCTION public.ct_account_finish(p_admin uuid,p_operation uuid,p_result jsonb) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN UPDATE public.ct_account_jobs SET status=CASE WHEN p_result?'error' THEN 'failed' ELSE 'completed' END,result=p_result WHERE admin_id=p_admin AND operation_id=p_operation AND status='processing';END $$;
REVOKE ALL ON FUNCTION public.ct_account_finish(uuid,uuid,jsonb) FROM PUBLIC,anon,authenticated;GRANT EXECUTE ON FUNCTION public.ct_account_finish(uuid,uuid,jsonb) TO service_role;
ALTER TABLE public.ct_sealed_chests ADD COLUMN purchase_price bigint NOT NULL DEFAULT 0;
CREATE TABLE public.ct_chest_purchases(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),user_id uuid NOT NULL REFERENCES public.ct_profiles(id),chest_id smallint NOT NULL REFERENCES public.ct_chest_types(id),offer_id uuid REFERENCES public.ct_chest_offers(id),asset_id uuid NOT NULL REFERENCES public.ct_sealed_chests(id),price_paid bigint NOT NULL CHECK(price_paid>=0),operation_id uuid NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(user_id,operation_id));
CREATE INDEX ct_chest_purchases_chest ON public.ct_chest_purchases(chest_id,user_id);CREATE INDEX ct_chest_purchases_offer ON public.ct_chest_purchases(offer_id,user_id);CREATE INDEX ct_chest_purchases_asset ON public.ct_chest_purchases(asset_id);
ALTER TABLE public.ct_chest_purchases ENABLE ROW LEVEL SECURITY;REVOKE ALL ON public.ct_chest_purchases FROM PUBLIC,anon,authenticated;
ALTER TABLE public.ct_chest_openings ADD COLUMN sealed_id uuid REFERENCES public.ct_sealed_chests(id);CREATE INDEX ct_opening_sealed ON public.ct_chest_openings(sealed_id);
UPDATE public.ct_chest_openings o SET sealed_id=(op.request->'values'->>'asset_id')::uuid FROM public.ct_operations op WHERE op.user_id=o.user_id AND op.operation_id=o.operation_id AND op.request->>'action'='open_sealed';
CREATE FUNCTION public.ct_buy_chest(p_operation_id uuid,p_chest_id smallint,p_expected_version bigint,p_expected_price bigint,p_expected_offer_id uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;q jsonb:=jsonb_build_object('kind','buy_chest','chest_id',p_chest_id,'version',p_expected_version,'price',p_expected_price,'offer',p_expected_offer_id);c public.ct_chest_types;v jsonb;ids text[];i integer;asset uuid;price bigint;offer uuid;
BEGIN PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;PERFORM public.ct_check_rate(u);
 SELECT * INTO c FROM public.ct_chest_types WHERE id=p_chest_id FOR UPDATE;IF NOT FOUND THEN RAISE EXCEPTION 'Coffre indisponible';END IF;
 v:=public.ct_chest_quote(c.id,u);price:=(v->>'current_price')::bigint;offer:=(v->>'offer_id')::uuid;
 IF NOT coalesce((v->>'available')::boolean,false) THEN RAISE EXCEPTION 'Coffre indisponible : dates, stock ou limite atteinte';END IF;
 IF p_expected_version IS DISTINCT FROM c.version OR p_expected_price IS DISTINCT FROM price OR p_expected_offer_id IS DISTINCT FROM offer THEN RAISE EXCEPTION 'Prix ou offre modifié. Actualisez les coffres.';END IF;
 PERFORM id FROM public.ct_titles WHERE available AND(NOT exclusive OR c.allow_exclusive) AND(c.title_pool IS NULL OR id=ANY(c.title_pool)) ORDER BY id FOR SHARE;
 SELECT array_agg(id ORDER BY id) INTO ids FROM public.ct_titles WHERE available AND(NOT exclusive OR c.allow_exclusive) AND(c.title_pool IS NULL OR id=ANY(c.title_pool));
 FOR i IN 1..8 LOOP IF c.weights[i]>0 AND NOT EXISTS(SELECT 1 FROM public.ct_titles WHERE id=ANY(ids) AND rarity=i) THEN RAISE EXCEPTION 'Catalogue du coffre incomplet';END IF;END LOOP;
 IF price>0 THEN PERFORM public.ct_post_credit(u,-price,'chest','chest-buy:'||p_operation_id::text);END IF;
 INSERT INTO public.ct_sealed_chests(user_id,chest_id,name,rarity,weights,title_ids,purchase_price) VALUES(u,c.id,c.name,c.rarity,c.weights,ids,price) RETURNING id INTO asset;
 INSERT INTO public.ct_chest_purchases(user_id,chest_id,offer_id,asset_id,price_paid,operation_id) VALUES(u,c.id,offer,asset,price,p_operation_id);
 UPDATE public.ct_chest_types SET stock_used=stock_used+1 WHERE id=c.id;IF offer IS NOT NULL THEN UPDATE public.ct_chest_offers SET stock_used=stock_used+1 WHERE id=offer;END IF;
 r:=jsonb_build_object('ok',true,'sealed_id',asset,'chest_id',c.id,'price_paid',price);INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;END $$;
ALTER FUNCTION public.ct_market_command(uuid,text,jsonb) RENAME TO ct_market_command_before_shop;
REVOKE ALL ON FUNCTION public.ct_market_command_before_shop(uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_market_command(p_operation_id uuid,p_action text,p_values jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;BEGIN IF p_action='buy_sealed' THEN PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,jsonb_build_object('kind','market','action',p_action,'values',p_values));IF r IS NOT NULL THEN RETURN r;END IF;RAISE EXCEPTION 'Achetez vos coffres dans la rubrique Coffres';END IF;RETURN public.ct_market_command_before_shop(p_operation_id,p_action,p_values);END $$;
REVOKE ALL ON FUNCTION public.ct_admin_edit_player(uuid,uuid,text,jsonb,text),public.ct_account_job(uuid,uuid,text,jsonb,text),public.ct_buy_chest(uuid,smallint,bigint,bigint,uuid),public.ct_market_command(uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_admin_edit_player(uuid,uuid,text,jsonb,text),public.ct_account_job(uuid,uuid,text,jsonb,text),public.ct_buy_chest(uuid,smallint,bigint,bigint,uuid),public.ct_market_command(uuid,text,jsonb) TO authenticated;
CREATE OR REPLACE FUNCTION public.ct_chest_quote(p_chest_id smallint,p_user_id uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT to_jsonb(c)||jsonb_build_object('base_price',c.price,'current_price',coalesce(o.sale_price,c.price),
 'discount_percent',round(100.0*(c.price-coalesce(o.sale_price,c.price))/c.price,1),
 'offer_id',o.id,'offer_name',o.name,'offer_ends_at',o.ends_at,
 'remaining_stock',CASE WHEN c.stock_limit IS NULL THEN NULL ELSE c.stock_limit-c.stock_used END,
 'offer_remaining',CASE WHEN o.stock_limit IS NULL THEN NULL ELSE o.stock_limit-o.stock_used END,
 'available',c.active AND (c.starts_at IS NULL OR now()>=c.starts_at) AND (c.ends_at IS NULL OR now()<c.ends_at)
 AND (c.stock_limit IS NULL OR c.stock_used<c.stock_limit)
 AND (c.per_player_limit IS NULL OR ((SELECT count(*) FROM public.ct_chest_openings WHERE chest_id=c.id AND user_id=p_user_id AND sealed_id IS NULL)+(SELECT count(*) FROM public.ct_chest_purchases WHERE chest_id=c.id AND user_id=p_user_id))<c.per_player_limit))
 FROM public.ct_chest_types c LEFT JOIN LATERAL(
 SELECT f.* FROM public.ct_chest_offers f WHERE f.chest_id=c.id AND f.active AND now()>=f.starts_at AND now()<f.ends_at AND f.sale_price<c.price
 AND(f.stock_limit IS NULL OR f.stock_used<f.stock_limit)
 AND(f.per_player_limit IS NULL OR ((SELECT count(*) FROM public.ct_chest_openings WHERE offer_id=f.id AND user_id=p_user_id AND sealed_id IS NULL)+(SELECT count(*) FROM public.ct_chest_purchases WHERE offer_id=f.id AND user_id=p_user_id))<f.per_player_limit)
 ORDER BY f.sale_price,f.ends_at,f.id LIMIT 1)o ON true WHERE c.id=p_chest_id;
$$;
CREATE OR REPLACE FUNCTION public.ct_market_command_before_store(p_operation_id uuid,p_action text,p_values jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
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
  INSERT INTO public.ct_chest_openings(user_id,chest_id,player_title_id,price_paid,base_price,weights,operation_id,sealed_id) VALUES(u,s.chest_id,v_instance,0,0,s.weights,p_operation_id,s.id);
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
CREATE OR REPLACE FUNCTION public.ct_rankings(p_metric text DEFAULT 'credits',p_period text DEFAULT 'all') RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_since timestamptz;v_result jsonb;
BEGIN
 IF p_metric IS NULL OR p_metric NOT IN('credits','wins','titles','chests','cosmic') OR p_period IS NULL OR p_period NOT IN('all','week') THEN RAISE EXCEPTION 'Invalid ranking';END IF;
 v_since:=CASE WHEN p_period='week' THEN date_trunc('week',now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' ELSE '-infinity'::timestamptz END;
 WITH metrics AS(
 SELECT user_id,balance::numeric score FROM public.ct_wallets WHERE p_metric='credits' AND p_period='all'
 UNION ALL SELECT user_id,sum(amount) FROM public.ct_wallet_transactions WHERE p_metric='credits' AND p_period='week' AND created_at>=v_since GROUP BY user_id
 UNION ALL SELECT user_id,count(*) FROM public.ct_game_rounds WHERE p_metric='wins' AND status='settled' AND payout>bet AND updated_at>=v_since GROUP BY user_id
 UNION ALL SELECT user_id,wins FROM public.ct_bot_summaries WHERE p_metric='wins' AND created_at>=v_since
 UNION ALL SELECT user_id,count(DISTINCT title_id) FROM public.ct_player_titles WHERE p_metric='titles' AND revoked_at IS NULL AND acquired_at>=v_since GROUP BY user_id
 UNION ALL SELECT user_id,count(*) FROM public.ct_chest_openings WHERE p_metric='chests' AND created_at>=v_since GROUP BY user_id
 UNION ALL SELECT user_id,chests FROM public.ct_bot_summaries WHERE p_metric='chests' AND created_at>=v_since
 UNION ALL SELECT i.user_id,sum(i.quantity) FROM public.ct_player_titles i JOIN public.ct_titles t ON t.id=i.title_id WHERE p_metric='cosmic' AND i.revoked_at IS NULL AND t.rarity=8 AND i.acquired_at>=v_since GROUP BY i.user_id
  UNION ALL SELECT user_id,(deltas->>'wins')::numeric FROM public.ct_player_edits WHERE p_metric='wins' AND p_period='all'
 UNION ALL SELECT user_id,chest_delta FROM public.ct_player_edits WHERE p_metric='chests' AND p_period='all'
 ),scores AS(SELECT user_id,sum(score) score FROM metrics GROUP BY user_id),top_players AS(
 SELECT p.id,p.username,p.avatar,coalesce(s.score,0) score FROM public.ct_profiles p JOIN public.ct_wallets w ON w.user_id=p.id LEFT JOIN scores s ON s.user_id=p.id
 WHERE NOT EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=p.id) AND NOT EXISTS(SELECT 1 FROM public.ct_preferences WHERE user_id=p.id AND leaderboard_hidden) AND(NOT p.is_bot OR EXISTS(SELECT 1 FROM public.ct_bots WHERE user_id=p.id AND active)) ORDER BY score DESC,p.username,p.id LIMIT 50)
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.score DESC,x.username,x.id),'[]'::jsonb) INTO v_result FROM(
 SELECT p.*, (SELECT to_jsonb(t) FROM public.ct_equipped_titles e JOIN public.ct_player_titles i ON i.id=e.player_title_id JOIN public.ct_titles t ON t.id=i.title_id WHERE e.user_id=p.id AND i.revoked_at IS NULL) equipped_title FROM top_players p)x;
 RETURN v_result;
END $$;
ALTER FUNCTION public.ct_public_profile(uuid) RENAME TO ct_public_profile_before_edits;
REVOKE ALL ON FUNCTION public.ct_public_profile_before_edits(uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_public_profile(p_user_id uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$ SELECT public.ct_public_profile_before_edits(p_user_id)||jsonb_build_object('chests',greatest(0,coalesce((public.ct_public_profile_before_edits(p_user_id)->>'chests')::bigint,0)+coalesce((SELECT chest_delta FROM public.ct_player_edits WHERE user_id=p_user_id),0)),'games',(public.ct_solo_statistics(p_user_id)->>'games')::bigint,'wins',(public.ct_solo_statistics(p_user_id)->>'wins')::bigint) $$;
REVOKE ALL ON FUNCTION public.ct_public_profile(uuid) FROM PUBLIC,anon,authenticated;GRANT EXECUTE ON FUNCTION public.ct_public_profile(uuid) TO anon,authenticated;
ALTER FUNCTION public.ct_admin_player(uuid) RENAME TO ct_admin_player_before_edits;
REVOKE ALL ON FUNCTION public.ct_admin_player_before_edits(uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_admin_player(p_user_id uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$ BEGIN IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required';END IF;RETURN public.ct_admin_player_before_edits(p_user_id)||jsonb_build_object('edit_version',coalesce((SELECT version FROM public.ct_player_edits WHERE user_id=p_user_id),0),'statistics',public.ct_solo_statistics(p_user_id),'chests',(public.ct_public_profile(p_user_id)->>'chests')::bigint,'account',(SELECT jsonb_build_object('email',CASE WHEN coalesce(to_jsonb(a)->'raw_app_meta_data'->>'ct_guest','false')='true' THEN NULL ELSE to_jsonb(a)->>'email' END,'guest',coalesce((to_jsonb(a)->'raw_app_meta_data'->>'ct_guest')::boolean,false)) FROM auth.users a WHERE a.id=p_user_id));END $$;
REVOKE ALL ON FUNCTION public.ct_admin_player(uuid) FROM PUBLIC,anon,authenticated;GRANT EXECUTE ON FUNCTION public.ct_admin_player(uuid) TO authenticated;
CREATE OR REPLACE FUNCTION public.ct_public_profile_details(p_user_id uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_profile jsonb;v_stats jsonb;v_positions jsonb;v_hidden boolean;
BEGIN
 IF EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=p_user_id) THEN RETURN NULL;END IF;
 v_profile:=public.ct_public_profile(p_user_id);IF v_profile IS NULL THEN RETURN NULL;END IF;
 SELECT public.ct_solo_statistics(p_user_id) INTO v_stats;
 SELECT coalesce((SELECT leaderboard_hidden FROM public.ct_preferences WHERE user_id=p_user_id),false) INTO v_hidden;
 IF v_hidden THEN v_positions:='[]'::jsonb;ELSE
 SELECT coalesce(jsonb_agg(jsonb_build_object('metric',metric,'period',period,'rank',r.ordinality) ORDER BY r.ordinality,metric,period),'[]'::jsonb) INTO v_positions FROM unnest(ARRAY['credits','wins','titles','chests','cosmic']) metric CROSS JOIN unnest(ARRAY['all','week']) period CROSS JOIN LATERAL jsonb_array_elements(public.ct_rankings(metric,period)) WITH ORDINALITY r(item,ordinality) WHERE r.item->>'id'=p_user_id::text;
 END IF;
 RETURN v_profile || jsonb_build_object('balance',(SELECT balance FROM public.ct_wallets WHERE user_id=p_user_id),'statistics',v_stats,'positions',v_positions,'leaderboard_hidden',v_hidden,'chest_spending',((SELECT coalesce(sum(price_paid),0) FROM public.ct_chest_purchases WHERE user_id=p_user_id)+(SELECT coalesce(sum(price_paid),0) FROM public.ct_chest_openings WHERE user_id=p_user_id)+coalesce((SELECT chest_spending FROM public.ct_bot_summaries WHERE user_id=p_user_id),0)),'title_copies',(SELECT coalesce(sum(quantity),0) FROM public.ct_player_titles WHERE user_id=p_user_id AND revoked_at IS NULL));
END $$;
COMMIT;
