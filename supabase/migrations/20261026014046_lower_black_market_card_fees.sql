BEGIN;
-- Basis points, read by every Black Market quote and settlement path.
-- Credit-market commission and previously issued receipts are unaffected.
UPDATE public.ct_demo_card_tiers AS tier
SET market_fee_bps=rate.bps,version=tier.version+1
FROM(VALUES('basic',200),('premium',150),('gold',100),('platinum',50),('diamond',25),('cosmic',0)) AS rate(id,bps)
WHERE tier.id=rate.id AND tier.market_fee_bps IS DISTINCT FROM rate.bps;
COMMIT;
