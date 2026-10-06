defmodule PhoenixKit.Newsletters.Web.LanguageOptions do
  @moduledoc """
  The languages the admin screens offer: the site's enabled languages when
  the Languages module is on, else just the site's content language — the
  same list the email-template editor offers.
  """

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings

  @doc "The site's languages, content language first. Never empty."
  @spec site_languages() :: [String.t()]
  def site_languages do
    content = content_language()

    enabled =
      if Languages.enabled?(),
        do: Languages.get_enabled_language_codes(),
        else: []

    Enum.uniq([content | enabled])
  rescue
    _ -> [content_language()]
  end

  defp content_language do
    case Settings.get_content_language() do
      language when is_binary(language) and language != "" -> language
      _ -> "en"
    end
  rescue
    _ -> "en"
  end
end
