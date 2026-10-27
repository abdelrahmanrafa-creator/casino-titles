BEGIN;
-- Specialized equal-mass billiard solver. Board units: radius 11 = 28.575 mm.
-- 0.17 kg spheres, inertia 2/5 m r²; fixed 1/240 s, swept pair contacts.
CREATE FUNCTION public.ct_pool_pro_engine(p_balls jsonb,p_angle double precision,p_power double precision,p_spin_x double precision,p_spin_y double precision,p_capture boolean DEFAULT true) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path='' AS $$
DECLARE
 x float8[];y float8[];px float8[];py float8[];vx float8[]:=array_fill(0::float8,ARRAY[16]);vy float8[]:=vx;wx float8[]:=vx;wy float8[]:=vx;wz float8[]:=vx;gone boolean[];nums int[];
 qx float8[]:=vx;qy float8[]:=vx;qz float8[]:=vx;qw float8[]:=array_fill(1::float8,ARRAY[16]);
 i int;j int;k int;s int;pass int;dt constant float8:=1.0/240;g constant float8:=9.81*385;radius constant float8:=11;
 dx float8;dy float8;dist float8;nx float8;ny float8;jn float8;jt float8;vt float8;slipx float8;slipy float8;slip float8;speed float8;total float8;acc float8;factor float8;aa float8;bb float8;cc float8;disc float8;toi float8;remain float8;rx float8;ry float8;rdx float8;rdy float8;overlap float8;oldqx float8;oldqy float8;oldqz float8;oldqw float8;norm float8;
 launch_speed float8:=p_power*17.3*(.7+.0115*p_power);first_hit int:=0;rail boolean:=false;rail_balls int[]:='{}';potted int[]:='{}';events jsonb:='[]';frames jsonb:='[]';times jsonb:='[]';frame jsonb;balls jsonb:='[]';last_sample int:=0;elapsed_step int:=0;
 jaws float8[][]:=ARRAY[ARRAY[472,-6],ARRAY[528,-6],ARRAY[472,506],ARRAY[528,506],ARRAY[-6,30],ARRAY[30,-6],ARRAY[970,-6],ARRAY[1006,30],ARRAY[-6,470],ARRAY[30,506],ARRAY[970,506],ARRAY[1006,470]];
 pockets float8[][]:=ARRAY[ARRAY[0,0],ARRAY[500,0],ARRAY[1000,0],ARRAY[0,500],ARRAY[500,500],ARRAY[1000,500]];
