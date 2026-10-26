BEGIN;
CREATE FUNCTION public.ct_admin_reason(p_reason text) RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$ SELECT CASE WHEN public.ct_is_owner() AND length(trim(coalesce(p_reason,'')))<8 THEN 'Action du propriétaire'||CASE WHEN length(trim(coalesce(p_reason,'')))>0 THEN ' : '||trim(p_reason) ELSE '' END ELSE p_reason END $$;
REVOKE ALL ON FUNCTION public.ct_admin_reason(text) FROM PUBLIC,anon,authenticated;
-- Normalize optional owner reasons inside each mutating RPC. Ordinary admins
-- retain their original validation. No client-supplied role flag is trusted.
DO $$ DECLARE f record;d text;BEGIN
 FOR f IN SELECT p.oid FROM pg_proc p JOIN pg_language l ON l.oid=p.prolang WHERE p.pronamespace='public'::regnamespace AND l.lanname='plpgsql' AND p.provolatile='v' AND 'p_reason'=ANY(p.proargnames) AND(p.proname LIKE 'ct_admin_%' OR p.proname LIKE 'ct_owner_%' OR p.proname IN('ct_account_job','ct_support_command')) LOOP
  SELECT pg_get_functiondef(f.oid) INTO d;d:=regexp_replace(d,'\mBEGIN\M','BEGIN p_reason:=public.ct_admin_reason(p_reason);','i');EXECUTE d;
 END LOOP;
END $$;
DO $$ DECLARE d text;BEGIN
 SELECT pg_get_functiondef('public.ct_admin_create_bots(uuid,jsonb,text)'::regprocedure) INTO d;
 d:=replace(d,'IF (SELECT count(*) FROM public.ct_bots)+v_count>(CASE WHEN v_compact THEN 50000 ELSE 5000 END) THEN RAISE EXCEPTION ''Limite de bots atteinte'';END IF;','IF NOT public.ct_is_owner() THEN IF (SELECT count(*) FROM public.ct_bots)+v_count>(CASE WHEN v_compact THEN 50000 ELSE 5000 END) THEN RAISE EXCEPTION ''Limite de bots atteinte'';END IF;END IF;');EXECUTE d;
 SELECT pg_get_functiondef('public.ct_admin_bots(text,integer)'::regprocedure) INTO d;
 d:=replace(d,'p_offset NOT BETWEEN 0 AND 50000','p_offset NOT BETWEEN 0 AND (CASE WHEN public.ct_is_owner() THEN 2147483647 ELSE 50000 END)');EXECUTE d;
