defmodule PhoenixKit.Newsletters.UnsubscribeToken do
  @moduledoc """
  The signed tokens in a broadcast's unsubscribe links.

  Two flavours, each under its own salt, so a token can never be read as the
  other kind:

    * a CRM recipient's: `%{contact_uuid: _, crm_list_uuid: _}`, salt `"unsubscribe"`;
    * a role recipient's: `%{user_uuid: _}`, salt `"newsletters_user_optout"`,
      which `verify/1` answers as `{:role_optout, claims}`.

  ## No expiry

  Mail is read long after it was sent, and an opt-out has to keep working: a
  link that dies leaves the person with no way to stop the mail, and a mail
  client's one-click POST gets its 200 regardless, so it reports success for
  nothing. These tokens can only reduce what someone receives, so a leaked one
  costs little. `PhoenixKit.Newsletters.PreferenceToken`, which can also
  resubscribe, keeps a limit.

  A token signed under `"unsubscribe"` before the newsletters-owned lists were
  removed (`%{user_uuid: _, list_uuid: _}`) still verifies, and with no expiry it
  always will. Callers match on claim shape, so it falls through to their
  invalid-link path.
  """

  alias PhoenixKit.Config

  @list_salt "unsubscribe"
  @role_salt "newsletters_user_optout"

  @doc "A token for one CRM list's recipient."
  @spec sign_list(String.t(), String.t()) :: String.t()
  def sign_list(contact_uuid, crm_list_uuid) do
    Phoenix.Token.sign(endpoint(), @list_salt, %{
      contact_uuid: contact_uuid,
      crm_list_uuid: crm_list_uuid
    })
  end

  @doc "A token for a role recipient."
  @spec sign_role(String.t()) :: String.t()
  def sign_role(user_uuid) do
    Phoenix.Token.sign(endpoint(), @role_salt, %{user_uuid: user_uuid})
  end

  @doc """
  Verifies a token under either salt: a token only verifies under the one it was
  signed with, so trying both accepts either kind and weakens neither.
  """
  @spec verify(term()) :: {:ok, map()} | {:role_optout, map()} | {:error, atom()}
  def verify(token) when is_binary(token) do
    endpoint = endpoint()

    case Phoenix.Token.verify(endpoint, @list_salt, token, max_age: :infinity) do
      {:ok, _claims} = ok ->
        ok

      {:error, _reason} ->
        case Phoenix.Token.verify(endpoint, @role_salt, token, max_age: :infinity) do
          {:ok, claims} -> {:role_optout, claims}
          {:error, _reason} = error -> error
        end
    end
  end

  def verify(_token), do: {:error, :invalid}

  @doc """
  What every token here is signed with.

  An explicit `config :phoenix_kit, endpoint: ...` wins, then the host's own
  endpoint. `PhoenixKitWeb.Endpoint` comes last: it ships in core but nothing
  starts it in a host app, and asking it for a secret raises, so reaching it
  there would fail every delivery and every unsubscribe.
  """
  @spec endpoint() :: module() | String.t()
  def endpoint do
    with :not_found <- Config.get(:endpoint),
         :error <- Config.get_parent_endpoint() do
      PhoenixKitWeb.Endpoint
    else
      {:ok, endpoint} -> endpoint
    end
  end
end
