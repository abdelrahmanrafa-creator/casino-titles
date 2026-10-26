BEGIN;
CREATE TABLE public.ct_owners(user_id uuid PRIMARY KEY REFERENCES public.ct_profiles(id) ON DELETE RESTRICT,granted_by uuid REFERENCES public.ct_profiles(id),created_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.ct_owners ENABLE ROW LEVEL SECURITY;REVOKE ALL ON public.ct_owners FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_is_owner() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$ SELECT auth.uid() IS NOT NULL AND EXISTS(SELECT 1 FROM public.ct_owners o JOIN public.ct_profiles p ON p.id=o.user_id WHERE o.user_id=auth.uid() AND NOT p.is_bot AND p.auth_user_id IS NOT NULL) $$;
CREATE OR REPLACE FUNCTION public.ct_is_admin() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$ SELECT public.ct_is_owner() OR(auth.uid() IS NOT NULL AND EXISTS(SELECT 1 FROM public.ct_admins WHERE user_id=auth.uid()) AND NOT EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=auth.uid())) $$;
CREATE OR REPLACE FUNCTION public.ct_admin_access() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$ SELECT jsonb_build_object('unlocked',public.ct_is_admin(),'is_admin',public.ct_is_admin(),'is_owner',public.ct_is_owner(),'role',CASE WHEN public.ct_is_owner() THEN 'owner' WHEN public.ct_is_admin() THEN 'admin' ELSE 'player' END,'expires_at',NULL,'configured',EXISTS(SELECT 1 FROM public.ct_admin_security),'bootstrap_available',EXISTS(SELECT 1 FROM public.ct_admin_security WHERE bootstrap_allowed) AND NOT EXISTS(SELECT 1 FROM public.ct_admins)) $$;
CREATE FUNCTION public.ct_owner_limit(p_normal numeric) RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$ SELECT CASE WHEN public.ct_is_owner() THEN 9000000000000 ELSE p_normal END $$;
CREATE FUNCTION public.ct_owner_roster(p_search text DEFAULT '') RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$ BEGIN IF NOT public.ct_is_owner() THEN RAISE EXCEPTION 'Accès propriétaire requis';END IF;RETURN jsonb_build_object('owners',(SELECT coalesce(jsonb_agg(jsonb_build_object('id',p.id,'username',p.username,'created_at',o.created_at) ORDER BY o.created_at),'[]') FROM public.ct_owners o JOIN public.ct_profiles p ON p.id=o.user_id),'players',(SELECT coalesce(jsonb_agg(x),'[]') FROM(SELECT p.id,p.username,EXISTS(SELECT 1 FROM public.ct_owners WHERE user_id=p.id) is_owner FROM public.ct_profiles p WHERE NOT p.is_bot AND p.auth_user_id IS NOT NULL AND position(lower(left(coalesce(p_search,''),50)) IN lower(p.username))>0 ORDER BY p.username LIMIT 30)x));END $$;
CREATE FUNCTION public.ct_owner_role(p_operation_id uuid,p_target uuid,p_grant boolean,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid:=auth.uid();q jsonb:=jsonb_build_object('kind','owner_role','target',p_target,'grant',p_grant,'reason',p_reason);r jsonb;
BEGIN PERFORM pg_advisory_xact_lock(173,1);IF NOT public.ct_is_owner() THEN RAISE EXCEPTION 'Accès propriétaire requis';END IF;r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;
 IF p_grant IS NULL OR length(trim(coalesce(p_reason,''))) NOT BETWEEN 8 AND 1000 THEN RAISE EXCEPTION 'Justification requise';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.ct_profiles WHERE id=p_target AND NOT is_bot AND auth_user_id IS NOT NULL) THEN RAISE EXCEPTION 'Un compte joueur connecté est requis';END IF;
 IF p_grant THEN INSERT INTO public.ct_owners(user_id,granted_by) VALUES(p_target,u) ON CONFLICT DO NOTHING;INSERT INTO public.ct_admins(user_id) VALUES(p_target) ON CONFLICT DO NOTHING;DELETE FROM public.ct_suspensions WHERE user_id=p_target;
 ELSE IF EXISTS(SELECT 1 FROM public.ct_owners WHERE user_id=p_target) AND(SELECT count(*) FROM public.ct_owners)<=1 THEN RAISE EXCEPTION 'Le dernier propriétaire doit être conservé';END IF;DELETE FROM public.ct_owners WHERE user_id=p_target;END IF;
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(u,'owner_role',p_target::text,p_reason,jsonb_build_object('granted',p_grant));r:=jsonb_build_object('ok',true,'is_owner',p_grant);INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;END $$;
-- Protect owners from ordinary-admin account takeover, suspension and demotion.
CREATE FUNCTION public.ct_owner_target_guard() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE target uuid;BEGIN target:=(CASE WHEN TG_TABLE_NAME='ct_account_jobs' THEN to_jsonb(NEW)->>'target_id' WHEN TG_OP='DELETE' THEN to_jsonb(OLD)->>'user_id' ELSE to_jsonb(NEW)->>'user_id' END)::uuid;IF EXISTS(SELECT 1 FROM public.ct_owners WHERE user_id=target) AND NOT public.ct_is_owner() AND auth.uid() IS NOT NULL THEN RAISE EXCEPTION 'Seul un propriétaire peut modifier ce compte';END IF;IF TG_TABLE_NAME='ct_suspensions' AND EXISTS(SELECT 1 FROM public.ct_owners WHERE user_id=target) THEN RAISE EXCEPTION 'Retirez le rôle propriétaire avant de suspendre ce compte';END IF;IF TG_OP='DELETE' THEN RETURN OLD;END IF;RETURN NEW;END $$;
CREATE TRIGGER ct_owner_admin_guard BEFORE DELETE ON public.ct_admins FOR EACH ROW EXECUTE FUNCTION public.ct_owner_target_guard();
CREATE TRIGGER ct_owner_suspension_guard BEFORE INSERT OR UPDATE ON public.ct_suspensions FOR EACH ROW EXECUTE FUNCTION public.ct_owner_target_guard();
CREATE TRIGGER ct_owner_account_guard BEFORE INSERT ON public.ct_account_jobs FOR EACH ROW EXECUTE FUNCTION public.ct_owner_target_guard();
DO $$ DECLARE d text;BEGIN SELECT pg_get_functiondef('public.ct_admin_edit_player(uuid,uuid,text,jsonb,text)'::regprocedure) INTO d;d:=replace(d,'BEGIN PERFORM pg_advisory_xact_lock(173,8);','BEGIN IF EXISTS(SELECT 1 FROM public.ct_owners WHERE user_id=p_user_id) AND NOT public.ct_is_owner() THEN RAISE EXCEPTION ''Seul un propriétaire peut modifier ce compte'';END IF;PERFORM pg_advisory_xact_lock(173,8);');EXECUTE d;END $$;
DO $$ DECLARE d text;BEGIN
 SELECT pg_get_functiondef('public.ct_admin_command(uuid,text,text,jsonb,text)'::regprocedure) INTO d;
 d:=replace(d,'BEGIN','BEGIN IF p_action IN(''credit'',''grant_title'',''suspend'',''unsuspend'',''revoke_title'') AND EXISTS(SELECT 1 FROM public.ct_owners WHERE user_id=p_target::uuid) AND NOT public.ct_is_owner() THEN RAISE EXCEPTION ''Seul un propriétaire peut modifier ce compte'';END IF;');EXECUTE d;
