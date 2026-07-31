defmodule PhoenixKit.Newsletters.I18nTest do
  @moduledoc """
  Smoke test for the per-module i18n wiring.

  Confirms that:
    * Every admin tab registered by `PhoenixKit.Newsletters.admin_tabs/0`
      carries `gettext_backend: PhoenixKit.Newsletters.Gettext`.
    * Locale switching on the module's own backend produces translated
      labels for at least one well-known msgid (regression guard for
      the `priv/gettext/<locale>/LC_MESSAGES/default.po` shipping with
      the package).
    * Falls back to the raw msgid for an unknown locale.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Gettext, as: NewslettersGettext

  setup do
    original = Gettext.get_locale(NewslettersGettext)
    on_exit(fn -> Gettext.put_locale(NewslettersGettext, original) end)
    :ok
  end

  describe "admin_tabs/0 wiring" do
    test "every tab carries the module's own gettext backend" do
      for tab <- Newsletters.admin_tabs() do
        assert tab.gettext_backend == NewslettersGettext,
               "Tab #{inspect(tab.id)} is missing or wrong gettext_backend " <>
                 "(got #{inspect(tab.gettext_backend)})"

        assert tab.gettext_domain == "default"
      end
    end

    test "every tab label has a non-identity ru translation (drift guard)" do
      Gettext.put_locale(NewslettersGettext, "ru")

      for tab <- Newsletters.admin_tabs() do
        translated = Tab.localized_label(tab)

        refute translated == tab.label,
               "Tab #{inspect(tab.id)} label #{inspect(tab.label)} has no ru " <>
                 "translation in priv/gettext/ru/LC_MESSAGES/default.po. " <>
                 "Add the msgid to default.pot and run `mix gettext.merge priv/gettext`."
      end
    end
  end

  describe "catalogue parity" do
    @locales ["en", "et", "ru"]

    defp msgids(path) do
      path
      |> File.read!()
      |> then(&Regex.scan(~r/^msgid "(.+)"$/m, &1))
      |> Enum.map(fn [_, msgid] -> msgid end)
      |> MapSet.new()
    end

    # A new gettext call reaches the .pot the moment someone runs the
    # extractor, but the .po files only follow if the merge is run too —
    # and a msgid missing from a locale renders as raw English with no
    # error anywhere. Compare the sets instead of waiting for a translator
    # to notice.
    test "every msgid in default.pot exists in every locale's catalogue" do
      template = msgids("priv/gettext/default.pot")

      for locale <- @locales do
        path = "priv/gettext/#{locale}/LC_MESSAGES/default.po"
        missing = MapSet.difference(template, msgids(path))

        assert MapSet.size(missing) == 0,
               "#{path} is missing #{MapSet.size(missing)} msgid(s) present in " <>
                 "default.pot: #{inspect(MapSet.to_list(missing))}. " <>
                 "Run `mix gettext.merge priv/gettext` and translate them."
      end
    end

    # Merging leaves a new entry with an empty msgstr, which gettext
    # silently renders as the raw msgid — so a merged-but-untranslated
    # catalogue looks exactly like a translated one at runtime. The header
    # entry (empty msgid) is excluded by requiring a non-empty msgid.
    test "no locale carries an untranslated entry" do
      for locale <- @locales do
        path = "priv/gettext/#{locale}/LC_MESSAGES/default.po"

        untranslated =
          ~r/^msgid "(.+)"\nmsgstr ""$/m
          |> Regex.scan(File.read!(path))
          |> Enum.map(fn [_, msgid] -> msgid end)

        assert untranslated == [],
               "#{path} has #{length(untranslated)} msgid(s) with an empty " <>
                 "translation: #{inspect(untranslated)}"
      end
    end
  end

  describe "Tab.localized_label/1 against the module's catalogue" do
    test "ru locale resolves the parent 'Newsletters' tab to 'Рассылки'" do
      Gettext.put_locale(NewslettersGettext, "ru")

      parent = Enum.find(Newsletters.admin_tabs(), &(&1.id == :admin_newsletters))
      assert Tab.localized_label(parent) == "Рассылки"
    end

    test "et locale resolves the parent 'Newsletters' tab to 'Uudiskirjad'" do
      Gettext.put_locale(NewslettersGettext, "et")

      parent = Enum.find(Newsletters.admin_tabs(), &(&1.id == :admin_newsletters))
      assert Tab.localized_label(parent) == "Uudiskirjad"
    end

    test "unknown locale falls back to the raw msgid" do
      Gettext.put_locale(NewslettersGettext, "zz")

      parent = Enum.find(Newsletters.admin_tabs(), &(&1.id == :admin_newsletters))
      assert Tab.localized_label(parent) == "Newsletters"
    end
  end
end
