BEGIN;
CREATE TABLE public.ct_quests (
 id text PRIMARY KEY,name text NOT NULL,description text NOT NULL,kind text NOT NULL,
 target integer NOT NULL CHECK(target>0),reward bigint NOT NULL CHECK(reward>0)
);
INSERT INTO public.ct_quests VALUES
 ('welcome','Les portes du cercle','Créez votre profil. Aucune mise nécessaire.','profile',1,250),
 ('first_title','Votre première signature','Obtenez votre premier titre.','titles',1,500),
 ('first_chest','Le premier secret','Ouvrez un coffre.','chests',1,250),
 ('three_chests','La curiosité récompensée','Ouvrez trois coffres.','chests',3,750);
CREATE TABLE public.ct_quest_claims (
 user_id uuid NOT NULL REFERENCES public.ct_profiles(id) ON DELETE CASCADE,
 quest_id text NOT NULL REFERENCES public.ct_quests(id),created_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(user_id,quest_id)
);
ALTER TABLE public.ct_quests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ct_quest_claims ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ct_quests,public.ct_quest_claims FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.ct_quests TO anon,authenticated;
GRANT SELECT ON public.ct_quest_claims TO authenticated;
CREATE POLICY ct_quests_catalog ON public.ct_quests FOR SELECT USING(true);
CREATE POLICY ct_quest_claims_owner ON public.ct_quest_claims FOR SELECT TO authenticated USING(user_id=auth.uid());
CREATE FUNCTION public.ct_quest_progress(p_uid uuid,p_kind text) RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT CASE p_kind WHEN 'profile' THEN (SELECT count(*) FROM public.ct_profiles WHERE id=p_uid)
 WHEN 'titles' THEN (SELECT count(DISTINCT title_id) FROM public.ct_player_titles WHERE user_id=p_uid)
 WHEN 'chests' THEN (SELECT count(*) FROM public.ct_chest_openings WHERE user_id=p_uid) ELSE 0 END;
$$;
CREATE FUNCTION public.ct_my_quests() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(to_jsonb(q)||jsonb_build_object('progress',public.ct_quest_progress(auth.uid(),q.kind),
 'claimed',EXISTS(SELECT 1 FROM public.ct_quest_claims WHERE user_id=auth.uid() AND quest_id=q.id)) ORDER BY q.reward),'[]'::jsonb) FROM public.ct_quests q;
$$;
CREATE FUNCTION public.ct_claim_quest(p_operation_id uuid,p_quest_id text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid;v_request jsonb:=jsonb_build_object('kind','quest','quest_id',p_quest_id);v_result jsonb;q public.ct_quests;
BEGIN
 v_uid:=public.ct_lock_wallet();v_result:=public.ct_replay(v_uid,p_operation_id,v_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 PERFORM public.ct_check_rate(v_uid);SELECT * INTO q FROM public.ct_quests WHERE id=p_quest_id FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown quest';END IF;
 IF EXISTS(SELECT 1 FROM public.ct_quest_claims WHERE user_id=v_uid AND quest_id=q.id) THEN RAISE EXCEPTION 'Quest already claimed';END IF;
 IF public.ct_quest_progress(v_uid,q.kind)<q.target THEN RAISE EXCEPTION 'Quest not completed';END IF;
 INSERT INTO public.ct_quest_claims(user_id,quest_id) VALUES(v_uid,q.id);
 v_result:=public.ct_post_credit(v_uid,q.reward,'quest','quest:'||q.id);
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(v_uid,p_operation_id,v_request,v_result);RETURN v_result;
END $$;
REVOKE ALL ON FUNCTION public.ct_quest_progress(uuid,text),public.ct_my_quests(),public.ct_claim_quest(uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_my_quests(),public.ct_claim_quest(uuid,text) TO authenticated;
COMMIT;
