BEGIN;
ALTER TABLE public.ct_titles ADD COLUMN event_key text;
ALTER TABLE public.ct_chest_types ADD COLUMN event_key text;
ALTER TABLE public.ct_sealed_chests ADD COLUMN edition_number bigint CHECK(edition_number>0),ADD COLUMN event_key text;
CREATE UNIQUE INDEX ct_chest_edition_unique ON public.ct_sealed_chests(chest_id,edition_number) WHERE edition_number IS NOT NULL;
CREATE TABLE public.ct_chest_edition_counters(chest_id smallint PRIMARY KEY REFERENCES public.ct_chest_types(id),last_number bigint NOT NULL CHECK(last_number>0));
ALTER TABLE public.ct_chest_edition_counters ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ct_chest_edition_counters FROM PUBLIC,anon,authenticated;
-- Every limited title is exclusive: standard pools cannot draw it.
INSERT INTO public.ct_titles(id,name,rarity,description,effect,acquisition,exclusive,event_key)
SELECT 'halloween-2026-'||lpad(n::text,2,'0'),name,rarity,'Une signature limitée née dans la nuit d’Halloween. Collection Halloween 2026.','halloween','Coffre Halloween · édition limitée 2026',true,'halloween-2026'
FROM(VALUES
 (1,'Apprenti citrouille',1),(2,'Cueilleur de bonbons',1),(3,'Petit fantôme',1),
 (4,'Gardien des lanternes',2),(5,'Chat de minuit',2),(6,'Marcheur de brume',2),
 (7,'Alchimiste des ombres',3),(8,'Danseur des spectres',3),(9,'Corbeau du crépuscule',3),(10,'Sorcier du cercle',3),
 (11,'Seigneur du manoir hanté',4),(12,'Reine des chauves-souris',4),(13,'Chevalier sans tête',4),(14,'Oracle de la lune rousse',4),
 (15,'Faucheur des âmes',5),(16,'Monarque des citrouilles',5),(17,'Gardien de la crypte',5),(18,'Enchanteur des malédictions',5),(19,'Duc des ténèbres',5),
 (20,'Spectre aux mille couleurs',6),(21,'Sorcière de l’aurore maudite',6),(22,'Phénix des flammes fantômes',6),
 (23,'Souverain de l’éclipse',7),(24,'Dévoreur de cauchemars',7),
 (25,'Éternité de la nuit cosmique',8)
)v(n,name,rarity);
-- Allocate an unused catalogue ID rather than assuming the administrator's IDs.
INSERT INTO public.ct_chest_types(id,name,price,weights,rarity,description,category,starts_at,ends_at,title_pool,allow_exclusive,event_key)
SELECT (coalesce(max(id),0)+1)::smallint,'Coffre Halloween',150000,ARRAY[1000,1000,2000,2000,2500,1000,400,100],5,'25 titres Halloween exclusifs. Un coffre numéroté à conserver, ouvrir ou échanger.','event','2026-10-26T00:00:00Z','2026-11-04T00:00:00Z',(SELECT array_agg(id ORDER BY id) FROM public.ct_titles WHERE event_key='halloween-2026'),true,'halloween-2026' FROM public.ct_chest_types;
-- Number all event editions atomically at issuance. Resale never changes a number.
WITH existing AS(SELECT s.id,row_number() OVER(PARTITION BY s.chest_id ORDER BY s.created_at,s.id) n FROM public.ct_sealed_chests s JOIN public.ct_chest_types c ON c.id=s.chest_id WHERE c.category='event') UPDATE public.ct_sealed_chests s SET edition_number=e.n FROM existing e WHERE e.id=s.id;
INSERT INTO public.ct_chest_edition_counters SELECT chest_id,max(edition_number) FROM public.ct_sealed_chests WHERE edition_number IS NOT NULL GROUP BY chest_id;
CREATE FUNCTION public.ct_chest_edition_assign() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE c public.ct_chest_types;i integer;
BEGIN
 IF TG_OP='UPDATE' THEN
  IF NEW.edition_number IS DISTINCT FROM OLD.edition_number OR NEW.event_key IS DISTINCT FROM OLD.event_key OR NEW.chest_id IS DISTINCT FROM OLD.chest_id THEN RAISE EXCEPTION 'La signature numérotée du coffre est immuable';END IF;RETURN NEW;
 END IF;
 SELECT * INTO c FROM public.ct_chest_types WHERE id=NEW.chest_id;
 NEW.event_key:=c.event_key;NEW.edition_number:=NULL;
 IF c.category='event' THEN
  INSERT INTO public.ct_chest_edition_counters(chest_id,last_number) VALUES(c.id,1) ON CONFLICT(chest_id) DO UPDATE SET last_number=public.ct_chest_edition_counters.last_number+1 RETURNING last_number INTO NEW.edition_number;
 END IF;
 -- Freeze the exact event pool for this copy, including after the event ends.
 SELECT coalesce(array_agg(t.id ORDER BY t.id),ARRAY[]::text[]) INTO NEW.title_ids FROM public.ct_titles t WHERE t.id=ANY(NEW.title_ids) AND(t.event_key IS NULL OR t.event_key=c.event_key) AND(c.event_key IS NULL OR t.event_key=c.event_key);
 FOR i IN 1..8 LOOP IF c.event_key IS NOT NULL AND NEW.weights[i]>0 AND NOT EXISTS(SELECT 1 FROM public.ct_titles WHERE id=ANY(NEW.title_ids) AND rarity=i) THEN RAISE EXCEPTION 'Catalogue du coffre incomplet';END IF;END LOOP;
 RETURN NEW;
END $$;
CREATE TRIGGER ct_chest_edition_assign BEFORE INSERT OR UPDATE ON public.ct_sealed_chests FOR EACH ROW EXECUTE FUNCTION public.ct_chest_edition_assign();
ALTER FUNCTION public.ct_sealed_inventory() RENAME TO ct_sealed_inventory_before_editions;
CREATE FUNCTION public.ct_sealed_inventory() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(x.item||jsonb_build_object('edition_number',s.edition_number,'event_key',s.event_key) ORDER BY x.n),'[]'::jsonb) FROM jsonb_array_elements(public.ct_sealed_inventory_before_editions()) WITH ORDINALITY x(item,n) JOIN public.ct_sealed_chests s ON s.id=(x.item->>'id')::uuid WHERE s.user_id=auth.uid();
$$;
ALTER FUNCTION public.ct_chest_passport(uuid,bigint) RENAME TO ct_chest_passport_before_editions;
CREATE FUNCTION public.ct_chest_passport(p_chest uuid,p_before bigint DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE r jsonb;BEGIN r:=public.ct_chest_passport_before_editions(p_chest,p_before);RETURN r||(SELECT jsonb_build_object('edition_number',edition_number,'event_key',event_key) FROM public.ct_sealed_chests WHERE id=p_chest);END $$;
REVOKE ALL ON FUNCTION public.ct_chest_edition_assign(),public.ct_sealed_inventory_before_editions(),public.ct_chest_passport_before_editions(uuid,bigint),public.ct_sealed_inventory(),public.ct_chest_passport(uuid,bigint) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_sealed_inventory(),public.ct_chest_passport(uuid,bigint) TO authenticated;
COMMIT;
