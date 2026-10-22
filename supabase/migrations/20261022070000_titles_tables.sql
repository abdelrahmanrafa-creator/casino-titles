BEGIN;
CREATE TABLE public.ct_rooms (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),game text NOT NULL CHECK(game IN('poker','chromatic')),
 code text NOT NULL UNIQUE,private boolean NOT NULL,host_id uuid NOT NULL REFERENCES public.ct_profiles(id),
 buy_in bigint NOT NULL CHECK(buy_in BETWEEN 100 AND 100000 AND buy_in%100=0),
 version bigint NOT NULL DEFAULT 0,state jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.ct_room_members (
 room_id uuid NOT NULL REFERENCES public.ct_rooms(id),user_id uuid NOT NULL REFERENCES public.ct_profiles(id),
 buy_in bigint NOT NULL CHECK(buy_in>0),paid boolean NOT NULL DEFAULT false,payout bigint CHECK(payout>=0),
 PRIMARY KEY(room_id,user_id)
);
CREATE INDEX ct_members_by_user ON public.ct_room_members(user_id,room_id);
CREATE TABLE public.ct_room_signals(room_id uuid PRIMARY KEY REFERENCES public.ct_rooms(id),version bigint NOT NULL);
ALTER TABLE public.ct_rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ct_room_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ct_room_signals ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ct_rooms,public.ct_room_members,public.ct_room_signals FROM PUBLIC,anon,authenticated;
-- Explicit service privileges: private game state never has a browser-readable policy.
GRANT ALL ON public.ct_rooms,public.ct_room_members,public.ct_room_signals TO service_role;
GRANT SELECT ON public.ct_operations,public.ct_profiles TO service_role;
CREATE FUNCTION public.ct_is_room_member(p_room_id uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM public.ct_room_members WHERE room_id=p_room_id AND user_id=auth.uid());
$$;
REVOKE ALL ON FUNCTION public.ct_is_room_member(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_is_room_member(uuid) TO authenticated;
GRANT SELECT ON public.ct_room_signals TO authenticated;
CREATE POLICY ct_room_member_signal ON public.ct_room_signals FOR SELECT TO authenticated USING(public.ct_is_room_member(room_id));
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM pg_publication WHERE pubname='supabase_realtime') AND
 NOT EXISTS(SELECT 1 FROM pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='ct_room_signals') THEN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.ct_room_signals;
 END IF;
