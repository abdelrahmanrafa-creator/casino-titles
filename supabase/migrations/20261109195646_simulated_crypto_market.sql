CREATE TABLE public.ct_crypto_settings(id boolean PRIMARY KEY DEFAULT true CHECK(id),version bigint NOT NULL DEFAULT 1,market_revision bigint NOT NULL DEFAULT 1,buy_enabled boolean NOT NULL DEFAULT true,sell_enabled boolean NOT NULL DEFAULT true,fee_bps integer NOT NULL DEFAULT 25 CHECK(fee_bps BETWEEN 0 AND 500),spread_bps integer NOT NULL DEFAULT 20 CHECK(spread_bps BETWEEN 0 AND 1000),max_trade bigint NOT NULL DEFAULT 10000000 CHECK(max_trade BETWEEN 10 AND 100000000),secret text NOT NULL DEFAULT(gen_random_uuid()::text||gen_random_uuid()::text));
INSERT INTO public.ct_crypto_settings(id) VALUES(true);
CREATE TABLE public.ct_crypto_assets(symbol text PRIMARY KEY CHECK(symbol ~ '^[A-Z0-9]{2,10}$'),name text NOT NULL,category text NOT NULL,color text NOT NULL,base_e6 bigint NOT NULL CHECK(base_e6 BETWEEN 10000 AND 1000000000000000),volatility numeric NOT NULL CHECK(volatility BETWEEN 0.01 AND 4),liquidity bigint NOT NULL CHECK(liquidity>0),total_atoms bigint NOT NULL CHECK(total_atoms>0),float_atoms bigint NOT NULL CHECK(float_atoms>=0 AND float_atoms<=total_atoms),buy_enabled boolean NOT NULL DEFAULT true,version bigint NOT NULL DEFAULT 1);
CREATE TABLE public.ct_crypto_positions(user_id uuid NOT NULL REFERENCES public.ct_profiles(id) ON DELETE CASCADE,symbol text NOT NULL REFERENCES public.ct_crypto_assets(symbol),atoms bigint NOT NULL DEFAULT 0 CHECK(atoms>=0),cost_basis bigint NOT NULL DEFAULT 0 CHECK(cost_basis>=0),realized bigint NOT NULL DEFAULT 0,PRIMARY KEY(user_id,symbol));
CREATE TABLE public.ct_crypto_trades(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,user_id uuid NOT NULL REFERENCES public.ct_profiles(id),operation_id uuid NOT NULL,symbol text NOT NULL REFERENCES public.ct_crypto_assets(symbol),side text NOT NULL CHECK(side IN('buy','sell')),atoms bigint NOT NULL CHECK(atoms>0),price_e6 bigint NOT NULL CHECK(price_e6>0),gross bigint NOT NULL,fee bigint NOT NULL,total bigint NOT NULL,realized bigint NOT NULL DEFAULT 0,created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(user_id,operation_id));
CREATE INDEX ct_crypto_trades_user ON public.ct_crypto_trades(user_id,id DESC);
CREATE TABLE public.ct_crypto_flows(symbol text NOT NULL REFERENCES public.ct_crypto_assets(symbol),bucket bigint NOT NULL,impact numeric NOT NULL,volume bigint NOT NULL DEFAULT 0,PRIMARY KEY(symbol,bucket));
CREATE INDEX ct_crypto_flows_cleanup ON public.ct_crypto_flows(bucket);
CREATE TABLE public.ct_crypto_public_cache(id boolean PRIMARY KEY DEFAULT true CHECK(id),bucket bigint,revision bigint,payload jsonb);
INSERT INTO public.ct_crypto_public_cache(id) VALUES(true);
CREATE TABLE public.ct_crypto_chart_cache(symbol text NOT NULL REFERENCES public.ct_crypto_assets(symbol),range_id text NOT NULL,bucket bigint NOT NULL,revision bigint NOT NULL,points jsonb NOT NULL,PRIMARY KEY(symbol,range_id));
DO $$ DECLARE t text;BEGIN FOREACH t IN ARRAY ARRAY['ct_crypto_settings','ct_crypto_assets','ct_crypto_positions','ct_crypto_trades','ct_crypto_flows','ct_crypto_public_cache','ct_crypto_chart_cache'] LOOP EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC,anon,authenticated',t);END LOOP;END $$;
-- Human-readable market references, entirely simulated in game credits.
INSERT INTO public.ct_crypto_assets(symbol,name,category,color,base_e6,volatility,liquidity,total_atoms,float_atoms) SELECT symbol,name,category,color,(base*1000000)::bigint,vol,liq,(supply*1000000)::bigint,(supply*1000000)::bigint FROM(VALUES
 ('BTC','Bitcoin','layer1','#f7931a',92000::numeric,0.8::numeric,50000000::bigint,21000000::numeric),('ETH','Ethereum','layer1','#9b8aff',3400,1,30000000,120000000),('SOL','Solana','layer1','#67e7bb',175,1.4,15000000,600000000),('BNB','BNB','layer1','#f3ba2f',590,1,18000000,150000000),('XRP','XRP','payments','#aec8e6',2.15,1.3,12000000,10000000000),('ADA','Cardano','layer1','#4b8dff',0.72,1.4,7000000,45000000000),('AVAX','Avalanche','layer1','#ed6c78',32,1.5,6000000,720000000),('DOT','Polkadot','layer1','#e566b0',5.8,1.3,5000000,1500000000),('LINK','Chainlink','defi','#7198ff',17.5,1.2,7000000,1000000000),('DOGE','Dogecoin','meme','#cbb85e',0.22,2.5,5000000,150000000000),('SUI','Sui','layer1','#73c7f7',3.2,1.8,5000000,10000000000),('TON','Toncoin','layer1','#4ea7e9',4.7,1.4,5000000,5000000000),('LTC','Litecoin','payments','#b2bdda',95,1.1,7000000,84000000),('BCH','Bitcoin Cash','payments','#56c98f',380,1.2,5000000,21000000),('ATOM','Cosmos','layer1','#a5acd1',6.4,1.4,4000000,400000000),('NEAR','NEAR Protocol','layer1','#e3deed',4.1,1.7,4000000,1200000000),('APT','Aptos','layer1','#8cd8d0',8.8,1.8,4000000,1100000000),('ARB','Arbitrum','layer2','#74b3ef',0.65,1.7,3000000,10000000000),('OP','Optimism','layer2','#ff7b81',1.6,1.7,3000000,4300000000),('POL','Polygon','layer2','#b68bf5',0.42,1.6,3500000,10000000000),('UNI','Uniswap','defi','#f985bb',9.5,1.5,3500000,1000000000),('AAVE','Aave','defi','#b590df',190,1.5,4000000,16000000),('MKR','Maker','defi','#61c7ad',1650,1.2,5000000,1000000),('INJ','Injective','defi','#71bef1',21,1.8,2500000,100000000),('RENDER','Render','ai','#e77585',6.2,1.9,3000000,540000000),('FET','Artificial Superintelligence','ai','#9a9adf',1.35,2,2500000,2700000000),('GRT','The Graph','ai','#a38de3',0.19,1.7,2500000,10000000000),('FIL','Filecoin','storage','#78b4ff',4.5,1.5,3000000,2000000000),('ICP','Internet Computer','storage','#dc85b8',9.6,1.5,3000000,530000000),('BONK','Bonk','meme','#eea969',0.035,3,1800000,100000000000),('USDC','USD Coin','stable','#6fa9ed',1,0.02,60000000,60000000000),('USDT','Tether','stable','#65c9a3',1,0.025,70000000,100000000000)
) a(symbol,name,category,color,base,vol,liq,supply);

