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
  alias PhoenixKit.Newsletters.Render
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

  defp render_page(socket) do
    socket.assigns
    |> Map.merge(%{url_path: "/admin/newsletters/layouts", phoenix_kit_current_scope: nil})
    |> LayoutEditor.render()
    |> Phoenix.LiveViewTest.rendered_to_string()
  end

  defp switch(socket, language) do
    {:noreply, socket} =
      LayoutEditor.handle_event("switch_language", %{"language" => language}, socket)

    socket
  end

  defp html_in(socket, language) do
    tab = Enum.find(socket.assigns.tabs, &(&1.language == language))
    socket.assigns.translations["html_body"][tab.keys["html_body"]]
  end

  defp type(socket, fields) do
    {:noreply, socket} = LayoutEditor.handle_event("validate", %{"fields" => fields}, socket)
    socket
  end

  defp save(socket) do
    {:noreply, socket} = LayoutEditor.handle_event("save", %{}, socket)
    socket
  end

  describe "a site that spells its languages with a dialect" do
    setup do: site_languages!(["en-US", "fr", "de", "es"])

    test "one tab per site language, none for the base key the layout stores" do
      layout = layout!("base_keys", %{"en" => "<p>EN {{{content}}}</p>"})

      socket = mounted(%{"id" => layout.uuid})

      assert socket.assigns.languages == ["en-US", "fr", "de", "es"]
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

      assert socket.assigns.languages == ["en-US", "fr", "de", "es", "pt"]

      assert [%{language: "pt", keys: %{"html_body" => "pt"}, site?: false}] =
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

      assert socket.assigns.languages == ["en-US", "fr", "de", "es"]
      assert socket.assigns.editor_locale == "en-US"
      assert Map.keys(socket.assigns.translations["html_body"]) == ["en-US"]
      assert socket.assigns.preview_html =~ "Sample broadcast"
    end

    test "the editor opens on the first tab that has content when the default has none" do
      layout = layout!("only_de", %{"de" => "<p>DE {{{content}}}</p>"})

      socket = mounted(%{"id" => layout.uuid})

      assert socket.assigns.editor_locale == "de"
      assert socket.assigns.preview_html =~ "DE "
    end
  end

  describe "a site with a dialect for most languages" do
    setup do: site_languages!(["en-GB", "nl-NL", "sv-SE", "fi", "da-DK", "cs", "ja"])

    test "seven tabs, each reading the base key; no dialect key after save" do
      html = for l <- ~w(cs da en fi ja nl sv), into: %{}, do: {l, "<p>#{l} {{{content}}}</p>"}
      layout = layout!("all_base", html)

      socket = mounted(%{"id" => layout.uuid})

      assert socket.assigns.languages == ["en-GB", "nl-NL", "sv-SE", "fi", "da-DK", "cs", "ja"]
      assert html_in(socket, "nl-NL") == "<p>nl {{{content}}}</p>"

      socket = switch(socket, "nl-NL")
      assert socket.assigns.editor_locale == "nl-NL"
      assert socket.assigns.preview_html =~ "nl "

      {:noreply, socket} =
        LayoutEditor.handle_event(
          "validate",
          %{"fields" => %{"html_body" => "<p>nl2 {{{content}}}</p>"}},
          socket
        )

      {:noreply, _} = LayoutEditor.handle_event("save", %{}, socket)

      saved = Layouts.get_layout(layout.uuid).html_body
      assert Map.keys(saved) |> Enum.sort() == ~w(cs da en fi ja nl sv)
      assert saved["nl"] == "<p>nl2 {{{content}}}</p>"
    end
  end

  describe "two dialects of one language and a layout that stores only the base" do
    setup do: site_languages!(["en-GB", "en-US", "de"])

    test "the first dialect takes the base key, the second gets its own" do
      layout = layout!("one_base", %{"en" => "<p>EN {{{content}}}</p>"})

      socket = mounted(%{"id" => layout.uuid})

      assert socket.assigns.languages == ["en-GB", "en-US", "de"]

      assert [
               %{language: "en-GB", keys: %{"html_body" => "en"}},
               %{language: "en-US", keys: %{"html_body" => "en-US"}},
               %{language: "de", keys: %{"html_body" => "de"}}
             ] = socket.assigns.tabs

      assert html_in(socket, "en-US") == nil
    end

    test "editing the first dialect's tab changes the one English version" do
      layout = layout!("one_base", %{"en" => "<p>EN {{{content}}}</p>"})

      mounted(%{"id" => layout.uuid})
      |> type(%{"html_body" => "<p>EN2 {{{content}}}</p>"})
      |> save()

      assert Layouts.get_layout(layout.uuid).html_body == %{"en" => "<p>EN2 {{{content}}}</p>"}
    end

    test "the second dialect's tab writes a key of its own, beside en" do
      layout = layout!("one_base", %{"en" => "<p>EN {{{content}}}</p>"})

      mounted(%{"id" => layout.uuid})
      |> switch("en-US")
      |> type(%{"html_body" => "<p>US {{{content}}}</p>"})
      |> save()

      assert Layouts.get_layout(layout.uuid).html_body == %{
               "en" => "<p>EN {{{content}}}</p>",
               "en-US" => "<p>US {{{content}}}</p>"
             }
    end
  end

  describe "a layout the old editor saved in part" do
    setup do: site_languages!(["en-US", "fr", "de", "es"])

    defp partial_layout! do
      {:ok, layout} =
        Layouts.create_layout(%{
          "name" => "partial",
          "html_body" => %{"en" => "<p>EN {{{content}}}</p>"},
          "display_name" => %{"en-US" => "News"},
          "subject" => %{"en-US" => "[US] {{subject}}"}
        })

      layout
    end

    test "the en-US tab shows the HTML and the display name; the stored subject is flagged" do
      socket = mounted(%{"id" => partial_layout!().uuid})

      assert socket.assigns.languages == ["en-US", "fr", "de", "es", "en-US (subject)"]
      assert socket.assigns.editor_locale == "en-US"
      assert html_in(socket, "en-US") =~ "EN "

      assert socket.assigns.translations["display_name"][
               socket.assigns.editor_keys["display_name"]
             ] == "News"

      assert socket.assigns.preview_html =~ "EN "

      # The subject stored under en-US is not what a send reads for this HTML.
      assert socket.assigns.editor_keys["subject"] == "en"
      assert socket.assigns.translations["subject"][socket.assigns.editor_keys["subject"]] == nil
    end

    test "the flagged subject is readable on its own tab, and clearing it removes it" do
      layout = partial_layout!()
      socket = mounted(%{"id" => layout.uuid}) |> switch("en-US (subject)")

      assert socket.assigns.editor_keys == %{
               "html_body" => nil,
               "subject" => "en-US",
               "display_name" => nil,
               "text_body" => "en-US"
             }

      html = render_page(socket)
      assert html =~ "[US] {{subject}}"
      assert html =~ "never used"
      assert html =~ "subject not used by sends"

      socket |> type(%{"subject" => ""}) |> save()
      saved = Layouts.get_layout(layout.uuid)

      assert saved.subject == %{}
      assert saved.html_body == %{"en" => "<p>EN {{{content}}}</p>"}
      assert saved.display_name == %{"en-US" => "News"}
    end

    test "saving from the en-US tab changes each field where it was and keeps the flagged subject" do
      layout = partial_layout!()

      mounted(%{"id" => layout.uuid})
      |> type(%{"html_body" => "<p>EN2 {{{content}}}</p>", "display_name" => "News 2"})
      |> save()

      saved = Layouts.get_layout(layout.uuid)

      assert saved.html_body == %{"en" => "<p>EN2 {{{content}}}</p>"}
      assert saved.display_name == %{"en-US" => "News 2"}
      assert saved.subject == %{"en-US" => "[US] {{subject}}"}
    end

    test "a language that exists only in a non-HTML field is still a tab, and survives a save" do
      {:ok, layout} =
        Layouts.create_layout(%{
          "name" => "subject_only",
          "html_body" => %{"en" => "<p>EN {{{content}}}</p>"},
          "subject" => %{"pt" => "[PT] {{subject}}"}
        })

      socket = mounted(%{"id" => layout.uuid})

      assert socket.assigns.languages == ["en-US", "fr", "de", "es", "pt"]
      socket = switch(socket, "pt")
      assert socket.assigns.translations["subject"]["pt"] == "[PT] {{subject}}"

      save(socket)
      assert Layouts.get_layout(layout.uuid).subject == %{"pt" => "[PT] {{subject}}"}
    end

    test "a field with no key on this tab is disabled, explained, and writes nothing" do
      layout = partial_layout!()
      socket = mounted(%{"id" => layout.uuid}) |> switch("en-US (subject)")

      html = render_page(socket)

      for field <- ~w(html_body display_name) do
        assert html =~ ~r/name="fields\[#{field}\]"[^>]*disabled/s
      end

      assert html =~ "Not editable here"

      # A valid value, so only the missing key keeps it out of the save.
      result =
        socket
        |> type(%{"html_body" => "<p>clobbered {{{content}}}</p>", "display_name" => "Clobbered"})
        |> save()

      assert result.assigns.errors == []
      saved = Layouts.get_layout(layout.uuid)
      assert saved.html_body == %{"en" => "<p>EN {{{content}}}</p>"}
      assert saved.display_name == %{"en-US" => "News"}
    end
  end

  describe "the subject is stored where a send reads it" do
    @html "<html><head><title>{{subject}}</title></head><body>{{{content}}}</body></html>"

    test "a dialect site over base keys: the pattern typed on en-US lands under en and is applied" do
      site_languages!(["en-US", "fr"])
      layout = layout!("base_keys", %{"en" => @html})

      socket =
        mounted(%{"id" => layout.uuid})
        |> type(%{"subject" => "[N] {{subject}}"})

      assert socket.assigns.preview_html =~ "[N] Sample subject"

      save(socket)
      saved = Layouts.get_layout(layout.uuid)

      assert saved.subject == %{"en" => "[N] {{subject}}"}
      assert Render.subject("Hello", saved, "en-US") == "[N] Hello"
      assert Render.subject("Hello", saved, "en") == "[N] Hello"
    end

    test "a base site over dialect keys: the pattern typed on en lands under en-US and is applied" do
      site_languages!(["en", "fr"])
      layout = layout!("dialect_keys", %{"en-US" => @html})

      mounted(%{"id" => layout.uuid})
      |> type(%{"subject" => "[N] {{subject}}"})
      |> save()

      saved = Layouts.get_layout(layout.uuid)

      assert saved.subject == %{"en-US" => "[N] {{subject}}"}
      assert Render.subject("Hello", saved, "en") == "[N] Hello"
    end

    test "a new translation keeps all its fields under one key" do
      site_languages!(["en-GB", "en-US"])
      layout = layout!("one_each", %{"en" => @html})

      mounted(%{"id" => layout.uuid})
      |> switch("en-US")
      |> type(%{
        "html_body" => @html,
        "subject" => "[US] {{subject}}",
        "display_name" => "US",
        "text_body" => "text"
      })
      |> save()

      saved = Layouts.get_layout(layout.uuid)

      assert Map.keys(saved.html_body) |> Enum.sort() == ["en", "en-US"]
      assert Map.keys(saved.subject) == ["en-US"]
      assert Map.keys(saved.display_name) == ["en-US"]
      assert Map.keys(saved.text_body) == ["en-US"]
      assert Render.subject("Hello", saved, "en-US") == "[US] Hello"
    end
  end

  describe "the editor's markup" do
    setup do: site_languages!(["en-US", "fr"])

    test "the name hint is shown" do
      html = render_page(mounted(%{}))

      assert html =~ "Lowercase Latin letters, numbers and underscores"
    end

    test "a suggestion and its button appear once a display name is typed, and go with a name" do
      socket = mounted(%{})
      refute render_page(socket) =~ "Use this name"

      socket = type(socket, %{"display_name" => "Monthly News"})
      html = render_page(socket)
      assert html =~ "Use this name"
      assert html =~ "monthly_news"
      assert html =~ ~s(phx-click="use_suggested_name")

      {:noreply, socket} = LayoutEditor.handle_event("use_suggested_name", %{}, socket)
      refute render_page(socket) =~ "Use this name"
    end

    test "a stored key the site does not offer is badged; site languages are not" do
      layout =
        layout!("with_pt", %{"en" => "<p>{{{content}}}</p>", "pt" => "<p>{{{content}}}</p>"})

      html = render_page(mounted(%{"id" => layout.uuid}))

      assert [_one] = Regex.scan(~r/not a site language/, html)

      assert html =~
               ~r/pt\s*<span[^>]*>\s*<\/span>\s*<span[^>]*badge-warning[^>]*>\s*not a site language/s
    end
  end

  describe "the layout's name" do
    setup do: site_languages!(["en-US", "fr"])

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
