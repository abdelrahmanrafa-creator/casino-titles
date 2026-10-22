BEGIN;
CREATE TABLE public.ct_game_rounds (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),user_id uuid NOT NULL REFERENCES public.ct_profiles(id) ON DELETE CASCADE,
 game text NOT NULL CHECK(game IN('coinflip','roulette','slots','baccarat','blackjack')),
 bet bigint NOT NULL CHECK(bet>0),payout bigint NOT NULL DEFAULT 0 CHECK(payout>=0),
 status text NOT NULL CHECK(status IN('active','settled')),choice jsonb NOT NULL DEFAULT '{}',
 state jsonb NOT NULL DEFAULT '{}',result jsonb,
 created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ct_round_history ON public.ct_game_rounds(user_id,created_at DESC);
CREATE UNIQUE INDEX ct_one_blackjack ON public.ct_game_rounds(user_id) WHERE game='blackjack' AND status='active';
ALTER TABLE public.ct_game_rounds ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ct_game_rounds FROM PUBLIC,anon,authenticated;
-- Intentionally no SELECT grant: blackjack state contains the future deck and dealer hole card.
CREATE FUNCTION public.ct_shuffled_deck(p_decks integer DEFAULT 1) RETURNS integer[] LANGUAGE plpgsql VOLATILE SET search_path='' AS $$
DECLARE v_deck integer[];i integer;j integer;v_temp integer;
BEGIN
 IF p_decks NOT BETWEEN 1 AND 8 THEN RAISE EXCEPTION 'Invalid deck count'; END IF;
 SELECT array_agg(n ORDER BY n) INTO v_deck FROM generate_series(0,p_decks*52-1) n;
 FOR i IN REVERSE cardinality(v_deck)..2 LOOP
  j:=public.ct_random_below(i)+1;v_temp:=v_deck[i];v_deck[i]:=v_deck[j];v_deck[j]:=v_temp;
 END LOOP;
 RETURN v_deck;
END $$;
CREATE FUNCTION public.ct_card_total(p_cards integer[],p_baccarat boolean DEFAULT false) RETURNS integer LANGUAGE plpgsql IMMUTABLE SET search_path='' AS $$
DECLARE v_total integer:=0;v_aces integer:=0;v_card integer;v_rank integer;
BEGIN
 FOREACH v_card IN ARRAY p_cards LOOP
  v_rank:=(v_card%52)%13+1;
  IF p_baccarat THEN v_total:=v_total+CASE WHEN v_rank>9 THEN 0 ELSE v_rank END;
  ELSE v_total:=v_total+CASE WHEN v_rank=1 THEN 11 ELSE least(v_rank,10) END;IF v_rank=1 THEN v_aces:=v_aces+1;END IF;END IF;
 END LOOP;
 IF p_baccarat THEN RETURN v_total%10; END IF;
 WHILE v_total>21 AND v_aces>0 LOOP v_total:=v_total-10;v_aces:=v_aces-1;END LOOP;
 RETURN v_total;
END $$;
CREATE FUNCTION public.ct_banker_draw(p_banker integer,p_player_third integer) RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path='' AS $$
 SELECT CASE WHEN p_player_third IS NULL THEN p_banker<=5
 WHEN p_banker<=2 THEN true WHEN p_banker=3 THEN p_player_third<>8
 WHEN p_banker=4 THEN p_player_third BETWEEN 2 AND 7
 WHEN p_banker=5 THEN p_player_third BETWEEN 4 AND 7
 WHEN p_banker=6 THEN p_player_third IN(6,7) ELSE false END;
