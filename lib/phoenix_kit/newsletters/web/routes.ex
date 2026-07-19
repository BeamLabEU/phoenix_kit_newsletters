defmodule PhoenixKit.Newsletters.Web.Routes do
  @moduledoc """
  Route definitions for Newsletters public routes (unsubscribe flow).

  Admin LiveView routes are auto-generated from live_view: fields in admin_tabs/0.
  This module only handles non-LiveView public routes.
  """

  alias PhoenixKit.Newsletters.Web.UnsubscribeController

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
      end
    end
  end
end
