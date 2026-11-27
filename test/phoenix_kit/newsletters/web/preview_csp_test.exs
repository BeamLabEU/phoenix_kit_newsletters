defmodule PhoenixKit.Newsletters.Web.PreviewCSPTest.Routes do
  @moduledoc false
  alias PhoenixKit.Newsletters.Web.Routes

  defmacro generated, do: Routes.generate("/")
end

defmodule PhoenixKit.Newsletters.Web.PreviewCSPTest.Router do
  @moduledoc false
  use Phoenix.Router, helpers: false

  import Phoenix.LiveView.Router

  alias PhoenixKit.Newsletters.Web.PreviewCSPTest.Routes, as: Generated

  require Generated

  pipeline :browser do
    plug(:accepts, ["html"])
  end

  Generated.generated()
end

defmodule PhoenixKit.Newsletters.Web.PreviewCSPTest do
  @moduledoc """
  The editors' previews, through a real request, under a page nonce.

  The nonce is set the way core's `on_mount` sets it in a LiveView process. A
  core without `PhoenixKitWeb.CSP` (older than this module's CSP support needs)
  has no nonce to give, and the preview is then the markup as it was.
  """

  use PhoenixKitNewsletters.DataCase, async: false

  import Phoenix.ConnTest

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Layouts
  alias PhoenixKit.Newsletters.Web.CSP

  @endpoint PhoenixKitNewsletters.Test.DeadRenderEndpoint

  @router PhoenixKit.Newsletters.Web.PreviewCSPTest.Router

  @layout_html "<html><head><style>.a{color:red}</style></head><body>{{{content}}}</body></html>"

  setup do
    Newsletters.enable_system()

    {:cont, _socket} =
      CSP.on_mount(
        :default,
        %{},
        %{"phoenix_kit_csp_nonces" => %{"style" => "n0nce", "script" => "n0nce"}},
        %Phoenix.LiveView.Socket{}
      )

    {:ok, layout} =
      Layouts.create_layout(%{"name" => "csp_layout", "html_body" => %{"en" => @layout_html}})

    {:ok, conn: build_conn(), layout: layout}
  end

  # The `<style>` opening tag as the preview's `srcdoc` attribute carries it.
  defp expected_style_tag do
    if Code.ensure_loaded?(PhoenixKitWeb.CSP),
      do: "&lt;style nonce=&quot;n0nce&quot;&gt;",
      else: "&lt;style&gt;"
  end

  defp srcdoc(html) do
    assert [_, srcdoc] = Regex.run(~r/<iframe[^>]*?\ssrcdoc="([^"]*)"/s, html)
    srcdoc
  end

  test "the layout editor's preview", %{conn: conn, layout: layout} do
    html = html_response(get(conn, "/layouts/#{layout.uuid}/edit"), 200)

    assert srcdoc(html) =~ expected_style_tag()
  end

  @tag :requires_v158
  test "the broadcast editor's preview", %{conn: conn, layout: layout} do
    {:ok, broadcast} =
      Newsletters.create_broadcast(%{
        subject: "Preview",
        markdown_body: "Hello",
        template_uuid: layout.uuid,
        source_type: "user_group",
        source_params: %{"role_uuids" => [Ecto.UUID.generate()]}
      })

    html = html_response(get(conn, "/broadcasts/#{broadcast.uuid}/edit"), 200)

    assert srcdoc(html) =~ expected_style_tag()
  end

  # What a live_session of this package does between the two renders: the request's
  # nonce goes into the session, and `on_mount` restores it in the socket's process.
  test "the nonce travels from the request to the connected view" do
    previous = Application.fetch_env(:phoenix_kit, :csp_nonce_assign_key)
    Application.put_env(:phoenix_kit, :csp_nonce_assign_key, :csp_nonce)

    on_exit(fn ->
      case previous do
        {:ok, key} -> Application.put_env(:phoenix_kit, :csp_nonce_assign_key, key)
        :error -> Application.delete_env(:phoenix_kit, :csp_nonce_assign_key)
      end
    end)

    session = CSP.live_session(Plug.Conn.assign(build_conn(), :csp_nonce, "fr0m-conn"))

    # A process of its own, as the connected view is: nothing set up above leaks in.
    restored =
      Task.async(fn ->
        {:cont, _socket} = CSP.on_mount(:default, %{}, session, %Phoenix.LiveView.Socket{})
        CSP.nonce(:style)
      end)
      |> Task.await()

    assert restored == if(Code.ensure_loaded?(PhoenixKitWeb.CSP), do: "fr0m-conn")
  end

  # The preference center has a live_session of its own and renders core's auth
  # page, which writes a `<style>`: the session carries the nonce to the connected
  # render, as core's guide asks of a live_session outside the kit's own.
  test "the preference center's live_session restores the page's nonces" do
    for path <- ["/newsletters/preferences", "/et/newsletters/preferences"] do
      %{phoenix_live_view: {_view, _action, _opts, %{extra: extra}}} =
        Phoenix.Router.route_info(@router, "GET", path, "host")

      assert extra.session == {CSP, :live_session, []}
      assert Enum.any?(extra.on_mount, &match?(%{id: {CSP, :default}}, &1))
    end
  end
end
