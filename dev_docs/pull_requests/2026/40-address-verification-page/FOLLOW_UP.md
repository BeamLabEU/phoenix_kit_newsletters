# Follow-up: PR #40

Resolution of the findings in `CLAUDE_REVIEW.md`.

| # | Finding | Resolution |
|---|---|---|
| 1 | Audience summary re-read on every page/filter patch | Fixed in dcd3948 (`load_summary/1`). |
| 2 | `start_batch/4` ran in the LiveView process | Fixed: `start_async/3` + `handle_async/3`, `starting` assign disables the button and refuses a second click; tests drive the task result through `handle_async/3`. |
| 3 | Second PubSub subscription when switching an audience back | Fixed: `subscribed_batches` is a `MapSet`; test added. |
| 4 | "Already running" guard is per-tab | Open. The engine does not dedupe by source; narrowed within a tab by `starting`. |
| 5 | Audience resolved on both renders | Open, by convention (work in `handle_params/3`). |