END $$;
DO $$ DECLARE d text;BEGIN
 SELECT pg_get_functiondef('public.ct_admin_revoke_title(uuid,uuid,text)'::regprocedure) INTO d;
 d:=replace(d,'BEGIN','BEGIN IF EXISTS(SELECT 1 FROM public.ct_player_titles i JOIN public.ct_owners o ON o.user_id=i.user_id WHERE i.id=p_instance_id) AND NOT public.ct_is_owner() THEN RAISE EXCEPTION ''Seul un propriétaire peut modifier ce compte'';END IF;');EXECUTE d;
 SELECT pg_get_functiondef('public.ct_admin_diamonds(uuid,text,bigint,text)'::regprocedure) INTO d;
 d:=replace(d,'PERFORM public.ct_post_diamond(v_uid,','IF EXISTS(SELECT 1 FROM public.ct_owners WHERE user_id=v_uid) AND NOT public.ct_is_owner() THEN RAISE EXCEPTION ''Seul un propriétaire peut modifier ce compte'';END IF;PERFORM public.ct_post_diamond(v_uid,');EXECUTE d;
END $$;
-- Keep technical wallet bounds and mathematical invariants; lift administrative
-- reward/configuration caps only for owner-created settings, persistently.
CREATE TABLE public.ct_owner_config_checks(table_name text NOT NULL,constraint_name text NOT NULL,expression text NOT NULL,columns text[] NOT NULL,PRIMARY KEY(table_name,constraint_name));
ALTER TABLE public.ct_owner_config_checks ENABLE ROW LEVEL SECURITY;REVOKE ALL ON public.ct_owner_config_checks FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_owner_config_guard() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE c record;k text;changed boolean;valid boolean;oldj jsonb:='{}';newj jsonb:=to_jsonb(NEW);
BEGIN IF public.ct_is_owner() THEN NEW.owner_override:=true;RETURN NEW;END IF;
 IF TG_OP='UPDATE' THEN oldj:=to_jsonb(OLD);IF NEW.owner_override IS DISTINCT FROM OLD.owner_override THEN RAISE EXCEPTION 'Accès propriétaire requis';END IF;ELSE NEW.owner_override:=false;END IF;
 FOR c IN SELECT * FROM public.ct_owner_config_checks WHERE table_name=TG_TABLE_NAME LOOP changed:=TG_OP='INSERT';FOREACH k IN ARRAY c.columns LOOP changed:=changed OR(newj->k IS DISTINCT FROM oldj->k);END LOOP;
  IF changed THEN EXECUTE format('SELECT %s FROM jsonb_populate_record(NULL::public.%I,$1)',c.expression,TG_TABLE_NAME) INTO valid USING newj;IF valid=false THEN RAISE EXCEPTION 'Ce montant ou cette quantité nécessite le rôle propriétaire';END IF;END IF;
 END LOOP;RETURN NEW;END $$;
