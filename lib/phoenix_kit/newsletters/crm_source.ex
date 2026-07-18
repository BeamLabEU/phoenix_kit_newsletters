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
  Sendable recipients of a CRM list — deduplicated by (downcased) email,
  since two memberships could in principle share a mailbox. The list's own
  per-list email uniqueness index makes an in-list duplicate rare, but the
  dedup stays as a defensive guarantee against ever double-sending to one
  address.

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

  defp sendable_query(crm_list_uuid) do
    member = list_member_schema()
    contact = contact_schema()

    from(m in member,
      join: c in ^contact,
      on: c.uuid == m.contact_uuid,
      where: m.list_uuid == ^crm_list_uuid,
      where: m.status == "subscribed",
      where: is_nil(c.opted_out_at),
      where: not is_nil(m.email),
      select: %{contact_uuid: m.contact_uuid, email: m.email}
    )
  end

  defp run_preflight_query(crm_list_uuid) do
    member = list_member_schema()
    contact = contact_schema()

    from(m in member,
      join: c in ^contact,
      on: c.uuid == m.contact_uuid,
      where: m.list_uuid == ^crm_list_uuid,
      select: %{
        total: count(m.uuid),
        sendable:
          filter(
            count(m.uuid),
            m.status == "subscribed" and is_nil(c.opted_out_at) and not is_nil(m.email)
          ),
        no_email:
          filter(
            count(m.uuid),
            m.status == "subscribed" and is_nil(c.opted_out_at) and is_nil(m.email)
          ),
        unsendable: filter(count(m.uuid), m.status != "subscribed" or not is_nil(c.opted_out_at))
      }
    )
    |> repo().one()
    |> case do
      nil -> %{total: 0, sendable: 0, no_email: 0, unsendable: 0}
      result -> result
    end
  end

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
    soft_call(@lists_mod, :remove_from_list, [contact, list, []])
  end

  @doc """
  Opts a contact out entirely — applies across every CRM list the contact
  belongs to (opt-out lives on the contact, not the membership). Idempotent.
  """
  @spec opt_out(struct()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def opt_out(contact) do
    soft_call(@lists_mod, :opt_out, [contact, [source: "unsubscribe_link"]])
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # Intentional apply/3 — calls an optional soft-dependency module to avoid
  # a compile-time dependency on the CRM package (mirrors the
  # `@email_templates_mod`/`soft_call/3` pattern used for the Emails module
  # elsewhere in this package).
  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp soft_call(mod, fun, args), do: apply(mod, fun, args)
end