END $$;
CREATE FUNCTION public.ct_create_room(p_user_id uuid,p_operation_id uuid,p_request jsonb,p_game text,p_code text,p_private boolean,p_buy_in bigint,p_state jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_result jsonb;v_room uuid;
BEGIN
 PERFORM 1 FROM public.ct_wallets WHERE user_id=p_user_id FOR UPDATE;
 IF NOT FOUND OR EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=p_user_id) THEN RAISE EXCEPTION 'Player unavailable';END IF;
 v_result:=public.ct_replay(p_user_id,p_operation_id,p_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 PERFORM public.ct_check_rate(p_user_id);
 PERFORM public.ct_post_credit(p_user_id,-p_buy_in,'table_buyin','table-create:'||p_operation_id::text);
 INSERT INTO public.ct_rooms(game,code,private,host_id,buy_in,state) VALUES(p_game,p_code,p_private,p_user_id,p_buy_in,p_state) RETURNING id INTO v_room;
 INSERT INTO public.ct_room_members(room_id,user_id,buy_in) VALUES(v_room,p_user_id,p_buy_in);
 INSERT INTO public.ct_room_signals(room_id,version) VALUES(v_room,0);
 v_result:=jsonb_build_object('room_id',v_room,'version',0);
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(p_user_id,p_operation_id,p_request,v_result);RETURN v_result;
END $$;
CREATE FUNCTION public.ct_commit_room(p_user_id uuid,p_operation_id uuid,p_request jsonb,p_room_id uuid,p_expected_version bigint,p_state jsonb,p_command text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.ct_rooms;v_result jsonb;v_total bigint;v_chips bigint;v_member record;v_pay bigint;v_seat jsonb;
BEGIN
 SELECT * INTO r FROM public.ct_rooms WHERE id=p_room_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Room not found';END IF;
 -- Consistent wallet order across rooms prevents settlement deadlocks.
 PERFORM 1 FROM public.ct_wallets WHERE user_id=p_user_id OR user_id IN(SELECT user_id FROM public.ct_room_members WHERE room_id=p_room_id) ORDER BY user_id FOR UPDATE;
 v_result:=public.ct_replay(p_user_id,p_operation_id,p_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 IF r.version<>p_expected_version THEN RAISE EXCEPTION 'Concurrent room update' USING ERRCODE='40001';END IF;
 IF EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=p_user_id) THEN RAISE EXCEPTION 'Account suspended';END IF;
 PERFORM public.ct_check_rate(p_user_id);
 IF p_command='join' THEN
  PERFORM public.ct_post_credit(p_user_id,-r.buy_in,'table_buyin','table-join:'||p_operation_id::text);
  INSERT INTO public.ct_room_members(room_id,user_id,buy_in) VALUES(r.id,p_user_id,r.buy_in);
 ELSIF NOT EXISTS(SELECT 1 FROM public.ct_room_members WHERE room_id=r.id AND user_id=p_user_id AND NOT paid) THEN
  RAISE EXCEPTION 'Room membership required' USING ERRCODE='42501';
 END IF;
 IF p_command='leave' AND r.state->>'phase'='waiting' THEN
  PERFORM public.ct_post_credit(p_user_id,r.buy_in,'table_refund','table-refund:'||r.id::text);
  UPDATE public.ct_room_members SET paid=true,payout=buy_in WHERE room_id=r.id AND user_id=p_user_id;
 END IF;
 SELECT coalesce(sum(buy_in),0) INTO v_total FROM public.ct_room_members WHERE room_id=r.id AND NOT paid;
 SELECT coalesce(sum((x->>'stack')::bigint+(x->>'committed')::bigint),0) INTO v_chips FROM jsonb_array_elements(p_state->'seats') x;
 IF v_total<>v_chips OR EXISTS(SELECT 1 FROM jsonb_array_elements(p_state->'seats') x WHERE (x->>'stack')::bigint<0 OR (x->>'committed')::bigint<0) THEN RAISE EXCEPTION 'Escrow conservation violation';END IF;
 IF p_state->>'phase'='finished' THEN
  FOR v_member IN SELECT * FROM public.ct_room_members WHERE room_id=r.id AND NOT paid LOOP
   SELECT x INTO v_seat FROM jsonb_array_elements(p_state->'seats') x WHERE x->>'id'=v_member.user_id::text;
   IF v_seat IS NULL THEN RAISE EXCEPTION 'Missing settlement seat';END IF;
   v_pay:=(v_seat->>'stack')::bigint;
   IF (v_seat->>'committed')::bigint<>0 THEN RAISE EXCEPTION 'Unsettled pot';END IF;
   IF v_pay>0 THEN PERFORM public.ct_post_credit(v_member.user_id,v_pay,'table_payout','table-payout:'||r.id::text);END IF;
   UPDATE public.ct_room_members SET paid=true,payout=v_pay WHERE room_id=r.id AND user_id=v_member.user_id;
  END LOOP;
 END IF;
 UPDATE public.ct_rooms SET state=p_state,host_id=coalesce((p_state->>'host')::uuid,host_id),version=version+1,updated_at=now() WHERE id=r.id;
 UPDATE public.ct_room_signals SET version=version+1 WHERE room_id=r.id;
 v_result:=jsonb_build_object('room_id',r.id,'version',r.version+1);
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(p_user_id,p_operation_id,p_request,v_result);RETURN v_result;
END $$;
REVOKE ALL ON FUNCTION public.ct_create_room(uuid,uuid,jsonb,text,text,boolean,bigint,jsonb),public.ct_commit_room(uuid,uuid,jsonb,uuid,bigint,jsonb,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_create_room(uuid,uuid,jsonb,text,text,boolean,bigint,jsonb),public.ct_commit_room(uuid,uuid,jsonb,uuid,bigint,jsonb,text),public.ct_replay(uuid,uuid,jsonb) TO service_role;
COMMIT;