$$;
CREATE FUNCTION public.ct_roulette_multiplier(p_number integer,p_choice jsonb) RETURNS integer LANGUAGE plpgsql IMMUTABLE SET search_path='' AS $$
DECLARE v_kind text:=p_choice->>'kind';v_value text:=p_choice->>'value';v_red boolean;
BEGIN
 v_red:=p_number=ANY(ARRAY[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36]);
 IF v_kind='number' THEN
  IF v_value IS NULL OR v_value!~'^(0|[1-9]|[12][0-9]|3[0-6])$' THEN RAISE EXCEPTION 'Invalid roulette number';END IF;
  RETURN CASE WHEN p_number=v_value::integer THEN 36 ELSE 0 END;
 ELSIF v_kind IN('dozen','column') THEN
  IF v_value IS NULL OR v_value!~'^[1-3]$' THEN RAISE EXCEPTION 'Invalid roulette group';END IF;
  IF p_number=0 THEN RETURN 0;END IF;
  RETURN CASE WHEN (v_kind='dozen' AND (p_number-1)/12+1=v_value::integer) OR (v_kind='column' AND (p_number-1)%3+1=v_value::integer) THEN 3 ELSE 0 END;
 ELSIF v_kind IN('red','black','even','odd','low','high') THEN
  IF p_number=0 THEN RETURN 0;END IF;
  RETURN CASE WHEN (v_kind='red' AND v_red) OR (v_kind='black' AND NOT v_red) OR
  (v_kind='even' AND p_number%2=0) OR (v_kind='odd' AND p_number%2=1) OR
  (v_kind='low' AND p_number BETWEEN 1 AND 18) OR (v_kind='high' AND p_number BETWEEN 19 AND 36) THEN 2 ELSE 0 END;
 END IF;
 RAISE EXCEPTION 'Invalid roulette choice';
END $$;
CREATE FUNCTION public.ct_slot_payout(p_grid integer[],p_bet bigint) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path='' AS $$
DECLARE v_lines integer[][]:=ARRAY[[1,2,3],[4,5,6],[7,8,9],[1,5,9],[7,5,3]];
 v_line integer[];v_pay integer[]:=ARRAY[3,5,12,30,200];v_total bigint:=0;v_wins jsonb:='[]';i integer:=0;
BEGIN
 IF cardinality(p_grid)<>9 OR array_position(p_grid,NULL) IS NOT NULL OR NOT(0<=ALL(p_grid) AND 4>=ALL(p_grid)) THEN RAISE EXCEPTION 'Invalid slot grid';END IF;
 FOREACH v_line SLICE 1 IN ARRAY v_lines LOOP
  i:=i+1;
  IF p_grid[v_line[1]]=p_grid[v_line[2]] AND p_grid[v_line[2]]=p_grid[v_line[3]] THEN
   v_total:=v_total+(p_bet/5)*v_pay[p_grid[v_line[1]]+1];v_wins:=v_wins||to_jsonb(i);
  END IF;
 END LOOP;
 RETURN jsonb_build_object('payout',v_total,'winning_lines',v_wins);
END $$;
CREATE FUNCTION public.ct_resolve_instant(p_game text,p_bet bigint,p_choice jsonb) RETURNS jsonb LANGUAGE plpgsql VOLATILE SET search_path='' AS $$
DECLARE v_result jsonb;v_payout bigint:=0;v_number integer;v_grid integer[]:='{}';i integer;
 v_deck integer[];v_player integer[];v_banker integer[];v_pt integer;v_bt integer;v_third integer;v_pos integer:=5;v_winner text;
BEGIN
 IF p_game='coinflip' THEN
  IF p_choice->>'side' IS NULL OR p_choice->>'side' NOT IN('pile','face') THEN RAISE EXCEPTION 'Choose pile or face';END IF;
  v_winner:=CASE WHEN public.ct_random_below(2)=0 THEN 'pile' ELSE 'face' END;
  IF v_winner=p_choice->>'side' THEN v_payout:=p_bet*2;END IF;
  v_result:=jsonb_build_object('side',v_winner);
 ELSIF p_game='roulette' THEN
  v_number:=public.ct_random_below(37);v_payout:=p_bet*public.ct_roulette_multiplier(v_number,p_choice);
  v_result:=jsonb_build_object('number',v_number);
 ELSIF p_game='slots' THEN
  FOR i IN 1..9 LOOP
   v_number:=public.ct_random_below(100);v_grid:=array_append(v_grid,CASE WHEN v_number<40 THEN 0 WHEN v_number<70 THEN 1 WHEN v_number<88 THEN 2 WHEN v_number<98 THEN 3 ELSE 4 END);
  END LOOP;
  v_result:=public.ct_slot_payout(v_grid,p_bet)||jsonb_build_object('grid',v_grid);v_payout:=(v_result->>'payout')::bigint;
 ELSIF p_game='baccarat' THEN
  IF p_choice->>'side' IS NULL OR p_choice->>'side' NOT IN('player','banker','tie') THEN RAISE EXCEPTION 'Choose player, banker or tie';END IF;
  v_deck:=public.ct_shuffled_deck(8);v_player:=ARRAY[v_deck[1],v_deck[3]];v_banker:=ARRAY[v_deck[2],v_deck[4]];
  v_pt:=public.ct_card_total(v_player,true);v_bt:=public.ct_card_total(v_banker,true);
  IF v_pt<8 AND v_bt<8 THEN
   IF v_pt<=5 THEN
    v_player:=array_append(v_player,v_deck[v_pos]);v_third:=public.ct_card_total(ARRAY[v_deck[v_pos]],true);v_pos:=v_pos+1;
   END IF;
   IF public.ct_banker_draw(v_bt,v_third) THEN v_banker:=array_append(v_banker,v_deck[v_pos]);END IF;
   v_pt:=public.ct_card_total(v_player,true);v_bt:=public.ct_card_total(v_banker,true);
  END IF;
  v_winner:=CASE WHEN v_pt>v_bt THEN 'player' WHEN v_bt>v_pt THEN 'banker' ELSE 'tie' END;
  IF v_winner=p_choice->>'side' THEN v_payout:=CASE v_winner WHEN 'tie' THEN p_bet*9 WHEN 'banker' THEN p_bet*195/100 ELSE p_bet*2 END;
  ELSIF v_winner='tie' AND p_choice->>'side' IN('banker','player') THEN v_payout:=p_bet;END IF;
  v_result:=jsonb_build_object('player',v_player,'banker',v_banker,'player_total',v_pt,'banker_total',v_bt,'winner',v_winner);
 ELSE RAISE EXCEPTION 'Unknown instant game';END IF;
 RETURN v_result||jsonb_build_object('payout',v_payout,'outcome',CASE WHEN v_payout>p_bet THEN 'win' WHEN v_payout=p_bet THEN 'push' ELSE 'loss' END);
