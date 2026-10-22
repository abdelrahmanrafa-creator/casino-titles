-- Generated from the versioned blackjack engine by scripts/blackjack-rules.mjs.
BEGIN;
CREATE TABLE public.ct_blackjack_rules(id boolean PRIMARY KEY DEFAULT true CHECK(id),dealer_hits_soft17 boolean NOT NULL DEFAULT false,natural_numerator integer NOT NULL DEFAULT 3,natural_denominator integer NOT NULL DEFAULT 2,max_hands integer NOT NULL DEFAULT 4 CHECK(max_hands BETWEEN 2 AND 4),double_after_split boolean NOT NULL DEFAULT true,CHECK((natural_numerator=3 AND natural_denominator=2) OR (natural_numerator=6 AND natural_denominator=5)));
INSERT INTO public.ct_blackjack_rules(id) VALUES(true);
ALTER TABLE public.ct_blackjack_rules ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ct_blackjack_rules FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.ct_blackjack_rules TO anon,authenticated;
CREATE POLICY ct_blackjack_rules_read ON public.ct_blackjack_rules FOR SELECT USING(true);
CREATE FUNCTION public.ct_soft_hand(p_cards integer[]) RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path='' AS $$
 SELECT public.ct_card_total(p_cards)=(SELECT coalesce(sum(least(c%13+1,10)),0)+10 FROM unnest(p_cards) c) AND EXISTS(SELECT 1 FROM unnest(p_cards)c WHERE c%13=0);