CREATE FUNCTION public.ct_crypto_noise(p_key text) RETURNS numeric LANGUAGE sql STABLE SET search_path='' AS $$ SELECT ((('x'||substr(encode(sha256(convert_to(p_key||secret,'UTF8')),'hex'),1,12))::bit(48)::bigint)::numeric/281474976710655)*2-1 FROM public.ct_crypto_settings WHERE id $$;
CREATE FUNCTION public.ct_crypto_mark(p_symbol text,p_bucket bigint) RETURNS bigint LANGUAGE plpgsql STABLE SET search_path='' AS $$
DECLARE a public.ct_crypto_assets;phase numeric;d bigint:=floor(p_bucket::numeric/1440);h bigint:=floor(p_bucket::numeric/60);f numeric;move numeric;impact numeric:=0;last_flow record;
BEGIN SELECT * INTO a FROM public.ct_crypto_assets WHERE symbol=p_symbol;IF NOT FOUND THEN RAISE EXCEPTION 'Crypto introuvable';END IF;
 phase:=public.ct_crypto_noise(p_symbol||':phase')*3.14159265;
 move:=sin(p_bucket::numeric/10080+phase)*0.13+sin(p_bucket::numeric/1440+phase)*0.035;
 f:=(p_bucket-d*1440)::numeric/1440;move:=move+(public.ct_crypto_noise('day:'||d)*(1-f)+public.ct_crypto_noise('day:'||(d+1))*f)*0.08;
 f:=(p_bucket-h*60)::numeric/60;move:=move+(public.ct_crypto_noise(p_symbol||':hour:'||h)*(1-f)+public.ct_crypto_noise(p_symbol||':hour:'||(h+1))*f)*0.025;
 move:=move+public.ct_crypto_noise(p_symbol||':minute:'||p_bucket)*0.0025;
 SELECT f.bucket,f.impact INTO last_flow FROM public.ct_crypto_flows f WHERE f.symbol=p_symbol AND f.bucket<=p_bucket ORDER BY f.bucket DESC LIMIT 1;
 IF FOUND THEN impact:=last_flow.impact*exp(-least(1000,(p_bucket-last_flow.bucket)::numeric)/90);END IF;
 RETURN greatest(10000,least(1000000000000000,round(a.base_e6*exp(move*a.volatility+impact))))::bigint;
