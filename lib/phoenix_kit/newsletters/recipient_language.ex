defmodule PhoenixKit.Newsletters.RecipientLanguage do
  @moduledoc """
  The language one broadcast email is rendered in, per recipient.

    * A role recipient is a core user: core's
      `PhoenixKit.Utils.RecipientLocale.for_rendering/1` — the user's
      preferred locale, else the site's content language, else `"en"`.
    * A CRM recipient has no user of its own: the contact's `locale`, else
      the list's `locale`, else the site's content language (same final
      fallback as a user without a preference).

  The result picks the layout's translation (`PhoenixKit.Newsletters.Layout.translation/3`
  narrows a dialect to its base, then falls back further) and core's
  header/footer files.
  """

  alias PhoenixKit.Newsletters.CRMSource
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.RecipientLocale

  @doc "The language to render `broadcast` in for `recipient`. Never `nil`."
  @spec for_recipient(map(), map()) :: String.t()
  def for_recipient(%User{} = user, _broadcast), do: RecipientLocale.for_rendering(user)

  def for_recipient(%{email: email}, %{crm_list_uuid: list_uuid})
      when is_binary(email) and is_binary(list_uuid) do
    CRMSource.recipient_locale(list_uuid, email) || RecipientLocale.for_rendering(nil)
  end

  def for_recipient(_recipient, _broadcast), do: RecipientLocale.for_rendering(nil)
end