BEGIN
 IF jsonb_array_length(p_balls)<>16 OR p_angle IS NULL OR NOT(p_angle BETWEEN -100 AND 100) OR p_power IS NULL OR NOT(p_power BETWEEN 5 AND 100) THEN RAISE EXCEPTION 'Direction ou puissance invalide';END IF;
 IF p_spin_x IS NULL OR p_spin_y IS NULL OR NOT(p_spin_x BETWEEN -1 AND 1 AND p_spin_y BETWEEN -1 AND 1) OR p_spin_x*p_spin_x+p_spin_y*p_spin_y>1.00001 THEN RAISE EXCEPTION 'Effet de bille invalide';END IF;
 SELECT array_agg((v->>'x')::float8 ORDER BY ord),array_agg((v->>'y')::float8 ORDER BY ord),array_agg((v->>'out')::boolean ORDER BY ord),array_agg((v->>'n')::int ORDER BY ord) INTO x,y,gone,nums FROM jsonb_array_elements(p_balls) WITH ORDINALITY a(v,ord);
 FOR i IN 1..16 LOOP IF p_balls->(i-1)->'q' IS NOT NULL THEN qx[i]:=coalesce((p_balls->(i-1)->'q'->>0)::float8,0);qy[i]:=coalesce((p_balls->(i-1)->'q'->>1)::float8,0);qz[i]:=coalesce((p_balls->(i-1)->'q'->>2)::float8,0);qw[i]:=coalesce((p_balls->(i-1)->'q'->>3)::float8,1);END IF;END LOOP;
 vx[1]:=cos(p_angle)*launch_speed;vy[1]:=sin(p_angle)*launch_speed;
 -- Cue angular impulse is r_contact × J / I, limited to a playable contact disk.
 wx[1]:=-vy[1]/radius*p_spin_y*1.8;wy[1]:=vx[1]/radius*p_spin_y*1.8;wz[1]:=p_spin_x*launch_speed/radius*.7;
 FOR s IN 1..7200 LOOP
  elapsed_step:=s;total:=0;px:=x;py:=y;
  FOR i IN 1..16 LOOP
   IF gone[i] THEN CONTINUE;END IF;
   x[i]:=x[i]+vx[i]*dt;y[i]:=y[i]+vy[i]*dt;
   -- Capture at the throat, after a ball enters a real mouth; no side-of-rail capture.
   FOR k IN 1..6 LOOP IF (x[i]-pockets[k][1])^2+(y[i]-pockets[k][2])^2<17^2 THEN
    gone[i]:=true;vx[i]:=0;vy[i]:=0;wx[i]:=0;wy[i]:=0;wz[i]:=0;potted:=array_append(potted,nums[i]);
    IF p_capture THEN events:=events||jsonb_build_array(jsonb_build_object('kind','pocket','pocket',k-1,'ball',nums[i],'step',s/2.0,'time_ms',s*1000*dt,'intensity',.5,'x',x[i],'y',y[i]));END IF;EXIT;
   END IF;END LOOP;
   IF gone[i] THEN CONTINUE;END IF;
   jn:=0;
   FOR k IN 1..12 LOOP dx:=x[i]-jaws[k][1];dy:=y[i]-jaws[k][2];dist:=sqrt(dx*dx+dy*dy);IF dist<18 AND dist>.00001 THEN nx:=dx/dist;ny:=dy/dist;vt:=vx[i]*nx+vy[i]*ny;x[i]:=jaws[k][1]+nx*18;y[i]:=jaws[k][2]+ny*18;IF vt<0 THEN vx[i]:=vx[i]-1.78*vt*nx;vy[i]:=vy[i]-1.78*vt*ny;jn:=greatest(jn,-vt);END IF;END IF;END LOOP;
   IF (x[i]<11 OR x[i]>989) AND y[i] BETWEEN 24 AND 476 THEN
    jn:=abs(vx[i]);x[i]:=CASE WHEN x[i]<11 THEN 22-x[i] ELSE 1978-x[i] END;
    jt:=greatest(-jn*.18,least(jn*.18,(vy[i]+CASE WHEN x[i]<500 THEN -1 ELSE 1 END*radius*wz[i])*.12));vy[i]:=vy[i]-jt;wz[i]:=wz[i]-jt/radius*2.5*CASE WHEN x[i]<500 THEN -1 ELSE 1 END;vx[i]:=-vx[i]*.88;
   END IF;
   IF (y[i]<11 OR y[i]>489) AND NOT(abs(x[i]-500)<25 OR x[i]<24 OR x[i]>976) THEN
    jn:=greatest(jn,abs(vy[i]));y[i]:=CASE WHEN y[i]<11 THEN 22-y[i] ELSE 978-y[i] END;
    jt:=greatest(-jn*.18,least(jn*.18,(vx[i]+CASE WHEN y[i]<250 THEN 1 ELSE -1 END*radius*wz[i])*.12));vx[i]:=vx[i]-jt;wz[i]:=wz[i]-jt/radius*2.5*CASE WHEN y[i]<250 THEN 1 ELSE -1 END;vy[i]:=-vy[i]*.88;
   END IF;
   IF jn>1 THEN
    IF first_hit>0 THEN rail:=true;IF NOT(nums[i]=ANY(rail_balls)) THEN rail_balls:=array_append(rail_balls,nums[i]);END IF;END IF;
    IF p_capture AND jn>30 THEN events:=events||jsonb_build_array(jsonb_build_object('kind','cushion','ball',nums[i],'step',s/2.0,'time_ms',s*1000*dt,'intensity',least(1,jn/1300),'x',x[i],'y',y[i]));END IF;
   END IF;
   -- Safety jaws: outside a mouth balls cannot leak beyond the table.
   IF x[i]<-24 OR x[i]>1024 OR y[i]<-24 OR y[i]>524 THEN x[i]:=greatest(11,least(989,x[i]));y[i]:=greatest(11,least(489,y[i]));vx[i]:=-vx[i]*.65;vy[i]:=-vy[i]*.65;END IF;
  END LOOP;
  FOR i IN 1..15 LOOP IF gone[i] THEN CONTINUE;END IF;
   FOR j IN i+1..16 LOOP IF gone[j] THEN CONTINUE;END IF;
    dx:=x[j]-x[i];dy:=y[j]-y[i];dist:=sqrt(dx*dx+dy*dy);remain:=0;
    IF dist>=22 THEN
     rx:=px[j]-px[i];ry:=py[j]-py[i];rdx:=(vx[j]-vx[i])*dt;rdy:=(vy[j]-vy[i])*dt;aa:=rdx*rdx+rdy*rdy;bb:=2*(rx*rdx+ry*rdy);cc:=rx*rx+ry*ry-484;disc:=bb*bb-4*aa*cc;
     IF aa>1e-10 AND bb<0 AND cc>0 AND disc>=0 THEN toi:=(-bb-sqrt(disc))/(2*aa);IF toi BETWEEN 0 AND 1 THEN
      x[i]:=px[i]+vx[i]*dt*toi;y[i]:=py[i]+vy[i]*dt*toi;x[j]:=px[j]+vx[j]*dt*toi;y[j]:=py[j]+vy[j]*dt*toi;dx:=x[j]-x[i];dy:=y[j]-y[i];dist:=sqrt(dx*dx+dy*dy);remain:=(1-toi)*dt;
     END IF;END IF;
    END IF;
    IF dist<=22.00001 THEN
     IF dist<.00001 THEN nx:=1;ny:=0;dist:=.00001;ELSE nx:=dx/dist;ny:=dy/dist;END IF;
     overlap:=greatest(0,(22-dist)/2);x[i]:=x[i]-nx*overlap;y[i]:=y[i]-ny*overlap;x[j]:=x[j]+nx*overlap;y[j]:=y[j]+ny*overlap;
     jn:=((vx[i]-vx[j])*nx+(vy[i]-vy[j])*ny)*.98;
     IF jn>0 THEN
      vt:=(vx[i]-vx[j])*(-ny)+(vy[i]-vy[j])*nx+radius*(wz[i]+wz[j]);jt:=greatest(-jn*.045,least(jn*.045,-vt/7));
      vx[i]:=vx[i]-jn*nx-jt*ny;vy[i]:=vy[i]-jn*ny+jt*nx;vx[j]:=vx[j]+jn*nx+jt*ny;vy[j]:=vy[j]+jn*ny-jt*nx;wz[i]:=wz[i]+2.5*jt/radius;wz[j]:=wz[j]+2.5*jt/radius;
      IF i=1 AND first_hit=0 THEN first_hit:=nums[j];END IF;
      IF p_capture AND jn>20 THEN events:=events||jsonb_build_array(jsonb_build_object('kind','impact','ball',nums[j],'step',s/2.0,'time_ms',s*1000*dt,'intensity',least(1,jn/1300),'x',x[i]+nx*11,'y',y[i]+ny*11));END IF;
     END IF;
     IF remain>0 THEN x[i]:=x[i]+vx[i]*remain;y[i]:=y[i]+vy[i]*remain;x[j]:=x[j]+vx[j]*remain;y[j]:=y[j]+vy[j]*remain;END IF;
    END IF;
   END LOOP;
  END LOOP;
  FOR i IN 1..16 LOOP
   IF gone[i] THEN CONTINUE;END IF;
   slipx:=vx[i]-radius*wy[i];slipy:=vy[i]+radius*wx[i];slip:=sqrt(slipx*slipx+slipy*slipy);speed:=sqrt(vx[i]*vx[i]+vy[i]*vy[i]);
   IF slip>3.5*.18*g*dt THEN
    acc:=.18*g/slip;vx[i]:=vx[i]-slipx*acc*dt;vy[i]:=vy[i]-slipy*acc*dt;wy[i]:=wy[i]+2.5*slipx*acc*dt/radius;wx[i]:=wx[i]-2.5*slipy*acc*dt/radius;
   ELSE
    -- Exact sliding-to-rolling projection followed by rolling resistance.
    vx[i]:=vx[i]-slipx/3.5;vy[i]:=vy[i]-slipy/3.5;speed:=sqrt(vx[i]*vx[i]+vy[i]*vy[i]);factor:=greatest(0,1-.025*g*dt/greatest(speed,.00001));vx[i]:=vx[i]*factor;vy[i]:=vy[i]*factor;wx[i]:=-vy[i]/radius;wy[i]:=vx[i]/radius;
   END IF;
   wz[i]:=sign(wz[i])*greatest(0,abs(wz[i])-5*dt);
   IF abs(vx[i])+abs(vy[i])<1 AND slip<2 THEN vx[i]:=0;vy[i]:=0;wx[i]:=0;wy[i]:=0;END IF;
   IF p_capture THEN
    oldqx:=qx[i];oldqy:=qy[i];oldqz:=qz[i];oldqw:=qw[i];qx[i]:=oldqx+dt*.5*(wx[i]*oldqw+wy[i]*oldqz-wz[i]*oldqy);qy[i]:=oldqy+dt*.5*(-wx[i]*oldqz+wy[i]*oldqw+wz[i]*oldqx);qz[i]:=oldqz+dt*.5*(wx[i]*oldqy-wy[i]*oldqx+wz[i]*oldqw);qw[i]:=oldqw-dt*.5*(wx[i]*oldqx+wy[i]*oldqy+wz[i]*oldqz);norm:=sqrt(qx[i]^2+qy[i]^2+qz[i]^2+qw[i]^2);qx[i]:=qx[i]/norm;qy[i]:=qy[i]/norm;qz[i]:=qz[i]/norm;qw[i]:=qw[i]/norm;
   END IF;
   total:=total+abs(vx[i])+abs(vy[i])+abs(wx[i])+abs(wy[i]);
  END LOOP;
  IF p_capture AND(s%24=0 OR total=0) THEN
   SELECT jsonb_agg(jsonb_build_array(round(x[z]::numeric,3),round(y[z]::numeric,3),gone[z],round(qx[z]::numeric,6),round(qy[z]::numeric,6),round(qz[z]::numeric,6),round(qw[z]::numeric,6)) ORDER BY z) INTO frame FROM generate_series(1,16)z;
   frames:=frames||jsonb_build_array(frame);times:=times||jsonb_build_array(round(s*1000*dt));last_sample:=s;
  END IF;
  EXIT WHEN total=0;
 END LOOP;
 FOR i IN 1..16 LOOP balls:=balls||jsonb_build_array(jsonb_build_object('n',nums[i],'x',x[i],'y',y[i],'out',gone[i],'q',jsonb_build_array(qx[i],qy[i],qz[i],qw[i])));END LOOP;
 RETURN jsonb_build_object('balls',balls,'frames',frames,'frame_times',times,'duration_ms',elapsed_step*1000*dt,'physics','pro-1','first',first_hit,'rail',rail,'rail_balls',to_jsonb(rail_balls),'potted',to_jsonb(potted),'events',events);