END $$;
CREATE FUNCTION public.ct_crypto_cost(p_price bigint,p_atoms bigint,p_side text,p_fee integer,p_spread integer,p_liquidity bigint) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path='' AS $$
DECLARE slip numeric:=least(0.10,(p_price::numeric*p_atoms/1000000000000)/p_liquidity*0.03);price bigint;gross bigint;fee bigint;
BEGIN price:=round(p_price*(1+CASE WHEN p_side='buy' THEN 1 ELSE -1 END*(p_spread::numeric/20000+slip)))::bigint;
 IF p_side='buy' THEN gross:=ceil(price::numeric*p_atoms/1000000000000)::bigint;ELSE gross:=floor(price::numeric*p_atoms/1000000000000)::bigint;END IF;
 fee:=ceil(gross::numeric*p_fee/10000)::bigint;
 RETURN jsonb_build_object('price_e6',price::text,'gross',gross,'fee',fee,'total',CASE WHEN p_side='buy' THEN gross+fee ELSE gross-fee END,'slippage_bps',round(slip*10000,2)::text);
END $$;
REVOKE ALL ON FUNCTION public.ct_crypto_noise(text),public.ct_crypto_mark(text,bigint),public.ct_crypto_cost(bigint,bigint,text,integer,integer,bigint) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.ct_crypto_market() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE b bigint:=floor(extract(epoch FROM now())/60);s public.ct_crypto_settings;c public.ct_crypto_public_cache;result jsonb;
BEGIN SELECT * INTO s FROM public.ct_crypto_settings WHERE id;SELECT * INTO c FROM public.ct_crypto_public_cache WHERE id;
 IF c.bucket=b AND c.revision=s.market_revision THEN RETURN c.payload;END IF;
 PERFORM pg_advisory_xact_lock(173,41);SELECT * INTO s FROM public.ct_crypto_settings WHERE id;SELECT * INTO c FROM public.ct_crypto_public_cache WHERE id;
 IF c.bucket=b AND c.revision=s.market_revision THEN RETURN c.payload;END IF;
 SELECT jsonb_build_object('simulated',true,'as_of',now(),'bucket',b,'version',s.version,'buy_enabled',s.buy_enabled,'sell_enabled',s.sell_enabled,'fee_bps',s.fee_bps,'spread_bps',s.spread_bps,'max_trade',s.max_trade,'assets',jsonb_agg(to_jsonb(x) ORDER BY x.rank DESC)) INTO result FROM(
  SELECT a.symbol,a.name,a.category,a.color,a.base_e6 rank,a.buy_enabled,a.version,a.float_atoms::text float_atoms,a.total_atoms::text total_atoms,public.ct_crypto_mark(a.symbol,b)::text price_e6,public.ct_crypto_mark(a.symbol,b-1440)::text previous_e6,
  round(a.liquidity*(0.2+abs(public.ct_crypto_noise(a.symbol||':volume:'||(b/1440)))))::bigint+coalesce((SELECT sum(volume) FROM public.ct_crypto_flows WHERE symbol=a.symbol AND bucket>b-1440),0)::bigint volume,
  (SELECT jsonb_agg(public.ct_crypto_mark(a.symbol,b-(12-i)*120)::text ORDER BY i) FROM generate_series(0,12)i) sparkline
  FROM public.ct_crypto_assets a
 )x;
 UPDATE public.ct_crypto_public_cache SET bucket=b,revision=s.market_revision,payload=result WHERE id;RETURN result;
