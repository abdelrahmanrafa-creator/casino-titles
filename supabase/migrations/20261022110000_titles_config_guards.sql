BEGIN;
ALTER TABLE public.ct_chest_types ADD COLUMN version bigint NOT NULL DEFAULT 0;
CREATE FUNCTION public.ct_chest_version() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
BEGIN NEW.version:=OLD.version+1;RETURN NEW;END $$;
CREATE TRIGGER ct_chest_config_version BEFORE UPDATE ON public.ct_chest_types FOR EACH ROW EXECUTE FUNCTION public.ct_chest_version();
REVOKE ALL ON FUNCTION public.ct_chest_version() FROM PUBLIC,anon,authenticated;
ALTER FUNCTION public.ct_open_chest(uuid,smallint) RENAME TO ct_open_chest_v1;
REVOKE ALL ON FUNCTION public.ct_open_chest_v1(uuid,smallint) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_open_chest(p_operation_id uuid,p_chest_id smallint,p_expected_version bigint) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid;v_result jsonb;v_version bigint;
BEGIN
 v_uid:=public.ct_lock_wallet();v_result:=public.ct_replay(v_uid,p_operation_id,jsonb_build_object('kind','chest','chest_id',p_chest_id));
 IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 SELECT version INTO v_version FROM public.ct_chest_types WHERE id=p_chest_id FOR SHARE;
 IF p_expected_version IS NULL OR v_version IS DISTINCT FROM p_expected_version THEN RAISE EXCEPTION 'Chest configuration changed. Refresh the probabilities before opening.';END IF;
 RETURN public.ct_open_chest_v1(p_operation_id,p_chest_id);
END $$;
ALTER FUNCTION public.ct_buy_title(uuid,text) RENAME TO ct_buy_title_v1;
REVOKE ALL ON FUNCTION public.ct_buy_title_v1(uuid,text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_buy_title(p_operation_id uuid,p_title_id text,p_expected_price bigint) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid;v_result jsonb;v_price bigint;
BEGIN
 v_uid:=public.ct_lock_wallet();v_result:=public.ct_replay(v_uid,p_operation_id,jsonb_build_object('kind','buy_title','title_id',p_title_id));
 IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 SELECT shop_price INTO v_price FROM public.ct_titles WHERE id=p_title_id FOR SHARE;
 IF p_expected_price IS NULL OR v_price IS DISTINCT FROM p_expected_price THEN RAISE EXCEPTION 'Shop price changed. Refresh before purchasing.';END IF;
 RETURN public.ct_buy_title_v1(p_operation_id,p_title_id);
END $$;
ALTER FUNCTION public.ct_blackjack_start(uuid,bigint) RENAME TO ct_blackjack_start_v1;
REVOKE ALL ON FUNCTION public.ct_blackjack_start_v1(uuid,bigint) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.ct_blackjack_start(p_operation_id uuid,p_bet bigint,p_expected_rules jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid;v_result jsonb;v_rules jsonb;
BEGIN
 v_uid:=public.ct_lock_wallet();v_result:=public.ct_replay(v_uid,p_operation_id,jsonb_build_object('kind','blackjack_start','bet',p_bet));
 IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 SELECT to_jsonb(r)-'id' INTO v_rules FROM public.ct_blackjack_rules r WHERE id FOR SHARE;
 IF p_expected_rules IS DISTINCT FROM v_rules THEN RAISE EXCEPTION 'Blackjack rules changed. Refresh before starting.';END IF;
 RETURN public.ct_blackjack_start_v1(p_operation_id,p_bet);
END $$;
REVOKE ALL ON FUNCTION public.ct_open_chest(uuid,smallint,bigint),public.ct_buy_title(uuid,text,bigint),public.ct_blackjack_start(uuid,bigint,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_open_chest(uuid,smallint,bigint),public.ct_buy_title(uuid,text,bigint),public.ct_blackjack_start(uuid,bigint,jsonb) TO authenticated;
COMMIT;