END $$;
CREATE OR REPLACE FUNCTION public.ct_pool_physics_spin(p_balls jsonb,p_angle float8,p_power float8,p_spin_x float8,p_spin_y float8) RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path='' AS $$ SELECT public.ct_pool_pro_engine(p_balls,p_angle,p_power,p_spin_x,p_spin_y,true) $$;
REVOKE ALL ON FUNCTION public.ct_pool_pro_engine(jsonb,float8,float8,float8,float8,boolean) FROM PUBLIC,anon,authenticated;
-- The planner uses the identical solver but does not build unused animation payloads.
DO $$DECLARE body text;BEGIN
 SELECT pg_get_functiondef('public.ct_pool_ai_plan(jsonb,integer,boolean,text)'::regprocedure) INTO body;
 body:=replace(body,'public.ct_pool_physics_spin(work,angle,power,sx,sy)','public.ct_pool_pro_engine(work,angle,power,sx,sy,false)');EXECUTE body;
 SELECT pg_get_functiondef('public.ct_pool_command(uuid,text,jsonb)'::regprocedure) INTO body;
 body:=replace(body,'''frames'',phys->''frames''','''frames'',phys->''frames'',''frame_times'',phys->''frame_times'',''duration_ms'',phys->''duration_ms'',''physics'',phys->''physics''');EXECUTE body;
