BEGIN;
ALTER TABLE public.ct_inbox_messages ADD COLUMN system_payload jsonb;
CREATE FUNCTION public.ct_notify_title_grant() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE t public.ct_titles;
BEGIN
 IF NEW.source<>'admin' AND NEW.source NOT LIKE 'distribution:%' THEN RETURN NEW;END IF;
 -- Frozen simulated accounts never read mail; avoid useless per-bot messages.
 IF NOT EXISTS(SELECT 1 FROM public.ct_profiles WHERE id=NEW.user_id AND NOT is_bot) THEN RETURN NEW;END IF;
 SELECT * INTO t FROM public.ct_titles WHERE id=NEW.title_id;
 INSERT INTO public.ct_inbox_messages(sender_name,recipient_id,subject,body,system_payload) VALUES('Casino & Titles',NEW.user_id,'Un titre vous a été offert',t.name,jsonb_build_object('kind','title_grant','title_id',t.id,'name',t.name,'rarity',t.rarity));RETURN NEW;
END $$;
CREATE TRIGGER ct_title_grant_inbox AFTER INSERT ON public.ct_player_titles FOR EACH ROW EXECUTE FUNCTION public.ct_notify_title_grant();
CREATE FUNCTION public.ct_notify_order() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE who uuid;role_name text;
BEGIN
 FOREACH who IN ARRAY ARRAY[NEW.buyer_id,NEW.seller_id] LOOP
  IF NOT EXISTS(SELECT 1 FROM public.ct_profiles WHERE id=who AND NOT is_bot) THEN CONTINUE;END IF;
  role_name:=CASE WHEN who=NEW.buyer_id THEN 'purchase' ELSE 'sale' END;
  INSERT INTO public.ct_inbox_messages(sender_name,recipient_id,subject,body,system_payload) VALUES('Casino & Titles',who,CASE WHEN role_name='purchase' THEN 'Achat confirmé : votre facture' ELSE 'Vente confirmée : votre facture' END,NEW.item_name,jsonb_build_object('kind','order','role',role_name,'item_kind',NEW.item_kind,'order_id',NEW.id,'order_number',NEW.order_number,'name',NEW.item_name,'rarity',NEW.rarity,'quantity',NEW.quantity,'amount',CASE WHEN role_name='purchase' THEN NEW.total ELSE NEW.seller_net END,'currency',NEW.currency));
 END LOOP;RETURN NEW;
END $$;
CREATE TRIGGER ct_order_inbox AFTER INSERT ON public.ct_orders FOR EACH ROW EXECUTE FUNCTION public.ct_notify_order();
REVOKE ALL ON FUNCTION public.ct_notify_title_grant(),public.ct_notify_order() FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.ct_inbox_list(p_before bigint DEFAULT NULL,p_unread boolean DEFAULT false) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid:=auth.uid();joined timestamptz;result jsonb;
BEGIN
 SELECT created_at INTO joined FROM public.ct_profiles WHERE id=u;
 IF joined IS NULL THEN RAISE EXCEPTION 'Profile required';END IF;
 IF p_unread IS NULL OR(p_before IS NOT NULL AND p_before<1) THEN RAISE EXCEPTION 'Filtre de messagerie invalide';END IF;
 WITH page AS MATERIALIZED(SELECT m.id,m.subject,m.system_payload,left(m.body,140) preview,m.sender_name,m.created_at,m.recipient_id IS NULL broadcast,r.read_at FROM public.ct_inbox_messages m LEFT JOIN public.ct_inbox_reads r ON r.message_id=m.id AND r.user_id=u
 WHERE(m.recipient_id=u OR(m.recipient_id IS NULL AND m.created_at>=joined)) AND(p_before IS NULL OR m.id<p_before) AND(NOT p_unread OR r.read_at IS NULL) ORDER BY m.id DESC LIMIT 21)
 SELECT jsonb_build_object('messages',coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY id DESC) FROM(SELECT * FROM page ORDER BY id DESC LIMIT 20)x),'[]'::jsonb),'has_more',(SELECT count(*)>20 FROM page)) INTO result;
 RETURN result||public.ct_inbox_summary();
END $$;
CREATE OR REPLACE FUNCTION public.ct_inbox_open(p_message bigint,p_admin boolean DEFAULT false) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
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
 RETURN jsonb_build_object('system_payload',m.system_payload,'id',m.id,'subject',m.subject,'body',m.body,'sender_name',m.sender_name,'created_at',m.created_at,'broadcast',m.recipient_id IS NULL,'read_at',opened);
END $$;
CREATE OR REPLACE FUNCTION public.ct_admin_inbox_sent(p_before bigint DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required';END IF;
 IF p_before IS NOT NULL AND p_before<1 THEN RAISE EXCEPTION 'Filtre de messagerie invalide';END IF;
 RETURN coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY id DESC) FROM(SELECT m.id,m.subject,m.system_payload,left(m.body,140) preview,m.sender_name,m.created_at,m.recipient_id IS NULL broadcast,p.username recipient FROM public.ct_inbox_messages m LEFT JOIN public.ct_profiles p ON p.id=m.recipient_id WHERE p_before IS NULL OR m.id<p_before ORDER BY m.id DESC LIMIT 20)x),'[]'::jsonb);
END $$;
COMMIT;
