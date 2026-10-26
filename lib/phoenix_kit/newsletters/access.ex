defmodule PhoenixKit.Newsletters.Access do
  @moduledoc """
  What the admin pages ask on top of the base `newsletters` key, which covers
  drafting broadcasts and managing layouts.

    * `newsletters.send` — actually send a broadcast: Send now, Schedule, and
      Retry on the details page.
    * `newsletters.audiences` — see who a broadcast reaches: the per-recipient
      delivery list on the details page and the address verification page.
    * `crm` (the CRM module's own key) — a CRM contact list is offered,
      previewed, saved or sent only for a viewer who also holds it; without
      it the editor offers role audiences only.

  Checks go through `PhoenixKit.Users.Auth.Scope.can?/2`, so Owner (who holds
  no permission rows) passes and a disabled module grants nothing.
  """

  alias PhoenixKit.Newsletters.CRMSource
  alias PhoenixKit.Users.Auth.Scope

  @send "newsletters.send"
  @audiences "newsletters.audiences"

  @doc "The key that lets a user send or schedule a broadcast."
  @spec send_key() :: String.t()
  def send_key, do: @send

  @doc "The key that lets a user see recipient addresses."
  @spec audiences_key() :: String.t()
  def audiences_key, do: @audiences

  @doc "True when the scope may send, schedule or retry a broadcast."
  @spec can_send?(term()) :: boolean()
  def can_send?(scope), do: Scope.can?(scope, @send)

  @doc "True when the scope may see recipient lists and addresses."
  @spec can_see_audiences?(term()) :: boolean()
  def can_see_audiences?(scope), do: Scope.can?(scope, @audiences)

  @doc """
  True when CRM contact lists may be offered and resolved for this scope:
  the CRM module is installed and the viewer holds its `crm` key.
  """
  @spec crm_lists?(term()) :: boolean()
  def crm_lists?(scope), do: CRMSource.available?() and Scope.can?(scope, "crm")

  @doc "The current scope from a LiveView socket."
  @spec scope(Phoenix.LiveView.Socket.t()) :: term()
  def scope(socket), do: socket.assigns[:phoenix_kit_current_scope]
end