END $$;
ALTER FUNCTION public.ct_admin_bot_storage() RENAME TO ct_admin_bot_storage_before_owner_jobs;
CREATE FUNCTION public.ct_admin_bot_storage() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$ SELECT public.ct_admin_bot_storage_before_owner_jobs()||jsonb_build_object('bot_limit',CASE WHEN public.ct_is_owner() THEN NULL ELSE 50000 END,'campaign_batch_limit',25) $$;
CREATE TABLE public.ct_owner_bot_jobs(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),owner_id uuid NOT NULL REFERENCES public.ct_profiles(id),total integer NOT NULL CHECK(total>0),completed integer NOT NULL DEFAULT 0 CHECK(completed>=0 AND completed<=total),status text NOT NULL DEFAULT 'ready' CHECK(status IN('ready','running','paused','completed','cancelled')),template jsonb NOT NULL,remaining_quotas integer[] NOT NULL CHECK(cardinality(remaining_quotas)=8 AND 0<=ALL(remaining_quotas)),name_roots text[] NOT NULL,next_run_at timestamptz NOT NULL DEFAULT now(),last_error text,created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.ct_owner_bot_jobs ENABLE ROW LEVEL SECURITY;REVOKE ALL ON public.ct_owner_bot_jobs FROM PUBLIC,anon,authenticated;
CREATE INDEX ct_owner_bot_jobs_recent ON public.ct_owner_bot_jobs(created_at DESC,id);
CREATE INDEX ct_owner_bot_jobs_next_run ON public.ct_owner_bot_jobs(next_run_at DESC);
CREATE FUNCTION public.ct_bot_job_json(p_job uuid) RETURNS jsonb LANGUAGE sql STABLE SET search_path='' AS $$ SELECT jsonb_build_object('id',id,'total',total,'completed',completed,'status',status,'last_error',last_error,'next_run_at',next_run_at,'created_at',created_at) FROM public.ct_owner_bot_jobs WHERE id=p_job $$;
CREATE FUNCTION public.ct_owner_bot_jobs() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$ BEGIN IF NOT public.ct_is_owner() THEN RAISE EXCEPTION 'Accès propriétaire requis';END IF;RETURN coalesce((SELECT jsonb_agg(public.ct_bot_job_json(x.id) ORDER BY created_at DESC,id) FROM(SELECT id,created_at FROM public.ct_owner_bot_jobs ORDER BY created_at DESC,id LIMIT 30)x),'[]');END $$;
CREATE FUNCTION public.ct_owner_bot_job_start(p_operation_id uuid,p_total integer,p_values jsonb,p_quotas integer[],p_name_roots text[]) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid:=auth.uid();q jsonb:=jsonb_build_object('kind','bot_job_start','total',p_total,'values',p_values,'quotas',p_quotas,'roots',p_name_roots);r jsonb;job uuid;BEGIN
 IF NOT public.ct_is_owner() THEN RAISE EXCEPTION 'Accès propriétaire requis';END IF;PERFORM pg_advisory_xact_lock(173,4);r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;
 IF p_total IS NULL OR p_total<1 OR cardinality(p_quotas) IS DISTINCT FROM 8 OR array_position(p_quotas,NULL) IS NOT NULL OR NOT(0<=ALL(p_quotas)) OR(SELECT sum(n::bigint) FROM unnest(p_quotas)n)<>p_total THEN RAISE EXCEPTION 'Quantité et répartition de campagne invalides';END IF;
 IF coalesce(cardinality(p_name_roots),0) NOT BETWEEN 1 AND 512 OR EXISTS(SELECT 1 FROM unnest(p_name_roots)n WHERE n IS NULL OR n!~'^[A-Za-z]{3,16}$') THEN RAISE EXCEPTION 'Racines de pseudos invalides';END IF;
 IF jsonb_typeof(p_values) IS DISTINCT FROM 'object' OR coalesce((p_values->>'titles_max')::integer,0) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Configuration hors limites';END IF;
 INSERT INTO public.ct_owner_bot_jobs(owner_id,total,template,remaining_quotas,name_roots) VALUES(u,p_total,p_values-'names'-'rarity_counts',p_quotas,p_name_roots) RETURNING id INTO job;
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(u,'owner_bot_job_start',job::text,'Action du propriétaire',jsonb_build_object('total',p_total));r:=public.ct_bot_job_json(job);INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;
END $$;
CREATE FUNCTION public.ct_owner_bot_job_control(p_operation_id uuid,p_job uuid,p_action text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid:=auth.uid();q jsonb:=jsonb_build_object('kind','bot_job_control','job',p_job,'action',p_action);r jsonb;b public.ct_owner_bot_jobs;BEGIN
 IF NOT public.ct_is_owner() THEN RAISE EXCEPTION 'Accès propriétaire requis';END IF;PERFORM pg_advisory_xact_lock(173,4);r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;SELECT * INTO b FROM public.ct_owner_bot_jobs WHERE id=p_job FOR UPDATE;
 IF b.id IS NULL OR p_action IS NULL OR p_action NOT IN('pause','resume','cancel') THEN RAISE EXCEPTION 'Campagne introuvable ou action invalide';END IF;
 IF b.status NOT IN('completed','cancelled') THEN UPDATE public.ct_owner_bot_jobs SET status=CASE p_action WHEN 'pause' THEN 'paused' WHEN 'resume' THEN 'ready' ELSE 'cancelled' END,last_error=CASE WHEN p_action='resume' THEN NULL ELSE last_error END,updated_at=now() WHERE id=p_job;END IF;
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(u,'owner_bot_job_control',p_job::text,'Action du propriétaire',jsonb_build_object('action',p_action));r:=public.ct_bot_job_json(p_job);INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;
END $$;
CREATE FUNCTION public.ct_owner_bot_job_step(p_operation_id uuid,p_job uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET statement_timeout='25s' AS $$
DECLARE u uuid:=auth.uid();q jsonb:=jsonb_build_object('kind','bot_job_step','job',p_job);r jsonb;b public.ct_owner_bot_jobs;v jsonb;names text[]:='{}';quotas integer[]:=ARRAY[0,0,0,0,0,0,0,0];remaining integer[];n integer;i integer;k integer;cap integer;tries integer;candidate text;root text;created jsonb;c public.ct_chest_types;next_allowed timestamptz;
BEGIN
 IF NOT public.ct_is_owner() THEN RAISE EXCEPTION 'Accès propriétaire requis';END IF;PERFORM pg_advisory_xact_lock(173,4);r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;SELECT * INTO b FROM public.ct_owner_bot_jobs WHERE id=p_job FOR UPDATE;
 IF b.id IS NULL THEN RAISE EXCEPTION 'Campagne introuvable ou action invalide';END IF;
 IF b.status NOT IN('ready','running') THEN RETURN jsonb_build_object('ok',false,'job',public.ct_bot_job_json(p_job));END IF;
 SELECT next_run_at INTO next_allowed FROM public.ct_owner_bot_jobs ORDER BY next_run_at DESC LIMIT 1;
 IF next_allowed>clock_timestamp() THEN RETURN jsonb_build_object('deferred',true,'retry_after_ms',greatest(1,ceil(extract(epoch FROM next_allowed-clock_timestamp())*1000)),'job',public.ct_bot_job_json(p_job));END IF;
 n:=least(25,greatest(1,1000/(b.template->>'titles_max')::integer),b.total-b.completed);remaining:=b.remaining_quotas;
 FOR i IN 1..n LOOP
  FOR k IN 0..7 LOOP cap:=1+((b.completed+i+k-1)%8);IF remaining[cap]>0 THEN remaining[cap]:=remaining[cap]-1;quotas[cap]:=quotas[cap]+1;EXIT;END IF;END LOOP;
  tries:=0;LOOP root:=b.name_roots[1+public.ct_random_below(cardinality(b.name_roots))];candidate:=root||CASE WHEN public.ct_random_below(3)=0 THEN '_' ELSE '' END||lpad(public.ct_random_below(1000000000)::text,6,'0');tries:=tries+1;
   EXIT WHEN NOT EXISTS(SELECT 1 FROM public.ct_profiles WHERE lower(username)=lower(candidate)) AND NOT(lower(candidate)=ANY(ARRAY(SELECT lower(x) FROM unnest(names)x)));
   IF tries>=50 THEN RAISE EXCEPTION 'Impossible de générer un pseudo libre';END IF;
  END LOOP;names:=array_append(names,candidate);
 END LOOP;
 SELECT * INTO c FROM public.ct_chest_types WHERE id=(b.template->>'chest_id')::smallint;
 v:=b.template||jsonb_build_object('compact',true,'names',to_jsonb(names),'rarity_counts',to_jsonb(quotas),'chest_price',c.price,'chest_version',c.version);
 IF coalesce(jsonb_array_length(v->'title_pool'),0)=0 THEN v:=v||jsonb_build_object('title_pool',(SELECT jsonb_agg(id ORDER BY id) FROM public.ct_titles WHERE available AND NOT exclusive AND rarity<=7));END IF;
 BEGIN
  created:=public.ct_admin_create_bots(md5('owner-bot-job:'||b.id::text||':'||b.completed::text)::uuid,v,'Campagne propriétaire · création progressive');
  UPDATE public.ct_owner_bot_jobs SET completed=completed+n,remaining_quotas=remaining,status=CASE WHEN completed+n=total THEN 'completed' ELSE 'running' END,next_run_at=clock_timestamp()+interval '1 second',last_error=NULL,updated_at=now() WHERE id=p_job;
  r:=jsonb_build_object('ok',true,'created',n,'job',public.ct_bot_job_json(p_job));
 EXCEPTION WHEN OTHERS THEN
  UPDATE public.ct_owner_bot_jobs SET status='paused',last_error=left(SQLERRM,1000),updated_at=now() WHERE id=p_job;r:=jsonb_build_object('ok',false,'error',left(SQLERRM,1000),'job',public.ct_bot_job_json(p_job));
 END;
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;
END $$;
REVOKE ALL ON FUNCTION public.ct_admin_bot_storage_before_owner_jobs(),public.ct_admin_bot_storage(),public.ct_bot_job_json(uuid),public.ct_owner_bot_jobs(),public.ct_owner_bot_job_start(uuid,integer,jsonb,integer[],text[]),public.ct_owner_bot_job_control(uuid,uuid,text),public.ct_owner_bot_job_step(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_admin_bot_storage(),public.ct_owner_bot_jobs(),public.ct_owner_bot_job_start(uuid,integer,jsonb,integer[],text[]),public.ct_owner_bot_job_control(uuid,uuid,text),public.ct_owner_bot_job_step(uuid,uuid) TO authenticated;
COMMIT;
