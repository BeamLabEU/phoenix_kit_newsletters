defmodule PhoenixKit.Newsletters.UserGroupSource do
  @moduledoc """
  Recipient source resolving to core users assigned one or more roles —
  the "user_group = roles" source (Stage 4 restructuring, spec §1/§7:
  "no new group entity — roles serve as groups"). Unlike `CRMSource`,
  `PhoenixKit.Users.Role`/`RoleAssignment` and `PhoenixKit.Users.Auth.User`
  are a hard runtime dependency of newsletters already (core itself is
  required), so no soft-dependency dance is needed to query them
  directly. `CRMSource.get_contact_by_user_uuid/1` — itself soft-dep
  guarded — is the only place this module reaches toward
  `phoenix_kit_crm`, which stays a genuinely optional module.

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

  Deduplication is by **user** (`distinct: u.uuid` in
  `users_for_role_uuids/1`), not by address the way `CRMSource` dedups
  its CRM-contact recipients — `phoenix_kit_users.email` carries a
  `UNIQUE` index, so for core users the two are equivalent; `CRMSource`
  dedups by address instead because two distinct CRM contacts can
  legitimately share one mailbox, which two distinct core users cannot.

  A user is sendable when active (`is_active`) and not opted out.
  Opt-out is checked two ways, since a role-sourced recipient may have
  no CRM contact at all: the user's own
  `custom_fields["newsletters_opted_out_at"]` (always checked — this is
  the only opt-out state a role recipient has when the CRM module isn't
  installed, or they've never been linked to a contact), **or**, when CRM is
  installed and a linked contact exists, that contact's `opted_out_at`
  (kept in sync with the contact-level opt-out CRM-list recipients
  already use, so opting out once covers both recipient sources for
  someone who happens to be both). `record_opt_out/1` writes both
  applicable places — see its own doc. `no_email` is realistically
  always 0 here — core `users.email` is `NOT NULL` — kept in
  `preflight/1`'s result only for shape parity with
  `CRMSource.preflight/1`.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Role
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Date, as: UtilsDate

  alias PhoenixKit.Newsletters.CRMSource

  # Written/read as an ISO 8601 timestamp string, same shape core's own
  # custom_fields values already use (see Auth.update_user_locale_preference/2).
  @opted_out_custom_field "newsletters_opted_out_at"

  @doc "Every role, for the broadcast editor's role multi-select (uuid + live name)."
  @spec list_roles() :: [Role.t()]
  def list_roles, do: Roles.list_roles()

  @doc """
  Sendable recipients across one or more roles — active, not-opted-out
  users, deduplicated by user (a user assigned more than one of the
  given roles is only sent to once — see the moduledoc on why this
  dedups by user rather than by address). A role uuid that no longer
  matches any role contributes nothing — doesn't raise.

  Returns `[%{user_uuid: uuid, email: string}]`, sorted by email for a
  stable, deterministic order.
  """
  @spec sendable_recipients([String.t()]) :: [%{user_uuid: String.t(), email: String.t()}]
  def sendable_recipients(role_uuids) when is_list(role_uuids) do
    users = users_for_role_uuids(role_uuids)
    contacts_by_user_uuid = batch_contacts_by_user_uuid(users)

    users
    |> Enum.filter(&sendable?(&1, contacts_by_user_uuid))
    |> Enum.map(&%{user_uuid: &1.uuid, email: &1.email})
    |> Enum.sort_by(& &1.email)
  end

  @doc """
  Preflight breakdown across one or more roles, for the broadcast
  editor's "N users: M sendable, K no email, L unsendable" summary —
  same shape as `CRMSource.preflight/1`, plus `stale_roles`: how many of
  the given uuids no longer match any role at all (renamed roles are
  never stale — only genuinely deleted/garbage uuids are — see the
  moduledoc). `role_uuids` is deduplicated first — a uuid repeated in
  the input must not inflate the stale count against
  `existing_role_count/1`, which already reports distinct matches.
  `unsendable` covers both deactivated users and opted-out ones (either
  opt-out path — see the moduledoc).
  """
  @spec preflight([String.t()]) :: %{
          total: non_neg_integer(),
          sendable: non_neg_integer(),
          no_email: non_neg_integer(),
          unsendable: non_neg_integer(),
          stale_roles: non_neg_integer()
        }
  def preflight(role_uuids) when is_list(role_uuids) do
    role_uuids = Enum.uniq(role_uuids)
    users = users_for_role_uuids(role_uuids)
    contacts_by_user_uuid = batch_contacts_by_user_uuid(users)
    total = length(users)
    sendable = Enum.count(users, &sendable?(&1, contacts_by_user_uuid))
    no_email = Enum.count(users, &(&1.email in [nil, ""]))

    %{
      total: total,
      sendable: sendable,
      no_email: no_email,
      unsendable: total - sendable - no_email,
      stale_roles: length(role_uuids) - existing_role_count(role_uuids)
    }
  end

  @doc """
  Whether `user` has opted out of role-sourced newsletters — checked
  both ways sendable?/1 does (see moduledoc): their own
  `custom_fields["#{@opted_out_custom_field}"]`, or (when CRM is
  installed) their linked contact's `opted_out_at`. Exposed for
  `UnsubscribeController`'s landing page to show the right state
  without duplicating either check.
  """
  @spec opted_out?(User.t()) :: boolean()
  def opted_out?(%User{} = user) do
    custom_field_opted_out?(user) or contact_opted_out?(user)
  end

  @doc """
  Records a role recipient's opt-out. Writes **both** applicable
  places, not either/or:

    1. Always: `custom_fields["#{@opted_out_custom_field}"]` on the
       user — the only opt-out state that exists at all when the CRM
       module isn't installed, or this user has never been linked to a
       contact.
    2. Additionally, when CRM is installed and a contact is already
       linked to this user (`CRMSource.get_contact_by_user_uuid/1` —
       looks up an existing link only, never creates one): that
       contact's `opted_out_at` too, via the same `CRMSource.opt_out/1`
       CRM-list recipients already use — so the one opt-out action
       covers both recipient sources for someone who happens to be
       both, and the contact-level state CRM-list sends check stays
       consistent.

  Idempotent either way: the custom_fields opt-out state is idempotent
  — the stored timestamp simply refreshes on a repeat call — and
  `CRMSource.opt_out/1` is already idempotent on an already-opted-out
  contact.

  The custom_fields write is the source of truth this function's return
  value reflects; a failure opting out the *linked contact* (CRM down,
  a changeset error) does not fail the overall call — the role-sourced
  opt-out already succeeded and future `sendable_recipients/1` calls
  already honor it — but is not silent either: it's logged, since it
  leaves the contact-level state (which CRM-list sends check) out of
  sync until it's retried.
  """
  @spec record_opt_out(User.t()) :: {:ok, User.t()} | {:error, term()}
  def record_opt_out(%User{} = user) do
    case set_custom_field_opted_out(user) do
      {:ok, updated_user} ->
        maybe_opt_out_linked_contact(updated_user)
        {:ok, updated_user}

      {:error, _reason} = error ->
        error
    end
  end

  defp set_custom_field_opted_out(user) do
    current_fields = user.custom_fields || %{}
    timestamp = UtilsDate.utc_now() |> DateTime.to_iso8601()
    updated_fields = Map.put(current_fields, @opted_out_custom_field, timestamp)

    Auth.update_user_custom_fields(user, updated_fields,
      ensure_definitions: false,
      broadcast: false
    )
  end

  defp maybe_opt_out_linked_contact(user) do
    case CRMSource.get_contact_by_user_uuid(user.uuid) do
      %{} = contact ->
        case CRMSource.opt_out(contact) do
          {:ok, _contact} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "UserGroupSource.record_opt_out/1: role opt-out for user #{user.uuid} " <>
                "succeeded, but opting out its linked CRM contact #{contact.uuid} failed: " <>
                "#{inspect(reason)}. That contact's opted_out_at was not updated — CRM-list " <>
                "sends to it won't reflect this opt-out until it's retried."
            )
        end

      nil ->
        :ok
    end
  end

  # One query for every user in the batch instead of sendable?/1 (below)
  # calling CRMSource.get_contact_by_user_uuid/1 per row — sendable_recipients/1
  # and preflight/1 (the editor recomputes the latter on every role-checkbox
  # click) would otherwise be an N+1 against the CRM contacts table for any
  # role set whose users don't already carry the custom_fields opt-out flag
  # (the common case). The single-user opted_out?/1 below is unrelated —
  # a lookup for exactly one user has no batch to make.
  defp batch_contacts_by_user_uuid(users) do
    users |> Enum.map(& &1.uuid) |> CRMSource.get_contacts_by_user_uuids()
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

  defp sendable?(%User{is_active: false}, _contacts_by_user_uuid), do: false
  defp sendable?(%User{email: email}, _contacts_by_user_uuid) when email in [nil, ""], do: false

  defp sendable?(%User{} = user, contacts_by_user_uuid) do
    not custom_field_opted_out?(user) and
      not batch_contact_opted_out?(user, contacts_by_user_uuid)
  end

  defp custom_field_opted_out?(%User{custom_fields: fields}) do
    is_map(fields) and not is_nil(Map.get(fields, @opted_out_custom_field))
  end

  defp batch_contact_opted_out?(%User{uuid: user_uuid}, contacts_by_user_uuid) do
    case Map.get(contacts_by_user_uuid, user_uuid) do
      %{opted_out_at: opted_out_at} -> not is_nil(opted_out_at)
      nil -> false
    end
  end

  defp contact_opted_out?(%User{uuid: user_uuid}) do
    case CRMSource.get_contact_by_user_uuid(user_uuid) do
      %{opted_out_at: opted_out_at} -> not is_nil(opted_out_at)
      nil -> false
    end
  end
end
