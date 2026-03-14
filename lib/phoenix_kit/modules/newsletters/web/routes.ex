defmodule PhoenixKit.Modules.Newsletters.Web.Routes do
  @moduledoc """
  Route definitions for Newsletters public routes (unsubscribe flow).

  Admin LiveView routes are auto-generated from live_view: fields in admin_tabs/0.
  This module only handles non-LiveView public routes.
  """

  alias PhoenixKit.Modules.Newsletters.Web.UnsubscribeController

  def generate(url_prefix) do
    quote do
      scope unquote(url_prefix) do
        pipe_through([:browser])

        get("/newsletters/unsubscribe", unquote(UnsubscribeController), :unsubscribe)
        post("/newsletters/unsubscribe", unquote(UnsubscribeController), :process_unsubscribe)
      end
    end
  end
end
