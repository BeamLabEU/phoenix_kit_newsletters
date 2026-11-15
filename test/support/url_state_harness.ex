defmodule PhoenixKitNewsletters.Test.UrlStateHarness do
  @moduledoc """
  Runs a `PhoenixKitWeb.Live.UrlState` LiveView's callbacks the way LiveView
  does, for tests that call them directly on a hand-built socket.

  LiveView runs the module's `on_mount` hook before `mount/3`, and the
  `handle_params` hook it attaches before the view's own `handle_params/3`. The
  hook is what puts the URL's state (page, page size, filters) in the assigns,
  and `PhoenixKitWeb.PageSize` needs the configuration it leaves there. This
  goes through the same public `on_mount/4` and LiveView's own
  `Phoenix.LiveView.Lifecycle.handle_params/3`, a `@doc false` function, so a
  LiveView upgrade that changes it shows up here first, as a failing helper.

  `test/web/dead_render_test.exs` covers the real router path.
  """

  alias Phoenix.LiveView.Lifecycle
  alias Phoenix.LiveView.Socket
  alias PhoenixKitWeb.Live.UrlState

  @doc "The socket as LiveView hands it to `mount/3`, after the UrlState hook."
  @spec prepare(module(), map(), Socket.t()) :: Socket.t()
  def prepare(view, params \\ %{}, %Socket{} = socket) do
    socket = %{
      socket
      | view: view,
        router: PhoenixKitNewsletters.Test.DeadRenderRouter,
        private: Map.put_new(socket.private, :lifecycle, %Lifecycle{})
    }

    {:cont, socket} =
      UrlState.on_mount({:url_state, view.__phoenix_kit_url_state__()}, params, %{}, socket)

    socket
  end

  @doc "`prepare/3`, then the view's `mount/3`."
  @spec mount(module(), map(), Socket.t()) :: {:ok, Socket.t()}
  def mount(view, params \\ %{}, %Socket{} = socket) do
    view.mount(params, %{}, prepare(view, params, socket))
  end

  @doc """
  The attached hooks, then the view's `handle_params/3`. A socket that has not
  been through `prepare/3` (a test that skips `mount/3`) is prepared first.
  """
  @spec handle_params(module(), map(), String.t(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_params(view, params, uri, %Socket{} = socket) do
    socket =
      if Map.has_key?(socket.private, :lifecycle), do: socket, else: prepare(view, params, socket)

    {:cont, socket} = Lifecycle.handle_params(params, uri, socket)
    view.handle_params(params, uri, socket)
  end
end
