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
