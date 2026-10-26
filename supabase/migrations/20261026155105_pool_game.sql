BEGIN;
CREATE TABLE public.ct_pool_matches(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),host_id uuid NOT NULL REFERENCES public.ct_profiles(id),guest_id uuid REFERENCES public.ct_profiles(id),ai boolean NOT NULL,
 status text NOT NULL CHECK(status IN('invited','active','completed','cancelled')),stake bigint NOT NULL DEFAULT 0 CHECK(stake BETWEEN 0 AND 1000000),
 turn integer NOT NULL DEFAULT 0 CHECK(turn IN(0,1)),host_group integer NOT NULL DEFAULT 0 CHECK(host_group IN(0,1,2)),balls jsonb NOT NULL,
 ball_in_hand boolean NOT NULL DEFAULT false,version integer NOT NULL DEFAULT 1,shots integer NOT NULL DEFAULT 0,winner integer CHECK(winner IN(0,1)),
 last_shot jsonb,turn_at timestamptz NOT NULL DEFAULT now(),created_at timestamptz NOT NULL DEFAULT now(),CHECK((ai AND guest_id IS NULL) OR(NOT ai AND guest_id IS NOT NULL AND host_id<>guest_id))
);
CREATE INDEX ct_pool_host ON public.ct_pool_matches(host_id,created_at DESC);
CREATE INDEX ct_pool_guest ON public.ct_pool_matches(guest_id,created_at DESC);
ALTER TABLE public.ct_pool_matches ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ct_pool_matches FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_notify_pool_invite() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE sender text;BEGIN IF NEW.status='invited' THEN SELECT username INTO sender FROM public.ct_profiles WHERE id=NEW.host_id;
 INSERT INTO public.ct_inbox_messages(sender_name,recipient_id,subject,body,system_payload) VALUES('Casino & Titles',NEW.guest_id,'Invitation de billard',sender,jsonb_build_object('kind','pool_invite','name',sender,'rarity',0,'amount',10000+NEW.stake,'stake',NEW.stake,'match_id',NEW.id,'expires_at',NEW.created_at+interval '15 minutes'));
