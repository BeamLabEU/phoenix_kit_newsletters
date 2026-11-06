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

  # The worker has already read this recipient's membership, for its links.
  def for_recipient(%{language: language}, _broadcast) do
    language || RecipientLocale.for_rendering(nil)
  end

  def for_recipient(%{email: email}, %{crm_list_uuid: list_uuid})
      when is_binary(email) and is_binary(list_uuid) do
    CRMSource.recipient_locale(list_uuid, email) || RecipientLocale.for_rendering(nil)
  end

  def for_recipient(_recipient, _broadcast), do: RecipientLocale.for_rendering(nil)

  @doc """
  The language to answer a CRM recipient in on a public page their email links
  to: the contact's own, else the list's (`nil` when the link names none), else
  the site's content language. The order `for_recipient/2` uses for the email, so
  the page reads like the message it was opened from. Never `nil`.
  """
  @spec for_contact(map(), map() | nil) :: String.t()
  def for_contact(contact, list \\ nil) do
    stated(contact) || stated(list) || RecipientLocale.for_rendering(nil)
  end

  @doc "The language a contact or a list states for itself, or `nil`."
  @spec stated(map() | nil) :: String.t() | nil
  def stated(%{locale: locale}) when is_binary(locale) and locale != "", do: locale
  def stated(_record), do: nil
end
