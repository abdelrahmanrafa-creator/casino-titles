BEGIN;
-- Broadcasts are stored once; only opening a message creates a per-player receipt.
CREATE TABLE public.ct_inbox_messages(
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 sender_id uuid REFERENCES public.ct_profiles(id) ON DELETE SET NULL,
 sender_name text NOT NULL,
 recipient_id uuid REFERENCES public.ct_profiles(id) ON DELETE CASCADE,
 subject text NOT NULL CHECK(length(trim(subject)) BETWEEN 3 AND 120),
 body text NOT NULL CHECK(length(trim(body)) BETWEEN 1 AND 4000),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX ct_inbox_recipient ON public.ct_inbox_messages(recipient_id,id DESC);
CREATE INDEX ct_inbox_sender ON public.ct_inbox_messages(sender_id,id DESC);
CREATE TABLE public.ct_inbox_reads(
 user_id uuid NOT NULL REFERENCES public.ct_profiles(id) ON DELETE CASCADE,
 message_id bigint NOT NULL REFERENCES public.ct_inbox_messages(id) ON DELETE CASCADE,
 read_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(user_id,message_id)
);
CREATE INDEX ct_inbox_reads_message ON public.ct_inbox_reads(message_id);
ALTER TABLE public.ct_inbox_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ct_inbox_reads ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ct_inbox_messages,public.ct_inbox_reads FROM PUBLIC,anon,authenticated;
REVOKE ALL ON SEQUENCE public.ct_inbox_messages_id_seq FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.ct_inbox_summary() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid:=auth.uid();joined timestamptz;
BEGIN
 SELECT created_at INTO joined FROM public.ct_profiles WHERE id=u;
 IF joined IS NULL THEN RAISE EXCEPTION 'Profile required';END IF;
 RETURN jsonb_build_object('unread',(SELECT count(*) FROM public.ct_inbox_messages m WHERE (m.recipient_id=u OR(m.recipient_id IS NULL AND m.created_at>=joined)) AND NOT EXISTS(SELECT 1 FROM public.ct_inbox_reads r WHERE r.user_id=u AND r.message_id=m.id)));
END $$;
CREATE FUNCTION public.ct_inbox_list(p_before bigint DEFAULT NULL,p_unread boolean DEFAULT false) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid:=auth.uid();joined timestamptz;result jsonb;
BEGIN
 SELECT created_at INTO joined FROM public.ct_profiles WHERE id=u;
 IF joined IS NULL THEN RAISE EXCEPTION 'Profile required';END IF;
 IF p_unread IS NULL OR(p_before IS NOT NULL AND p_before<1) THEN RAISE EXCEPTION 'Filtre de messagerie invalide';END IF;
 WITH page AS MATERIALIZED(SELECT m.id,m.subject,left(m.body,140) preview,m.sender_name,m.created_at,m.recipient_id IS NULL broadcast,r.read_at FROM public.ct_inbox_messages m LEFT JOIN public.ct_inbox_reads r ON r.message_id=m.id AND r.user_id=u
 WHERE(m.recipient_id=u OR(m.recipient_id IS NULL AND m.created_at>=joined)) AND(p_before IS NULL OR m.id<p_before) AND(NOT p_unread OR r.read_at IS NULL) ORDER BY m.id DESC LIMIT 21)
 SELECT jsonb_build_object('messages',coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY id DESC) FROM(SELECT * FROM page ORDER BY id DESC LIMIT 20)x),'[]'::jsonb),'has_more',(SELECT count(*)>20 FROM page)) INTO result;
 RETURN result||public.ct_inbox_summary();
END $$;
CREATE FUNCTION public.ct_inbox_open(p_message bigint,p_admin boolean DEFAULT false) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid:=auth.uid();joined timestamptz;m public.ct_inbox_messages;opened timestamptz;
BEGIN
 SELECT created_at INTO joined FROM public.ct_profiles WHERE id=u;
 IF joined IS NULL THEN RAISE EXCEPTION 'Profile required';END IF;
 IF p_admin IS NULL THEN RAISE EXCEPTION 'Filtre de messagerie invalide';END IF;
 IF p_admin AND NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required';END IF;
 SELECT * INTO m FROM public.ct_inbox_messages WHERE id=p_message AND(p_admin OR recipient_id=u OR(recipient_id IS NULL AND created_at>=joined));
 IF m.id IS NULL THEN RAISE EXCEPTION 'Message introuvable';END IF;
 IF NOT p_admin THEN
  INSERT INTO public.ct_inbox_reads(user_id,message_id) VALUES(u,m.id) ON CONFLICT DO NOTHING;
  SELECT read_at INTO opened FROM public.ct_inbox_reads WHERE user_id=u AND message_id=m.id;
 END IF;
 RETURN jsonb_build_object('id',m.id,'subject',m.subject,'body',m.body,'sender_name',m.sender_name,'created_at',m.created_at,'broadcast',m.recipient_id IS NULL,'read_at',opened);