$$;
REVOKE ALL ON FUNCTION public.ct_soft_hand(integer[]) FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.ct_blackjack_view(p_round_id uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('round_id',r.id,'game','blackjack','status',r.status,'bet',r.bet,'payout',r.payout,
 'rules',r.state->'rules','hands',r.state->'hands','active_hand',r.state->'active_hand',
 'dealer',CASE WHEN r.status='active' THEN jsonb_build_array(r.state->'dealer'->0) ELSE r.state->'dealer' END,
 'result',r.result) FROM public.ct_game_rounds r WHERE r.id=p_round_id;
$$;
CREATE OR REPLACE FUNCTION public.ct_finish_blackjack(p_round_id uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.ct_game_rounds;v_dealer integer[];v_deck integer[];v_cards integer[];
 v_hands jsonb;v_hand jsonb;i integer;v_pt integer;v_dt integer;v_bet bigint;v_payout bigint:=0;v_hand_pay bigint;
 v_natural boolean;v_dealer_natural boolean;v_need_draw boolean:=false;v_outcome text;
BEGIN
 SELECT * INTO STRICT r FROM public.ct_game_rounds WHERE id=p_round_id FOR UPDATE;
 IF r.status='settled' THEN RETURN;END IF;
 SELECT array_agg(v::integer ORDER BY n) INTO v_dealer FROM jsonb_array_elements_text(r.state->'dealer') WITH ORDINALITY x(v,n);
 SELECT array_agg(v::integer ORDER BY n) INTO v_deck FROM jsonb_array_elements_text(r.state->'deck') WITH ORDINALITY x(v,n);
 v_hands:=r.state->'hands';v_dealer_natural:=public.ct_card_total(v_dealer)=21 AND cardinality(v_dealer)=2;
 FOR i IN 0..jsonb_array_length(v_hands)-1 LOOP
  v_hand:=v_hands->i;
  SELECT array_agg(v::integer ORDER BY n) INTO v_cards FROM jsonb_array_elements_text(v_hand->'cards') WITH ORDINALITY x(v,n);
  v_pt:=public.ct_card_total(v_cards);v_natural:=v_pt=21 AND cardinality(v_cards)=2 AND NOT(v_hand->>'split')::boolean;
  IF v_pt<=21 AND NOT v_natural THEN v_need_draw:=true;END IF;
 END LOOP;
 IF v_need_draw AND NOT v_dealer_natural THEN
  WHILE public.ct_card_total(v_dealer)<17 OR (public.ct_card_total(v_dealer)=17 AND coalesce((r.state->'rules'->>'dealer_hits_soft17')::boolean,false) AND public.ct_soft_hand(v_dealer)) LOOP
   IF cardinality(v_deck)=0 THEN RAISE EXCEPTION 'Deck exhausted';END IF;
   v_dealer:=array_append(v_dealer,v_deck[1]);v_deck:=v_deck[2:];
  END LOOP;
 END IF;
 v_dt:=public.ct_card_total(v_dealer);
 FOR i IN 0..jsonb_array_length(v_hands)-1 LOOP
  v_hand:=v_hands->i;v_bet:=(v_hand->>'bet')::bigint;
  SELECT array_agg(v::integer ORDER BY n) INTO v_cards FROM jsonb_array_elements_text(v_hand->'cards') WITH ORDINALITY x(v,n);
  v_pt:=public.ct_card_total(v_cards);v_natural:=v_pt=21 AND cardinality(v_cards)=2 AND NOT(v_hand->>'split')::boolean;
  v_hand_pay:=CASE WHEN v_pt>21 THEN 0 WHEN v_dealer_natural THEN CASE WHEN v_natural THEN v_bet ELSE 0 END
  WHEN v_natural THEN v_bet+v_bet*coalesce((r.state->'rules'->>'natural_numerator')::integer,3)/coalesce((r.state->'rules'->>'natural_denominator')::integer,2) WHEN v_dt>21 OR v_pt>v_dt THEN v_bet*2 WHEN v_pt=v_dt THEN v_bet ELSE 0 END;
  v_outcome:=CASE WHEN v_hand_pay>v_bet THEN 'win' WHEN v_hand_pay=v_bet THEN 'push' ELSE 'loss' END;
  v_hands:=jsonb_set(v_hands,ARRAY[i::text],v_hand||jsonb_build_object('status','settled','total',v_pt,'payout',v_hand_pay,'outcome',v_outcome));
  v_payout:=v_payout+v_hand_pay;
 END LOOP;
 IF v_payout>0 THEN PERFORM public.ct_post_credit(r.user_id,v_payout,'payout','blackjack-payout:'||r.id::text);END IF;
 UPDATE public.ct_game_rounds SET status='settled',payout=v_payout,updated_at=now(),
 state=state||jsonb_build_object('dealer',v_dealer,'deck','[]'::jsonb,'hands',v_hands),
 result=jsonb_build_object('dealer',v_dealer,'dealer_total',v_dt,'hands',v_hands,'payout',v_payout,
 'outcome',CASE WHEN v_payout>bet THEN 'win' WHEN v_payout=bet THEN 'push' ELSE 'loss' END) WHERE id=r.id;
END $$;
CREATE OR REPLACE FUNCTION public.ct_blackjack_start(p_operation_id uuid,p_bet bigint) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid;v_request jsonb:=jsonb_build_object('kind','blackjack_start','bet',p_bet);v_result jsonb;
 v_deck integer[];v_player integer[];v_dealer integer[];v_round uuid;
BEGIN
 v_uid:=public.ct_lock_wallet();v_result:=public.ct_replay(v_uid,p_operation_id,v_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 IF p_bet IS NULL OR p_bet NOT BETWEEN 20 AND 1000000 OR p_bet%20<>0 THEN RAISE EXCEPTION 'Bet must be a multiple of 20, from 20 to 1000000';END IF;
 IF EXISTS(SELECT 1 FROM public.ct_game_rounds WHERE user_id=v_uid AND game='blackjack' AND status='active') THEN RAISE EXCEPTION 'Resume your current blackjack round';END IF;
 PERFORM public.ct_check_rate(v_uid);PERFORM public.ct_post_credit(v_uid,-p_bet,'wager','blackjack:'||p_operation_id::text);
 v_deck:=public.ct_shuffled_deck();v_player:=ARRAY[v_deck[1],v_deck[3]];v_dealer:=ARRAY[v_deck[2],v_deck[4]];
 INSERT INTO public.ct_game_rounds(user_id,game,bet,status,state) VALUES(v_uid,'blackjack',p_bet,'active',
 jsonb_build_object('hands',jsonb_build_array(jsonb_build_object('cards',v_player,'bet',p_bet,'status','playing','split',false)),
 'dealer',v_dealer,'deck',v_deck[5:],'active_hand',0,'rules',(SELECT to_jsonb(c) FROM public.ct_blackjack_rules c WHERE id))) RETURNING id INTO v_round;
 IF public.ct_card_total(v_player)=21 OR public.ct_card_total(v_dealer)=21 THEN PERFORM public.ct_finish_blackjack(v_round);END IF;
 v_result:=public.ct_blackjack_view(v_round);
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(v_uid,p_operation_id,v_request,v_result);RETURN v_result;
END $$;
CREATE OR REPLACE FUNCTION public.ct_blackjack_action(p_operation_id uuid,p_round_id uuid,p_action text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid;v_request jsonb:=jsonb_build_object('kind','blackjack_action','round',p_round_id,'action',p_action);v_result jsonb;
 r public.ct_game_rounds;v_hands jsonb;v_hand jsonb;v_other jsonb;v_cards integer[];v_deck integer[];v_index integer;v_next integer:=-1;i integer;v_bet bigint;v_extra bigint:=0;
BEGIN
 v_uid:=public.ct_lock_wallet();v_result:=public.ct_replay(v_uid,p_operation_id,v_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 SELECT * INTO r FROM public.ct_game_rounds WHERE id=p_round_id AND user_id=v_uid AND game='blackjack' AND status='active' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Active round not found';END IF;
 IF p_action IS NULL OR p_action NOT IN('hit','stand','double','split') THEN RAISE EXCEPTION 'Invalid blackjack action';END IF;
 PERFORM public.ct_check_rate(v_uid);
 v_hands:=r.state->'hands';v_index:=(r.state->>'active_hand')::integer;v_hand:=v_hands->v_index;v_bet:=(v_hand->>'bet')::bigint;
 SELECT array_agg(v::integer ORDER BY n) INTO v_cards FROM jsonb_array_elements_text(v_hand->'cards') WITH ORDINALITY x(v,n);
 SELECT array_agg(v::integer ORDER BY n) INTO v_deck FROM jsonb_array_elements_text(r.state->'deck') WITH ORDINALITY x(v,n);
 IF v_hand->>'status'<>'playing' THEN RAISE EXCEPTION 'Hand is not active';END IF;
 IF p_action='split' THEN
  IF cardinality(v_cards)<>2 OR v_cards[1]%13<>v_cards[2]%13 OR jsonb_array_length(v_hands)>=coalesce((r.state->'rules'->>'max_hands')::integer,4) THEN RAISE EXCEPTION 'Pair required, maximum four hands';END IF;
  v_extra:=v_bet;
  v_other:=jsonb_build_object('cards',ARRAY[v_cards[2],v_deck[2]],'bet',v_bet,'status',CASE WHEN v_cards[1]%13=0 OR public.ct_card_total(ARRAY[v_cards[2],v_deck[2]])=21 THEN 'stood' ELSE 'playing' END,'split',true);
  v_cards:=ARRAY[v_cards[1],v_deck[1]];v_deck:=v_deck[3:];
  v_hand:=v_hand||jsonb_build_object('cards',v_cards,'split',true,'status',CASE WHEN v_cards[1]%13=0 OR public.ct_card_total(v_cards)=21 THEN 'stood' ELSE 'playing' END);
  v_hands:=v_hands||jsonb_build_array(v_other);
 ELSE
  IF p_action='double' THEN
   IF cardinality(v_cards)<>2 THEN RAISE EXCEPTION 'Double requires two cards';END IF;
   IF (v_hand->>'split')::boolean AND NOT coalesce((r.state->'rules'->>'double_after_split')::boolean,true) THEN RAISE EXCEPTION 'Double after split disabled';END IF;
   v_extra:=v_bet;v_hand:=v_hand||jsonb_build_object('bet',v_bet*2);
  END IF;
  IF p_action IN('hit','double') THEN
   v_cards:=array_append(v_cards,v_deck[1]);v_deck:=v_deck[2:];v_hand:=v_hand||jsonb_build_object('cards',v_cards);
  END IF;
  IF p_action IN('stand','double') OR public.ct_card_total(v_cards)>=21 THEN
   v_hand:=v_hand||jsonb_build_object('status',CASE WHEN public.ct_card_total(v_cards)>21 THEN 'bust' ELSE 'stood' END);
  END IF;
 END IF;
 IF v_extra>0 THEN PERFORM public.ct_post_credit(v_uid,-v_extra,'wager','blackjack-action:'||p_operation_id::text);END IF;
 v_hands:=jsonb_set(v_hands,ARRAY[v_index::text],v_hand);
 FOR i IN 0..jsonb_array_length(v_hands)-1 LOOP IF v_hands->i->>'status'='playing' THEN v_next:=i;EXIT;END IF;END LOOP;
 UPDATE public.ct_game_rounds SET bet=bet+v_extra,updated_at=now(),state=state||jsonb_build_object('hands',v_hands,'deck',v_deck,'active_hand',greatest(v_next,0)) WHERE id=r.id;
 IF v_next=-1 THEN PERFORM public.ct_finish_blackjack(r.id);END IF;
 v_result:=public.ct_blackjack_view(r.id);
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(v_uid,p_operation_id,v_request,v_result);RETURN v_result;
END $$;
CREATE FUNCTION public.ct_admin_blackjack_rules(p_operation_id uuid,p_rules jsonb,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid:=auth.uid();v_request jsonb:=jsonb_build_object('kind','blackjack_rules','rules',p_rules,'reason',p_reason);v_result jsonb;
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(v_uid::text||p_operation_id::text,93));v_result:=public.ct_replay(v_uid,p_operation_id,v_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 IF p_reason IS NULL OR length(trim(p_reason))<8 THEN RAISE EXCEPTION 'Justification required';END IF;
 UPDATE public.ct_blackjack_rules SET dealer_hits_soft17=(p_rules->>'dealer_hits_soft17')::boolean,natural_numerator=(p_rules->>'natural_numerator')::integer,natural_denominator=(p_rules->>'natural_denominator')::integer,max_hands=(p_rules->>'max_hands')::integer,double_after_split=(p_rules->>'double_after_split')::boolean WHERE id;
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(v_uid,'blackjack_rules','blackjack',p_reason,p_rules);
 v_result:='{"ok":true}'::jsonb;INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(v_uid,p_operation_id,v_request,v_result);RETURN v_result;
END $$;
REVOKE ALL ON FUNCTION public.ct_admin_blackjack_rules(uuid,jsonb,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_admin_blackjack_rules(uuid,jsonb,text) TO authenticated;
COMMIT;
