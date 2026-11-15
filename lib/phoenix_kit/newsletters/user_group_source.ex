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

  Resolution is by role **uuid**, not name. Since core 3.5 a role's `name` is a
  fixed key and people see its translated label (`Roles.display_name/2`), but
  broadcasts saved earlier, when a name could still change, hold uuids, and a
  uuid is the key every other module uses. `Broadcast.role_uuids/1` is the only
  input the resolvers take; `Broadcast.role_names_snapshot/1` holds the names,
  for display only, through `role_labels/1`. A stale uuid (a deleted role, or
  garbage) contributes nothing and does not raise; the direct
  `role_uuid in ^role_uuids` query below has no dependency on the role still
  existing.

  Deduplication is by user (`distinct: u.uuid` in `users_query/1`), then by
  address, as `CRMSource` does: a login is unique, but the address mail goes to is
  not. A managed organization's `contact_email` can be shared with another
  organization or with a member's own login, and one inbox gets one copy.

  A user is sendable when active (`is_active`), reachable, confirmed and not
  opted out. Reachable means `delivery_address/1` finds an address: a managed
  organization's mail goes to its `contact_email`, and an account's
  reserved `.invalid` login address never receives any. Confirmed is core's rule
  for mail nobody asked for (`Auth.unsolicited_mail_allowed?/1`, core 3.6),
  repeated in `confirmed?/2` so the floor stays at 3.5: an address nobody proved
  may be a typo or made up, and every newsletter to it is a bounce or a
  complaint against the sender.
  Opt-out is checked two ways, since a role-sourced recipient may have
  no CRM contact at all: the user's own
  `custom_fields["newsletters_opted_out_at"]` (always checked — this is
  the only opt-out state a role recipient has when the CRM module isn't
  installed, or they've never been linked to a contact), **or**, when CRM is
  installed and a linked contact exists, that contact's `opted_out_at`
  (kept in sync with the contact-level opt-out CRM-list recipients
  already use, so opting out once covers both recipient sources for
  someone who happens to be both). `record_opt_out/1` writes both
  applicable places — see its own doc. `no_email` counts the users
  `delivery_address/1` finds nothing for.
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
  alias PhoenixKit.Newsletters.EmailVerification

  # Written/read as an ISO 8601 timestamp string, same shape core's own
  # custom_fields values already use (see Auth.update_user_locale_preference/2).
  @opted_out_custom_field "newsletters_opted_out_at"

  @doc """
  Every role, for the role pickers of the editor and the verification page. Show
  each one with `role_label/1`; `name` is the key a broadcast's snapshot keeps.
  """
  @spec list_roles() :: [Role.t()]
  def list_roles, do: Roles.list_roles()

  @doc "What people call `role` in the current language (core's translated label)."
  @spec role_label(Role.t()) :: String.t()
  def role_label(%Role{} = role), do: Roles.display_name(role)

  @doc """
  The labels of the roles a broadcast's `role_names_snapshot` names, in the
  current language. A role deleted since keeps the name it was saved with.
  """
  @spec role_labels([String.t()]) :: [String.t()]
  def role_labels([]), do: []

  def role_labels(names) when is_list(names) do
    labels = Roles.display_names()
    Enum.map(names, &Map.get(labels, &1, &1))
  end

  @doc """
  Sendable recipients across one or more roles — active, not-opted-out
  users, deduplicated by user and then by address (see the moduledoc). A role
  uuid that no longer matches any role contributes nothing — doesn't raise.

  Returns `[%{user_uuid: uuid, email: string}]`, sorted by email for a
  stable, deterministic order.
  """
  @spec sendable_recipients([String.t()]) :: [%{user_uuid: String.t(), email: String.t()}]
  def sendable_recipients(role_uuids) when is_list(role_uuids) do
    users = users_for_role_uuids(role_uuids)
    context = sendable_context(users)

    users
    |> Enum.filter(&sendable?(&1, context))
    |> Enum.map(&%{user_uuid: &1.uuid, email: delivery_address(&1)})
    |> Enum.sort_by(&{String.downcase(&1.email), &1.user_uuid})
    |> Enum.uniq_by(&String.downcase(&1.email))
  end

  @doc "How many of these role uuids no longer match a role. Reads the roles only."
  @spec stale_role_count([String.t()]) :: non_neg_integer()
  def stale_role_count(role_uuids) when is_list(role_uuids) do
    role_uuids = Enum.uniq(role_uuids)
    length(role_uuids) - existing_role_count(role_uuids)
  end

  @doc """
  Whether the user is, right now, a sendable recipient of these roles — the
  question `sendable_recipients/1` answers for everyone, asked for one user. The
  worker asks it just before sending, because a throttled broadcast can run for
  days after its audience was resolved.
  """
  @spec sendable_recipient?([String.t()], String.t()) :: boolean()
  def sendable_recipient?(role_uuids, user_uuid) when is_list(role_uuids) do
    role_uuids
    |> users_query()
    |> where([u], u.uuid == ^user_uuid)
    |> RepoHelper.repo().all()
    |> Enum.any?(fn user -> sendable?(user, sendable_context([user])) end)
  end

  @doc """
  The address a user's mail goes to, or `nil` when there is none to reach.

  Core's `User.delivery_email/1`, which reads a managed organization's
  `contact_email`. `.invalid` is reserved (RFC 2606) and core gives such
  accounts one on purpose, so it counts as no address.
  """
  @spec delivery_address(User.t()) :: String.t() | nil
  def delivery_address(%User{} = user) do
    address = User.delivery_email(user)

    if deliverable?(address), do: address
  end

  defp deliverable?(address) when is_binary(address) do
    address = address |> String.trim() |> String.downcase()
    address != "" and not String.ends_with?(address, ".invalid")
  end

  defp deliverable?(_address), do: false

  @doc """
  Preflight breakdown across one or more roles, for the broadcast
  editor's "N users: M sendable, K no email, U not confirmed, L
  unsubscribed" summary — same shape as `CRMSource.preflight/1`, plus
  `unconfirmed` and `stale_roles`.
  `unconfirmed` counts the users who would be sendable but for an address they
  never confirmed (see the moduledoc); `stale_roles` is how many of
  the given uuids no longer match any role at all (renamed roles are
  never stale — only genuinely deleted/garbage uuids are — see the
  moduledoc). `role_uuids` is deduplicated first — a uuid repeated in
  the input must not inflate the stale count against
  `existing_role_count/1`, which already reports distinct matches.
  `unsendable` covers both deactivated users and opted-out ones (either
  opt-out path — see the moduledoc). `sendable + no_email + unconfirmed +
  unsendable` is `total`.
  """
  @spec preflight([String.t()]) :: %{
          total: non_neg_integer(),
          sendable: non_neg_integer(),
          no_email: non_neg_integer(),
          unsendable: non_neg_integer(),
          unconfirmed: non_neg_integer(),
          stale_roles: non_neg_integer()
        }
  def preflight(role_uuids) when is_list(role_uuids) do
    role_uuids = Enum.uniq(role_uuids)
    users = users_for_role_uuids(role_uuids)
    context = sendable_context(users)
    total = length(users)
    sendable = Enum.count(users, &sendable?(&1, context))
    no_email = Enum.count(users, &is_nil(delivery_address(&1)))
    # Would be sendable if confirmation were not asked: the users it alone holds back.
    unconfirmed =
      Enum.count(users, &sendable?(&1, %{context | confirmation_required: false})) - sendable

    %{
      total: total,
      sendable: sendable,
      no_email: no_email,
      unsendable: total - sendable - no_email - unconfirmed,
      unconfirmed: unconfirmed,
      stale_roles: stale_role_count(role_uuids)
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

  @doc """
  The opt-out behind "unsubscribed from all newsletters", which promises more
  than a contact row can hold: `CRMSource.opt_out/2` covers every contact at the
  address, and this adds every account delivering there, so role mail stops too.
  This includes managed organizations sharing an inbox and accounts with no
  linked contact for the role check to find.

  The contact side is what the result reports. An account that cannot be written
  is logged, as in `record_opt_out/1`.
  """
  @spec opt_out_contact(struct(), keyword()) :: {:ok, struct()} | {:error, term()}
  def opt_out_contact(contact, opts \\ []) do
    with {:ok, updated} <- CRMSource.opt_out(contact, opts) do
      with_accounts(contact, &set_custom_field_opted_out/1)
      {:ok, updated}
    end
  end

  @doc """
  The way back from `opt_out_contact/2` and `record_opt_out/1`, which set more
  than a contact's `opted_out_at`: left in place, the account's own flag would keep
  role mail blocked after the page says "Welcome back".
  """
  @spec opt_in_contact(struct(), keyword()) :: {:ok, struct()} | {:error, term()}
  def opt_in_contact(contact, opts \\ []) do
    with {:ok, updated} <- CRMSource.opt_in(contact, opts) do
      with_accounts(contact, &clear_custom_field_opted_out/1)
      {:ok, updated}
    end
  end

  defp with_accounts(contact, write) do
    Enum.each(accounts_of(contact), fn user ->
      case write.(user) do
        {:ok, _user} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "UserGroupSource: could not update the opt-out of user #{user.uuid}: " <>
              EmailVerification.mask_addresses(inspect(reason))
          )
      end
    end)
  end

  # A delivery address is not unique: several managed organizations and a
  # personal account can share it. A contact link must not hide those accounts.
  defp accounts_of(contact) do
    linked =
      case Map.get(contact, :user_uuid) do
        uuid when is_binary(uuid) -> dynamic([u], u.uuid == ^uuid)
        _ -> dynamic(false)
      end

    address =
      case Map.get(contact, :email) do
        email when is_binary(email) and email != "" ->
          dynamic(
            [u],
            fragment(
              "lower(CASE WHEN ? THEN ? ELSE ? END) = lower(?)",
              u.managed_by_members,
              u.contact_email,
              u.email,
              ^email
            )
          )

        _ ->
          dynamic(false)
      end

    User
    |> where(^dynamic(^linked or ^address))
    |> RepoHelper.repo().all()
  end

  # The merge and delete writers, not update_user_custom_fields/3: this column is
  # shared with core's own keys, and a whole-map write can lose a concurrent one.
  defp set_custom_field_opted_out(user) do
    timestamp = UtilsDate.utc_now() |> DateTime.to_iso8601()

    Auth.merge_user_custom_fields(user, %{@opted_out_custom_field => timestamp},
      ensure_definitions: false,
      broadcast: false
    )
  end

  defp clear_custom_field_opted_out(user) do
    Auth.delete_user_custom_field(user, @opted_out_custom_field, broadcast: false)
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
                "#{EmailVerification.mask_addresses(inspect(reason))}. That contact's " <>
                "opted_out_at was not updated — CRM-list sends to it won't reflect this " <>
                "opt-out until it's retried."
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
    role_uuids |> users_query() |> RepoHelper.repo().all()
  end

  defp users_query(role_uuids) do
    from(u in User,
      join: a in assoc(u, :role_assignments),
      where: a.role_uuid in ^role_uuids,
      distinct: u.uuid
    )
  end

  defp existing_role_count([]), do: 0

  defp existing_role_count(role_uuids) do
    Role
    |> where([r], r.uuid in ^role_uuids)
    |> RepoHelper.repo().aggregate(:count)
  end

  # What sendable?/2 needs besides the user, read once for a whole batch.
  defp sendable_context(users) do
    %{
      contacts_by_user_uuid: batch_contacts_by_user_uuid(users),
      confirmation_required: confirmation_required?()
    }
  end

  defp sendable?(%User{is_active: false}, _context), do: false

  defp sendable?(%User{} = user, context) do
    not is_nil(delivery_address(user)) and
      confirmed?(user, context.confirmation_required) and
      not custom_field_opted_out?(user) and
      not batch_contact_opted_out?(user, context.contacts_by_user_uuid)
  end

  # Core's `Auth.unsolicited_mail_allowed?/1` (3.6), copied so the floor can stay
  # at 3.5. Keep these clauses in step with that function: a managed
  # organization's address is set by its managers, and a site that does not ask
  # for confirmation has no confirmed accounts to tell apart. `confirmed_at`
  # matches any datetime struct, as core does, not only `DateTime`.
  defp confirmed?(%User{managed_by_members: true}, _required), do: true
  defp confirmed?(%User{confirmed_at: %_{}}, _required), do: true
  defp confirmed?(%User{}, required), do: not required

  defp confirmation_required? do
    PhoenixKit.Settings.get_boolean_setting("require_email_confirmation", true)
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