END $$;
CREATE FUNCTION public.ct_admin_inbox_recipients(p_search text) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required';END IF;
 IF length(trim(coalesce(p_search,''))) NOT BETWEEN 2 AND 24 THEN RETURN '[]'::jsonb;END IF;
 RETURN coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM(SELECT id,username FROM public.ct_profiles WHERE lower(username) LIKE replace(replace(replace(lower(trim(p_search)),'\','\\'),'%','\%'),'_','\_')||'%' ORDER BY lower(username) LIMIT 12)x),'[]'::jsonb);
END $$;
CREATE FUNCTION public.ct_admin_inbox_sent(p_before bigint DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required';END IF;
 IF p_before IS NOT NULL AND p_before<1 THEN RAISE EXCEPTION 'Filtre de messagerie invalide';END IF;
 RETURN coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY id DESC) FROM(SELECT m.id,m.subject,left(m.body,140) preview,m.sender_name,m.created_at,m.recipient_id IS NULL broadcast,p.username recipient FROM public.ct_inbox_messages m LEFT JOIN public.ct_profiles p ON p.id=m.recipient_id WHERE p_before IS NULL OR m.id<p_before ORDER BY m.id DESC LIMIT 20)x),'[]'::jsonb);
END $$;
CREATE FUNCTION public.ct_admin_inbox_send(p_operation_id uuid,p_recipient uuid,p_subject text,p_body text,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;request jsonb:=jsonb_build_object('kind','admin_inbox_send','recipient',p_recipient,'subject',p_subject,'body',p_body,'reason',p_reason);message_id bigint;sender text;
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required';END IF;
 u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,request);IF r IS NOT NULL THEN RETURN r;END IF;
 PERFORM public.ct_check_rate(u);
 IF length(trim(coalesce(p_reason,''))) NOT BETWEEN 8 AND 1000 THEN RAISE EXCEPTION 'Justification administrateur requise';END IF;
 IF length(trim(coalesce(p_subject,''))) NOT BETWEEN 3 AND 120 THEN RAISE EXCEPTION 'Sujet requis : 3 à 120 caractères';END IF;
 IF length(trim(coalesce(p_body,''))) NOT BETWEEN 1 AND 4000 THEN RAISE EXCEPTION 'Votre message doit contenir 1 à 4000 caractères';END IF;
 IF p_recipient IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.ct_profiles WHERE id=p_recipient) THEN RAISE EXCEPTION 'Destinataire introuvable';END IF;
 SELECT username INTO sender FROM public.ct_profiles WHERE id=u;
 INSERT INTO public.ct_inbox_messages(sender_id,sender_name,recipient_id,subject,body) VALUES(u,sender,p_recipient,trim(p_subject),trim(p_body)) RETURNING id INTO message_id;
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(u,'inbox_send',coalesce(p_recipient::text,'all'),p_reason,jsonb_build_object('message_id',message_id,'subject',trim(p_subject),'broadcast',p_recipient IS NULL));
 r:=jsonb_build_object('ok',true,'id',message_id,'broadcast',p_recipient IS NULL);
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,request,r);RETURN r;
END $$;
REVOKE ALL ON FUNCTION public.ct_inbox_summary(),public.ct_inbox_list(bigint,boolean),public.ct_inbox_open(bigint,boolean),public.ct_admin_inbox_recipients(text),public.ct_admin_inbox_sent(bigint),public.ct_admin_inbox_send(uuid,uuid,text,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_inbox_summary(),public.ct_inbox_list(bigint,boolean),public.ct_inbox_open(bigint,boolean),public.ct_admin_inbox_recipients(text),public.ct_admin_inbox_sent(bigint),public.ct_admin_inbox_send(uuid,uuid,text,text,text) TO authenticated;
COMMIT;