END IF;RETURN NEW;END $$;
CREATE TRIGGER ct_pool_invite_inbox AFTER INSERT ON public.ct_pool_matches FOR EACH ROW EXECUTE FUNCTION public.ct_notify_pool_invite();
REVOKE ALL ON FUNCTION public.ct_notify_pool_invite() FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_pool_rack() RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path='' AS $$
DECLARE b jsonb:='[{"n":0,"x":250,"y":250,"out":false}]';row_n integer;col integer;idx integer:=1;nums integer[]:=ARRAY[1,9,2,10,8,3,11,4,12,5,6,13,7,14,15];
BEGIN FOR row_n IN 0..4 LOOP FOR col IN 0..row_n LOOP b:=b||jsonb_build_array(jsonb_build_object('n',nums[idx],'x',700+row_n*19.2,'y',250+(col-row_n/2.0)*22.2,'out',false));idx:=idx+1;END LOOP;END LOOP;RETURN b;END $$;
-- Bounded, authoritative physics: sixteen balls, elastic impacts, cushions and six pockets.
-- Only the direction, strength and (after a foul) cue position come from the client.
CREATE FUNCTION public.ct_pool_physics(p_balls jsonb,p_angle double precision,p_power double precision) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path='' AS $$
DECLARE x double precision[];y double precision[];vx double precision[]:=array_fill(0::double precision,ARRAY[16]);vy double precision[]:=vx;gone boolean[];nums integer[];i integer;j integer;k integer;step integer;dx double precision;dy double precision;dist double precision;imp double precision;overlap double precision;speed double precision;first_hit integer:=0;rail boolean:=false;potted integer[]:='{}';frames jsonb:='[]';frame jsonb;balls jsonb:='[]';pockets double precision[][]:=ARRAY[ARRAY[0,0],ARRAY[500,0],ARRAY[1000,0],ARRAY[0,500],ARRAY[500,500],ARRAY[1000,500]];
BEGIN
 SELECT array_agg((v->>'x')::double precision ORDER BY ord),array_agg((v->>'y')::double precision ORDER BY ord),array_agg((v->>'out')::boolean ORDER BY ord),array_agg((v->>'n')::integer ORDER BY ord) INTO x,y,gone,nums FROM jsonb_array_elements(p_balls) WITH ORDINALITY a(v,ord);
 vx[1]:=cos(p_angle)*p_power*.12;vy[1]:=sin(p_angle)*p_power*.12;
 FOR step IN 1..900 LOOP
  speed:=0;
  FOR i IN 1..16 LOOP
   IF gone[i] THEN CONTINUE;END IF;x[i]:=x[i]+vx[i];y[i]:=y[i]+vy[i];
   FOR k IN 1..6 LOOP IF (x[i]-pockets[k][1])^2+(y[i]-pockets[k][2])^2<24^2 THEN gone[i]:=true;vx[i]:=0;vy[i]:=0;potted:=array_append(potted,nums[i]);EXIT;END IF;END LOOP;
   IF gone[i] THEN CONTINUE;END IF;
   IF x[i]<11 OR x[i]>989 THEN x[i]:=greatest(11,least(989,x[i]));vx[i]:=-vx[i]*.88;IF first_hit>0 THEN rail:=true;END IF;END IF;
   IF y[i]<11 OR y[i]>489 THEN y[i]:=greatest(11,least(489,y[i]));vy[i]:=-vy[i]*.88;IF first_hit>0 THEN rail:=true;END IF;END IF;
  END LOOP;
  FOR i IN 1..15 LOOP IF gone[i] THEN CONTINUE;END IF;
   FOR j IN i+1..16 LOOP IF gone[j] THEN CONTINUE;END IF;
    dx:=x[j]-x[i];dy:=y[j]-y[i];dist:=sqrt(dx*dx+dy*dy);
    IF dist<22 AND dist>.00001 THEN
     dx:=dx/dist;dy:=dy/dist;overlap:=(22-dist)/2;x[i]:=x[i]-dx*overlap;y[i]:=y[i]-dy*overlap;x[j]:=x[j]+dx*overlap;y[j]:=y[j]+dy*overlap;
     imp:=(vx[i]-vx[j])*dx+(vy[i]-vy[j])*dy;
     IF imp>0 THEN vx[i]:=vx[i]-imp*dx;vy[i]:=vy[i]-imp*dy;vx[j]:=vx[j]+imp*dx;vy[j]:=vy[j]+imp*dy;IF i=1 AND first_hit=0 THEN first_hit:=nums[j];END IF;END IF;
    END IF;
   END LOOP;
  END LOOP;
  FOR i IN 1..16 LOOP vx[i]:=vx[i]*.988;vy[i]:=vy[i]*.988;IF abs(vx[i])+abs(vy[i])<.025 THEN vx[i]:=0;vy[i]:=0;END IF;speed:=speed+abs(vx[i])+abs(vy[i]);END LOOP;
  IF step%8=0 OR speed=0 THEN SELECT jsonb_agg(jsonb_build_array(round(x[z]::numeric,2),round(y[z]::numeric,2),gone[z]) ORDER BY z) INTO frame FROM generate_series(1,16)z;frames:=frames||jsonb_build_array(frame);END IF;
  EXIT WHEN speed=0;
 END LOOP;
 FOR i IN 1..16 LOOP balls:=balls||jsonb_build_array(jsonb_build_object('n',nums[i],'x',x[i],'y',y[i],'out',gone[i]));END LOOP;
 RETURN jsonb_build_object('balls',balls,'frames',frames,'first',first_hit,'rail',rail,'potted',to_jsonb(potted));
