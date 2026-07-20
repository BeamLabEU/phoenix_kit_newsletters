defmodule PhoenixKit.Newsletters.UserGroupSource do
  @moduledoc """
  Recipient source resolving to core users assigned one or more roles —
  the "user_group = roles" source (Stage 4 restructuring, spec §1/§7:
  "no new group entity — roles serve as groups"). Unlike `CRMSource`,
  `PhoenixKit.Users.Role`/`RoleAssignment` and `PhoenixKit.Users.Auth.User`
  are a hard runtime dependency of newsletters already (core itself is
  required), so no soft-dependency dance is needed to query them
  directly. Only the opt-out check below reaches into `phoenix_kit_crm`,
  which stays a genuinely optional module — guarded the same
  `Code.ensure_loaded?/1` + `apply/3` pattern `CRMSource` already uses
  for its own plain (non-`from`/`join`) calls.

  Resolution is by role **uuid**, not name — a role's `name` is mutable
  (`Roles.update_role/2` doesn't protect it, not even for system roles),
  so a broadcast that stored names would silently re-target (or empty
  out) whatever the role gets renamed to. `Broadcast.role_uuids/1` is
  the only input these functions take; `Broadcast.role_names_snapshot/1`
  is a separate, display-only concern this module never touches. A
  stale uuid (its role renamed-and-since-untracked is impossible — see
  above — but genuinely deleted, or simply garbage) contributes nothing
  and does not raise; the direct `role_uuid in ^role_uuids` query below
  has no dependency on the role even still existing.

  A user is sendable when active (`is_active`) and — only when the CRM
  module is installed — their linked contact (if any) hasn't opted out.
  Opt-out lives on the contact, not the user, per the restructuring
  spec's single-home-for-opt-out decision (§4.2/§7): a user with no
  linked contact has never been through the preference center and is
  therefore never opted out. `no_email` is realistically always 0 here
  — core `users.email` is `NOT NULL` — kept in `preflight/1`'s result
  only for shape parity with `CRMSource.preflight/1`.
  """

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Role
  alias PhoenixKit.Users.Roles

  @contacts_mod PhoenixKitCRM.Contacts

  @doc "Every role, for the broadcast editor's role multi-select (uuid + live name)."
  @spec list_roles() :: [Role.t()]
  def list_roles, do: Roles.list_roles()

  @doc """
  Sendable recipients across one or more roles — active users whose
  linked contact (if any) hasn't opted out, deduplicated by user (a
  user assigned more than one of the given roles is only sent to once).
  A role uuid that no longer matches any role contributes nothing —
  doesn't raise.

  Returns `[%{user_uuid: uuid, email: string}]`, sorted by email for a
  stable, deterministic order.
  """
  @spec sendable_recipients([String.t()]) :: [%{user_uuid: String.t(), email: String.t()}]
  def sendable_recipients(role_uuids) when is_list(role_uuids) do
    role_uuids
    |> users_for_role_uuids()
    |> Enum.filter(&sendable?/1)
    |> Enum.map(&%{user_uuid: &1.uuid, email: &1.email})
    |> Enum.sort_by(& &1.email)
  end

  @doc """
  Preflight breakdown across one or more roles, for the broadcast
  editor's "N users: M sendable, K no email, L unsendable" summary —
  same shape as `CRMSource.preflight/1`, plus `stale_roles`: how many of
  the given uuids no longer match any role at all (renamed roles are
  never stale — only genuinely deleted/garbage uuids are — see the
  moduledoc). `unsendable` covers both deactivated users and (when CRM
  is installed) opted-out ones.
  """
  @spec preflight([String.t()]) :: %{
          total: non_neg_integer(),
          sendable: non_neg_integer(),
          no_email: non_neg_integer(),
          unsendable: non_neg_integer(),
          stale_roles: non_neg_integer()
        }
  def preflight(role_uuids) when is_list(role_uuids) do
    users = users_for_role_uuids(role_uuids)
    total = length(users)
    sendable = Enum.count(users, &sendable?/1)
    no_email = Enum.count(users, &(&1.email in [nil, ""]))

    %{
      total: total,
      sendable: sendable,
      no_email: no_email,
      unsendable: total - sendable - no_email,
      stale_roles: length(role_uuids) - existing_role_count(role_uuids)
    }
  end

  defp users_for_role_uuids([]), do: []

  defp users_for_role_uuids(role_uuids) do
    from(u in User,
      join: a in assoc(u, :role_assignments),
      where: a.role_uuid in ^role_uuids,
      distinct: u.uuid
    )
    |> RepoHelper.repo().all()
  end

  defp existing_role_count([]), do: 0

  defp existing_role_count(role_uuids) do
    Role
    |> where([r], r.uuid in ^role_uuids)
    |> RepoHelper.repo().aggregate(:count)
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
