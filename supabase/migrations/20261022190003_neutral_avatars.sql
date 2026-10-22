BEGIN;
-- Remove the robot avatar from existing accounts, regardless of account type.
UPDATE public.ct_profiles SET avatar=replace(avatar,'🤖','🎲') WHERE position('🤖' IN avatar)>0;
CREATE FUNCTION public.ct_neutral_avatar() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
BEGIN NEW.avatar:=replace(NEW.avatar,'🤖','🎲');RETURN NEW;END $$;
REVOKE ALL ON FUNCTION public.ct_neutral_avatar() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER ct_neutral_avatar BEFORE INSERT OR UPDATE OF avatar ON public.ct_profiles FOR EACH ROW EXECUTE FUNCTION public.ct_neutral_avatar();
-- Old clients and default server values pass through the same normalization.
COMMIT;
