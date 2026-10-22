BEGIN;
CREATE TABLE public.ct_rarities (
 id smallint PRIMARY KEY CHECK(id BETWEEN 1 AND 8),
 name text NOT NULL UNIQUE, color text NOT NULL, expected_count integer NOT NULL CHECK(expected_count>0)
);
INSERT INTO public.ct_rarities VALUES
 (1,'COMMUN','#a1a1aa',70),(2,'RARE','#60a5fa',60),(3,'ÉPIQUE','#b47aff',50),(4,'LÉGENDAIRE','#f5b85a',45),
 (5,'MYTHIQUE','#3ce0cc',35),(6,'RAINBOW','#f0abfc',25),(7,'XTREM','#ffca36',20),(8,'COSMIQUE','#b6a1ff',15);
CREATE TABLE public.ct_titles (
 id text PRIMARY KEY, name text NOT NULL UNIQUE, rarity smallint NOT NULL REFERENCES public.ct_rarities(id),
 description text NOT NULL, effect text NOT NULL, acquisition text NOT NULL,
 available boolean NOT NULL DEFAULT true, exclusive boolean NOT NULL DEFAULT false,
 shop_price bigint CHECK(shop_price>0), created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.ct_player_titles (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL REFERENCES public.ct_profiles(id) ON DELETE CASCADE,
 title_id text NOT NULL REFERENCES public.ct_titles(id), source text NOT NULL,
 acquired_at timestamptz NOT NULL DEFAULT now(), UNIQUE(user_id,id)
);
CREATE INDEX ct_inventory_owner ON public.ct_player_titles(user_id,acquired_at DESC);
CREATE TABLE public.ct_equipped_titles (
 user_id uuid PRIMARY KEY REFERENCES public.ct_profiles(id) ON DELETE CASCADE,
 player_title_id uuid NOT NULL,
 FOREIGN KEY(user_id,player_title_id) REFERENCES public.ct_player_titles(user_id,id) ON DELETE CASCADE
);
ALTER TABLE public.ct_rarities ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ct_titles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ct_player_titles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ct_equipped_titles ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ct_rarities,public.ct_titles,public.ct_player_titles,public.ct_equipped_titles FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.ct_rarities,public.ct_titles,public.ct_equipped_titles TO anon,authenticated;
GRANT SELECT ON public.ct_player_titles TO authenticated;
CREATE POLICY ct_rarities_read ON public.ct_rarities FOR SELECT USING(true);
CREATE POLICY ct_titles_read ON public.ct_titles FOR SELECT USING(true);
CREATE POLICY ct_inventory_read ON public.ct_player_titles FOR SELECT TO authenticated USING(user_id=auth.uid());
CREATE POLICY ct_equipped_read ON public.ct_equipped_titles FOR SELECT USING(true);
CREATE FUNCTION public.ct_equip_title(p_player_title_id uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid;
BEGIN
 v_uid:=public.ct_lock_wallet();
 IF p_player_title_id IS NULL THEN DELETE FROM public.ct_equipped_titles WHERE user_id=v_uid; RETURN; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.ct_player_titles WHERE id=p_player_title_id AND user_id=v_uid) THEN
  RAISE EXCEPTION 'Title not owned' USING ERRCODE='42501'; END IF;
 INSERT INTO public.ct_equipped_titles(user_id,player_title_id) VALUES(v_uid,p_player_title_id)
 ON CONFLICT(user_id) DO UPDATE SET player_title_id=EXCLUDED.player_title_id;
END $$;
-- Public projection deliberately excludes inventory rows and private identity details.
CREATE FUNCTION public.ct_public_profile(p_user_id uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('id',p.id,'username',p.username,'avatar',p.avatar,'created_at',p.created_at,
 'equipped_title',(SELECT to_jsonb(t) FROM public.ct_equipped_titles e JOIN public.ct_player_titles i ON i.id=e.player_title_id
 JOIN public.ct_titles t ON t.id=i.title_id WHERE e.user_id=p.id),
 'unique_titles',(SELECT count(DISTINCT title_id) FROM public.ct_player_titles WHERE user_id=p.id))
 FROM public.ct_profiles p WHERE p.id=p_user_id;
$$;
REVOKE ALL ON FUNCTION public.ct_equip_title(uuid),public.ct_public_profile(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_equip_title(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ct_public_profile(uuid) TO anon,authenticated;
COMMIT;