END $$;
CREATE FUNCTION public.ct_crypto_chart(p_symbol text,p_range text DEFAULT 'day') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE b bigint:=floor(extract(epoch FROM now())/60);v bigint;span integer;step integer;c public.ct_crypto_chart_cache;points jsonb;
BEGIN SELECT version INTO v FROM public.ct_crypto_assets WHERE symbol=p_symbol;IF v IS NULL THEN RAISE EXCEPTION 'Crypto introuvable';END IF;
 IF p_range='hour' THEN span:=60;step:=1;ELSIF p_range='day' THEN span:=1440;step:=10;ELSIF p_range='week' THEN span:=10080;step:=60;ELSE RAISE EXCEPTION 'Période crypto invalide';END IF;
 SELECT * INTO c FROM public.ct_crypto_chart_cache WHERE symbol=p_symbol AND range_id=p_range;
 IF c.bucket=b AND c.revision=v THEN RETURN jsonb_build_object('points',c.points,'as_of',now(),'simulated',true);END IF;
 PERFORM pg_advisory_xact_lock(174,hashtext(p_symbol||':'||p_range));
 SELECT * INTO c FROM public.ct_crypto_chart_cache WHERE symbol=p_symbol AND range_id=p_range;
 IF c.bucket=b AND c.revision=v THEN RETURN jsonb_build_object('points',c.points,'as_of',now(),'simulated',true);END IF;
 SELECT jsonb_agg(jsonb_build_object('time',t*60,'price_e6',public.ct_crypto_mark(p_symbol,t)::text) ORDER BY t) INTO points FROM generate_series(b-span,b,step)t;
 INSERT INTO public.ct_crypto_chart_cache(symbol,range_id,bucket,revision,points) VALUES(p_symbol,p_range,b,v,points) ON CONFLICT(symbol,range_id) DO UPDATE SET bucket=excluded.bucket,revision=excluded.revision,points=excluded.points;
 RETURN jsonb_build_object('points',points,'as_of',now(),'simulated',true);
END $$;

