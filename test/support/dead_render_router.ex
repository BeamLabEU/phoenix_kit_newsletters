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