DO $$ DECLARE tab text;c record;expr text;cols text[];BEGIN
 FOREACH tab IN ARRAY ARRAY['ct_promos','ct_quests','ct_events','ct_market_settings','ct_demo_card_tiers','ct_chest_types','ct_chest_offers','ct_titles'] LOOP
  EXECUTE format('ALTER TABLE public.%I ADD COLUMN owner_override boolean NOT NULL DEFAULT false',tab);
  FOR c IN SELECT oid,conname,conkey,pg_get_expr(conbin,conrelid) e FROM pg_constraint WHERE conrelid=('public.'||tab)::regclass AND contype='c' LOOP
   SELECT array_agg(attname::text) INTO cols FROM pg_attribute WHERE attrelid=('public.'||tab)::regclass AND attnum=ANY(c.conkey);
   IF NOT(cols&&ARRAY['credits','reward','reward_chest_count','target','credits_per_diamond','max_purchase_cents','daily_user_cents','daily_cents','weekly_cents','lifetime_cents','min_purchase_cents','total_cap_cents','price','shop_price','sale_price']) THEN CONTINUE;END IF;
   expr:=regexp_replace(c.e,'(<=[[:space:]]*)([0-9]{4,})','\1(CASE WHEN owner_override THEN 9000000000000 ELSE \2 END)','g');
   IF tab='ct_demo_card_tiers' THEN expr:=replace(replace(expr,'(1000000000)::bigint','(CASE WHEN owner_override THEN 9000000000000 ELSE 1000000000 END)'),'(100000000)::bigint','(CASE WHEN owner_override THEN 9000000000000 ELSE 100000000 END)');END IF;
   IF 'reward_chest_count'=ANY(cols) THEN expr:=replace(expr,'<= 5','<= CASE WHEN owner_override THEN 2147483647 ELSE 5 END');END IF;
   IF expr<>c.e THEN INSERT INTO public.ct_owner_config_checks VALUES(tab,c.conname,c.e,cols);EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT %I',tab,c.conname);EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I CHECK(%s)',tab,c.conname,expr);END IF;
  END LOOP;
  EXECUTE format('CREATE TRIGGER ct_owner_config_guard BEFORE INSERT OR UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.ct_owner_config_guard()',tab);
 END LOOP;
END $$;
-- These existing RPCs keep their authorization, audit and replay logic. Only
-- their administrative numeric ceilings are made owner-aware.
DO $$ DECLARE f record;d text;BEGIN
 FOR f IN SELECT oid FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname=ANY(ARRAY['ct_admin_command_v1','ct_admin_edit_player','ct_admin_catalog','ct_admin_save_quest','ct_admin_save_promo','ct_admin_diamonds']) LOOP
  SELECT pg_get_functiondef(f.oid) INTO d;
  d:=regexp_replace(d,'(BETWEEN[[:space:]]+[0-9]+[[:space:]]+AND[[:space:]]+)([0-9]{5,})','\1public.ct_owner_limit(\2)','gi');
  d:=regexp_replace(d,'(>[[:space:]]*)([0-9]{5,})','\1public.ct_owner_limit(\2)','g');EXECUTE d;
 END LOOP;
