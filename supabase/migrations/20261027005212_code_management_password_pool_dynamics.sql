BEGIN;
ALTER TABLE public.ct_promos ADD COLUMN id uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE;
CREATE TABLE public.ct_code_history(code text PRIMARY KEY,promo_id uuid NOT NULL,created_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.ct_code_history ENABLE ROW LEVEL SECURITY;REVOKE ALL ON public.ct_code_history FROM PUBLIC,anon,authenticated;
INSERT INTO public.ct_code_history(code,promo_id) SELECT code,id FROM public.ct_promos;
CREATE FUNCTION public.ct_reserve_code() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$ BEGIN
 IF TG_OP='INSERT' AND EXISTS(SELECT 1 FROM public.ct_promos WHERE code=NEW.code) THEN SELECT id INTO NEW.id FROM public.ct_promos WHERE code=NEW.code;END IF;
 INSERT INTO public.ct_code_history(code,promo_id) VALUES(NEW.code,NEW.id) ON CONFLICT DO NOTHING;
 IF (SELECT promo_id FROM public.ct_code_history WHERE code=NEW.code)<>NEW.id THEN RAISE EXCEPTION 'Ce code a déjà été attribué';END IF;RETURN NEW;END $$;
CREATE TRIGGER ct_reserve_code BEFORE INSERT OR UPDATE OF code ON public.ct_promos FOR EACH ROW EXECUTE FUNCTION public.ct_reserve_code();
ALTER TABLE public.ct_promo_claims DROP CONSTRAINT ct_promo_claims_code_fkey;
ALTER TABLE public.ct_promo_claims ADD CONSTRAINT ct_promo_claims_code_fkey FOREIGN KEY(code) REFERENCES public.ct_promos(code) ON UPDATE CASCADE;
ALTER FUNCTION public.ct_admin_save_promo(uuid,jsonb,text) RENAME TO ct_admin_save_promo_before_management;
REVOKE ALL ON FUNCTION public.ct_admin_save_promo_before_management(uuid,jsonb,text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_admin_save_promo(p_operation_id uuid,p_values jsonb,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid:=auth.uid();q jsonb:=jsonb_build_object('kind','code_edit','values',p_values,'reason',p_reason);r jsonb;old_code text:=upper(trim(coalesce(p_values->>'original_code',p_values->>'code')));new_code text:=upper(trim(p_values->>'code'));p public.ct_promos;
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(173,3);r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;
 SELECT * INTO p FROM public.ct_promos WHERE code=old_code FOR UPDATE;
 IF old_code<>new_code THEN
  IF p.id IS NULL OR (p_values->>'version')::bigint IS DISTINCT FROM p.version THEN RAISE EXCEPTION 'Code modifié depuis son affichage';END IF;
  UPDATE public.ct_promos SET code=new_code WHERE id=p.id;
 END IF;
 r:=public.ct_admin_save_promo_before_management(md5('code-edit:'||p_operation_id)::uuid,p_values-'original_code',p_reason)||jsonb_build_object('code',new_code);
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;
END $$;
CREATE FUNCTION public.ct_admin_code_batch(p_operation_id uuid,p_count integer,p_values jsonb,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid:=auth.uid();q jsonb:=jsonb_build_object('kind','code_batch','count',p_count,'values',p_values,'reason',p_reason);r jsonb;codes jsonb:='[]';c text;i integer;j integer;digits text;attempts integer:=0;
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 IF p_count IS NULL OR p_count NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'Choisissez 1 à 500 codes par lot';END IF;
 PERFORM pg_advisory_xact_lock(173,3);r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;
 FOR i IN 1..p_count LOOP
  LOOP digits:='';FOR j IN 1..16 LOOP digits:=digits||public.ct_random_below(10)::text;END LOOP;c:=substr(digits,1,4)||'-'||substr(digits,5,4)||'-'||substr(digits,9,4)||'-'||substr(digits,13,4);attempts:=attempts+1;
   EXIT WHEN NOT EXISTS(SELECT 1 FROM public.ct_code_history WHERE code=c);IF attempts>p_count*100 THEN RAISE EXCEPTION 'Génération indisponible, réessayez';END IF;
  END LOOP;
  PERFORM public.ct_admin_save_promo(md5('code-batch:'||p_operation_id||':'||i)::uuid,(p_values-'original_code'-'version')||jsonb_build_object('code',c,'version',NULL),p_reason);codes:=codes||to_jsonb(c);
 END LOOP;r:=jsonb_build_object('ok',true,'codes',codes);INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;
END $$;
CREATE FUNCTION public.ct_admin_code_claims(p_code text,p_offset integer DEFAULT 0) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$ BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 RETURN coalesce((SELECT jsonb_agg(x ORDER BY created_at DESC,user_id) FROM(SELECT c.user_id,p.username,c.created_at FROM public.ct_promo_claims c JOIN public.ct_profiles p ON p.id=c.user_id WHERE c.code=upper(trim(p_code)) ORDER BY c.created_at DESC,c.user_id LIMIT 100 OFFSET greatest(0,least(coalesce(p_offset,0),10000000)))x),'[]');END $$;
REVOKE ALL ON FUNCTION public.ct_reserve_code(),public.ct_admin_save_promo(uuid,jsonb,text),public.ct_admin_code_batch(uuid,integer,jsonb,text),public.ct_admin_code_claims(text,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_admin_save_promo(uuid,jsonb,text),public.ct_admin_code_batch(uuid,integer,jsonb,text),public.ct_admin_code_claims(text,integer) TO authenticated;
ALTER TABLE public.ct_account_jobs DROP CONSTRAINT ct_account_jobs_action_check;
ALTER TABLE public.ct_account_jobs ADD CONSTRAINT ct_account_jobs_action_check CHECK(action IN('email','reset','password'));
DO $$ DECLARE d text;BEGIN
 SELECT pg_get_functiondef('public.ct_account_job(uuid,uuid,text,jsonb,text)'::regprocedure) INTO d;
 d:=replace(d,'p_action NOT IN(''email'',''reset'')','p_action NOT IN(''email'',''reset'',''password'')');
 EXECUTE d;
END $$;


-- Two integration substeps per frame: lower drag, resilient cushions and less tunnelling.
CREATE OR REPLACE FUNCTION public.ct_pool_physics_spin(p_balls jsonb,p_angle double precision,p_power double precision,p_spin_x double precision,p_spin_y double precision) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path='' AS $$
DECLARE x double precision[];y double precision[];vx double precision[]:=array_fill(0::double precision,ARRAY[16]);vy double precision[]:=vx;gone boolean[];nums integer[];i integer;j integer;k integer;step integer;dx double precision;dy double precision;dist double precision;imp double precision;overlap double precision;speed double precision;first_hit integer:=0;spin_x double precision:=p_spin_x;spin_y double precision:=p_spin_y;initial_speed double precision:=p_power*.18;wall_speed double precision;events jsonb:='[]';rail boolean:=false;potted integer[]:='{}';frames jsonb:='[]';frame jsonb;balls jsonb:='[]';pockets double precision[][]:=ARRAY[ARRAY[0,0],ARRAY[500,0],ARRAY[1000,0],ARRAY[0,500],ARRAY[500,500],ARRAY[1000,500]];
BEGIN
 IF p_spin_x IS NULL OR p_spin_y IS NULL OR NOT(p_spin_x BETWEEN -1 AND 1 AND p_spin_y BETWEEN -1 AND 1) OR p_spin_x*p_spin_x+p_spin_y*p_spin_y>1.00001 THEN RAISE EXCEPTION 'Effet de bille invalide';END IF;
 SELECT array_agg((v->>'x')::double precision ORDER BY ord),array_agg((v->>'y')::double precision ORDER BY ord),array_agg((v->>'out')::boolean ORDER BY ord),array_agg((v->>'n')::integer ORDER BY ord) INTO x,y,gone,nums FROM jsonb_array_elements(p_balls) WITH ORDINALITY a(v,ord);
 vx[1]:=cos(p_angle)*p_power*.18;vy[1]:=sin(p_angle)*p_power*.18;
 FOR step IN 1..1800 LOOP
  speed:=0;
  FOR i IN 1..16 LOOP
   IF gone[i] THEN CONTINUE;END IF;x[i]:=x[i]+vx[i]*.5;y[i]:=y[i]+vy[i]*.5;
   FOR k IN 1..6 LOOP IF (x[i]-pockets[k][1])^2+(y[i]-pockets[k][2])^2<24^2 THEN gone[i]:=true;vx[i]:=0;vy[i]:=0;potted:=array_append(potted,nums[i]);events:=events||jsonb_build_array(jsonb_build_object('kind','pocket','ball',nums[i],'step',step/2.0,'x',x[i],'y',y[i]));EXIT;END IF;END LOOP;
   IF gone[i] THEN CONTINUE;END IF;
   IF x[i]<11 OR x[i]>989 THEN x[i]:=CASE WHEN x[i]<11 THEN 22-x[i] ELSE 1978-x[i] END;vx[i]:=-vx[i]*.93;IF first_hit>0 THEN rail:=true;END IF;IF i=1 THEN vy[1]:=vy[1]+abs(vx[1])*spin_x*.22*CASE WHEN x[1]<500 THEN -1 ELSE 1 END;spin_x:=spin_x*.65;END IF;END IF;
   IF y[i]<11 OR y[i]>489 THEN y[i]:=CASE WHEN y[i]<11 THEN 22-y[i] ELSE 978-y[i] END;vy[i]:=-vy[i]*.93;IF first_hit>0 THEN rail:=true;END IF;IF i=1 THEN vx[1]:=vx[1]+abs(vy[1])*spin_x*.22*CASE WHEN y[1]<250 THEN 1 ELSE -1 END;spin_x:=spin_x*.65;END IF;END IF;
  END LOOP;
  FOR i IN 1..15 LOOP IF gone[i] THEN CONTINUE;END IF;
   FOR j IN i+1..16 LOOP IF gone[j] THEN CONTINUE;END IF;
    dx:=x[j]-x[i];dy:=y[j]-y[i];dist:=sqrt(dx*dx+dy*dy);
    IF dist<22 AND dist>.00001 THEN
     dx:=dx/dist;dy:=dy/dist;overlap:=(22-dist)/2;x[i]:=x[i]-dx*overlap;y[i]:=y[i]-dy*overlap;x[j]:=x[j]+dx*overlap;y[j]:=y[j]+dy*overlap;
     imp:=((vx[i]-vx[j])*dx+(vy[i]-vy[j])*dy)*.985;
     IF imp>0 THEN vx[i]:=vx[i]-imp*dx;vy[i]:=vy[i]-imp*dy;vx[j]:=vx[j]+imp*dx;vy[j]:=vy[j]+imp*dy;IF i=1 AND first_hit=0 THEN first_hit:=nums[j];
 -- Follow/draw is applied once at the first impact; spin fades while travelling.
 vx[1]:=vx[1]+cos(p_angle)*initial_speed*spin_y*.36;
 vy[1]:=vy[1]+sin(p_angle)*initial_speed*spin_y*.36;
 events:=events||jsonb_build_array(jsonb_build_object('kind','impact','ball',nums[j],'step',step/2.0,'x',x[1],'y',y[1]));spin_y:=0;END IF;END IF;
    END IF;
   END LOOP;
  END LOOP;
  spin_x:=spin_x*.997;spin_y:=spin_y*.997;
  FOR i IN 1..16 LOOP vx[i]:=vx[i]*.996;vy[i]:=vy[i]*.996;IF abs(vx[i])+abs(vy[i])<.025 THEN vx[i]:=0;vy[i]:=0;END IF;speed:=speed+abs(vx[i])+abs(vy[i]);END LOOP;
  IF step%16=0 OR speed=0 THEN SELECT jsonb_agg(jsonb_build_array(round(x[z]::numeric,2),round(y[z]::numeric,2),gone[z]) ORDER BY z) INTO frame FROM generate_series(1,16)z;frames:=frames||jsonb_build_array(frame);END IF;
  EXIT WHEN speed=0;
 END LOOP;
 FOR i IN 1..16 LOOP balls:=balls||jsonb_build_array(jsonb_build_object('n',nums[i],'x',x[i],'y',y[i],'out',gone[i]));END LOOP;
 RETURN jsonb_build_object('balls',balls,'frames',frames,'first',first_hit,'rail',rail,'potted',to_jsonb(potted),'events',events);
END $$;
CREATE OR REPLACE FUNCTION public.ct_pool_physics(p_balls jsonb,p_angle double precision,p_power double precision) RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path='' AS $$ SELECT public.ct_pool_physics_spin(p_balls,p_angle,p_power,0,0) $$;
COMMIT;
