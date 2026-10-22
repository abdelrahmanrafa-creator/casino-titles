BEGIN;
CREATE TABLE public.ct_preferences(user_id uuid PRIMARY KEY REFERENCES public.ct_profiles(id) ON DELETE CASCADE,reduced_motion boolean NOT NULL DEFAULT false,updated_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.ct_preferences ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ct_preferences FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.ct_preferences TO authenticated;
CREATE POLICY ct_own_preferences ON public.ct_preferences FOR SELECT TO authenticated USING(user_id=auth.uid());
CREATE FUNCTION public.ct_save_preferences(p_reduced_motion boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid;
BEGIN v_uid:=public.ct_lock_wallet();INSERT INTO public.ct_preferences(user_id,reduced_motion) VALUES(v_uid,p_reduced_motion) ON CONFLICT(user_id) DO UPDATE SET reduced_motion=EXCLUDED.reduced_motion,updated_at=now();END $$;
CREATE TABLE public.ct_events (
 id text PRIMARY KEY,name text NOT NULL,description text NOT NULL,
 starts_at timestamptz NOT NULL,ends_at timestamptz NOT NULL,active boolean NOT NULL DEFAULT true,
 reward bigint NOT NULL DEFAULT 0 CHECK(reward BETWEEN 0 AND 100000),title_id text REFERENCES public.ct_titles(id),
 kind text NOT NULL DEFAULT 'profile' CHECK(kind IN('profile','games','chests','titles','variety','card_win')),
 target integer NOT NULL DEFAULT 1 CHECK(target>0),CHECK(ends_at>starts_at),CHECK(reward>0 OR title_id IS NOT NULL)
);
CREATE TABLE public.ct_event_claims(user_id uuid NOT NULL REFERENCES public.ct_profiles(id) ON DELETE CASCADE,event_id text NOT NULL REFERENCES public.ct_events(id),created_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(user_id,event_id));
ALTER TABLE public.ct_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ct_event_claims ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ct_events,public.ct_event_claims FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.ct_events TO anon,authenticated;
GRANT SELECT ON public.ct_event_claims TO authenticated;
CREATE POLICY ct_events_catalog ON public.ct_events FOR SELECT USING(true);
CREATE POLICY ct_event_claims_owner ON public.ct_event_claims FOR SELECT TO authenticated USING(user_id=auth.uid());
UPDATE public.ct_titles SET exclusive=true,acquisition='Événement d’ouverture du cercle' WHERE id='ct-2-060';
INSERT INTO public.ct_events(id,name,description,starts_at,ends_at,reward,title_id) VALUES
 ('opening-2026','L’ouverture du cercle','Rejoignez le cercle et recevez une signature exclusive de lancement. Aucune mise requise.','2026-10-21 22:00:00+00','2026-11-22 23:00:00+00',500,'ct-2-060');
CREATE FUNCTION public.ct_claim_event(p_operation_id uuid,p_event_id text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid;v_request jsonb:=jsonb_build_object('kind','event','event_id',p_event_id);v_result jsonb;e public.ct_events;
BEGIN
 v_uid:=public.ct_lock_wallet();v_result:=public.ct_replay(v_uid,p_operation_id,v_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 PERFORM public.ct_check_rate(v_uid);SELECT * INTO e FROM public.ct_events WHERE id=p_event_id AND active AND now()>=starts_at AND now()<ends_at FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Event unavailable';END IF;
 IF public.ct_quest_progress(v_uid,e.kind)<e.target THEN RAISE EXCEPTION 'Event requirement not met';END IF;
 INSERT INTO public.ct_event_claims(user_id,event_id) VALUES(v_uid,e.id);
 v_result:=jsonb_build_object('event_id',e.id,'amount',e.reward);
 IF e.reward>0 THEN v_result:=v_result||public.ct_post_credit(v_uid,e.reward,'event','event:'||e.id);END IF;
 IF e.title_id IS NOT NULL THEN INSERT INTO public.ct_player_titles(user_id,title_id,source) VALUES(v_uid,e.title_id,'event:'||e.name);END IF;
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(v_uid,p_operation_id,v_request,v_result);RETURN v_result;
END $$;
CREATE TABLE public.ct_achievements(id text PRIMARY KEY,name text NOT NULL,kind text NOT NULL,target integer NOT NULL CHECK(target>0));
INSERT INTO public.ct_achievements VALUES('first-title','Une signature à soi','titles',1),('collector','L’œil du collectionneur','titles',10),('curious','Les secrets du cercle','chests',10),('regular','Habitué des tables','games',25),('explorer','L’explorateur','variety',5);
CREATE TABLE public.ct_player_achievements(user_id uuid NOT NULL REFERENCES public.ct_profiles(id) ON DELETE CASCADE,achievement_id text NOT NULL REFERENCES public.ct_achievements(id),earned_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(user_id,achievement_id));
ALTER TABLE public.ct_achievements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ct_player_achievements ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ct_achievements,public.ct_player_achievements FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.ct_achievements TO anon,authenticated;
GRANT SELECT ON public.ct_player_achievements TO authenticated;
CREATE POLICY ct_achievements_catalog ON public.ct_achievements FOR SELECT USING(true);
CREATE POLICY ct_achievements_owner ON public.ct_player_achievements FOR SELECT TO authenticated USING(user_id=auth.uid());
CREATE FUNCTION public.ct_my_achievements() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid;v_result jsonb;
BEGIN
 v_uid:=public.ct_lock_wallet();
 INSERT INTO public.ct_player_achievements(user_id,achievement_id) SELECT v_uid,a.id FROM public.ct_achievements a WHERE public.ct_quest_progress(v_uid,a.kind)>=a.target ON CONFLICT DO NOTHING;
 SELECT coalesce(jsonb_agg(to_jsonb(a)||jsonb_build_object('progress',public.ct_quest_progress(v_uid,a.kind),'earned_at',p.earned_at) ORDER BY a.target),'[]'::jsonb) INTO v_result
 FROM public.ct_achievements a LEFT JOIN public.ct_player_achievements p ON p.achievement_id=a.id AND p.user_id=v_uid;
 RETURN v_result;
END $$;
CREATE FUNCTION public.ct_admin_catalog(p_operation_id uuid,p_kind text,p_id text,p_values jsonb,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid:=auth.uid();v_request jsonb:=jsonb_build_object('kind','catalog','type',p_kind,'id',p_id,'values',p_values,'reason',p_reason);v_result jsonb;
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(v_uid::text||p_operation_id::text,93));v_result:=public.ct_replay(v_uid,p_operation_id,v_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 IF p_reason IS NULL OR length(trim(p_reason)) NOT BETWEEN 8 AND 1000 THEN RAISE EXCEPTION 'Justification required';END IF;
 IF p_id IS NULL OR p_id!~'^[a-zA-Z0-9_-]{1,80}$' THEN RAISE EXCEPTION 'Invalid catalog ID';END IF;
 IF p_kind='title' THEN
  INSERT INTO public.ct_titles(id,name,rarity,description,effect,acquisition,available,exclusive,shop_price)
  VALUES(p_id,p_values->>'name',(p_values->>'rarity')::smallint,p_values->>'description',
  (ARRAY['plain','glimmer','pulse','gold','aqua','rainbow','honey','galaxy'])[(p_values->>'rarity')::integer],
  p_values->>'acquisition',(p_values->>'available')::boolean,(p_values->>'exclusive')::boolean,(p_values->>'shop_price')::bigint)
  ON CONFLICT(id) DO UPDATE SET name=EXCLUDED.name,description=EXCLUDED.description,acquisition=EXCLUDED.acquisition,available=EXCLUDED.available,exclusive=EXCLUDED.exclusive,shop_price=EXCLUDED.shop_price;
 ELSIF p_kind='rarity' THEN
  IF p_values->>'color' IS NULL OR p_values->>'color'!~'^#[0-9a-fA-F]{6}$' THEN RAISE EXCEPTION 'Hex color required';END IF;
  UPDATE public.ct_rarities SET color=p_values->>'color' WHERE id=p_id::smallint;IF NOT FOUND THEN RAISE EXCEPTION 'Rarity not found';END IF;
 ELSIF p_kind='event' THEN
  INSERT INTO public.ct_events(id,name,description,starts_at,ends_at,active,reward,title_id,kind,target)
  VALUES(p_id,p_values->>'name',p_values->>'description',(p_values->>'starts_at')::timestamptz,(p_values->>'ends_at')::timestamptz,
  (p_values->>'active')::boolean,coalesce((p_values->>'reward')::bigint,0),p_values->>'title_id',coalesce(p_values->>'kind','profile'),coalesce((p_values->>'target')::integer,1))
  ON CONFLICT(id) DO UPDATE SET name=EXCLUDED.name,description=EXCLUDED.description,starts_at=EXCLUDED.starts_at,ends_at=EXCLUDED.ends_at,active=EXCLUDED.active,reward=EXCLUDED.reward,title_id=EXCLUDED.title_id,kind=EXCLUDED.kind,target=EXCLUDED.target;
 ELSE RAISE EXCEPTION 'Unknown catalog command';END IF;
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(v_uid,'catalog:'||p_kind,p_id,p_reason,p_values);
 v_result:='{"ok":true}'::jsonb;INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(v_uid,p_operation_id,v_request,v_result);RETURN v_result;
END $$;
CREATE FUNCTION public.ct_admin_player(p_user_id uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 RETURN jsonb_build_object('profile',public.ct_public_profile(p_user_id),
 'transactions',coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM(SELECT * FROM public.ct_wallet_transactions WHERE user_id=p_user_id ORDER BY created_at DESC LIMIT 50)t),'[]'::jsonb),
 'games',coalesce((SELECT jsonb_agg(to_jsonb(r)) FROM(SELECT id,game,bet,payout,status,created_at FROM public.ct_game_rounds WHERE user_id=p_user_id ORDER BY created_at DESC LIMIT 50)r),'[]'::jsonb),
 'inventory',coalesce((SELECT jsonb_agg(to_jsonb(i)) FROM public.ct_player_titles i WHERE user_id=p_user_id),'[]'::jsonb));
END $$;
-- Revocations preserve acquisition history and chest references.
ALTER TABLE public.ct_player_titles ADD COLUMN revoked_at timestamptz;
CREATE FUNCTION public.ct_admin_revoke_title(p_operation_id uuid,p_instance_id uuid,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid:=auth.uid();v_owner uuid;v_request jsonb:=jsonb_build_object('kind','revoke','instance',p_instance_id,'reason',p_reason);v_result jsonb;
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(v_uid::text||p_operation_id::text,93));v_result:=public.ct_replay(v_uid,p_operation_id,v_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 IF p_reason IS NULL OR length(trim(p_reason))<8 THEN RAISE EXCEPTION 'Justification required';END IF;
 SELECT user_id INTO v_owner FROM public.ct_player_titles WHERE id=p_instance_id AND revoked_at IS NULL;
 IF NOT FOUND THEN RAISE EXCEPTION 'Owned title not found';END IF;
 PERFORM 1 FROM public.ct_wallets WHERE user_id=v_owner FOR UPDATE;
 UPDATE public.ct_player_titles SET revoked_at=now() WHERE id=p_instance_id;
 DELETE FROM public.ct_equipped_titles WHERE player_title_id=p_instance_id;
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(v_uid,'revoke_title',v_owner::text,p_reason,jsonb_build_object('instance_id',p_instance_id));
 v_result:='{"ok":true}'::jsonb;INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(v_uid,p_operation_id,v_request,v_result);RETURN v_result;
END $$;
CREATE OR REPLACE FUNCTION public.ct_equip_title(p_player_title_id uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid;
BEGIN
 v_uid:=public.ct_lock_wallet();
 IF p_player_title_id IS NULL THEN DELETE FROM public.ct_equipped_titles WHERE user_id=v_uid;RETURN;END IF;
 IF NOT EXISTS(SELECT 1 FROM public.ct_player_titles WHERE id=p_player_title_id AND user_id=v_uid AND revoked_at IS NULL) THEN RAISE EXCEPTION 'Title not owned' USING ERRCODE='42501';END IF;
 INSERT INTO public.ct_equipped_titles(user_id,player_title_id) VALUES(v_uid,p_player_title_id) ON CONFLICT(user_id) DO UPDATE SET player_title_id=EXCLUDED.player_title_id;
END $$;
CREATE OR REPLACE FUNCTION public.ct_player_snapshot() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT public.ct_economy_snapshot()||jsonb_build_object('inventory',coalesce((SELECT jsonb_agg(to_jsonb(i) ORDER BY i.acquired_at DESC,i.id DESC) FROM public.ct_player_titles i WHERE i.user_id=auth.uid() AND revoked_at IS NULL),'[]'::jsonb),
 'equipped_id',(SELECT player_title_id FROM public.ct_equipped_titles WHERE user_id=auth.uid()),
 'openings',coalesce((SELECT jsonb_agg(to_jsonb(o) ORDER BY o.created_at DESC,o.id DESC) FROM(SELECT * FROM public.ct_chest_openings WHERE user_id=auth.uid() ORDER BY created_at DESC,id DESC LIMIT 30)o),'[]'::jsonb),
 'purchases',coalesce((SELECT jsonb_agg(title_id) FROM public.ct_purchases WHERE user_id=auth.uid()),'[]'::jsonb));
$$;
-- Prevent old administrative command from physically deleting acquisition records.
ALTER FUNCTION public.ct_admin_command(uuid,text,text,jsonb,text) RENAME TO ct_admin_command_v1;
REVOKE ALL ON FUNCTION public.ct_admin_command_v1(uuid,text,text,jsonb,text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_admin_command(p_operation_id uuid,p_action text,p_target text,p_value jsonb,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF p_action='revoke_title' THEN RETURN public.ct_admin_revoke_title(p_operation_id,(p_value->>'instance_id')::uuid,p_reason);END IF;
 RETURN public.ct_admin_command_v1(p_operation_id,p_action,p_target,p_value,p_reason);
END $$;
REVOKE ALL ON FUNCTION public.ct_save_preferences(boolean),public.ct_claim_event(uuid,text),public.ct_my_achievements(),public.ct_admin_catalog(uuid,text,text,jsonb,text),public.ct_admin_player(uuid),public.ct_admin_revoke_title(uuid,uuid,text),public.ct_admin_command(uuid,text,text,jsonb,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_save_preferences(boolean),public.ct_claim_event(uuid,text),public.ct_my_achievements(),public.ct_admin_catalog(uuid,text,text,jsonb,text),public.ct_admin_player(uuid),public.ct_admin_revoke_title(uuid,uuid,text),public.ct_admin_command(uuid,text,text,jsonb,text) TO authenticated;
COMMIT;
