# Casino & Titles

This repository is the existing Casino & Titles Site. Preserve its Site identity and audience.

## Required French and English support

Every user-facing change must work in both `fr` and `en`, including administrator pages, errors, accessible labels, placeholders, validation, game logs, new system content and transactional summaries. No third language is supported.

The React JSX runtime in `src/i18n` localizes displayed text at render time and subscribes to the language preference. Do not manipulate DOM text nodes or translate stored identifiers, form values, usernames, access codes or player-written messages. Mark player-written content and identifiers with `translate="no"` on a dedicated element. Keep proper product names unchanged.

Add English translations to `src/i18n/messages/*.txt` as `source|English`. If a source is originally English, add its French translation to `src/i18n/messages-fr.txt`. Use `{0}`, `{1}`, etc. for dynamic values; preserve every parameter. Use idiomatic complete sentences; review fragments and generated messages in context. Ship translations for new built-in titles, quests, events and achievements. Do not translate player content automatically.

Run `npm run i18n:build` after editing catalogs. `npm run i18n:check` is required before a build and rejects new untranslated source strings. Use `locale()` for numbers and dates, and preserve exact monetary arithmetic. Test switching languages while a page is open, persistence, player content, dynamic quantities, errors and at least one representative administrator screen. Normal tests default to French; update text expectations when French copy intentionally changes.
