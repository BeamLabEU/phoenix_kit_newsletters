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
    defp translations(stored), do: %{"html_body" => Map.new(stored, &{&1, "x"})}

    defp tabs(site, stored) do
      site
      |> Layout.language_tabs(translations(stored))
      |> Enum.map(&{&1.language, &1.keys["html_body"]})
    end

    test "a stored base key serves the dialect tab; no extra tab for it" do
      assert tabs(["en-US", "fr", "de", "es"], ["en"]) ==
               [{"en-US", "en"}, {"fr", "fr"}, {"de", "de"}, {"es", "es"}]
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

    # The ownership pass order: a per-tab loop (each tab tries exact, base,
    # dialect in site order) gives these two cases a key on two tabs, so
    # typing in one language overwrites the other.
    test "an earlier tab never takes the key a later tab spells exactly (dialect)" do
      assert tabs(["en-GB", "en-US"], ["en-US"]) == [{"en-GB", "en-GB"}, {"en-US", "en-US"}]
    end

    test "an earlier tab never takes the key a later tab spells exactly (base)" do
      assert tabs(["en-US", "en"], ["en"]) == [{"en-US", "en-US"}, {"en", "en"}]
    end

    test "base keys go to the first tab before any dialect match is made" do
      assert tabs(["en-GB", "en-US"], ["en", "en-US"]) == [{"en-GB", "en"}, {"en-US", "en-US"}]
    end

    test "_ and - spell the same language, and the site's two spellings are one tab" do
      assert tabs(["pt_BR"], ["pt-BR"]) == [{"pt_BR", "pt-BR"}]
      assert tabs(["en_US", "en-US"], ["en-US"]) == [{"en_US", "en-US"}]
    end

    test "stored keys no site language claims follow the site's tabs, sorted, marked" do
      tabs = Layout.language_tabs(["de-DE", "en-US"], translations(["pt", "en", "de", "ja"]))

      assert Enum.map(tabs, &{&1.language, &1.keys["html_body"], &1.site?}) == [
               {"de-DE", "de", true},
               {"en-US", "en", true},
               {"ja", "ja", false},
               {"pt", "pt", false}
             ]
    end

    test "every stored key is on exactly one tab" do
      stored = ~w(cs da en fi ja nl sv)
      site = ["en-GB", "nl-NL", "sv-SE", "fi", "da-DK", "cs", "ja"]
      keys = site |> tabs(stored) |> Enum.map(&elem(&1, 1))

      assert Enum.sort(keys) == stored
    end

    test "agrees with translation_key/3 on which key a language reads" do
      map = %{"en" => "EN", "fr" => "FR"}

      for {lang, key} <- tabs(["en-US", "fr-FR"], Map.keys(map)) do
        assert key == Layout.translation_key(map, lang, nil)
      end
    end

    test "blank values are not stored translations" do
      # A blank under a key the tab would otherwise claim does not claim it.
      translations = %{
        "html_body" => %{"en" => "x"},
        "display_name" => %{"en-GB" => "  "},
        "subject" => %{"pt" => "  "}
      }

      assert [%{language: "en-US", keys: keys}] = Layout.language_tabs(["en-US"], translations)

      assert keys["display_name"] == "en"
      assert keys["subject"] == "en"
    end

    test "a blank-only key is not a tab" do
      assert [%{language: "en-US"}] =
               Layout.language_tabs(["en-US"], %{
                 "html_body" => %{"en" => "x", "pt" => ""},
                 "text_body" => %{"fr" => "   "}
               })
    end
  end

  describe "language_tabs/2 — each field is stored where a send reads it" do
    test "the subject follows the HTML's key; so does a field with no match of its own" do
      translations = %{"html_body" => %{"en" => "<p>{{{content}}}</p>"}}

      assert [%{language: "en-US", keys: keys}] = Layout.language_tabs(["en-US"], translations)

      assert keys == %{
               "html_body" => "en",
               "subject" => "en",
               "display_name" => "en",
               "text_body" => "en"
             }
    end

    test "a second dialect with no HTML starts one key for all four fields" do
      translations = %{"html_body" => %{"en" => "x"}, "display_name" => %{"en" => "n"}}

      assert [_, %{language: "en-US", keys: keys}] =
               Layout.language_tabs(["en-GB", "en-US"], translations)

      assert Map.values(keys) |> Enum.uniq() == ["en-US"]
    end

    test "the display name is matched on its own, as Layout.display_name/2 does" do
      translations = %{
        "html_body" => %{"en" => "x"},
        "display_name" => %{"en-US" => "News"},
        "text_body" => %{}
      }

      assert [%{language: "en-US", keys: %{"html_body" => "en", "display_name" => "en-US"}}] =
               Layout.language_tabs(["en-US"], translations)
    end

    test "a subject under a key no HTML is under is a residue tab: shown, not used, not lost" do
      translations = %{
        "html_body" => %{"en" => "x"},
        "subject" => %{"en-US" => "[US] {{subject}}"},
        "display_name" => %{"en-US" => "News"}
      }

      assert [
               %{
                 language: "en-US",
                 site?: true,
                 keys: %{"subject" => "en", "display_name" => "en-US"}
               },
               %{
                 language: "en-US (subject)",
                 locale: "en-US",
                 site?: false,
                 residue?: true,
                 keys: %{"html_body" => nil, "subject" => "en-US", "display_name" => nil}
               }
             ] = Layout.language_tabs(["en-US"], translations)
    end

    test "a language held only by a non-HTML field is a tab, with no HTML key" do
      translations = %{"html_body" => %{"en" => "x"}, "subject" => %{"pt" => "{{subject}}"}}

      assert [
               %{language: "en-US"},
               %{
                 language: "pt",
                 site?: false,
                 residue?: true,
                 keys: %{"html_body" => nil, "subject" => "pt", "display_name" => "pt"}
               }
             ] = Layout.language_tabs(["en-US"], translations)
    end

    test "a display name under a key of its own is a tab whose HTML key is its own" do
      translations = %{"html_body" => %{"en" => "x"}, "display_name" => %{"pt" => "Notícias"}}

      assert [
               %{language: "en-US"},
               %{
                 language: "pt",
                 site?: false,
                 residue?: false,
                 keys: %{"html_body" => "pt", "subject" => "pt", "display_name" => "pt"}
               }
             ] = Layout.language_tabs(["en-US"], translations)
    end

    test "a tab has no key in a field where a site tab owns its key" do
      translations = %{
        "html_body" => %{"en" => "x"},
        "display_name" => %{"en-US" => "a", "en" => "b"}
      }

      assert [
               %{language: "en-US", keys: %{"html_body" => "en", "display_name" => "en-US"}},
               %{
                 language: "en",
                 keys: %{"html_body" => nil, "subject" => nil, "display_name" => "en"}
               }
             ] = Layout.language_tabs(["en-US"], translations)
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