END $$;
CREATE FUNCTION public.ct_play_game(p_operation_id uuid,p_game text,p_bet bigint,p_choice jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid;v_request jsonb:=jsonb_build_object('kind','game','game',p_game,'bet',p_bet,'choice',p_choice);
 v_result jsonb;v_round uuid;v_payout bigint;
BEGIN
 v_uid:=public.ct_lock_wallet();v_result:=public.ct_replay(v_uid,p_operation_id,v_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 IF p_bet IS NULL OR p_bet NOT BETWEEN 20 AND 1000000 OR p_bet%20<>0 THEN RAISE EXCEPTION 'Bet must be a multiple of 20, from 20 to 1000000';END IF;
 IF p_game IS NULL OR p_game NOT IN('coinflip','roulette','slots','baccarat') OR p_choice IS NULL OR jsonb_typeof(p_choice)<>'object' THEN RAISE EXCEPTION 'Invalid game';END IF;
 PERFORM public.ct_check_rate(v_uid);
 PERFORM public.ct_post_credit(v_uid,-p_bet,'wager','bet:'||p_operation_id::text);
 v_result:=public.ct_resolve_instant(p_game,p_bet,p_choice);v_payout:=(v_result->>'payout')::bigint;
 IF v_payout>0 THEN PERFORM public.ct_post_credit(v_uid,v_payout,'payout','payout:'||p_operation_id::text);END IF;
 INSERT INTO public.ct_game_rounds(user_id,game,bet,payout,status,choice,result) VALUES(v_uid,p_game,p_bet,v_payout,'settled',p_choice,v_result) RETURNING id INTO v_round;
 v_result:=v_result||jsonb_build_object('round_id',v_round,'game',p_game,'bet',p_bet,'balance',(SELECT balance FROM public.ct_wallets WHERE user_id=v_uid));
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(v_uid,p_operation_id,v_request,v_result);RETURN v_result;
END $$;
CREATE FUNCTION public.ct_game_history() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(to_jsonb(g) ORDER BY g.created_at DESC,g.id DESC),'[]'::jsonb) FROM
 (SELECT id,game,bet,payout,status,result,created_at FROM public.ct_game_rounds WHERE user_id=auth.uid() ORDER BY created_at DESC,id DESC LIMIT 30) g;
$$;
REVOKE ALL ON FUNCTION public.ct_shuffled_deck(integer),public.ct_card_total(integer[],boolean),public.ct_banker_draw(integer,integer),public.ct_roulette_multiplier(integer,jsonb),public.ct_slot_payout(integer[],bigint),public.ct_resolve_instant(text,bigint,jsonb),public.ct_play_game(uuid,text,bigint,jsonb),public.ct_game_history() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_play_game(uuid,text,bigint,jsonb),public.ct_game_history() TO authenticated;
COMMIT;