END $$;
REVOKE ALL ON FUNCTION public.ct_is_owner(),public.ct_owner_limit(numeric),public.ct_owner_roster(text),public.ct_owner_role(uuid,uuid,boolean,text),public.ct_owner_target_guard(),public.ct_owner_config_guard() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_is_owner(),public.ct_owner_roster(text),public.ct_owner_role(uuid,uuid,boolean,text) TO authenticated;
-- Large chest rewards are entitlements, not unbounded synchronous inserts.
CREATE TABLE public.ct_pending_chest_rewards(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),user_id uuid NOT NULL REFERENCES public.ct_profiles(id),chest_id smallint NOT NULL REFERENCES public.ct_chest_types(id),name text NOT NULL,rarity smallint NOT NULL,weights integer[] NOT NULL CHECK(public.ct_valid_weights(weights)),title_ids text[] NOT NULL,total integer NOT NULL CHECK(total>0),remaining integer NOT NULL CHECK(remaining>=0 AND remaining<=total),promo boolean NOT NULL,created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX ct_pending_rewards_user ON public.ct_pending_chest_rewards(user_id,created_at) WHERE remaining>0;
ALTER TABLE public.ct_pending_chest_rewards ENABLE ROW LEVEL SECURITY;REVOKE ALL ON public.ct_pending_chest_rewards FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_issue_reward_batch(p_reward uuid) RETURNS jsonb LANGUAGE plpgsql SET search_path='' AS $$
DECLARE b public.ct_pending_chest_rewards;n integer;k integer;asset uuid;result jsonb:='[]';BEGIN
 SELECT * INTO b FROM public.ct_pending_chest_rewards WHERE id=p_reward FOR UPDATE;IF b.id IS NULL THEN RAISE EXCEPTION 'Récompense introuvable';END IF;n:=least(100,b.remaining);
 FOR k IN 1..n LOOP INSERT INTO public.ct_sealed_chests(user_id,chest_id,name,rarity,weights,title_ids) VALUES(b.user_id,b.chest_id,b.name,b.rarity,b.weights,b.title_ids) RETURNING id INTO asset;
  IF b.promo THEN INSERT INTO public.ct_chest_purchases(user_id,chest_id,asset_id,price_paid,operation_id) VALUES(b.user_id,b.chest_id,asset,0,md5('reward:'||b.id::text||':'||(b.total-b.remaining+k)::text)::uuid);END IF;
  result:=result||jsonb_build_array(jsonb_build_object('id',asset,'name',b.name));
 END LOOP;UPDATE public.ct_pending_chest_rewards SET remaining=remaining-n WHERE id=b.id;RETURN result;
