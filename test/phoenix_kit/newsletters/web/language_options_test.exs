defmodule PhoenixKit.Newsletters.Web.LanguageOptionsTest do
  @moduledoc """
  The admin screens' languages against core's own Languages API — which, as
  of core 2.50, is part of core rather than a registered module, so it is
  called directly (`Languages.enabled?/0` is the site's multi-language
  switch), never looked up in the module registry.
  """

  use PhoenixKitNewsletters.DataCase, async: false

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Newsletters.Web.BroadcastEditor
  alias PhoenixKit.Newsletters.Web.LanguageOptions
  alias PhoenixKit.Settings

  test "multi-language off: just the site's content language" do
    refute Languages.enabled?()
    assert LanguageOptions.site_languages() == [Settings.get_content_language()]
  end

  describe "multi-language on" do
    setup do
      {:ok, _} = Languages.enable_system()
      {:ok, _} = Languages.add_language("de-DE")
      :ok
    end

    test "the content language first, then every enabled language" do
      [first | _] = languages = LanguageOptions.site_languages()

      assert first == Settings.get_content_language()
      assert "de-DE" in languages
      assert languages == Enum.uniq(languages)
    end

    test "a layout's own languages are kept even when the site does not offer them" do
      assert "zz" in LanguageOptions.with_languages(["zz"])
      assert "de-DE" in LanguageOptions.with_languages(["zz"])
    end

    test "the broadcast editor's preview offers them, and accepts a switch to one" do
      PhoenixKit.Settings.update_boolean_setting("newsletters_enabled", true)

      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, flash: %{}, live_action: :new}
      }

      {:ok, socket} = BroadcastEditor.mount(%{}, %{}, socket)
      {:noreply, socket} = BroadcastEditor.handle_params(%{}, "/", socket)

      assert "de-DE" in socket.assigns.preview_languages
      assert socket.assigns.preview_locale == Settings.get_content_language()

      {:noreply, socket} =
        BroadcastEditor.handle_event(
          "validate",
          %{"preview_locale" => "de-DE", "markdown" => "Hallo"},
          %{socket | assigns: Map.put(socket.assigns, :markdown_content, "Hallo")}
        )

      assert socket.assigns.preview_locale == "de-DE"
      assert socket.assigns.preview_html =~ "Hallo"
    end
  end
end
