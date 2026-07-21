defmodule PhoenixKit.Newsletters.Web.Routes do
  @moduledoc """
  Route definitions for Newsletters public routes (unsubscribe flow, the
  subscription preference center).

  Admin LiveView routes are auto-generated from live_view: fields in admin_tabs/0.
  This module handles non-LiveView public routes, plus the preference
  center's own `live_session` — it can't ride the admin_tabs/
  user_dashboard_tabs auto-registration mechanism (both wrap their routes
  in an auth-gated live_session), and this page must stay reachable by a
  signed token with no login at all (spec §7).
  """

  alias PhoenixKit.Newsletters.Web.PreferenceCenterLive
  alias PhoenixKit.Newsletters.Web.UnsubscribeController
  alias PhoenixKitWeb.Users.Auth

  def generate(url_prefix) do
    quote do
      # RFC 8058 one-click unsubscribe (List-Unsubscribe-Post). This is
      # always a cold, session-less POST issued by the mail client, so it
      # cannot go through the host's :browser pipeline — protect_from_forgery
      # would 403 it (a mail client never carries a CSRF token or cookie).
      # Deliberately minimal/self-contained so it doesn't assume anything
      # about what else the host app's :browser pipeline includes.
      pipeline :phoenix_kit_newsletters_one_click do
        plug(:accepts, ["html"])
      end

      scope unquote(url_prefix) do
        pipe_through([:phoenix_kit_newsletters_one_click])

        get(
          "/newsletters/unsubscribe/one-click",
          unquote(UnsubscribeController),
          :one_click_unsubscribe
        )

        post(
          "/newsletters/unsubscribe/one-click",
          unquote(UnsubscribeController),
          :one_click_unsubscribe
        )
      end

      scope unquote(url_prefix) do
        pipe_through([:browser])

        get("/newsletters/unsubscribe", unquote(UnsubscribeController), :unsubscribe)
        post("/newsletters/unsubscribe", unquote(UnsubscribeController), :process_unsubscribe)

        # Permissive on_mount (same one core's own public auth pages use,
        # e.g. login) — it populates @phoenix_kit_current_scope when a
        # session exists but never requires one. The LiveView itself
        # branches on token vs. authenticated scope vs. neither.
        live_session :phoenix_kit_newsletters_preferences,
          on_mount: [{unquote(Auth), :phoenix_kit_mount_current_scope}] do
          live("/newsletters/preferences", unquote(PreferenceCenterLive), :index)
        end
      end
    end
  end
end