END $$;
CREATE FUNCTION public.ct_large_chest_reward(p_user uuid,p_chest smallint,p_count integer,p_promo boolean) RETURNS jsonb LANGUAGE plpgsql SET search_path='' AS $$
DECLARE c public.ct_chest_types;ids text[];reward uuid;i integer;BEGIN
 IF p_count IS NULL OR p_count<1 THEN RAISE EXCEPTION 'Quantité de coffres invalide';END IF;
 SELECT * INTO c FROM public.ct_chest_types WHERE id=p_chest AND active AND(starts_at IS NULL OR starts_at<=now()) AND(ends_at IS NULL OR ends_at>now()) FOR UPDATE;
 IF c.id IS NULL OR(NOT p_promo AND(c.category<>'standard' OR c.stock_limit IS NOT NULL OR c.per_player_limit IS NOT NULL)) THEN RAISE EXCEPTION 'Coffre de récompense indisponible';END IF;
 IF p_promo THEN
  IF c.stock_limit IS NOT NULL AND c.stock_used::bigint+p_count>c.stock_limit THEN RAISE EXCEPTION 'Stock du coffre de récompense insuffisant';END IF;
  IF c.per_player_limit IS NOT NULL AND p_count::bigint+(SELECT count(*) FROM public.ct_chest_purchases WHERE user_id=p_user AND chest_id=c.id)+(SELECT count(*) FROM public.ct_chest_openings WHERE user_id=p_user AND chest_id=c.id AND sealed_id IS NULL)+(SELECT coalesce(sum(remaining),0) FROM public.ct_pending_chest_rewards WHERE user_id=p_user AND chest_id=c.id AND promo)>c.per_player_limit THEN RAISE EXCEPTION 'Limite par joueur du coffre de récompense atteinte';END IF;
 END IF;
 SELECT array_agg(id ORDER BY id) INTO ids FROM public.ct_titles WHERE available AND(NOT exclusive OR c.allow_exclusive) AND(c.title_pool IS NULL OR id=ANY(c.title_pool)) AND(event_key IS NULL OR event_key=c.event_key) AND(c.event_key IS NULL OR event_key=c.event_key);
 FOR i IN 1..8 LOOP IF c.weights[i]>0 AND NOT EXISTS(SELECT 1 FROM public.ct_titles WHERE id=ANY(ids) AND rarity=i) THEN RAISE EXCEPTION 'Catalogue du coffre incomplet';END IF;END LOOP;
 INSERT INTO public.ct_pending_chest_rewards(user_id,chest_id,name,rarity,weights,title_ids,total,remaining,promo) VALUES(p_user,c.id,c.name,c.rarity,c.weights,ids,p_count,p_count,p_promo) RETURNING id INTO reward;
 IF p_promo THEN UPDATE public.ct_chest_types SET stock_used=stock_used+p_count WHERE id=c.id;END IF;
 RETURN public.ct_issue_reward_batch(reward);
END $$;
ALTER FUNCTION public.ct_grant_promo_chests(uuid,smallint,integer,uuid) RENAME TO ct_grant_promo_chests_before_owner;
CREATE FUNCTION public.ct_grant_promo_chests(p_user uuid,p_chest smallint,p_count integer,p_operation uuid) RETURNS jsonb LANGUAGE plpgsql SET search_path='' AS $$ BEGIN IF p_count<=5 THEN RETURN public.ct_grant_promo_chests_before_owner(p_user,p_chest,p_count,p_operation);END IF;RETURN public.ct_large_chest_reward(p_user,p_chest,p_count,true);END $$;
ALTER FUNCTION public.ct_grant_sealed(uuid,smallint,integer) RENAME TO ct_grant_sealed_before_owner;
CREATE FUNCTION public.ct_grant_sealed(p_user uuid,p_chest smallint,p_count integer) RETURNS jsonb LANGUAGE plpgsql SET search_path='' AS $$ BEGIN IF p_count<=5 THEN RETURN public.ct_grant_sealed_before_owner(p_user,p_chest,p_count);END IF;RETURN public.ct_large_chest_reward(p_user,p_chest,p_count,false);END $$;
CREATE FUNCTION public.ct_pending_rewards() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$ SELECT coalesce(jsonb_agg(x),'[]') FROM(SELECT id,name,remaining,total FROM public.ct_pending_chest_rewards WHERE user_id=auth.uid() AND remaining>0 ORDER BY created_at,id LIMIT 50)x $$;
CREATE FUNCTION public.ct_collect_reward_batch(p_operation_id uuid,p_reward uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;q jsonb:=jsonb_build_object('kind','collect_reward_batch','reward',p_reward);r jsonb;a jsonb;BEGIN PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;
 IF NOT EXISTS(SELECT 1 FROM public.ct_pending_chest_rewards WHERE id=p_reward AND user_id=u AND remaining>0) THEN RAISE EXCEPTION 'Récompense introuvable';END IF;a:=public.ct_issue_reward_batch(p_reward);r:=jsonb_build_object('ok',true,'sealed_chests',a,'remaining',(SELECT remaining FROM public.ct_pending_chest_rewards WHERE id=p_reward));INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;END $$;
REVOKE ALL ON FUNCTION public.ct_issue_reward_batch(uuid),public.ct_large_chest_reward(uuid,smallint,integer,boolean),public.ct_grant_promo_chests_before_owner(uuid,smallint,integer,uuid),public.ct_grant_sealed_before_owner(uuid,smallint,integer),public.ct_grant_promo_chests(uuid,smallint,integer,uuid),public.ct_grant_sealed(uuid,smallint,integer),public.ct_pending_rewards(),public.ct_collect_reward_batch(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_pending_rewards(),public.ct_collect_reward_batch(uuid,uuid) TO authenticated;
COMMIT;
