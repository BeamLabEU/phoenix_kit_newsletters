defmodule PhoenixKitNewsletters.Test.DeadRenderHooks do
  @moduledoc """
  Stands in for the `on_mount` hooks a PhoenixKit host puts in front of the
  admin LiveViews: it assigns the keys the templates read (`@url_path`,
  the current scope and locale). Only what the host would provide — never
  anything the LiveViews under test assign themselves.
  """

  import Phoenix.Component, only: [assign: 3]

  def on_mount(:default, _params, _session, socket) do
    {:cont,
     socket
     |> assign(:url_path, "/admin/newsletters")
     |> assign(:phoenix_kit_current_scope, nil)
     |> assign(:phoenix_kit_current_user, nil)
     |> assign(:current_locale, "en")}
  end
end
