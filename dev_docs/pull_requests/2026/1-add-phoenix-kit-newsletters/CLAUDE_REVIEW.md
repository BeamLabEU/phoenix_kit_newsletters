# Code Review: PR #1 — Add phoenix_kit_newsletters package

**Reviewed:** 2026-03-15
**Reviewer:** Claude (claude-opus-4-6)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/1
**Head SHA:** 3fbbcd3bd36bf13feb4e71e8c5fd5b7fa2ce2c87

## Summary

Initial extraction of the Newsletters module from `phoenix_kit` into a standalone Hex package. Includes Ecto schemas (Broadcast, Delivery, List, ListMember), Oban-based broadcaster and delivery worker, 6 admin LiveViews, unsubscribe controller, and public routes.

## Issues Found

### 1. [BUG - HIGH] Transaction result ignored in `broadcaster.ex`

**File:** `lib/phoenix_kit/modules/newsletters/broadcaster.ex` lines 59–68

The return value of `repo.transaction/1` is never checked. If the transaction fails (e.g., DB connection error mid-batch), the code still returns `{:ok, broadcast}` and logs success. The broadcast will be stuck in `"sending"` status with no deliveries enqueued.

```elixir
# Result of this transaction is ignored:
repo.transaction(fn ->
  stream_active_members(broadcast.list_uuid)
  |> Stream.chunk_every(@batch_size)
  |> Enum.each(fn batch ->
    process_batch(broadcast, batch, repo)
  end)
end)

Logger.info("Broadcaster: Enqueued #{total} deliveries for broadcast #{broadcast.uuid}")
{:ok, broadcast}  # Always returned, even if transaction failed
```

**Fix:** Pattern-match or case on the transaction result and return `{:error, reason}` on failure.

**Confidence:** 90/100

---

### 2. [BUG - CRITICAL] Hardcoded `path: "/app"` for phoenix_kit dependency in `mix.exs`

**File:** `mix.exs` line 27

```elixir
{:phoenix_kit, "~> 1.7", path: "/app"},
```

The `path:` option overrides Hex resolution and points to an absolute local path. When this package is published to Hex.pm and installed by any external user, Mix will look for `phoenix_kit` at `/app` on their filesystem — which won't exist. This breaks any installation outside this specific dev environment.

**Fix:** Remove `path: "/app"` before publishing: `{:phoenix_kit, "~> 1.7"}`.

**Confidence:** 85/100

---

### 3. [BUG - HIGH] Endpoint mismatch between token signing and verification in unsubscribe flow

**Files:**
- `lib/phoenix_kit/modules/newsletters/workers/delivery_worker.ex` line 96–99 (signs tokens)
- `lib/phoenix_kit/modules/newsletters/web/unsubscribe_controller.ex` lines 14, 35, 51 (verifies tokens)

`delivery_worker.ex` uses the configurable endpoint for signing:
```elixir
endpoint = PhoenixKit.Config.get(:endpoint, PhoenixKitWeb.Endpoint)
unsubscribe_token = Phoenix.Token.sign(endpoint, "unsubscribe", token_data)
```

But `unsubscribe_controller.ex` hardcodes `PhoenixKitWeb.Endpoint` for verification:
```elixir
case Phoenix.Token.verify(PhoenixKitWeb.Endpoint, "unsubscribe", token, max_age: 604_800) do
```

If a parent app configures a custom endpoint via `PhoenixKit.Config`, tokens will be signed with one module and verified with another — causing all unsubscribe links to return `{:error, :invalid}`.

**Fix:** Use `PhoenixKit.Config.get(:endpoint, PhoenixKitWeb.Endpoint)` in the controller as well.

**Confidence:** 82/100

---

## Verdict

**Needs Work** — Issues 2 and 3 are blocking for correctness. Issue 2 must be resolved before this can be published to Hex.pm.
