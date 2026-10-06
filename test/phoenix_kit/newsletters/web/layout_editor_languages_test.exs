defmodule PhoenixKit.Newsletters.Web.LayoutEditorLanguagesTest do
  @moduledoc """
  The layout editor's language tabs against the site's languages: one tab
  per site language, reading and writing the key the layout already stores
  that language under (`en` for `en-US`), never a dialect key beside it.
  Synthetic languages and content only.
  """

  use PhoenixKitNewsletters.DataCase, async: false

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Newsletters.Layouts
  alias PhoenixKit.Newsletters.Web.LayoutEditor
  alias PhoenixKit.Settings

  setup do
    Settings.update_boolean_setting("newsletters_enabled", true)
    :ok
  end

  # Sets the site's languages, in order; the first is the content language.
  defp site_languages!(codes) do
    {:ok, _} = Languages.enable_system()

    languages =
      codes
      |> Enum.with_index()
      |> Enum.map(fn {code, index} ->
        %{
          "code" => code,
          "name" => code,
          "is_default" => index == 0,
          "is_enabled" => true,
          "position" => index
        }
      end)

    {:ok, _} =
      Settings.update_json_setting_with_module(
        "languages_config",
        %{"languages" => languages},
        "languages"
      )

    assert Languages.get_enabled_language_codes() == codes
    :ok
  end

  defp mounted(params) do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
    {:ok, socket} = LayoutEditor.mount(params, %{}, socket)
    {:noreply, socket} = LayoutEditor.handle_params(params, "/", socket)
    socket
  end

  defp layout!(name, html_by_language) do
    {:ok, layout} = Layouts.create_layout(%{"name" => name, "html_body" => html_by_language})
    layout
  end

  defp switch(socket, language) do
    {:noreply, socket} =
      LayoutEditor.handle_event("switch_language", %{"language" => language}, socket)

    socket
  end

  defp html_in(socket, language) do
    tab = Enum.find(socket.assigns.tabs, &(&1.language == language))
    socket.assigns.translations["html_body"][tab.key]
  end

  describe "a site that spells its languages with a dialect" do
    setup do: site_languages!(["en-US", "et", "ru", "uk"])

    test "one tab per site language, none for the base key the layout stores" do
      layout = layout!("base_keys", %{"en" => "<p>EN {{{content}}}</p>"})

      socket = mounted(%{"id" => layout.uuid})

      assert socket.assigns.languages == ["en-US", "et", "ru", "uk"]
    end

    test "the dialect tab shows the base key's content and previews it" do
      layout = layout!("base_keys", %{"en" => "<p>EN {{{content}}}</p>"})

      socket = mounted(%{"id" => layout.uuid})

      assert socket.assigns.editor_locale == "en-US"
      assert html_in(socket, "en-US") == "<p>EN {{{content}}}</p>"
      assert socket.assigns.preview_html =~ "EN "
    end

    test "saving on the dialect tab updates the base key and adds no dialect key" do
      layout = layout!("base_keys", %{"en" => "<p>EN {{{content}}}</p>"})
      socket = mounted(%{"id" => layout.uuid})

      {:noreply, socket} =
        LayoutEditor.handle_event(
          "validate",
          %{"fields" => %{"html_body" => "<p>EN2 {{{content}}}</p>"}},
          socket
        )

      {:noreply, _} = LayoutEditor.handle_event("save", %{}, socket)

      assert Layouts.get_layout(layout.uuid).html_body == %{"en" => "<p>EN2 {{{content}}}</p>"}
    end

    test "a key whose language the site dropped is its own tab, after the site's, and survives" do
      layout =
        layout!("dropped", %{"en" => "<p>EN {{{content}}}</p>", "pt" => "<p>PT {{{content}}}</p>"})

      socket = mounted(%{"id" => layout.uuid})

      assert socket.assigns.languages == ["en-US", "et", "ru", "uk", "pt"]

      assert [%{language: "pt", key: "pt", site?: false}] =
               Enum.filter(socket.assigns.tabs, &(not &1.site?))

      socket = socket |> switch("pt")

      {:noreply, socket} =
        LayoutEditor.handle_event(
          "validate",
          %{"fields" => %{"html_body" => "<p>PT2 {{{content}}}</p>"}},
          socket
        )

      {:noreply, _} = LayoutEditor.handle_event("save", %{}, socket)

      assert Layouts.get_layout(layout.uuid).html_body == %{
               "en" => "<p>EN {{{content}}}</p>",
               "pt" => "<p>PT2 {{{content}}}</p>"
             }
    end

    test "a new layout puts the starter HTML under the first tab's own key" do
      socket = mounted(%{})

      assert socket.assigns.languages == ["en-US", "et", "ru", "uk"]
      assert socket.assigns.editor_locale == "en-US"
      assert Map.keys(socket.assigns.translations["html_body"]) == ["en-US"]
      assert socket.assigns.preview_html =~ "Sample broadcast"
    end

    test "the editor opens on the first tab that has content when the default has none" do
      layout = layout!("only_ru", %{"ru" => "<p>RU {{{content}}}</p>"})

      socket = mounted(%{"id" => layout.uuid})

      assert socket.assigns.editor_locale == "ru"
      assert socket.assigns.preview_html =~ "RU "
    end
  end

  describe "a site with a dialect for most languages" do
    setup do: site_languages!(["en-GB", "fr-FR", "de-DE", "it", "es-ES", "pl", "ru"])

    test "seven tabs, each reading the base key; no dialect key after save" do
      html = for l <- ~w(de en es fr it pl ru), into: %{}, do: {l, "<p>#{l} {{{content}}}</p>"}
      layout = layout!("all_base", html)

      socket = mounted(%{"id" => layout.uuid})

      assert socket.assigns.languages == ["en-GB", "fr-FR", "de-DE", "it", "es-ES", "pl", "ru"]
      assert html_in(socket, "fr-FR") == "<p>fr {{{content}}}</p>"

      socket = switch(socket, "fr-FR")
      assert socket.assigns.editor_locale == "fr-FR"
      assert socket.assigns.preview_html =~ "fr "

      {:noreply, socket} =
        LayoutEditor.handle_event(
          "validate",
          %{"fields" => %{"html_body" => "<p>fr2 {{{content}}}</p>"}},
          socket
        )

      {:noreply, _} = LayoutEditor.handle_event("save", %{}, socket)

      saved = Layouts.get_layout(layout.uuid).html_body
      assert Map.keys(saved) |> Enum.sort() == ~w(de en es fr it pl ru)
      assert saved["fr"] == "<p>fr2 {{{content}}}</p>"
    end
  end

  describe "two dialects of one language and a layout that stores only the base" do
    setup do: site_languages!(["en-GB", "en-US", "ru"])

    test "the first dialect takes the base key, the second gets its own" do
      layout = layout!("one_base", %{"en" => "<p>EN {{{content}}}</p>"})

      socket = mounted(%{"id" => layout.uuid})

      assert socket.assigns.languages == ["en-GB", "en-US", "ru"]

      assert [
               %{language: "en-GB", key: "en"},
               %{language: "en-US", key: "en-US"},
               %{language: "ru", key: "ru"}
             ] = socket.assigns.tabs

      assert html_in(socket, "en-US") == nil
    end

    test "saving leaves one version of English, not two" do
      layout = layout!("one_base", %{"en" => "<p>EN {{{content}}}</p>"})
      socket = mounted(%{"id" => layout.uuid})

      {:noreply, _} = LayoutEditor.handle_event("save", %{}, socket)

      assert Layouts.get_layout(layout.uuid).html_body == %{"en" => "<p>EN {{{content}}}</p>"}
    end
  end

  describe "the layout's name" do
    setup do: site_languages!(["en-US", "ru"])

    test "an unusable name is refused with a readable, rule-stating message" do
      socket = mounted(%{})

      {:noreply, socket} =
        LayoutEditor.handle_event("save", %{"name" => "My Layout"}, socket)

      assert [error] = socket.assigns.errors
      assert error =~ "Name"
      assert error =~ "Latin"
      assert error =~ "underscore"
    end

    test "with no name and a display name, a slug is suggested; it can be taken" do
      socket = mounted(%{})

      {:noreply, socket} =
        LayoutEditor.handle_event(
          "validate",
          %{"name" => "", "fields" => %{"display_name" => "Monthly News - 2026"}},
          socket
        )

      assert socket.assigns.suggested_name == "monthly_news_2026"

      {:noreply, socket} = LayoutEditor.handle_event("use_suggested_name", %{}, socket)

      assert socket.assigns.name == "monthly_news_2026"
      assert socket.assigns.suggested_name == nil
    end

    test "no suggestion once a name is typed" do
      socket = mounted(%{})

      {:noreply, socket} =
        LayoutEditor.handle_event(
          "validate",
          %{"name" => "mine", "fields" => %{"display_name" => "Monthly News"}},
          socket
        )

      assert socket.assigns.suggested_name == nil
    end
  end
end
