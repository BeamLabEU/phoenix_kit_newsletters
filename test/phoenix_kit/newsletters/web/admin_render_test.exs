defmodule PhoenixKit.Newsletters.Web.AdminRenderTest do
  @moduledoc """
  Renders the admin list templates to HTML. The LiveView client refuses a
  `phx-change` on an input outside a `<form>` — and callback-level tests
  (`handle_event/3` called directly) cannot see markup — so the shape of
  the markup is pinned here.
  """

  use PhoenixKitNewsletters.DataCase, async: false

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PhoenixKit.Newsletters.Layout
  alias PhoenixKit.Newsletters.Layouts
  alias PhoenixKit.Newsletters.Web.Broadcasts
  alias PhoenixKit.Newsletters.Web.LayoutsIndex
  alias PhoenixKitNewsletters.Test.Repo

  setup do
    PhoenixKit.Settings.update_boolean_setting("newsletters_enabled", true)
    :ok
  end

  defp render_page(module, params) do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
    {:ok, socket} = module.mount(params, %{}, socket)
    {:noreply, socket} = module.handle_params(params, "/", socket)

    socket.assigns
    |> Map.merge(%{url_path: "/admin/newsletters", phoenix_kit_current_scope: nil})
    |> module.render()
    |> rendered_to_string()
  end

  # The status <select> sits inside the form that carries phx-change, and
  # carries no phx-change of its own. (No HTML parser among this package's
  # deps; the rendered markup is regular enough for these patterns.)
  defp assert_filter_in_form(html, form_id) do
    assert [_, form_body] =
             Regex.run(
               ~r{<form[^>]*id="#{form_id}"[^>]*phx-change="filter_status"[^>]*>(.*?)</form>}s,
               html
             ),
           "no form##{form_id} with phx-change=\"filter_status\""

    assert form_body =~ ~r{<select[^>]*name="status"}
    refute html =~ ~r{<select[^>]*phx-change}
  end

  test "the layouts status filter is a form" do
    assert_filter_in_form(render_page(LayoutsIndex, %{}), "layouts-status-filter")
  end

  test "the broadcasts status filter is a form, with and without results" do
    {:ok, _} =
      PhoenixKit.Newsletters.create_broadcast(%{
        subject: "Listed",
        source_type: "user_group",
        source_params: %{"role_uuids" => [Ecto.UUID.generate()]}
      })

    assert_filter_in_form(render_page(Broadcasts, %{}), "broadcasts-status-filter")

    # A filter that matches nothing keeps the filter on screen.
    html = render_page(Broadcasts, %{"status" => "failed"})
    assert_filter_in_form(html, "broadcasts-status-filter")
    assert html =~ "No broadcasts with this status"
  end

  test "a carried-over system email is badged and has no Restore button" do
    system =
      Repo.insert!(%Layout{
        name: "test_email",
        status: "archived",
        html_body: %{"en" => "<p>core email</p>"},
        metadata: %{"email_is_system" => true}
      })

    {:ok, operator} =
      Layouts.create_layout(%{
        "name" => "old_layout",
        "status" => "archived",
        "html_body" => %{"en" => "{{{content}}}"}
      })

    html = render_page(LayoutsIndex, %{"status" => "archived"})

    restore_for = fn uuid ->
      Regex.scan(~r{<button[^>]*phx-click="restore"[^>]*phx-value-uuid="#{uuid}"}, html)
    end

    assert [] = restore_for.(system.uuid)
    assert [_] = restore_for.(operator.uuid)

    # One badge, in the system email's own row.
    assert [_] =
             Regex.scan(
               ~r{<span[^>]*class="[^"]*badge[^"]*"[^>]*>\s*System email\s*</span>},
               html
             )

    [system_row] = Regex.run(~r{<tr>(?:(?!</tr>).)*test_email(?:(?!</tr>).)*</tr>}s, html)
    assert system_row =~ "System email"
  end
end