END $$;
CREATE FUNCTION public.ct_pool_json(p_id uuid) RETURNS jsonb LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT to_jsonb(m)||jsonb_build_object('host_name',h.username,'guest_name',CASE WHEN m.ai THEN NULL ELSE g.username END,'entry',10000,'expires_at',CASE WHEN m.status='invited' THEN m.created_at+interval '15 minutes' ELSE m.turn_at+interval '2 minutes' END) FROM public.ct_pool_matches m JOIN public.ct_profiles h ON h.id=m.host_id LEFT JOIN public.ct_profiles g ON g.id=m.guest_id WHERE m.id=p_id;
$$;
CREATE FUNCTION public.ct_pool_lobby(p_versions jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid:=auth.uid();BEGIN IF u IS NULL THEN RAISE EXCEPTION 'Authentication required';END IF;
 RETURN coalesce((SELECT jsonb_agg(CASE WHEN (p_versions->>m.id::text)::integer IS DISTINCT FROM m.version AND p_versions ? m.id::text THEN public.ct_pool_json(m.id) ELSE public.ct_pool_json(m.id) #- '{last_shot,frames}' #- '{last_shot,before}' END ORDER BY m.created_at DESC) FROM(SELECT id,created_at,version FROM public.ct_pool_matches WHERE(host_id=u OR guest_id=u) AND(status='active' OR status='invited' AND created_at>now()-interval '15 minutes' OR status='completed' AND created_at>now()-interval '1 day') ORDER BY CASE status WHEN 'active' THEN 0 WHEN 'invited' THEN 1 ELSE 2 END,created_at DESC LIMIT 10)m),'[]');END $$;
CREATE FUNCTION public.ct_pool_players(p_search text) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required';END IF;IF length(trim(coalesce(p_search,'')))<2 THEN RETURN '[]';END IF;
 RETURN coalesce((SELECT jsonb_agg(to_jsonb(p)) FROM(SELECT id,username FROM public.ct_profiles WHERE id<>auth.uid() AND NOT is_bot AND left(lower(username),length(trim(p_search)))=lower(trim(p_search)) AND NOT EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=id) ORDER BY username LIMIT 10)p),'[]');END $$;
CREATE FUNCTION public.ct_pool_command(p_operation_id uuid,p_action text,p_values jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET statement_timeout='15s' AS $$
DECLARE u uuid:=auth.uid();q jsonb:=jsonb_build_object('kind','pool','action',p_action,'values',p_values);r jsonb;m public.ct_pool_matches;mid uuid;other uuid;stake bigint;ai_mode boolean;who integer;ang double precision;power double precision;phys jsonb;before_balls jsonb;own_group integer;remaining integer;foul boolean;keep_turn boolean:=false;n integer;v jsonb;idx integer;px double precision;py double precision;target jsonb;best double precision:=1e9;score double precision;win integer;reason text;opponent uuid;pk integer;gx double precision;gy double precision;tx double precision;ty double precision;dx double precision;dy double precision;ln double precision;blocker jsonb;clear_path boolean;projection double precision;pockets double precision[][]:=ARRAY[ARRAY[0,0],ARRAY[500,0],ARRAY[1000,0],ARRAY[0,500],ARRAY[500,500],ARRAY[1000,500]];
BEGIN
 -- One pool command at a time per participant, then wallet locks in UUID order.
 IF u IS NULL THEN RAISE EXCEPTION 'Authentication required';END IF;
 PERFORM pg_advisory_xact_lock(173,8);PERFORM pg_advisory_xact_lock(173,15);
 PERFORM public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;PERFORM public.ct_check_rate(u);
 IF p_action='create' THEN
  ai_mode:=coalesce((p_values->>'ai')::boolean,false);other:=nullif(p_values->>'guest','')::uuid;stake:=coalesce((p_values->>'stake')::bigint,0);
  IF stake NOT BETWEEN 0 AND 1000000 OR(ai_mode AND stake<>0) OR(NOT ai_mode AND(other IS NULL OR other=u OR NOT EXISTS(SELECT 1 FROM public.ct_profiles WHERE id=other AND NOT is_bot) OR EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=other))) THEN RAISE EXCEPTION 'Invitation ou mise invalide';END IF;
  IF EXISTS(SELECT 1 FROM public.ct_pool_matches WHERE(host_id=u OR guest_id=u) AND(status='active' OR(status='invited' AND host_id=u AND created_at>now()-interval '15 minutes'))) THEN RAISE EXCEPTION 'Terminez ou annulez votre partie de billard actuelle';END IF;
  IF NOT ai_mode AND(SELECT count(*) FROM public.ct_pool_matches WHERE guest_id=other AND status='invited' AND created_at>now()-interval '15 minutes')>=5 THEN RAISE EXCEPTION 'Ce joueur a trop d’invitations en attente';END IF;
  INSERT INTO public.ct_pool_matches(host_id,guest_id,ai,status,stake,balls) VALUES(u,CASE WHEN ai_mode THEN NULL ELSE other END,ai_mode,CASE WHEN ai_mode THEN 'active' ELSE 'invited' END,stake,public.ct_pool_rack()) RETURNING id INTO mid;
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
   before_balls:=m.balls;
   IF p_action='ai' THEN
    px:=(m.balls->0->>'x')::double precision;py:=(m.balls->0->>'y')::double precision;
    FOR v IN SELECT b FROM jsonb_array_elements(m.balls)b WHERE NOT(b->>'out')::boolean AND(b->>'n')::integer<>0 AND CASE WHEN remaining=0 THEN(b->>'n')::integer=8 WHEN own_group=1 THEN(b->>'n')::integer BETWEEN 1 AND 7 WHEN own_group=2 THEN(b->>'n')::integer BETWEEN 9 AND 15 ELSE(b->>'n')::integer<>8 END LOOP
     FOR pk IN 1..6 LOOP
      tx:=(v->>'x')::double precision;ty:=(v->>'y')::double precision;dx:=pockets[pk][1]-tx;dy:=pockets[pk][2]-ty;ln:=sqrt(dx*dx+dy*dy);gx:=tx-dx/ln*22;gy:=ty-dy/ln*22;
      IF gx NOT BETWEEN 12 AND 988 OR gy NOT BETWEEN 12 AND 488 THEN CONTINUE;END IF;
      -- Reject blocked cue-to-ghost and object-to-pocket paths.
      clear_path:=true;
      FOR blocker IN SELECT b FROM jsonb_array_elements(m.balls)b WHERE NOT(b->>'out')::boolean AND(b->>'n')::integer NOT IN(0,(v->>'n')::integer) LOOP
       dx:=gx-px;dy:=gy-py;projection:=greatest(0,least(1,(((blocker->>'x')::double precision-px)*dx+((blocker->>'y')::double precision-py)*dy)/greatest(1,dx*dx+dy*dy)));
       IF ((blocker->>'x')::double precision-px-projection*dx)^2+((blocker->>'y')::double precision-py-projection*dy)^2<23^2 THEN clear_path:=false;EXIT;END IF;
       dx:=pockets[pk][1]-tx;dy:=pockets[pk][2]-ty;projection:=greatest(0,least(1,(((blocker->>'x')::double precision-tx)*dx+((blocker->>'y')::double precision-ty)*dy)/(dx*dx+dy*dy)));
       IF ((blocker->>'x')::double precision-tx-projection*dx)^2+((blocker->>'y')::double precision-ty-projection*dy)^2<23^2 THEN clear_path:=false;EXIT;END IF;
      END LOOP;
      IF NOT clear_path THEN CONTINUE;END IF;
      -- A ghost ball behind the target cannot be reached with a forward cut.
      IF (tx-gx)*(gx-px)+(ty-gy)*(gy-py)<=0 THEN CONTINUE;END IF;
      score:=sqrt((gx-px)^2+(gy-py)^2)+ln*1.2;
      IF score<best THEN best:=score;ang:=atan2(gy-py,gx-px);power:=least(100,greatest(30,score/13+23));END IF;
     END LOOP;
    END LOOP;
    IF best=1e9 THEN
     SELECT b INTO target FROM jsonb_array_elements(m.balls)b WHERE NOT(b->>'out')::boolean AND(b->>'n')::integer<>0 AND CASE WHEN remaining=0 THEN(b->>'n')::integer=8 WHEN own_group=1 THEN(b->>'n')::integer BETWEEN 1 AND 7 WHEN own_group=2 THEN(b->>'n')::integer BETWEEN 9 AND 15 ELSE(b->>'n')::integer<>8 END ORDER BY ((b->>'x')::double precision-px)^2+((b->>'y')::double precision-py)^2 LIMIT 1;
     ang:=atan2((target->>'y')::double precision-py,(target->>'x')::double precision-px);power:=65;
    END IF;ang:=ang+(random()-.5)*.012;
   ELSE ang:=(p_values->>'angle')::double precision;power:=(p_values->>'power')::double precision;END IF;
   IF ang IS NULL OR power IS NULL OR NOT(ang BETWEEN -100 AND 100 AND power BETWEEN 5 AND 100) THEN RAISE EXCEPTION 'Direction ou puissance invalide';END IF;
   phys:=public.ct_pool_physics(m.balls,ang,power);n:=(phys->>'first')::integer;
   foul:=(phys->'potted' @> '[0]') OR n=0 OR(NOT(phys->>'rail')::boolean AND jsonb_array_length(phys->'potted')=0) OR(remaining=0 AND n<>8) OR(remaining>0 AND(n=8 OR(own_group=1 AND n>7) OR(own_group=2 AND n<9)));
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
   UPDATE public.ct_pool_matches SET balls=phys->'balls',host_group=m.host_group,ball_in_hand=foul,turn=CASE WHEN keep_turn THEN m.turn ELSE 1-m.turn END,shots=shots+1,version=version+1,turn_at=clock_timestamp(),last_shot=jsonb_build_object('actor',m.turn,'foul',foul,'potted',phys->'potted','first',phys->'first','frames',phys->'frames','before',before_balls,'angle',ang,'power',power,'reason',reason) WHERE id=mid;
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
REVOKE ALL ON FUNCTION public.ct_pool_rack(),public.ct_pool_physics(jsonb,double precision,double precision),public.ct_pool_json(uuid),public.ct_pool_lobby(jsonb),public.ct_pool_players(text),public.ct_pool_command(uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_pool_lobby(jsonb),public.ct_pool_players(text),public.ct_pool_command(uuid,text,jsonb) TO authenticated;
COMMIT;
