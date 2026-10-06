defmodule PhoenixKit.Newsletters.LayoutTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Newsletters.Layout

  describe "translation/3 — language → base → dialect → site → any" do
    @map %{"en" => "EN", "de" => "DE", "pt-BR" => "PT-BR", "fr" => "FR"}

    test "the exact language first" do
      assert Layout.translation(@map, "de", "en") == "DE"
      assert Layout.translation(@map, "pt-BR", "en") == "PT-BR"
    end

    test "a dialect narrows to its base, and _ reads as -" do
      assert Layout.translation(@map, "de-AT", "en") == "DE"
      assert Layout.translation(@map, "pt_BR", "en") == "PT-BR"
    end

    test "a base finds another dialect of itself before the site default" do
      assert Layout.translation(@map, "pt", "en") == "PT-BR"
      assert Layout.translation(@map, "pt-PT", "en") == "PT-BR"
    end

    test "then the site's language, then any language, alphabetically" do
      assert Layout.translation(@map, "ru", "fr") == "FR"
      assert Layout.translation(@map, "ru", "et") == "DE"
      assert Layout.translation(@map, nil, nil) == "DE"
    end

    test "blank values count as missing; nothing usable is nil" do
      assert Layout.translation(%{"de" => "  ", "en" => "EN"}, "de", "et") == "EN"
      assert Layout.translation(%{"de" => ""}, "de", "en") == nil
      assert Layout.translation(%{}, "de", "en") == nil
      assert Layout.translation(nil, "de", "en") == nil
    end
  end

  describe "language_tabs/2 — one tab per site language, one tab per stored key" do
    defp tabs(site, stored),
      do: Enum.map(Layout.language_tabs(site, stored), &{&1.language, &1.key})

    test "a stored base key serves the dialect tab; no extra tab for it" do
      assert tabs(["en-US", "et", "ru", "uk"], ["en"]) ==
               [{"en-US", "en"}, {"et", "et"}, {"ru", "ru"}, {"uk", "uk"}]
    end

    test "an exact key wins over the base key" do
      assert tabs(["en-US"], ["en", "en-US"]) == [{"en-US", "en-US"}, {"en", "en"}]
    end

    test "another dialect of the language serves a tab with no key of its own" do
      assert tabs(["en-US"], ["en-GB"]) == [{"en-US", "en-GB"}]
    end

    test "a stored key belongs to the first tab only; the next dialect gets its own key" do
      assert tabs(["en-GB", "en-US"], ["en"]) == [{"en-GB", "en"}, {"en-US", "en-US"}]
    end

    test "a later tab's exact key is not taken by an earlier tab's base match" do
      assert tabs(["en-GB", "en-US"], ["en", "en-US"]) == [{"en-GB", "en"}, {"en-US", "en-US"}]
    end

    test "_ and - spell the same language" do
      assert tabs(["pt_BR"], ["pt-BR"]) == [{"pt_BR", "pt-BR"}]
    end

    test "stored keys no site language claims follow the site's tabs, sorted, marked" do
      tabs = Layout.language_tabs(["de-DE", "en-US"], ["pt", "en", "de", "ja"])

      assert Enum.map(tabs, &{&1.language, &1.key, &1.site?}) == [
               {"de-DE", "de", true},
               {"en-US", "en", true},
               {"ja", "ja", false},
               {"pt", "pt", false}
             ]
    end

    test "every stored key is on exactly one tab" do
      stored = ~w(de en es fr it pl ru)
      site = ["en-GB", "fr-FR", "de-DE", "it", "es-ES", "pl", "ru"]
      keys = Enum.map(Layout.language_tabs(site, stored), & &1.key)

      assert Enum.sort(keys) == stored
    end

    test "agrees with translation_key/3 on which key a language reads" do
      map = %{"en" => "EN", "fr" => "FR"}

      tabs = Layout.language_tabs(["en-US", "fr-FR"], Map.keys(map))

      for %{language: lang, key: key} <- tabs do
        assert key == Layout.translation_key(map, lang, nil)
      end
    end
  end

  describe "suggest_name/1" do
    test "ASCII letters and digits, spaces and dashes become underscores, lowercase" do
      assert Layout.suggest_name("Monthly News - 2026") == "monthly_news_2026"
      assert Layout.suggest_name("  my-layout  ") == "my_layout"
    end

    test "a suggestion is always a valid name; none when nothing usable is left" do
      assert Layout.suggest_name("2026 news") == "layout_2026_news"
      assert Layout.suggest_name("Новости") == nil
      assert Layout.suggest_name("") == nil
      assert Layout.suggest_name(nil) == nil

      for text <- ["A b", "x--y", "9", "Ünï cödé 1"] do
        assert Layout.suggest_name(text) =~ ~r/\A[a-z][a-z0-9_]*\z/
      end
    end
  end

  describe "changeset/2" do
    defp changeset(attrs) do
      Layout.changeset(
        %Layout{},
        Map.merge(%{"name" => "welcome_layout", "html_body" => %{"en" => "{{{content}}}"}}, attrs)
      )
    end

    test "a valid layout" do
      assert changeset(%{}).valid?
      assert changeset(%{"html_body" => %{"en" => "<div>{{content}}</div>"}}).valid?
      cs = changeset(%{"html_body" => %{en: "{{{content}}}"}})
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :html_body) == %{"en" => "{{{content}}}"}
    end

    test "malformed translation values are rejected instead of silently dropped" do
      for field <- ~w(display_name subject html_body text_body),
          value <- [42, true, nil, %{}, ["text"]] do
        cs = changeset(%{field => %{"en" => "{{{content}}} {{subject}}", "de" => value}})
        refute cs.valid?, "#{field} accepted #{inspect(value)}"
        assert cs.errors[String.to_existing_atom(field)]
      end
    end

    test "every HTML translation must place the body" do
      cs = changeset(%{"html_body" => %{"en" => "{{{content}}}", "de" => "<p>kein Inhalt</p>"}})
      refute cs.valid?

      assert {"must place the broadcast with {{{content}}} (missing in %{language})", opts} =
               cs.errors[:html_body]

      assert opts[:language] == "de"
    end

    test "an HTML body is required" do
      refute changeset(%{"html_body" => %{}}).valid?
      refute changeset(%{"html_body" => %{"en" => "   "}}).valid?
    end

    test "a subject pattern must place {{subject}}; blank ones are dropped" do
      refute changeset(%{"subject" => %{"en" => "Fixed subject"}}).valid?
      assert changeset(%{"subject" => %{"en" => "[News] {{subject}}"}}).valid?

      cs = changeset(%{"subject" => %{"en" => "", "de" => "  "}})
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :subject) == %{}
    end

    test "a carried-over row stays editable: only the translations a change touches are checked" do
      # As V2 copies it: subjects without {{subject}}, a language without a
      # body placeholder.
      carried = %Layout{
        name: "newsletter",
        status: "active",
        html_body: %{"en" => "<div>{{content}}</div>", "de" => "<p>alt</p>"},
        subject: Map.new(~w(en de fr it es pl ru), &{&1, "News (#{&1})"})
      }

      assert Layout.changeset(carried, %{"display_name" => %{"en" => "Newsletter"}}).valid?

      # The editor sends every language back; unchanged ones are not checked.
      resent = %{"subject" => carried.subject, "html_body" => carried.html_body}
      assert Layout.changeset(carried, resent).valid?

      # An edited translation is.
      refute Layout.changeset(carried, %{"subject" => Map.put(carried.subject, "en", "Fixed")}).valid?

      refute Layout.changeset(carried, %{
               "html_body" => Map.put(carried.html_body, "en", "<p>no body</p>")
             }).valid?

      assert Layout.changeset(carried, %{
               "subject" => Map.put(carried.subject, "en", "[News] {{subject}}")
             }).valid?
    end

    test "an edit cannot leave no language placing the body" do
      layout = %Layout{
        name: "two_languages",
        status: "active",
        html_body: %{"en" => "<div>{{{content}}}</div>", "de" => "<p>alt</p>"}
      }

      # Deleting the only translation that places the body: the untouched
      # German one does not, so nothing would.
      refute Layout.changeset(layout, %{"html_body" => %{"de" => "<p>alt</p>"}}).valid?
      assert Layout.changeset(layout, %{"html_body" => %{"en" => "{{content}}"}}).valid?
    end

    test "a carried-over system email cannot be made active" do
      system = %Layout{
        name: "test_email",
        status: "archived",
        html_body: %{"en" => "<p>test</p>"},
        metadata: %{"email_is_system" => true}
      }

      assert Layout.system_email?(system)
      refute Layout.changeset(system, %{"status" => "active"}).valid?
      assert Layout.changeset(system, %{"display_name" => %{"en" => "Test"}}).valid?

      # metadata is not cast: the flag cannot be dropped through attrs.
      cs = Layout.changeset(system, %{"metadata" => %{}})
      assert Ecto.Changeset.get_field(cs, :metadata) == %{"email_is_system" => true}
    end

    test "name is a slug, status is active or archived" do
      refute changeset(%{"name" => "Welcome Layout"}).valid?
      refute changeset(%{"name" => "1st"}).valid?
      refute changeset(%{"status" => "draft"}).valid?
      assert changeset(%{"status" => "archived"}).valid?
    end
  end

  test "languages/1 lists the languages with HTML" do
    layout = %Layout{html_body: %{"en" => "x", "de" => "y", "fr" => " "}}
    assert Layout.languages(layout) == ["de", "en"]
  end
end
