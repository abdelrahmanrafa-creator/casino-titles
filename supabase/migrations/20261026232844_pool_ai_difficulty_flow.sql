BEGIN;
ALTER TABLE public.ct_pool_matches ADD COLUMN ai_difficulty text NOT NULL DEFAULT 'normal' CHECK(ai_difficulty IN('easy','normal','hard'));
CREATE FUNCTION public.ct_pool_path_clear(p_balls jsonb,p_x double precision,p_y double precision,p_tx double precision,p_ty double precision,p_ignore integer[]) RETURNS boolean LANGUAGE plpgsql IMMUTABLE SET search_path='' AS $$
DECLARE b jsonb;dx double precision:=p_tx-p_x;dy double precision:=p_ty-p_y;t double precision;
BEGIN FOR b IN SELECT v FROM jsonb_array_elements(p_balls)v WHERE NOT(v->>'out')::boolean AND NOT((v->>'n')::integer=ANY(p_ignore)) LOOP
 t:=greatest(0,least(1,(((b->>'x')::double precision-p_x)*dx+((b->>'y')::double precision-p_y)*dy)/greatest(1,dx*dx+dy*dy)));
 IF ((b->>'x')::double precision-p_x-t*dx)^2+((b->>'y')::double precision-p_y-t*dy)^2<23^2 THEN RETURN false;END IF;
 END LOOP;RETURN true;END $$;
