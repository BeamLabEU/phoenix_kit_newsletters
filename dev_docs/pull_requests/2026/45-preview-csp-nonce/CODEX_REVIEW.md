# PR #45 review — Email preview CSP nonces

Reviewed the two editor previews, the preference center's live session, the optional core API calls, and the CSP tests. [PR #45](https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/45)

## IMPROVEMENT - MEDIUM

On a host with a style nonce, each preview change ran the tokenizer across every HTML tag, even in messages styled entirely with inline attributes. The tokenizer also compiled its interpolated regex on each call. The helper now checks for a possible style opening tag first and compiles the tokenizer at build time. The timing test includes a real style element in every case so it still exercises the tokenizer.

With 250 KB of table markup containing no style blocks, the median of five local runs fell from 60 ms to 1.6 ms. Both versions returned the original HTML byte for byte.

## Test coverage

The inline-tag source check used a word boundary after the tag name. It flagged the new Elixir regex as markup and overlooked uppercase tags. It now matches HTML tag-name delimiters case-insensitively.

A Chromium smoke test rendered the helper's output and an unstamped control in separate sandboxed frames on the same page. Under a nonce-only style policy, the stamped paragraph took its stylesheet color and the control kept the browser default.

On the merged tree with locked PhoenixKit 3.9.0, all 1,177 tests passed with PostgreSQL. The precommit gate passed, including the dependency audit, strict Credo, and Dialyzer. The locked core exercises the compatibility fallback. The browser smoke test supplied the style nonce explicitly.
