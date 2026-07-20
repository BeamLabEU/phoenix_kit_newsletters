defmodule PhoenixKit.Newsletters.PreferenceToken do
  @moduledoc """
  Signs/verifies the subscription preference center's login-free access
  token — `%{contact_uuid: uuid}`.

  Deliberately a **different salt** (`"newsletters_preferences"`) than the
  per-list unsubscribe token (`"unsubscribe"`, `UnsubscribeController`/
  `DeliveryWorker`). The two tokens grant different capabilities — a
  per-list unsubscribe token can only remove one specific membership,
  while a preference-center token opens the full self-service surface
  (every subscribable list, plus the global opt-out/resubscribe toggle)
  for whichever contact it names. `Phoenix.Token.verify/4` refuses a
  token signed under a different salt outright, so keeping them on
  separate salts means a leaked/forwarded per-list unsubscribe link can
  never be replayed against the broader preference page, and vice versa
  — the two capability classes stay non-interchangeable even though both
  ultimately key off the same `contact_uuid`.

  Same `max_age` as the existing unsubscribe token (7 days) — this link
  rides in the same broadcast emails.
  """

  @salt "newsletters_preferences"
  @max_age 604_800

  @doc "Signs a `contact_uuid` into a preference-center access token."
  @spec sign(String.t()) :: String.t()
  def sign(contact_uuid) when is_binary(contact_uuid) do
    endpoint = PhoenixKit.Config.get(:endpoint, PhoenixKitWeb.Endpoint)
    Phoenix.Token.sign(endpoint, @salt, %{contact_uuid: contact_uuid})
  end

  @doc """
  Verifies a preference-center token, returning the `contact_uuid` it
  names. `{:error, :invalid}` for anything malformed, expired, or signed
  under a different salt — deliberately not distinguished further, so a
  crafted/stale token never leaks which failure mode it hit.
  """
  @spec verify(String.t()) :: {:ok, String.t()} | {:error, :invalid}
  def verify(token) when is_binary(token) do
    endpoint = PhoenixKit.Config.get(:endpoint, PhoenixKitWeb.Endpoint)

    case Phoenix.Token.verify(endpoint, @salt, token, max_age: @max_age) do
      {:ok, %{contact_uuid: contact_uuid}} -> {:ok, contact_uuid}
      _ -> {:error, :invalid}
    end
  end

  def verify(_), do: {:error, :invalid}
end
