defmodule PhoenixKit.Newsletters.CRMSource do
  @moduledoc """
  Optional-dependency bridge to `phoenix_kit_crm` contact lists, for
  broadcasts whose `source_type` is `"crm_list"`.

  `phoenix_kit_crm` is an optional module — every public function here
  goes through `available?/0` (via `Code.ensure_loaded?/1`, the same soft
  dependency pattern used elsewhere in this package for the Emails
  module) so newsletters keeps working with zero CRM installed. Unlike
  the Emails soft dependency (which only ever calls `Repo.get/2` — a
  plain function call), the queries here use the `from`/`join` DSL, which
  performs compile-time schema introspection on a literal module
  reference — a module attribute doesn't escape that (Elixir inlines
  `@attr` to its literal value at every use site, so it reads the same as
  writing the module name directly). `list_member_schema/0`/
  `contact_schema/0` build the atom via `Module.concat/1` INSIDE a
  function instead, so it resolves at runtime and Ecto treats it as a
  genuinely dynamic queryable — this compiles cleanly even when CRM isn't
  a dependency of the app at all.

  A member is sendable when `status == "subscribed"`, the contact isn't
  opted out (`opted_out_at` lives on the contact, applying across every
  list it belongs to), and the membership has a snapshotted email —
  matching the contract documented on `PhoenixKitCRM.Lists`.
  """

  import Ecto.Query

  @lists_mod PhoenixKitCRM.Lists
  @contacts_mod PhoenixKitCRM.Contacts

  # Built via Module.concat/1 at call time, not a module attribute — see
  # the moduledoc for why a module attribute doesn't avoid the
  # compile-time schema introspection this needs to dodge.
  defp list_member_schema, do: Module.concat([PhoenixKitCRM, Schemas, ListMember])
  defp contact_schema, do: Module.concat([PhoenixKitCRM, Schemas, Contact])
  defp list_schema, do: Module.concat([PhoenixKitCRM, Schemas, ContactList])

  @doc "Whether the CRM module is installed."
  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(@lists_mod)

  @doc "Active (non-archived) CRM lists, for the broadcast editor's source picker."
  @spec list_lists() :: [struct()]
  def list_lists do
    if available?() do
      soft_call(@lists_mod, :list_lists, [[status: "active"]])
    else
      []
    end
  end

  @doc "Fetches a CRM list by uuid. Returns nil if not found, invalid, or CRM isn't installed."
  @spec get_list(String.t() | nil) :: struct() | nil
  def get_list(nil), do: nil

  def get_list(uuid) do
    if available?() do
      soft_call(@lists_mod, :get_list, [uuid])
    else
      nil
    end
  end

  @doc """
  Sendable recipients of a CRM list — deduplicated by (downcased) email.
  Within a single list this can't currently happen at all
  (`idx_crm_list_members_list_email` is a per-list CITEXT-unique index —
  confirmed directly in `CRMSourceTest`), but this resolver is written to
  take one `crm_list_uuid`, and a future caller merging recipients across
  *several* lists (a broadcast targeting more than one list, say) would
  hit real duplicates the moment that lands — the dedup, and
  `sendable_query/1`'s `order_by`, are already in place for that. Empty
  for an archived list — see `sendable_query/1`.

  Returns `[%{contact_uuid: uuid, email: string}]`.
  """
  @spec sendable_recipients(String.t()) :: [%{contact_uuid: String.t(), email: String.t()}]
  def sendable_recipients(crm_list_uuid) do
    if available?() do
      crm_list_uuid
      |> sendable_query()
      |> repo().all()
      |> Enum.uniq_by(fn %{email: email} -> String.downcase(email) end)
    else
      []
    end
  end

  @doc """
  Preflight breakdown for a CRM list, for the broadcast editor/details
  "N members: M sendable, K no email, L unsubscribed/opted-out" summary.

  `sendable` counts before `sendable_recipients/1`'s email dedup — a
  defensive display figure, not necessarily the exact number of emails
  that go out (see its moduledoc). `unsendable` covers both non-subscribed
  memberships (pending/removed) and subscribed memberships whose contact
  has since opted out.
  """
  @spec preflight(String.t()) :: %{
          total: non_neg_integer(),
          sendable: non_neg_integer(),
          no_email: non_neg_integer(),
          unsendable: non_neg_integer()
        }
  def preflight(crm_list_uuid) do
    if available?() do
      run_preflight_query(crm_list_uuid)
    else
      %{total: 0, sendable: 0, no_email: 0, unsendable: 0}
    end
  end

  # Joins the list itself (not just member+contact) and requires
  # `status == "active"` — an archived list is never sendable, regardless
  # of how many subscribed/opted-in members it still has. `order_by` on
  # `m.uuid` (ListMember's uuid is UUIDv7, so this is also chronological
  # by add-time) makes "which duplicate wins" a stable, deterministic
  # contract for `sendable_recipients/1`'s `Enum.uniq_by` rather than
  # depending on whatever order Postgres happens to return rows in.
  defp sendable_query(crm_list_uuid) do
    member = list_member_schema()
    contact = contact_schema()
    list = list_schema()

    from(m in member,
      join: c in ^contact,
      on: c.uuid == m.contact_uuid,
      join: l in ^list,
      on: l.uuid == m.list_uuid,
      where: m.list_uuid == ^crm_list_uuid,
      where: m.status == "subscribed",
      where: is_nil(c.opted_out_at),
      where: not is_nil(m.email),
      where: l.status == "active",
      order_by: [asc: m.uuid],
      select: %{contact_uuid: m.contact_uuid, email: m.email}
    )
  end

  # `total` counts every member regardless of the list's own status (so an
  # archived list still shows its real membership count, not a
  # misleadingly-zeroed one); `sendable`/`no_email` additionally require
  # `l.status == "active"`, and `unsendable` picks up everything an
  # archived list excludes from those two — keeping
  # total == sendable + no_email + unsendable an invariant either way.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp run_preflight_query(crm_list_uuid) do
    member = list_member_schema()
    contact = contact_schema()
    list = list_schema()

    from(m in member,
      join: c in ^contact,
      on: c.uuid == m.contact_uuid,
      join: l in ^list,
      on: l.uuid == m.list_uuid,
      where: m.list_uuid == ^crm_list_uuid,
      select: %{
        total: count(m.uuid),
        sendable:
          filter(
            count(m.uuid),
            m.status == "subscribed" and is_nil(c.opted_out_at) and not is_nil(m.email) and
              l.status == "active"
          ),
        no_email:
          filter(
            count(m.uuid),
            m.status == "subscribed" and is_nil(c.opted_out_at) and is_nil(m.email) and
              l.status == "active"
          ),
        unsendable:
          filter(
            count(m.uuid),
            m.status != "subscribed" or not is_nil(c.opted_out_at) or l.status != "active"
          )
      }
    )
    |> repo().one()
    |> normalize_preflight_result()
  end

  # Ecto's `dynamic/2` can't be interpolated inside `filter/2` (only at the
  # top level of where/having/select/etc.), so the three conditions above
  # can't be extracted into reusable dynamics — hence the disable: this is
  # inherent domain complexity (three mutually-exclusive, jointly-exhaustive
  # partition conditions, sharing state deliberately since the moduledoc's
  # total == sendable + no_email + unsendable invariant depends on it).
  defp normalize_preflight_result(nil), do: %{total: 0, sendable: 0, no_email: 0, unsendable: 0}
  defp normalize_preflight_result(result), do: result

  @doc "Fetches a CRM contact by uuid. Returns nil if not found, invalid, or CRM isn't installed."
  @spec get_contact(String.t() | nil) :: struct() | nil
  def get_contact(nil), do: nil

  def get_contact(uuid) do
    if available?() do
      soft_call(@contacts_mod, :get_contact, [uuid])
    else
      nil
    end
  end

  @doc """
  The (at most one) CRM contact linked to a given core user, via the
  contact's own `user_uuid` soft-link — never creates one. Returns nil
  if not found, invalid, or CRM isn't installed.
  """
  @spec get_contact_by_user_uuid(String.t() | nil) :: struct() | nil
  def get_contact_by_user_uuid(nil), do: nil

  def get_contact_by_user_uuid(user_uuid) do
    if available?() do
      soft_call(@contacts_mod, :get_by_user_uuid, [user_uuid])
    else
      nil
    end
  end

  @doc """
  Batch lookup: every CRM contact linked to one of the given core user
  uuids, as a `%{user_uuid => contact}` map — the batch counterpart to
  `get_contact_by_user_uuid/1`, for a caller resolving contacts for a
  whole list of users at once (`UserGroupSource.sendable_recipients/1`/
  `preflight/1`) instead of issuing one query per user. Empty map if
  CRM isn't installed or the list is empty; a user uuid with no linked
  contact is simply absent from the map (mirrors `get_contact_by_user_uuid/1`
  returning `nil` for the same case).
  """
  @spec get_contacts_by_user_uuids([String.t()]) :: %{String.t() => struct()}
  def get_contacts_by_user_uuids([]), do: %{}

  # Chunked: `IN ^list` binds one parameter per uuid and Postgres caps a
  # single query at 65,535 binds — a role set resolving to an "all users"
  # audience could hit that ceiling (the per-user path this replaced had
  # no such bound). 5k per chunk keeps queries comfortably small while
  # still being ~N/5000 round-trips instead of N.
  def get_contacts_by_user_uuids(user_uuids) when is_list(user_uuids) do
    if available?() do
      contact = contact_schema()

      user_uuids
      |> Enum.uniq()
      |> Enum.chunk_every(5_000)
      |> Enum.flat_map(fn chunk ->
        repo().all(from(c in contact, where: c.user_uuid in ^chunk))
      end)
      |> Map.new(&{&1.user_uuid, &1})
    else
      %{}
    end
  end

  @doc """
  The membership (any status) currently holding `email` in the CRM list —
  used to resolve a delivery's `recipient_email` back to a `contact_uuid`
  for the unsubscribe token, and to detect an already-unsubscribed click
  before re-removing (idempotency messaging).

  Returns nil if not found, CRM isn't installed, or the list doesn't exist.
  """
  @spec get_member_by_email(String.t(), String.t()) :: struct() | nil
  def get_member_by_email(crm_list_uuid, email) do
    with true <- available?(),
         %{} = list <- get_list(crm_list_uuid) do
      soft_call(@lists_mod, :get_member_by_email, [list, email])
    else
      _ -> nil
    end
  end

  @doc """
  Unsubscribes a contact from one CRM list (soft: membership status →
  `"removed"`). Idempotent — a contact already removed from the list
  stays `{:ok, member}`; only a contact who was NEVER a member of this
  list at all returns `{:error, :not_member}` (a stale/crafted token).
  """
  @spec remove_from_list(struct(), struct()) :: {:ok, struct()} | {:error, :not_member}
  def remove_from_list(contact, list) do
    if available?() do
      soft_call(@lists_mod, :remove_from_list, [contact, list, []])
    else
      {:error, :not_member}
    end
  end

  @doc """
  Opts a contact out entirely — applies across every CRM list the contact
  belongs to (opt-out lives on the contact, not the membership). Idempotent.
  `opts` accepts `:source` (default `"unsubscribe_link"`, the original
  caller) — the preference center passes `source: "preference_center"` so
  the two entry points stay distinguishable in the contact's consent log.
  """
  @spec opt_out(struct(), keyword()) ::
          {:ok, struct()} | {:error, Ecto.Changeset.t() | :unavailable}
  def opt_out(contact, opts \\ []) do
    if available?() do
      soft_call(@lists_mod, :opt_out, [
        contact,
        Keyword.put_new(opts, :source, "unsubscribe_link")
      ])
    else
      {:error, :unavailable}
    end
  end

  @doc """
  Opts a contact back in — clears the contact-level opt-out set by
  `opt_out/2`. Idempotent. This is the re-subscription path the
  preference center's "resubscribe" action uses (spec §7/§8: allowed,
  and this view is exactly where the re-consent happens); it does not
  touch any individual list membership.
  """
  @spec opt_in(struct(), keyword()) ::
          {:ok, struct()} | {:error, Ecto.Changeset.t() | :unavailable}
  def opt_in(contact, opts \\ []) do
    if available?() do
      soft_call(@lists_mod, :opt_in, [
        contact,
        Keyword.put_new(opts, :source, "preference_center")
      ])
    else
      {:error, :unavailable}
    end
  end

  @doc """
  Active, subscribable CRM lists — the preference center's toggle list.
  A list not marked `subscribable` (the CRM list editor's own checkbox,
  default off) never appears here regardless of status; an archived list
  never appears here regardless of the flag.
  """
  @spec list_subscribable_lists() :: [struct()]
  def list_subscribable_lists do
    if available?() do
      soft_call(@lists_mod, :list_lists, [[status: "active", subscribable: true]])
    else
      []
    end
  end

  @doc "Whether the contact currently has an active (`subscribed`) membership on the list."
  @spec subscribed?(struct(), struct()) :: boolean()
  def subscribed?(contact, list) do
    if available?() do
      soft_call(@lists_mod, :subscribed?, [contact, list])
    else
      false
    end
  end

  @doc """
  Subscribes a contact to one CRM list — the preference center's toggle-on
  action. `source: "form"` (self-service, one of
  `PhoenixKitCRM.Schemas.ListMember.sources/0`) tags the membership as
  coming from the person themselves, not an admin/import.
  """
  @spec subscribe(struct(), struct()) ::
          {:ok, struct()}
          | {:error, :already_member | :email_already_in_list | Ecto.Changeset.t() | :unavailable}
  def subscribe(contact, list) do
    if available?() do
      soft_call(@lists_mod, :add_contact_to_list, [contact, list, [source: "form"]])
    else
      {:error, :unavailable}
    end
  end

  @doc """
  Finds the CRM contact already linked to this login user, or lazily
  creates+links one — **never** via `PhoenixKitCRM.Contacts.connect_user/2`
  (which would placeholder-register a *new* core user if none matched the
  email; here the user already exists, and the link must point at exactly
  that `user_uuid`, never mint anything).

  Resolution order: (1) a contact already linked to this `user_uuid` —
  the common case after the first call; (2) if exactly ONE existing,
  not-yet-linked contact holds this email, link it in place (reuses a
  person's existing CRM presence — e.g. as a supplier/client contact —
  rather than accumulating a second record for the same already-known
  identity); (3) otherwise (no match, or the email is ambiguous — see
  below) create a bare contact from the user's email and link it.

  **Ambiguous email is deliberately treated as "no match", not "pick
  one"** (review finding on the first cut): under the CRM import policy
  ("every imported row creates a NEW contact" — §4.3 of the restructuring
  spec), one address can legitimately belong to several distinct contact
  rows. Auto-linking to an arbitrary one of them (the previous behavior:
  the oldest) would put only THAT record under this person's control —
  the others stay subscribed to whatever lists they're on, invisible on
  this page, so the person "unsubscribes" and mail keeps arriving from a
  list they never see. Same reasoning excludes already-linked contacts
  from the candidate count — a contact linked to a DIFFERENT user is not
  this person's, ambiguous or not.

  Takes any map/struct with `:uuid` and `:email` (a `%User{}`, or an
  equivalent plain map) so callers don't need a real `User` struct in
  hand. Returns `{:error, :unavailable}` if CRM isn't installed.
  """
  @spec find_or_link_contact_for_user(%{uuid: String.t(), email: String.t()}) ::
          {:ok, struct()} | {:error, Ecto.Changeset.t() | :unavailable}
  def find_or_link_contact_for_user(%{uuid: user_uuid, email: email})
      when is_binary(user_uuid) and is_binary(email) do
    if available?() do
      case soft_call(@contacts_mod, :get_by_user_uuid, [user_uuid]) do
        nil -> find_or_create_contact_and_link(user_uuid, email)
        contact -> {:ok, contact}
      end
    else
      {:error, :unavailable}
    end
  end

  defp find_or_create_contact_and_link(user_uuid, email) do
    unlinked =
      soft_call(@contacts_mod, :list_by_email, [email])
      |> Enum.filter(&(Map.get(&1, :user_uuid) == nil))

    case unlinked do
      [existing] -> link_contact_to_user(existing, user_uuid)
      _ -> create_and_link_contact(user_uuid, email)
    end
  end

  defp create_and_link_contact(user_uuid, email) do
    case soft_call(@contacts_mod, :create_contact, [%{"name" => email, "email" => email}]) do
      {:ok, contact} -> link_contact_to_user(contact, user_uuid)
      {:error, _} = error -> error
    end
  end

  # `Contact.link_user_changeset/2` is a schema-level helper (not a
  # `Contacts` context function) — resolved via `contact_schema/0`'s
  # runtime `Module.concat/1`, same soft-dependency reasoning as the
  # `from`/`join` schema references above, since calling it still requires
  # naming the module.
  defp link_contact_to_user(contact, user_uuid) do
    changeset = contact_schema().link_user_changeset(contact, user_uuid)
    repo().update(changeset)
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # Intentional apply/3 — calls an optional soft-dependency module to avoid
  # a compile-time dependency on the CRM package (mirrors the
  # `@email_templates_mod`/`soft_call/3` pattern used for the Emails module
  # elsewhere in this package).
  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp soft_call(mod, fun, args), do: apply(mod, fun, args)
end
