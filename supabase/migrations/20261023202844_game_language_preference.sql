BEGIN;
ALTER TABLE public.ct_preferences ADD COLUMN language text NOT NULL DEFAULT 'fr' CHECK(language IN('fr','en'));
CREATE FUNCTION public.ct_language() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$BEGIN IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501';END IF;RETURN jsonb_build_object('language',coalesce((SELECT language FROM public.ct_preferences WHERE user_id=auth.uid()),'fr'));END $$;
CREATE FUNCTION public.ct_set_language(p_language text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$BEGIN IF auth.uid() IS NULL OR NOT EXISTS(SELECT 1 FROM public.ct_profiles WHERE id=auth.uid()) THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501';END IF;IF p_language IS NULL OR p_language NOT IN('fr','en') THEN RAISE EXCEPTION 'Choose French or English';END IF;INSERT INTO public.ct_preferences(user_id,language) VALUES(auth.uid(),p_language) ON CONFLICT(user_id) DO UPDATE SET language=EXCLUDED.language,updated_at=now();END $$;
REVOKE ALL ON FUNCTION public.ct_language(),public.ct_set_language(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_language(),public.ct_set_language(text) TO authenticated;
COMMIT;
