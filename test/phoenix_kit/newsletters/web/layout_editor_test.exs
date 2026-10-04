defmodule PhoenixKit.Newsletters.Web.LayoutEditorTest do
  @moduledoc """
  Direct callback tests for the layout screens — no endpoint in this
  package, so `mount/3`, `handle_params/3` and `handle_event/3` are called
  on a hand-built socket, as in `broadcast_editor_test.exs`.
  """

  use PhoenixKitNewsletters.DataCase, async: false

  alias PhoenixKit.Newsletters.Layout
  alias PhoenixKit.Newsletters.Layouts
  alias PhoenixKit.Newsletters.Web.LayoutEditor
  alias PhoenixKit.Newsletters.Web.LayoutsIndex

  setup do
    PhoenixKit.Settings.update_boolean_setting("newsletters_enabled", true)
    :ok
  end

  defp mounted(module, params) do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
    {:ok, socket} = module.mount(params, %{}, socket)
    {:noreply, socket} = module.handle_params(params, "/", socket)
    socket
  end

  describe "LayoutEditor" do
    test "a new layout starts with core's chrome and the body in the content language" do
      socket = mounted(LayoutEditor, %{})
      locale = socket.assigns.editor_locale

      html = socket.assigns.translations["html_body"][locale]
      assert Layout.places_content?(html)
      assert html =~ "{{{header}}}"
      assert html =~ "{{{footer}}}"
      assert socket.assigns.preview_html =~ "Sample broadcast"
    end

    test "edits per language and saves every language" do
      socket = mounted(LayoutEditor, %{})
      locale = socket.assigns.editor_locale

      {:noreply, socket} =
        LayoutEditor.handle_event(
          "validate",
          %{"name" => "acme_layout", "fields" => %{"html_body" => "<div>{{{content}}}</div>"}},
          socket
        )

      # A language the site does not offer cannot be switched to.
      {:noreply, same} =
        LayoutEditor.handle_event("switch_language", %{"language" => "xx"}, socket)

      assert same.assigns.editor_locale == locale

      {:noreply, _socket} = LayoutEditor.handle_event("save", %{}, socket)

      assert [%Layout{name: "acme_layout", html_body: %{^locale => "<div>{{{content}}}</div>"}}] =
               Layouts.list_layouts()
    end

    test "a layout without {{{content}}} is refused with a readable error" do
      socket = mounted(LayoutEditor, %{})

      {:noreply, socket} =
        LayoutEditor.handle_event(
          "save",
          %{"name" => "broken", "fields" => %{"html_body" => "<p>no body</p>"}},
          socket
        )

      assert [error] = socket.assigns.errors
      assert error =~ "{{{content}}}"
      assert Layouts.list_layouts() == []
    end

    test "editing keeps languages the site does not offer" do
      {:ok, layout} =
        Layouts.create_layout(%{
          "name" => "legacy_layout",
          "html_body" => %{"zz" => "{{content}}", "en" => "{{{content}}}"}
        })

      socket = mounted(LayoutEditor, %{"id" => layout.uuid})
      assert "zz" in socket.assigns.languages

      {:noreply, _} = LayoutEditor.handle_event("save", %{}, socket)
      assert Layouts.get_layout(layout.uuid).html_body["zz"] == "{{content}}"
    end

    test "correcting a field refreshes save errors without hiding remaining errors" do
      socket = mounted(LayoutEditor, %{})

      {:noreply, socket} =
        LayoutEditor.handle_event(
          "save",
          %{
            "name" => "Invalid Name",
            "fields" => %{"html_body" => "<p>no body</p>"}
          },
          socket
        )

      assert length(socket.assigns.errors) == 2

      {:noreply, socket} =
        LayoutEditor.handle_event(
          "validate",
          %{
            "fields" => %{"html_body" => "{{{content}}}"}
          },
          socket
        )

      assert [error] = socket.assigns.errors
      assert error =~ "Name"

      {:noreply, socket} =
        LayoutEditor.handle_event("validate", %{"name" => "corrected"}, socket)

      assert socket.assigns.errors == []
    end
  end

  describe "LayoutsIndex" do
    test "make default, archive, restore" do
      {:ok, layout} =
        Layouts.create_layout(%{"name" => "listed", "html_body" => %{"en" => "{{{content}}}"}})

      socket = mounted(LayoutsIndex, %{})
      assert [%Layout{name: "listed"}] = socket.assigns.layouts

      {:noreply, socket} =
        LayoutsIndex.handle_event("set_default", %{"uuid" => layout.uuid}, socket)

      assert socket.assigns.default_uuid == layout.uuid

      {:noreply, socket} = LayoutsIndex.handle_event("archive", %{"uuid" => layout.uuid}, socket)
      assert socket.assigns.layouts == []
      assert socket.assigns.default_uuid == nil

      {:noreply, socket} = LayoutsIndex.handle_event("restore", %{"uuid" => layout.uuid}, socket)
      assert Layouts.get_layout(layout.uuid).status == "active"
      assert socket.assigns.default_uuid == nil
    end
  end
end
