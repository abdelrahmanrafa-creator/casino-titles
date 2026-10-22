import {readFile,writeFile} from 'node:fs/promises';
const original=await readFile(new URL('../supabase/migrations/20261022061000_titles_blackjack.sql',import.meta.url),'utf8');
let functions=['ct_blackjack_view','ct_finish_blackjack','ct_blackjack_start','ct_blackjack_action'].map(name=>{
 const block=original.match(new RegExp(`CREATE FUNCTION public\\.${name}\\([\\s\\S]*?\\$\\$;`));
 if(!block)throw Error(`Missing ${name}`);return block[0].replace('CREATE FUNCTION','CREATE OR REPLACE FUNCTION');
}).join('\n');
const substitutions=[
 ["'hands',r.state->'hands','active_hand'","'rules',r.state->'rules','hands',r.state->'hands','active_hand'"],
 ['WHILE public.ct_card_total(v_dealer)<17 LOOP',"WHILE public.ct_card_total(v_dealer)<17 OR (public.ct_card_total(v_dealer)=17 AND coalesce((r.state->'rules'->>'dealer_hits_soft17')::boolean,false) AND public.ct_soft_hand(v_dealer)) LOOP"],
 ['WHEN v_natural THEN v_bet*5/2',"WHEN v_natural THEN v_bet+v_bet*coalesce((r.state->'rules'->>'natural_numerator')::integer,3)/coalesce((r.state->'rules'->>'natural_denominator')::integer,2)"],
 ["'dealer',v_dealer,'deck',v_deck[5:],'active_hand',0)","'dealer',v_dealer,'deck',v_deck[5:],'active_hand',0,'rules',(SELECT to_jsonb(c) FROM public.ct_blackjack_rules c WHERE id))"],
 ['jsonb_array_length(v_hands)>=4',"jsonb_array_length(v_hands)>=coalesce((r.state->'rules'->>'max_hands')::integer,4)"],
 ["IF cardinality(v_cards)<>2 THEN RAISE EXCEPTION 'Double requires two cards';END IF;", "IF cardinality(v_cards)<>2 THEN RAISE EXCEPTION 'Double requires two cards';END IF;\n   IF (v_hand->>'split')::boolean AND NOT coalesce((r.state->'rules'->>'double_after_split')::boolean,true) THEN RAISE EXCEPTION 'Double after split disabled';END IF;"]
];
for(const [before,after] of substitutions){if(!functions.includes(before))throw Error(`Missing rule insertion: ${before}`);functions=functions.replace(before,after);}
const prefix=`-- Generated from the versioned blackjack engine by scripts/blackjack-rules.mjs.\nBEGIN;
CREATE TABLE public.ct_blackjack_rules(id boolean PRIMARY KEY DEFAULT true CHECK(id),dealer_hits_soft17 boolean NOT NULL DEFAULT false,natural_numerator integer NOT NULL DEFAULT 3,natural_denominator integer NOT NULL DEFAULT 2,max_hands integer NOT NULL DEFAULT 4 CHECK(max_hands BETWEEN 2 AND 4),double_after_split boolean NOT NULL DEFAULT true,CHECK((natural_numerator=3 AND natural_denominator=2) OR (natural_numerator=6 AND natural_denominator=5)));
INSERT INTO public.ct_blackjack_rules(id) VALUES(true);
ALTER TABLE public.ct_blackjack_rules ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ct_blackjack_rules FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.ct_blackjack_rules TO anon,authenticated;
CREATE POLICY ct_blackjack_rules_read ON public.ct_blackjack_rules FOR SELECT USING(true);
CREATE FUNCTION public.ct_soft_hand(p_cards integer[]) RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path='' AS $$
 SELECT public.ct_card_total(p_cards)=(SELECT coalesce(sum(least(c%13+1,10)),0)+10 FROM unnest(p_cards) c) AND EXISTS(SELECT 1 FROM unnest(p_cards)c WHERE c%13=0);
$$;
REVOKE ALL ON FUNCTION public.ct_soft_hand(integer[]) FROM PUBLIC,anon,authenticated;
`;
const suffix=`
CREATE FUNCTION public.ct_admin_blackjack_rules(p_operation_id uuid,p_rules jsonb,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_uid uuid:=auth.uid();v_request jsonb:=jsonb_build_object('kind','blackjack_rules','rules',p_rules,'reason',p_reason);v_result jsonb;
BEGIN
 IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(v_uid::text||p_operation_id::text,93));v_result:=public.ct_replay(v_uid,p_operation_id,v_request);IF v_result IS NOT NULL THEN RETURN v_result;END IF;
 IF p_reason IS NULL OR length(trim(p_reason))<8 THEN RAISE EXCEPTION 'Justification required';END IF;
 UPDATE public.ct_blackjack_rules SET dealer_hits_soft17=(p_rules->>'dealer_hits_soft17')::boolean,natural_numerator=(p_rules->>'natural_numerator')::integer,natural_denominator=(p_rules->>'natural_denominator')::integer,max_hands=(p_rules->>'max_hands')::integer,double_after_split=(p_rules->>'double_after_split')::boolean WHERE id;
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(v_uid,'blackjack_rules','blackjack',p_reason,p_rules);
 v_result:='{"ok":true}'::jsonb;INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(v_uid,p_operation_id,v_request,v_result);RETURN v_result;
END $$;
REVOKE ALL ON FUNCTION public.ct_admin_blackjack_rules(uuid,jsonb,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_admin_blackjack_rules(uuid,jsonb,text) TO authenticated;
COMMIT;\n`;
await writeFile(new URL('../supabase/migrations/20261022100000_titles_blackjack_rules.sql',import.meta.url),prefix+functions+suffix);
console.log('Versioned blackjack rule migration generated.');
