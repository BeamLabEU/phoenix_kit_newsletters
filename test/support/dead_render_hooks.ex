defmodule PhoenixKitNewsletters.Test.DeadRenderHooks do
  @moduledoc """
  Stands in for the `on_mount` hooks a PhoenixKit host puts in front of the
  admin LiveViews: it assigns the keys the templates read (`@url_path`,
  the current scope and locale). Only what the host would provide — never
  anything the LiveViews under test assign themselves.
  """

  import Phoenix.Component, only: [assign: 3]

  # The admin pages check `newsletters.send` / `newsletters.audiences`, so
  # they get a scope holding every key; the public pages get no one.
  def on_mount(:admin, params, session, socket) do
    {:cont, socket} = on_mount(:default, params, session, socket)

    {:cont,
     assign(socket, :phoenix_kit_current_scope, PhoenixKitNewsletters.TestScopes.full_scope())}
  end

  def on_mount(:default, _params, _session, socket) do
    {:cont,
     socket
     |> assign(:url_path, "/admin/newsletters")
     |> assign(:phoenix_kit_current_scope, nil)
     |> assign(:phoenix_kit_current_user, nil)
     |> assign(:current_locale, "en")}
  end
end
