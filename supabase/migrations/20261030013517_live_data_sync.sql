-- Private invalidation signals; never broadcast rows, balances, messages or identifiers.
CREATE FUNCTION public.ct_live_notify(p_topic text,p_scope text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE marker text:='ct.live_'||md5(p_topic||':'||p_scope);
BEGIN
 IF pg_catalog.to_regprocedure('realtime.send(jsonb,text,text,boolean)') IS NULL THEN RETURN; END IF;
 IF current_setting(marker,true)='sent' THEN RETURN; END IF;
 PERFORM set_config(marker,'sent',true);
 PERFORM realtime.send(jsonb_build_object('scope',p_scope),'changed',p_topic,true);
EXCEPTION WHEN OTHERS THEN
 -- Realtime is auxiliary: a transient notification outage must never reject a purchase.
 RAISE WARNING 'Live notification unavailable';
END $$;
REVOKE ALL ON FUNCTION public.ct_live_notify(text,text) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.ct_live_row_changed() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE row_data jsonb;old_data jsonb;target text;col text;ticket_owner uuid;
BEGIN
 IF TG_OP='UPDATE' AND NEW IS NOT DISTINCT FROM OLD THEN RETURN NULL; END IF;
 IF TG_OP<>'DELETE' THEN row_data:=to_jsonb(NEW); END IF;
 IF TG_OP<>'INSERT' THEN old_data:=to_jsonb(OLD); END IF;
 FOR i IN 1..TG_NARGS-1 LOOP
  col:=TG_ARGV[i];
  IF col='ticket_owner' THEN
   SELECT user_id INTO ticket_owner FROM public.ct_support_tickets WHERE id=(coalesce(row_data,old_data)->>'ticket_id')::bigint;
  ELSE
   FOR target IN SELECT DISTINCT value FROM (VALUES(row_data->>col),(old_data->>col)) v(value) WHERE value IS NOT NULL LOOP
    PERFORM public.ct_live_notify('ct:live:user:'||target,TG_ARGV[0]);
   END LOOP;
  END IF;
 END LOOP;
 IF ticket_owner IS NOT NULL THEN PERFORM public.ct_live_notify('ct:live:user:'||ticket_owner::text,'support'); END IF;
 IF TG_TABLE_NAME IN ('ct_profiles','ct_wallets','ct_player_titles','ct_equipped_titles','ct_sealed_chests','ct_preferences') THEN
  PERFORM public.ct_live_notify('ct:live:global','community');
 END IF;
 PERFORM public.ct_live_notify('ct:live:admin','admin');
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.ct_live_row_changed() FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.ct_live_global_changed() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE changed boolean;
BEGIN
 IF TG_LEVEL='STATEMENT' THEN
  EXECUTE 'SELECT EXISTS(SELECT 1 FROM ct_live_changed)' INTO changed;
  IF NOT changed THEN RETURN NULL; END IF;
 END IF;
 IF TG_ARGV[0]<>'admin' THEN PERFORM public.ct_live_notify('ct:live:global',TG_ARGV[0]); END IF;
 PERFORM public.ct_live_notify('ct:live:admin','admin');
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.ct_live_global_changed() FROM PUBLIC,anon,authenticated;

DO $$ DECLARE t text;op text;scope text; BEGIN
 FOREACH t IN ARRAY ARRAY['ct_wallets','ct_diamond_wallets','ct_player_titles','ct_equipped_titles','ct_sealed_chests','ct_demo_cards','ct_card_usage_resets','ct_pending_chest_rewards','ct_admins','ct_owners','ct_suspensions','ct_player_edits','ct_preferences','ct_player_achievements','ct_quest_claims','ct_event_claims','ct_clickers','ct_daily_rewards','ct_free_gifts','ct_promo_claims','ct_circle_applications','ct_circle_claims','ct_inbox_reads'] LOOP
  IF to_regclass('public.'||t) IS NULL THEN CONTINUE; END IF;
  EXECUTE format('CREATE TRIGGER ct_live_account AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.ct_live_row_changed(''account'',''user_id'')',t);
 END LOOP;
 CREATE TRIGGER ct_live_profile AFTER INSERT OR UPDATE OR DELETE ON public.ct_profiles FOR EACH ROW EXECUTE FUNCTION public.ct_live_row_changed('account','id');
 CREATE TRIGGER ct_live_inbox AFTER INSERT OR UPDATE OR DELETE ON public.ct_inbox_messages FOR EACH ROW EXECUTE FUNCTION public.ct_live_row_changed('account','recipient_id');
 CREATE TRIGGER ct_live_orders AFTER INSERT OR UPDATE OR DELETE ON public.ct_orders FOR EACH ROW EXECUTE FUNCTION public.ct_live_row_changed('account','buyer_id','seller_id');
 CREATE TRIGGER ct_live_trade AFTER INSERT OR UPDATE OR DELETE ON public.ct_direct_trades FOR EACH ROW EXECUTE FUNCTION public.ct_live_row_changed('account','a','b');
 CREATE TRIGGER ct_live_ticket AFTER INSERT OR UPDATE OR DELETE ON public.ct_support_tickets FOR EACH ROW EXECUTE FUNCTION public.ct_live_row_changed('support','user_id');
 CREATE TRIGGER ct_live_reply AFTER INSERT OR UPDATE OR DELETE ON public.ct_support_messages FOR EACH ROW EXECUTE FUNCTION public.ct_live_row_changed('support','ticket_owner');
 FOR t,scope IN SELECT key,value FROM jsonb_each_text('{
 "ct_titles":"catalog","ct_rarities":"catalog","ct_chest_types":"catalog","ct_chest_offers":"catalog","ct_quests":"catalog","ct_events":"catalog","ct_achievements":"catalog","ct_blackjack_rules":"catalog","ct_game_controls":"catalog","ct_demo_card_tiers":"catalog","ct_market_settings":"catalog","ct_market_finance":"catalog",
 "ct_market_listings":"market","ct_credit_offers":"market","ct_wholesale_offers":"market","ct_pm_listings":"market","ct_pm_reviews":"market","ct_seller_demo_reviews":"market","ct_market_promotions":"market",
 "ct_bot_batches":"community","ct_bot_summaries":"community","ct_title_distributions":"community","ct_market_news":"news",
 "ct_promos":"admin","ct_code_history":"admin","ct_admin_audit_logs":"admin","ct_owner_bot_jobs":"admin","ct_circle_codes":"admin"
 }'::jsonb) LOOP
  IF to_regclass('public.'||t) IS NULL THEN CONTINUE; END IF;
  FOREACH op IN ARRAY ARRAY['INSERT','UPDATE','DELETE'] LOOP
   EXECUTE format('CREATE TRIGGER %I AFTER %s ON public.%I REFERENCING %s TABLE AS ct_live_changed FOR EACH STATEMENT EXECUTE FUNCTION public.ct_live_global_changed(%L)','ct_live_'||lower(op),op,t,CASE WHEN op='DELETE' THEN 'OLD' ELSE 'NEW' END,scope);
  END LOOP;
 END LOOP;
 -- Broadcast inbox messages (recipient NULL) must reach every signed-in player.
 CREATE TRIGGER ct_live_broadcast_letter_insert AFTER INSERT ON public.ct_inbox_messages FOR EACH ROW WHEN (NEW.recipient_id IS NULL) EXECUTE FUNCTION public.ct_live_global_changed('news');
 CREATE TRIGGER ct_live_broadcast_letter_update AFTER UPDATE ON public.ct_inbox_messages FOR EACH ROW WHEN (NEW.recipient_id IS NULL OR OLD.recipient_id IS NULL) EXECUTE FUNCTION public.ct_live_global_changed('news');
 CREATE TRIGGER ct_live_broadcast_letter_delete AFTER DELETE ON public.ct_inbox_messages FOR EACH ROW WHEN (OLD.recipient_id IS NULL) EXECUTE FUNCTION public.ct_live_global_changed('news');
END $$;

-- Do not grant INSERT: clients cannot publish private invalidation signals.
DO $$ BEGIN
 IF to_regclass('realtime.messages') IS NOT NULL THEN
  EXECUTE $policy$ CREATE POLICY ct_live_read ON realtime.messages FOR SELECT TO authenticated USING (
   extension='broadcast' AND topic=realtime.topic() AND (
    realtime.topic()='ct:live:global'
    OR realtime.topic()='ct:live:user:'||(SELECT auth.uid())::text
    OR (realtime.topic()='ct:live:admin' AND (SELECT public.ct_is_admin()))
   )
  ) $policy$;
 END IF;
END $$;