END $$;

-- Versioned club rules preserve ongoing matches and legacy application clients.
ALTER TABLE public.ct_pool_matches ADD COLUMN rules_version text NOT NULL DEFAULT 'house-v1' CHECK(rules_version IN('house-v1','club-v2'));
DO $$DECLARE body text;BEGIN
 SELECT pg_get_functiondef('public.ct_pool_ai_plan(jsonb,integer,boolean,text)'::regprocedure) INTO body;
 body:=replace(body,'''target'',target,''mode'',''pot''','''target'',target,''pocket'',pk-1,''mode'',''pot''');EXECUTE body;
 SELECT pg_get_functiondef('public.ct_pool_command(uuid,text,jsonb)'::regprocedure) INTO body;
 body:=replace(body,'DECLARE u uuid:=auth.uid();','DECLARE called_pocket integer;actual_pocket integer;u uuid:=auth.uid();');
 body:=replace(body,'balls,ai_difficulty) VALUES','balls,ai_difficulty,rules_version) VALUES');
 body:=replace(body,'public.ct_pool_rack(),difficulty) RETURNING','public.ct_pool_rack(),difficulty,CASE WHEN p_values->>''rules''=''club-v2'' THEN ''club-v2'' ELSE ''house-v1'' END) RETURNING');
 body:=replace(body,'phys:=public.ct_pool_physics_spin(m.balls,ang,power,spin_x,spin_y);',
 $patch$IF m.rules_version='club-v2' AND remaining=0 THEN
 called_pocket:=CASE WHEN p_action='ai' THEN coalesce((ai_plan->>'pocket')::integer,0) ELSE (p_values->>'called_pocket')::integer END;
 IF called_pocket IS NULL OR called_pocket NOT BETWEEN 0 AND 5 THEN RAISE EXCEPTION 'Choisissez la poche de la bille noire avant de tirer';END IF;
 END IF;
 phys:=public.ct_pool_physics_spin(m.balls,ang,power,spin_x,spin_y);$patch$);
 body:=replace(body,'IF phys->''potted'' @> ''[8]'' THEN',
 $patch$IF m.rules_version='club-v2' AND m.shots=0 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(phys->'potted') a(v) WHERE a.v::text::integer<>0) AND jsonb_array_length(phys->'rail_balls')<4 THEN foul:=true;foul_reason:='illegal_break';END IF;
 IF m.rules_version='club-v2' AND phys->'potted' @> '[8]' AND m.shots>0 THEN
 SELECT (e->>'pocket')::integer INTO actual_pocket FROM jsonb_array_elements(phys->'events') e WHERE e->>'kind'='pocket' AND(e->>'ball')::integer=8 LIMIT 1;
 IF called_pocket IS DISTINCT FROM actual_pocket THEN foul:=true;foul_reason:='wrong_pocket';END IF;
 END IF;
 IF phys->'potted' @> '[8]' THEN$patch$);
 body:=replace(body,'IF NOT foul AND own_group=0 THEN','IF NOT foul AND own_group=0 AND(m.rules_version=''house-v1'' OR m.shots>0) THEN');
 body:=replace(body,'keep_turn:=NOT foul AND EXISTS(', 'keep_turn:=NOT foul AND EXISTS(');
 body:=replace(body,'ELSE false END);','ELSE m.rules_version=''club-v2'' AND m.shots=0 AND(a.n::text)::integer<>0 END);');
 body:=replace(body,'''foul_reason'',foul_reason,','''called_pocket'',called_pocket,''foul_reason'',foul_reason,');
 -- Respot the eight on a clear position along the foot spot line, including at break scratches.
 body:=replace(body,$old$phys:=jsonb_set(phys,ARRAY['balls',idx::text],jsonb_build_object('n',8,'x',700,'y',250,'out',false));$old$,
 $new$FOR pk IN 0..25 LOOP px:=700+CASE WHEN pk%2=0 THEN pk/2 ELSE -(pk+1)/2 END*23;EXIT WHEN px BETWEEN 25 AND 975 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(phys->'balls') b WHERE(b->>'n')::integer<>8 AND NOT(b->>'out')::boolean AND((b->>'x')::float8-px)^2+((b->>'y')::float8-250)^2<23^2);END LOOP;
 phys:=jsonb_set(phys,ARRAY['balls',idx::text],jsonb_build_object('n',8,'x',px,'y',250,'out',false));$new$);
 EXECUTE body;
END $$;
COMMIT;

