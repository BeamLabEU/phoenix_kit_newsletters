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
