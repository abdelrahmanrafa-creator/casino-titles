# Simulated Crypto market

Route: /crypto. Administrator section: /admin?section=crypto.

All assets, reference prices, volumes and market scenarios are simulated. Orders use existing game credits; there are no deposits, withdrawals, exchange credentials or real-wallet connections.

## Main files

- src/features/Crypto.tsx and crypto.css: market, portfolio, activity and signed order preview.
- src/components/CryptoChart.tsx: SVG curves and sparklines.
- src/lib/crypto.ts: exact six-decimal quantities and localized display.
- src/features/admin/AdminCrypto.tsx: fees, trade limits and market pauses.
- supabase/migrations/20261109195646_simulated_crypto_market.sql: schema, shared pricing engine, authenticated atomic operations and audit.
- tests/crypto-market.test.mjs: conservation, rollback, replay, signatures, permissions, pricing and exact quantities.

## Shared simulation

The secret-keyed server model combines multi-day trends, smoothly interpolated daily/hourly factors and minute noise. Recent actual game orders affect prices with decaying pressure. Quotes disclose execution price and fees; spread and quantity-dependent slippage prevent instant self-pump round-trip profit. Historical curves are bounded samples, not stored ticks. The public cache has one row; chart cache has at most three rows per asset. Only actual trades and active minute flows add history; old flows are cleaned in bounded batches.

## Safety and operations

Private tables have RLS enabled and no direct player grants. Read-only market/chart RPCs expose public simulated data only. Holdings/history RPCs use auth.uid(); admin RPCs verify the stored role. Mutations use the existing economic lock, wallet ledger, treasury mirror, idempotency receipts and private live invalidations. Signed quotes expire within 20 seconds or at the minute boundary and are invalidated by changed settings/order books.

Default transaction fee is 0.25%, configurable from 0 to 5%; default maximum is 10,000,000 credits, configurable from 10 to 100,000,000. Individual asset pauses block new purchases while global sell control remains separate. Settings changes are versioned and audited.

Local-only UI fixture: npm run dev, then /__crypto-preview. Its mock API and fixture are excluded from production bundles. Never use production accounts to generate test orders. Run node --test tests/crypto-market.test.mjs and npm run build after changes. Add every new UI string to the French/English catalogs.

## Marketplace payments (0.8.0)

Sellers opt in per listing or wholesale stock, selecting all 32 current assets or a supported subset. Existing offers remain opted out. A grouped Black Market purchase only accepts assets common to every copy allocated to that quantity. Item barter cannot be paid in crypto.

The signed 20-second quote freezes the current simulated mid price, listing stock/discounts, server credits-per-diamond rate, allowed assets and the existing marketplace fee. Player-market commission is deducted from the seller; Black Market card fees are added for the buyer. There is no additional crypto conversion spread or charge. Quantities use six decimals; conversion rounds up. Seller net plus server fee exactly equals buyer debit.

ct_crypto_payment_buy uses the shared economic lock and operation receipt, revalidates the quote, and transfers existing holdings directly to the seller and private server treasury. It never sells to the house or mints offset credits/diamonds. Credit bundles release their already-funded escrow. Position acquisition cost and realized disposal value are updated. ct_crypto_payment_ledger records all three conserving legs. Asset float and market impact remain unchanged for peer-to-peer payments.

Order snapshots and inbox notices preserve the actual crypto amounts and frozen rate. Reference credit/diamond prices remain stored for item price analytics; they are not fiat charges. Standard order corrections in credits/diamonds are blocked for crypto receipts. Admin Crypto lists actual server fee holdings by asset.

Implementation: src/components/CryptoPayments.tsx, CryptoReceipt.tsx and supabase/migrations/20261109203635_crypto_market_payments.sql. Tests: tests/crypto-payments.test.mjs. Local fixture: /__crypto-payments-preview (DEV only).