CREATE FUNCTION public.ct_crypto_portfolio(p_before bigint DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid:=auth.uid();b bigint:=floor(extract(epoch FROM now())/60);
BEGIN IF u IS NULL THEN RAISE EXCEPTION 'Connexion requise.';END IF;
 RETURN jsonb_build_object('balance',coalesce((SELECT balance FROM public.ct_wallets WHERE user_id=u),0),'positions',coalesce((SELECT jsonb_agg(jsonb_build_object('symbol',p.symbol,'atoms',p.atoms::text,'cost_basis',p.cost_basis,'realized',p.realized,'value',floor(public.ct_crypto_mark(p.symbol,b)::numeric*p.atoms/1000000000000)::text)) FROM public.ct_crypto_positions p WHERE p.user_id=u AND(p.atoms>0 OR p.realized<>0)),'[]'),'realized',coalesce((SELECT sum(realized) FROM public.ct_crypto_positions WHERE user_id=u),0),'trades',coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM(SELECT id,symbol,side,atoms::text,price_e6::text,gross,fee,total,realized,created_at FROM public.ct_crypto_trades WHERE user_id=u AND(p_before IS NULL OR id<p_before) ORDER BY id DESC LIMIT 30)x),'[]'));
END $$;
CREATE FUNCTION public.ct_crypto_quote(p_symbol text,p_side text,p_units text DEFAULT NULL,p_budget bigint DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid:=auth.uid();s public.ct_crypto_settings;a public.ct_crypto_assets;b bigint:=floor(extract(epoch FROM now())/60);price bigint;qty bigint;held bigint;budget bigint;lo bigint:=0;hi bigint;mid bigint;cost jsonb;q jsonb;
BEGIN IF u IS NULL OR NOT EXISTS(SELECT 1 FROM public.ct_profiles WHERE id=u AND NOT is_bot) OR EXISTS(SELECT 1 FROM public.ct_suspensions WHERE user_id=u) THEN RAISE EXCEPTION 'Compte joueur actif requis';END IF;
 IF p_side NOT IN('buy','sell') OR p_side IS NULL THEN RAISE EXCEPTION 'Sens de transaction invalide';END IF;
 SELECT * INTO s FROM public.ct_crypto_settings WHERE id;SELECT * INTO a FROM public.ct_crypto_assets WHERE symbol=p_symbol;IF NOT FOUND THEN RAISE EXCEPTION 'Crypto introuvable';END IF;
 IF(p_side='buy' AND(NOT s.buy_enabled OR NOT a.buy_enabled)) OR(p_side='sell' AND NOT s.sell_enabled) THEN RAISE EXCEPTION 'Transactions crypto temporairement suspendues';END IF;
 SELECT coalesce((SELECT atoms FROM public.ct_crypto_positions WHERE user_id=u AND symbol=p_symbol),0) INTO held;price:=public.ct_crypto_mark(p_symbol,b);
 IF p_budget IS NOT NULL THEN
  IF p_side<>'buy' OR p_units IS NOT NULL OR p_budget NOT BETWEEN 10 AND s.max_trade THEN RAISE EXCEPTION 'Budget crypto invalide';END IF;
  budget:=least(p_budget,coalesce((SELECT balance FROM public.ct_wallets WHERE user_id=u),0));hi:=least(a.float_atoms,ceil(budget::numeric*1000000000000/price)::bigint);
  WHILE lo<hi LOOP mid:=lo+(hi-lo+1)/2;cost:=public.ct_crypto_cost(price,mid,p_side,s.fee_bps,s.spread_bps,a.liquidity);IF(cost->>'total')::bigint<=budget THEN lo:=mid;ELSE hi:=mid-1;END IF;END LOOP;qty:=lo;
 ELSE
  IF p_units IS NULL OR length(p_units)>24 OR p_units !~ '^[0-9]{1,16}(\.[0-9]{1,6})?$' THEN RAISE EXCEPTION 'Quantité crypto invalide : six décimales maximum';END IF;
  IF p_units::numeric*1000000>9000000000000000000 THEN RAISE EXCEPTION 'Quantité crypto invalide : six décimales maximum';END IF;qty:=(p_units::numeric*1000000)::bigint;
 END IF;
 IF qty<=0 OR(p_side='buy' AND qty>a.float_atoms) OR(p_side='sell' AND qty>held) THEN RAISE EXCEPTION 'Quantité crypto indisponible';END IF;
 cost:=public.ct_crypto_cost(price,qty,p_side,s.fee_bps,s.spread_bps,a.liquidity);
 IF(cost->>'gross')::bigint<10 OR(cost->>'gross')::bigint>s.max_trade OR(cost->>'total')::bigint<=0 THEN RAISE EXCEPTION 'Montant crypto hors limites';END IF;
 IF p_side='buy' AND(cost->>'total')::bigint>coalesce((SELECT balance FROM public.ct_wallets WHERE user_id=u),0) THEN RAISE EXCEPTION 'Crédits disponibles insuffisants';END IF;
 q:=cost||jsonb_build_object('symbol',p_symbol,'side',p_side,'atoms',qty::text,'bucket',b,'asset_version',a.version,'settings_version',s.version,'expires_at',least(floor(extract(epoch FROM now()))::bigint+20,(b+1)*60),'fee_bps',s.fee_bps);
 RETURN q||jsonb_build_object('token',encode(sha256(convert_to(u::text||q::text||s.secret,'UTF8')),'hex'));
END $$;

CREATE FUNCTION public.ct_crypto_trade(p_operation_id uuid,p_quote jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;s public.ct_crypto_settings;a public.ct_crypto_assets;p public.ct_crypto_positions;r jsonb;q jsonb:=jsonb_build_object('kind','crypto_trade','quote',p_quote);raw jsonb:=p_quote-'token';b bigint:=floor(extract(epoch FROM now())/60);qty bigint;gross bigint;fee bigint;total bigint;removed bigint:=0;delta bigint;trade_id bigint;last_flow record;impact numeric:=0;
BEGIN PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;PERFORM public.ct_check_rate(u);
 SELECT * INTO s FROM public.ct_crypto_settings WHERE id FOR UPDATE;
 IF p_quote->>'token' IS DISTINCT FROM encode(sha256(convert_to(u::text||raw::text||s.secret,'UTF8')),'hex') THEN RAISE EXCEPTION 'Devis crypto invalide';END IF;
 SELECT * INTO a FROM public.ct_crypto_assets WHERE symbol=p_quote->>'symbol' FOR UPDATE;
 IF NOT FOUND OR (p_quote->>'bucket')::bigint<>b OR (p_quote->>'expires_at')::bigint<extract(epoch FROM now()) OR (p_quote->>'asset_version')::bigint<>a.version OR(p_quote->>'settings_version')::bigint<>s.version THEN RAISE EXCEPTION 'Le cours a changé. Demandez un nouveau devis.';END IF;
 IF(p_quote->>'side'='buy' AND(NOT s.buy_enabled OR NOT a.buy_enabled)) OR(p_quote->>'side'='sell' AND NOT s.sell_enabled) THEN RAISE EXCEPTION 'Transactions crypto temporairement suspendues';END IF;
 qty:=(p_quote->>'atoms')::bigint;gross:=(p_quote->>'gross')::bigint;fee:=(p_quote->>'fee')::bigint;total:=(p_quote->>'total')::bigint;
 INSERT INTO public.ct_crypto_positions(user_id,symbol) VALUES(u,a.symbol) ON CONFLICT DO NOTHING;SELECT * INTO p FROM public.ct_crypto_positions WHERE user_id=u AND symbol=a.symbol FOR UPDATE;
 IF p_quote->>'side'='buy' THEN
  IF a.float_atoms<qty THEN RAISE EXCEPTION 'Quantité crypto indisponible';END IF;
  PERFORM public.ct_post_credit(u,-total,'crypto_buy','crypto:'||p_operation_id::text);UPDATE public.ct_crypto_positions SET atoms=atoms+qty,cost_basis=cost_basis+total WHERE user_id=u AND symbol=a.symbol;delta:=-qty;
 ELSE
  IF p.atoms<qty THEN RAISE EXCEPTION 'Quantité crypto indisponible';END IF;
  removed:=CASE WHEN qty=p.atoms THEN p.cost_basis ELSE floor(p.cost_basis::numeric*qty/p.atoms)::bigint END;
  PERFORM public.ct_post_credit(u,total,'crypto_sell','crypto:'||p_operation_id::text);UPDATE public.ct_crypto_positions SET atoms=atoms-qty,cost_basis=cost_basis-removed,realized=realized+total-removed WHERE user_id=u AND symbol=a.symbol;delta:=qty;
 END IF;
 UPDATE public.ct_crypto_assets SET float_atoms=float_atoms+delta,version=version+1 WHERE symbol=a.symbol;
 SELECT f.bucket,f.impact INTO last_flow FROM public.ct_crypto_flows f WHERE f.symbol=a.symbol AND f.bucket<=b ORDER BY f.bucket DESC LIMIT 1;
 IF FOUND THEN impact:=last_flow.impact*exp(-least(1000,(b-last_flow.bucket)::numeric)/90);END IF;
 impact:=greatest(-0.4,least(0.4,impact+CASE WHEN p_quote->>'side'='buy' THEN 1 ELSE -1 END*least(0.10,gross::numeric/a.liquidity*0.02)));
 INSERT INTO public.ct_crypto_flows(symbol,bucket,impact,volume) VALUES(a.symbol,b,impact,gross) ON CONFLICT(symbol,bucket) DO UPDATE SET impact=excluded.impact,volume=ct_crypto_flows.volume+excluded.volume;
 INSERT INTO public.ct_crypto_trades(user_id,operation_id,symbol,side,atoms,price_e6,gross,fee,total,realized) VALUES(u,p_operation_id,a.symbol,p_quote->>'side',qty,(p_quote->>'price_e6')::bigint,gross,fee,total,CASE WHEN delta>0 THEN total-removed ELSE 0 END) RETURNING id INTO trade_id;
 UPDATE public.ct_crypto_settings SET market_revision=market_revision+1 WHERE id;
 DELETE FROM public.ct_crypto_flows WHERE(symbol,bucket) IN(SELECT symbol,bucket FROM public.ct_crypto_flows WHERE bucket<b-11520 ORDER BY bucket LIMIT 200);
 r:=jsonb_build_object('ok',true,'trade_id',trade_id,'symbol',a.symbol,'side',p_quote->>'side','atoms',qty::text,'total',total,'fee',fee);
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;
END $$;

REVOKE ALL ON FUNCTION public.ct_crypto_market(),public.ct_crypto_chart(text,text),public.ct_crypto_portfolio(bigint),public.ct_crypto_quote(text,text,text,bigint),public.ct_crypto_trade(uuid,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_crypto_market(),public.ct_crypto_chart(text,text) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_crypto_portfolio(bigint),public.ct_crypto_quote(text,text,text,bigint),public.ct_crypto_trade(uuid,jsonb) TO authenticated;
CREATE TRIGGER ct_crypto_live_positions AFTER INSERT OR UPDATE OR DELETE ON public.ct_crypto_positions FOR EACH ROW EXECUTE FUNCTION public.ct_live_row_changed('account','user_id');
CREATE TRIGGER ct_crypto_live_global AFTER UPDATE ON public.ct_crypto_assets FOR EACH ROW EXECUTE FUNCTION public.ct_live_global_changed('crypto');

CREATE FUNCTION public.ct_admin_crypto() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required';END IF;
 RETURN jsonb_build_object('settings',(SELECT to_jsonb(s)-'secret'-'market_revision' FROM public.ct_crypto_settings s WHERE id),'assets',(SELECT jsonb_agg(jsonb_build_object('symbol',a.symbol,'name',a.name,'buy_enabled',a.buy_enabled,'version',a.version,'float_atoms',a.float_atoms::text,'held_atoms',(a.total_atoms-a.float_atoms)::text) ORDER BY a.base_e6 DESC) FROM public.ct_crypto_assets a),'stats',(SELECT jsonb_build_object('trades',count(*),'players',count(DISTINCT user_id),'volume',coalesce(sum(gross),0),'fees',coalesce(sum(fee),0),'realized',coalesce(sum(realized),0)) FROM public.ct_crypto_trades),'recent',coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM(SELECT t.id,p.username,t.symbol,t.side,t.atoms::text,t.total,t.fee,t.created_at FROM public.ct_crypto_trades t JOIN public.ct_profiles p ON p.id=t.user_id ORDER BY t.id DESC LIMIT 30)x),'[]'));
END $$;
CREATE FUNCTION public.ct_admin_crypto_update(p_operation_id uuid,p_values jsonb,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid;r jsonb;q jsonb:=jsonb_build_object('kind','admin_crypto','values',p_values,'reason',p_reason);s public.ct_crypto_settings;
BEGIN PERFORM pg_advisory_xact_lock(173,8);u:=public.ct_lock_wallet();IF NOT public.ct_is_admin() THEN RAISE EXCEPTION 'Administrator required';END IF;r:=public.ct_replay(u,p_operation_id,q);IF r IS NOT NULL THEN RETURN r;END IF;
 IF length(trim(coalesce(p_reason,''))) NOT BETWEEN 8 AND 1000 THEN RAISE EXCEPTION 'Justification requise';END IF;
 SELECT * INTO s FROM public.ct_crypto_settings WHERE id FOR UPDATE;
 IF p_values->>'action'='settings' THEN
  IF(p_values->>'version')::bigint IS DISTINCT FROM s.version THEN RAISE EXCEPTION 'Réglages crypto modifiés. Relisez les valeurs.';END IF;
  UPDATE public.ct_crypto_settings SET buy_enabled=(p_values->>'buy_enabled')::boolean,sell_enabled=(p_values->>'sell_enabled')::boolean,fee_bps=(p_values->>'fee_bps')::integer,max_trade=(p_values->>'max_trade')::bigint,version=version+1,market_revision=market_revision+1 WHERE id;
 ELSIF p_values->>'action'='asset' THEN
  UPDATE public.ct_crypto_assets SET buy_enabled=(p_values->>'buy_enabled')::boolean,version=version+1 WHERE symbol=p_values->>'symbol' AND version=(p_values->>'version')::bigint;
  IF NOT FOUND THEN RAISE EXCEPTION 'Réglages crypto modifiés. Relisez les valeurs.';END IF;UPDATE public.ct_crypto_settings SET version=version+1,market_revision=market_revision+1 WHERE id;
 ELSE RAISE EXCEPTION 'Action crypto invalide';END IF;
 INSERT INTO public.ct_admin_audit_logs(admin_id,action,target,reason,details) VALUES(u,'crypto_settings',coalesce(p_values->>'symbol','crypto'),p_reason,p_values);
 PERFORM public.ct_live_notify('ct:live:global','crypto');PERFORM public.ct_live_notify('ct:live:admin','admin');r:=jsonb_build_object('ok',true);
 INSERT INTO public.ct_operations(user_id,operation_id,request,result) VALUES(u,p_operation_id,q,r);RETURN r;
END $$;
REVOKE ALL ON FUNCTION public.ct_admin_crypto(),public.ct_admin_crypto_update(uuid,jsonb,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ct_admin_crypto(),public.ct_admin_crypto_update(uuid,jsonb,text) TO authenticated;
