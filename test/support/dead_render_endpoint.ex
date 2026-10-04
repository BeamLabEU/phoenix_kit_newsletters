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

defmodule PhoenixKitNewsletters.Test.DeadRenderRouter do
  @moduledoc """
  A router with this package's LiveViews mounted the way a host mounts them
  (`live/4` inside a `live_session`), so a request goes through
  `Phoenix.LiveView.Plug` and `Phoenix.LiveView.Controller.live_render/3` —
  the dead render a browser gets on first load. Mirrors the routes in
  `PhoenixKit.Newsletters.admin_tabs/0` and `Web.Routes`.
  """

  use Phoenix.Router

  import Phoenix.LiveView.Router

  alias PhoenixKit.Newsletters.Web

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
  end

  scope "/" do
    pipe_through(:browser)

    live_session :newsletters_admin,
      on_mount: [{PhoenixKitNewsletters.Test.DeadRenderHooks, :default}] do
      live("/broadcasts", Web.Broadcasts, :index, as: :broadcasts_index)
      live("/broadcasts/new", Web.BroadcastEditor, :new, as: :broadcast_new)
      live("/broadcasts/:id/edit", Web.BroadcastEditor, :edit, as: :broadcast_edit)
      live("/broadcasts/:id", Web.BroadcastDetails, :show, as: :broadcast_show)
      live("/layouts", Web.LayoutsIndex, :index, as: :layouts_index)
      live("/layouts/new", Web.LayoutEditor, :new, as: :layout_new)
      live("/layouts/:id/edit", Web.LayoutEditor, :edit, as: :layout_edit)
    end
  end
end

defmodule PhoenixKitNewsletters.Test.DeadRenderErrorHTML do
  @moduledoc """
  Error pages for the test endpoint. Phoenix renders the 500 page before it
  re-raises a request's exception, so without a module that can render one
  a failing request shows "no 500 template" instead of the real error.
  """

  def render(template, _assigns), do: template
end

defmodule PhoenixKitNewsletters.Test.DeadRenderEndpoint do
  @moduledoc """
  The smallest endpoint that lets `Phoenix.ConnTest` drive a real request
  through `DeadRenderRouter`. Started by `test_helper.exs`; configured in
  `config/test.exs`. It never listens on a port (`server: false`).
  """

  use Phoenix.Endpoint, otp_app: :phoenix_kit_newsletters

  plug(Plug.Session,
    store: :cookie,
    key: "_newsletters_test_key",
    signing_salt: "newsletters_test_session"
  )

  plug(PhoenixKitNewsletters.Test.DeadRenderRouter)
end