CREATE FUNCTION public.ct_pool_ai_plan(p_balls jsonb,p_group integer,p_in_hand boolean,p_level text) RETURNS jsonb LANGUAGE plpgsql VOLATILE SET search_path='' AS $$
DECLARE b jsonb;candidate jsonb;sim jsonb;work jsonb;best_plan jsonb;pool jsonb:='[]';orig_x double precision:=(p_balls->0->>'x')::double precision;orig_y double precision:=(p_balls->0->>'y')::double precision;x double precision;y double precision;tx double precision;ty double precision;gx double precision;gy double precision;dx double precision;dy double precision;len double precision;dist double precision;cut double precision;angle double precision;power double precision;sx double precision;sy double precision;quality double precision;best double precision:=-1e9;remaining integer;pk integer;position_n integer;variant integer;limit_n integer;first_n integer;foul boolean;own_pots integer;opponent_pots integer;cue_x double precision;cue_y double precision;next_dist double precision;error_angle double precision;variants integer;target integer;mirror_x double precision;mirror_y double precision;pockets double precision[][]:=ARRAY[ARRAY[0,0],ARRAY[500,0],ARRAY[1000,0],ARRAY[0,500],ARRAY[500,500],ARRAY[1000,500]];
BEGIN
 IF p_level NOT IN('easy','normal','hard') OR p_level IS NULL THEN RAISE EXCEPTION 'Niveau de billard invalide';END IF;
 SELECT count(*) INTO remaining FROM jsonb_array_elements(p_balls)v WHERE NOT(v->>'out')::boolean AND CASE p_group WHEN 1 THEN(v->>'n')::integer BETWEEN 1 AND 7 WHEN 2 THEN(v->>'n')::integer BETWEEN 9 AND 15 ELSE(v->>'n')::integer NOT IN(0,8) END;
 -- Generate direct potting lines. Ball in hand allows a deliberate free cue position.
 FOR b IN SELECT v FROM jsonb_array_elements(p_balls)v WHERE NOT(v->>'out')::boolean AND CASE WHEN remaining=0 THEN(v->>'n')::integer=8 WHEN p_group=1 THEN(v->>'n')::integer BETWEEN 1 AND 7 WHEN p_group=2 THEN(v->>'n')::integer BETWEEN 9 AND 15 ELSE(v->>'n')::integer NOT IN(0,8) END LOOP
  tx:=(b->>'x')::double precision;ty:=(b->>'y')::double precision;target:=(b->>'n')::integer;
  FOR pk IN 1..6 LOOP
   dx:=pockets[pk][1]-tx;dy:=pockets[pk][2]-ty;len:=sqrt(dx*dx+dy*dy);IF len<1 THEN CONTINUE;END IF;gx:=tx-dx/len*22;gy:=ty-dy/len*22;
   IF gx NOT BETWEEN 12 AND 988 OR gy NOT BETWEEN 12 AND 488 OR NOT public.ct_pool_path_clear(p_balls,tx,ty,pockets[pk][1],pockets[pk][2],ARRAY[0,target]) THEN CONTINUE;END IF;
   FOR position_n IN 0..(CASE WHEN p_in_hand THEN 2 ELSE 0 END) LOOP
    x:=CASE position_n WHEN 0 THEN orig_x WHEN 1 THEN gx-dx/len*90 ELSE gx-dx/len*160 END;y:=CASE position_n WHEN 0 THEN orig_y WHEN 1 THEN gy-dy/len*90 ELSE gy-dy/len*160 END;
    IF p_in_hand AND(x NOT BETWEEN 25 AND 975 OR y NOT BETWEEN 25 AND 475 OR NOT public.ct_pool_path_clear(p_balls,x,y,x,y,ARRAY[0])) THEN CONTINUE;END IF;
    dist:=sqrt((gx-x)^2+(gy-y)^2);IF dist<1 THEN CONTINUE;END IF;cut:=((tx-gx)*(gx-x)+(ty-gy)*(gy-y))/(22*dist);
    IF cut<.2 OR NOT public.ct_pool_path_clear(p_balls,x,y,gx,gy,ARRAY[0,target]) THEN CONTINUE;END IF;
    power:=least(100,greatest(20,(dist+len/greatest(.35,cut))/10+10));
    pool:=pool||jsonb_build_array(jsonb_build_object('angle',atan2(gy-y,gx-x),'power',power,'x',x,'y',y,'target',target,'mode','pot','rank',dist+len/cut+200*(1-cut)));
   END LOOP;
  END LOOP;
 END LOOP;
 -- A legal direct contact and cushion kicks are available when no pot is clear.
 IF jsonb_array_length(pool)=0 THEN
  FOR b IN SELECT v FROM jsonb_array_elements(p_balls)v WHERE NOT(v->>'out')::boolean AND CASE WHEN remaining=0 THEN(v->>'n')::integer=8 WHEN p_group=1 THEN(v->>'n')::integer BETWEEN 1 AND 7 WHEN p_group=2 THEN(v->>'n')::integer BETWEEN 9 AND 15 ELSE(v->>'n')::integer NOT IN(0,8) END LOOP
   tx:=(b->>'x')::double precision;ty:=(b->>'y')::double precision;target:=(b->>'n')::integer;
   dist:=greatest(1,sqrt((tx-orig_x)^2+(ty-orig_y)^2));gx:=tx-(tx-orig_x)/dist*22;gy:=ty-(ty-orig_y)/dist*22;
   IF public.ct_pool_path_clear(p_balls,orig_x,orig_y,gx,gy,ARRAY[0,target]) THEN pool:=pool||jsonb_build_array(jsonb_build_object('angle',atan2(ty-orig_y,tx-orig_x),'power',65,'x',orig_x,'y',orig_y,'target',target,'mode','safety','rank',sqrt((tx-orig_x)^2+(ty-orig_y)^2)));END IF;
   IF p_level='hard' THEN FOR pk IN 1..4 LOOP mirror_x:=CASE pk WHEN 1 THEN 22-tx WHEN 2 THEN 1978-tx ELSE tx END;mirror_y:=CASE pk WHEN 3 THEN 22-ty WHEN 4 THEN 978-ty ELSE ty END;
    pool:=pool||jsonb_build_array(jsonb_build_object('angle',atan2(mirror_y-orig_y,mirror_x-orig_x),'power',85,'x',orig_x,'y',orig_y,'target',target,'mode','bank','rank',1000+sqrt((mirror_x-orig_x)^2+(mirror_y-orig_y)^2)));
   END LOOP;END IF;
  END LOOP;
 END IF;
 IF jsonb_array_length(pool)=0 THEN RETURN jsonb_build_object('angle',0,'power',45,'x',orig_x,'y',orig_y,'spin_x',0,'spin_y',0,'mode','safety');END IF;
 limit_n:=CASE p_level WHEN 'easy' THEN 1 WHEN 'normal' THEN 2 ELSE 3 END;variants:=CASE p_level WHEN 'easy' THEN 2 WHEN 'normal' THEN 3 ELSE 5 END;
 -- At most fifteen bounded simulations; no search is performed under the economy lock.
 FOR candidate IN SELECT v FROM jsonb_array_elements(pool)v ORDER BY(v->>'rank')::double precision LIMIT limit_n LOOP
  FOR variant IN 0..variants-1 LOOP
   sx:=0;sy:=CASE variant WHEN 1 THEN CASE WHEN p_level='easy' THEN -.2 ELSE -.6 END WHEN 2 THEN .5 ELSE 0 END;
   IF variant IN(3,4) THEN sx:=CASE WHEN variant=3 THEN -.45 ELSE .45 END;sy:=-.25;END IF;
   angle:=(candidate->>'angle')::double precision;power:=(candidate->>'power')::double precision;IF variant=3 THEN power:=least(100,power*1.08);END IF;
   work:=jsonb_set(p_balls,'{0}',jsonb_build_object('n',0,'x',(candidate->>'x')::double precision,'y',(candidate->>'y')::double precision,'out',false));sim:=public.ct_pool_physics_spin(work,angle,power,sx,sy);first_n:=(sim->>'first')::integer;
   foul:=(sim->'potted' @> '[0]') OR first_n=0 OR(NOT(sim->>'rail')::boolean AND jsonb_array_length(sim->'potted')=0) OR(remaining=0 AND first_n<>8) OR(remaining>0 AND(first_n=8 OR(p_group=1 AND first_n>7) OR(p_group=2 AND first_n<9)));
   SELECT count(*) FILTER(WHERE CASE WHEN remaining=0 THEN n=8 WHEN p_group=1 THEN n BETWEEN 1 AND 7 WHEN p_group=2 THEN n BETWEEN 9 AND 15 ELSE n NOT IN(0,8) END),count(*) FILTER(WHERE CASE p_group WHEN 1 THEN n BETWEEN 9 AND 15 WHEN 2 THEN n BETWEEN 1 AND 7 ELSE false END) INTO own_pots,opponent_pots FROM(SELECT(value::text)::integer n FROM jsonb_array_elements(sim->'potted'))t;
   cue_x:=(sim#>>'{balls,0,x}')::double precision;cue_y:=(sim#>>'{balls,0,y}')::double precision;
   quality:=own_pots*150-opponent_pots*15-CASE WHEN foul THEN 1500 ELSE 0 END-sqrt((cue_x-500)^2+(cue_y-250)^2)/25;
   IF sim->'potted' @> '[8]' THEN quality:=quality+CASE WHEN remaining=0 AND NOT foul THEN 3000 ELSE -5000 END;END IF;
   IF p_level='hard' THEN
    SELECT min(sqrt(((v->>'x')::double precision-cue_x)^2+((v->>'y')::double precision-cue_y)^2)) INTO next_dist FROM jsonb_array_elements(sim->'balls')v WHERE NOT(v->>'out')::boolean AND CASE p_group WHEN 1 THEN(v->>'n')::integer BETWEEN 1 AND 7 WHEN 2 THEN(v->>'n')::integer BETWEEN 9 AND 15 ELSE(v->>'n')::integer NOT IN(0,8) END;
    quality:=quality-coalesce(next_dist,0)/65;
   END IF;
   IF quality>best THEN best:=quality;best_plan:=candidate||jsonb_build_object('power',power,'spin_x',sx,'spin_y',sy,'quality',quality);END IF;
  END LOOP;
 END LOOP;
 error_angle:=CASE p_level WHEN 'easy' THEN .055 WHEN 'normal' THEN .009 ELSE .0015 END;
 RETURN best_plan||jsonb_build_object('angle',(best_plan->>'angle')::double precision+(random()-.5)*error_angle,'power',least(100,greatest(5,(best_plan->>'power')::double precision*(1+(random()-.5)*CASE p_level WHEN 'easy' THEN .18 WHEN 'normal' THEN .05 ELSE .012 END))));
END $$;
REVOKE ALL ON FUNCTION public.ct_pool_path_clear(jsonb,double precision,double precision,double precision,double precision,integer[]),public.ct_pool_ai_plan(jsonb,integer,boolean,text) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.ct_pool_command(p_operation_id uuid,p_action text,p_values jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET statement_timeout='15s' AS $$
DECLARE u uuid:=auth.uid();q jsonb:=jsonb_build_object('kind','pool','action',p_action,'values',p_values);r jsonb;m public.ct_pool_matches;mid uuid;other uuid;stake bigint;ai_mode boolean;who integer;ang double precision;power double precision;spin_x double precision:=0;spin_y double precision:=0;ai_plan jsonb;difficulty text:='normal';phys jsonb;before_balls jsonb;own_group integer;remaining integer;foul boolean;foul_reason text;keep_turn boolean:=false;n integer;v jsonb;idx integer;px double precision;py double precision;target jsonb;best double precision:=1e9;score double precision;win integer;reason text;opponent uuid;pk integer;gx double precision;gy double precision;tx double precision;ty double precision;dx double precision;dy double precision;ln double precision;blocker jsonb;clear_path boolean;projection double precision;pockets double precision[][]:=ARRAY[ARRAY[0,0],ARRAY[500,0],ARRAY[1000,0],ARRAY[0,500],ARRAY[500,500],ARRAY[1000,500]];
BEGIN
 -- One pool command at a time per participant, then wallet locks in UUID order.
 IF u IS NULL THEN RAISE EXCEPTION 'Authentication required';END IF;
 IF p_operation_id IS NULL THEN RAISE EXCEPTION 'Operation ID required';END IF;
 IF p_action='ai' THEN PERFORM pg_advisory_xact_lock(17316,hashtext(u::text));END IF;
 -- Pure AI planning is outside the financial lock. Version validation below rejects a changed table.
 IF p_action='ai' AND NOT EXISTS(SELECT 1 FROM public.ct_operations WHERE user_id=u AND operation_id=p_operation_id) THEN
  IF EXISTS(SELECT 1 FROM public.ct_request_limits WHERE user_id=u AND window_start>now()-interval '1 minute' AND requests>=30) THEN RAISE EXCEPTION 'Too many operations. Retry in one minute.';END IF;
  SELECT * INTO m FROM public.ct_pool_matches WHERE id=(p_values->>'id')::uuid AND(host_id=u OR guest_id=u);
  IF m.id IS NULL OR m.status<>'active' OR NOT m.ai OR m.turn<>1 OR(p_values->>'version')::integer IS DISTINCT FROM m.version THEN RAISE EXCEPTION 'Ce tour ne vous appartient pas ou la table a changé';END IF;
  IF EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=u) THEN RAISE EXCEPTION 'Account suspended';END IF;
  own_group:=CASE WHEN m.host_group=0 THEN 0 ELSE 3-m.host_group END;ai_plan:=public.ct_pool_ai_plan(m.balls,own_group,m.ball_in_hand,m.ai_difficulty);
 END IF;
 PERFORM pg_advisory_xact_lock(173,8);PERFORM pg_advisory_xact_lock(173,15);
 PERFORM public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;PERFORM public.ct_check_rate(u);
 IF p_action='create' THEN
  ai_mode:=coalesce((p_values->>'ai')::boolean,false);difficulty:=CASE WHEN ai_mode THEN coalesce(p_values->>'difficulty','normal') ELSE 'normal' END;IF difficulty NOT IN('easy','normal','hard') THEN RAISE EXCEPTION 'Niveau de billard invalide';END IF;other:=nullif(p_values->>'guest','')::uuid;stake:=coalesce((p_values->>'stake')::bigint,0);
  IF stake NOT BETWEEN 0 AND 1000000 OR(ai_mode AND stake<>0) OR(NOT ai_mode AND(other IS NULL OR other=u OR NOT EXISTS(SELECT 1 FROM public.ct_profiles WHERE id=other AND NOT is_bot) OR EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=other))) THEN RAISE EXCEPTION 'Invitation ou mise invalide';END IF;
  IF EXISTS(SELECT 1 FROM public.ct_pool_matches WHERE(host_id=u OR guest_id=u) AND(status='active' OR(status='invited' AND host_id=u AND created_at>now()-interval '15 minutes'))) THEN RAISE EXCEPTION 'Terminez ou annulez votre partie de billard actuelle';END IF;
  IF NOT ai_mode AND(SELECT count(*) FROM public.ct_pool_matches WHERE guest_id=other AND status='invited' AND created_at>now()-interval '15 minutes')>=5 THEN RAISE EXCEPTION 'Ce joueur a trop d’invitations en attente';END IF;
  INSERT INTO public.ct_pool_matches(host_id,guest_id,ai,status,stake,balls,ai_difficulty) VALUES(u,CASE WHEN ai_mode THEN NULL ELSE other END,ai_mode,CASE WHEN ai_mode THEN 'active' ELSE 'invited' END,stake,public.ct_pool_rack(),difficulty) RETURNING id INTO mid;
  IF ai_mode THEN PERFORM public.ct_post_credit(u,-10000,'pool_entry','pool-entry:'||mid);END IF;
 ELSE
  mid:=(p_values->>'id')::uuid;SELECT * INTO m FROM public.ct_pool_matches WHERE id=mid AND(host_id=u OR guest_id=u) FOR UPDATE;IF m.id IS NULL THEN RAISE EXCEPTION 'Partie de billard introuvable';END IF;
  who:=CASE WHEN m.host_id=u THEN 0 ELSE 1 END;opponent:=CASE WHEN who=0 THEN m.guest_id ELSE m.host_id END;
  IF p_action='cancel' THEN
   IF m.status<>'invited' THEN RAISE EXCEPTION 'Invitation indisponible';END IF;UPDATE public.ct_pool_matches SET status='cancelled',version=version+1 WHERE id=mid;
  ELSIF p_action='accept' THEN
   IF m.status<>'invited' OR m.guest_id IS DISTINCT FROM u OR m.created_at<now()-interval '15 minutes' THEN RAISE EXCEPTION 'Invitation indisponible';END IF;
   IF EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id IN(m.host_id,m.guest_id)) THEN RAISE EXCEPTION 'Account suspended';END IF;
   IF EXISTS(SELECT 1 FROM public.ct_pool_matches WHERE id<>mid AND status='active' AND(host_id IN(m.host_id,m.guest_id) OR guest_id IN(m.host_id,m.guest_id))) THEN RAISE EXCEPTION 'Un des joueurs a déjà une partie en cours';END IF;
   PERFORM 1 FROM public.ct_wallets WHERE user_id IN(m.host_id,m.guest_id) ORDER BY user_id FOR UPDATE;
   PERFORM public.ct_post_credit(m.host_id,-10000-m.stake,'pool_entry','pool-entry:'||mid);PERFORM public.ct_post_credit(m.guest_id,-10000-m.stake,'pool_entry','pool-entry:'||mid);
   UPDATE public.ct_pool_matches SET status='active',turn_at=clock_timestamp(),version=version+1 WHERE id=mid;
  ELSIF p_action IN('resign','timeout') THEN
   IF m.status<>'active' THEN RAISE EXCEPTION 'Partie déjà terminée';END IF;
   IF p_action='timeout' AND(m.ai OR m.turn=who OR m.turn_at>clock_timestamp()-interval '2 minutes') THEN RAISE EXCEPTION 'Le délai du tour n’est pas écoulé';END IF;
   win:=CASE WHEN p_action='resign' THEN 1-who ELSE who END;reason:=p_action;
  ELSIF p_action IN('shoot','ai') THEN
   IF m.status<>'active' OR(p_values->>'version')::integer IS DISTINCT FROM m.version OR(p_action='shoot' AND m.turn<>who) OR(p_action='ai' AND(NOT m.ai OR m.turn<>1)) THEN RAISE EXCEPTION 'Ce tour ne vous appartient pas ou la table a changé';END IF;
   own_group:=CASE WHEN m.host_group=0 THEN 0 WHEN m.turn=0 THEN m.host_group ELSE 3-m.host_group END;
   SELECT count(*) INTO remaining FROM jsonb_array_elements(m.balls)b WHERE NOT(b->>'out')::boolean AND CASE WHEN own_group=1 THEN(b->>'n')::integer BETWEEN 1 AND 7 WHEN own_group=2 THEN(b->>'n')::integer BETWEEN 9 AND 15 ELSE(b->>'n')::integer NOT IN(0,8) END;
   IF m.ball_in_hand AND p_action='shoot' THEN
    px:=(p_values->>'x')::double precision;py:=(p_values->>'y')::double precision;
    IF px IS NULL OR py IS NULL OR NOT(px BETWEEN 25 AND 975 AND py BETWEEN 25 AND 475) OR EXISTS(SELECT 1 FROM jsonb_array_elements(m.balls)b WHERE(b->>'n')::integer<>0 AND NOT(b->>'out')::boolean AND((b->>'x')::double precision-px)^2+((b->>'y')::double precision-py)^2<23^2) THEN RAISE EXCEPTION 'Placez la bille blanche dans une zone libre de la table';END IF;
    m.balls:=jsonb_set(m.balls,'{0}',jsonb_build_object('n',0,'x',px,'y',py,'out',false));
   END IF;
   IF p_action='ai' THEN
    ang:=(ai_plan->>'angle')::double precision;power:=(ai_plan->>'power')::double precision;spin_x:=(ai_plan->>'spin_x')::double precision;spin_y:=(ai_plan->>'spin_y')::double precision;
    IF m.ball_in_hand THEN m.balls:=jsonb_set(m.balls,'{0}',jsonb_build_object('n',0,'x',(ai_plan->>'x')::double precision,'y',(ai_plan->>'y')::double precision,'out',false));END IF;
   ELSE ang:=(p_values->>'angle')::double precision;power:=(p_values->>'power')::double precision;END IF;
   before_balls:=m.balls;
   IF ang IS NULL OR power IS NULL OR NOT(ang BETWEEN -100 AND 100 AND power BETWEEN 5 AND 100) THEN RAISE EXCEPTION 'Direction ou puissance invalide';END IF;
   IF p_action='shoot' THEN spin_x:=coalesce((p_values->>'spin_x')::double precision,0);spin_y:=coalesce((p_values->>'spin_y')::double precision,0);END IF;
   phys:=public.ct_pool_physics_spin(m.balls,ang,power,spin_x,spin_y);n:=(phys->>'first')::integer;
   foul:=(phys->'potted' @> '[0]') OR n=0 OR(NOT(phys->>'rail')::boolean AND jsonb_array_length(phys->'potted')=0) OR(remaining=0 AND n<>8) OR(remaining>0 AND(n=8 OR(own_group=1 AND n>7) OR(own_group=2 AND n<9)));
   foul_reason:=CASE WHEN phys->'potted' @> '[0]' THEN 'scratch' WHEN n=0 THEN 'miss' WHEN remaining=0 AND n<>8 OR remaining>0 AND(n=8 OR own_group=1 AND n>7 OR own_group=2 AND n<9) THEN 'wrong_ball' WHEN NOT(phys->>'rail')::boolean AND jsonb_array_length(phys->'potted')=0 THEN 'no_cushion' ELSE NULL END;
   IF phys->'potted' @> '[8]' THEN
    IF m.shots=0 THEN
     SELECT ord::integer-1 INTO idx FROM jsonb_array_elements(phys->'balls') WITH ORDINALITY a(b,ord) WHERE(b->>'n')::integer=8;
     phys:=jsonb_set(phys,ARRAY['balls',idx::text],jsonb_build_object('n',8,'x',700,'y',250,'out',false));
    ELSE win:=CASE WHEN remaining=0 AND NOT foul THEN m.turn ELSE 1-m.turn END;reason:='eight';END IF;
   END IF;
   IF NOT foul AND own_group=0 THEN
    SELECT(value::text)::integer INTO n FROM jsonb_array_elements(phys->'potted') WHERE(value::text)::integer NOT IN(0,8) LIMIT 1;
    IF n IS NOT NULL THEN own_group:=CASE WHEN n<8 THEN 1 ELSE 2 END;m.host_group:=CASE WHEN m.turn=0 THEN own_group ELSE 3-own_group END;END IF;
   END IF;
   keep_turn:=NOT foul AND EXISTS(SELECT 1 FROM jsonb_array_elements(phys->'potted')a(n) WHERE CASE WHEN own_group=1 THEN(a.n::text)::integer BETWEEN 1 AND 7 WHEN own_group=2 THEN(a.n::text)::integer BETWEEN 9 AND 15 ELSE false END);
   -- Restore a playable white ball after a scratch, scanning for a free position.
   IF foul THEN
    FOR idx IN 0..99 LOOP px:=60+(idx%10)*95;py:=45+(idx/10)*45;EXIT WHEN NOT EXISTS(SELECT 1 FROM jsonb_array_elements(phys->'balls')b WHERE(b->>'n')::integer<>0 AND NOT(b->>'out')::boolean AND((b->>'x')::double precision-px)^2+((b->>'y')::double precision-py)^2<24^2);END LOOP;
    phys:=jsonb_set(phys,'{balls,0}',jsonb_build_object('n',0,'x',px,'y',py,'out',false));
   END IF;
   UPDATE public.ct_pool_matches SET balls=phys->'balls',host_group=m.host_group,ball_in_hand=foul,turn=CASE WHEN keep_turn THEN m.turn ELSE 1-m.turn END,shots=shots+1,version=version+1,turn_at=clock_timestamp(),last_shot=jsonb_build_object('actor',m.turn,'foul',foul,'foul_reason',foul_reason,'potted',phys->'potted','first',phys->'first','frames',phys->'frames','before',before_balls,'angle',ang,'power',power,'spin_x',spin_x,'spin_y',spin_y,'events',phys->'events','ai_difficulty',m.ai_difficulty,'ai_mode',ai_plan->>'mode','reason',reason) WHERE id=mid;
   IF win IS NULL AND m.shots>=199 THEN
    UPDATE public.ct_pool_matches SET status='completed',last_shot=last_shot||'{"reason":"draw"}' WHERE id=mid;
    IF m.stake>0 THEN PERFORM public.ct_post_credit(m.host_id,m.stake,'pool_refund','pool-refund:'||mid);PERFORM public.ct_post_credit(m.guest_id,m.stake,'pool_refund','pool-refund:'||mid);END IF;
   END IF;
  ELSE RAISE EXCEPTION 'Action inconnue';END IF;
  IF win IS NOT NULL THEN
   UPDATE public.ct_pool_matches SET status='completed',winner=win,version=version+1,last_shot=coalesce(last_shot,'{}')||jsonb_build_object('reason',reason) WHERE id=mid;
   IF m.stake>0 THEN PERFORM public.ct_post_credit(CASE WHEN win=0 THEN m.host_id ELSE m.guest_id END,2*m.stake,'pool_payout','pool-win:'||mid);END IF;
  END IF;
 END IF;
 r:=public.ct_pool_json(mid);r:=jsonb_set(r,'{last_shot}',CASE WHEN jsonb_typeof(r->'last_shot')='object' THEN (r->'last_shot')-'frames'::text-'before'::text ELSE '{}'::jsonb END);INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;
END $$;


COMMIT;
