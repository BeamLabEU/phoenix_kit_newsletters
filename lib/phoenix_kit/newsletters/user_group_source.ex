defmodule PhoenixKit.Newsletters.UserGroupSource do
  @moduledoc """
  Recipient source resolving to core users assigned one or more roles —
  the "user_group = roles" source (Stage 4 restructuring, spec §1/§7:
  "no new group entity — roles serve as groups"). Unlike `CRMSource`,
  `PhoenixKit.Users.Roles` and `PhoenixKit.Users.Auth.User` are a hard
  runtime dependency of newsletters already (core itself is required),
  so no soft-dependency dance is needed to call them directly. Only the
  opt-out check below reaches into `phoenix_kit_crm`, which stays a
  genuinely optional module — guarded the same `Code.ensure_loaded?/1` +
  `apply/3` pattern `CRMSource` already uses for its own plain (non-
  `from`/`join`) calls.

  A user is sendable when active (`is_active`) and — only when the CRM
  module is installed — their linked contact (if any) hasn't opted out.
  Opt-out lives on the contact, not the user, per the restructuring
  spec's single-home-for-opt-out decision (§4.2/§7): a user with no
  linked contact has never been through the preference center and is
  therefore never opted out. `no_email` is realistically always 0 here
  — core `users.email` is `NOT NULL` — kept in `preflight/1`'s result
  only for shape parity with `CRMSource.preflight/1`.
  """

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Roles

  @contacts_mod PhoenixKitCRM.Contacts

  @doc "All role names, for the broadcast editor's role multi-select."
  @spec list_role_names() :: [String.t()]
  def list_role_names do
    Roles.list_roles() |> Enum.map(& &1.name)
  end

  @doc """
  Sendable recipients across one or more roles — active users whose
  linked contact (if any) hasn't opted out, deduplicated by user (a
  user assigned more than one of the given roles is only sent to once).

  Returns `[%{user_uuid: uuid, email: string}]`, sorted by email for a
  stable, deterministic order.
  """
  @spec sendable_recipients([String.t()]) :: [%{user_uuid: String.t(), email: String.t()}]
  def sendable_recipients(role_names) when is_list(role_names) do
    role_names
    |> users_for_roles()
    |> Enum.filter(&sendable?/1)
    |> Enum.map(&%{user_uuid: &1.uuid, email: &1.email})
    |> Enum.sort_by(& &1.email)
  end

  @doc """
  Preflight breakdown across one or more roles, for the broadcast
  editor's "N users: M sendable, K no email, L unsendable" summary —
  same shape as `CRMSource.preflight/1`. `unsendable` covers both
  deactivated users and (when CRM is installed) opted-out ones.
  """
  @spec preflight([String.t()]) :: %{
          total: non_neg_integer(),
          sendable: non_neg_integer(),
          no_email: non_neg_integer(),
          unsendable: non_neg_integer()
        }
  def preflight(role_names) when is_list(role_names) do
    users = users_for_roles(role_names)
    total = length(users)
    sendable = Enum.count(users, &sendable?/1)
    no_email = Enum.count(users, &(&1.email in [nil, ""]))

    %{
      total: total,
      sendable: sendable,
      no_email: no_email,
      unsendable: total - sendable - no_email
    }
  end

  defp users_for_roles(role_names) do
    role_names
    |> Enum.flat_map(&Roles.users_with_role/1)
    |> Enum.uniq_by(& &1.uuid)
  end

  defp sendable?(%User{is_active: false}), do: false
  defp sendable?(%User{email: email}) when email in [nil, ""], do: false
  defp sendable?(%User{} = user), do: not opted_out?(user)

  defp opted_out?(%User{uuid: user_uuid}) do
    if crm_available?() do
      case soft_get_by_user_uuid(user_uuid) do
        %{opted_out_at: opted_out_at} -> not is_nil(opted_out_at)
        nil -> false
      end
    else
      false
    end
  end

  defp crm_available?, do: Code.ensure_loaded?(@contacts_mod)

  # Intentional apply/3 — calls an optional soft-dependency module to avoid
  # a compile-time dependency on the CRM package (mirrors CRMSource's
  # soft_call/3).
  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp soft_get_by_user_uuid(user_uuid), do: apply(@contacts_mod, :get_by_user_uuid, [user_uuid])
end
