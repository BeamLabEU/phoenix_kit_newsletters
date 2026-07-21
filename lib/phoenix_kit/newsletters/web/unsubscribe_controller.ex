defmodule PhoenixKit.Newsletters.Web.UnsubscribeController do
  @moduledoc false

  use PhoenixKitWeb, :controller

  require Logger

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.CRMSource
  alias PhoenixKit.Newsletters.UserGroupSource
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  plug(:put_view, html: PhoenixKit.Newsletters.Web.UnsubscribeHTML)

  # GET /newsletters/unsubscribe?token=...
  #
  # The token carries one of three claim shapes, set at send time by
  # DeliveryWorker.build_unsubscribe_url/2:
  #   - %{user_uuid:, list_uuid:} — newsletters-list broadcast (original
  #     flavor). Shows the list/all choice page — never mutates on GET.
  #   - %{contact_uuid:, crm_list_uuid:} — crm_list broadcast. Renders a
  #     confirm page (see render_crm_confirm/4) — also never mutates on
  #     GET, matching flavor-A: corporate link-scanners/antivirus tools
  #     routinely GET every link found in an email body, and a GET that
  #     silently unsubscribed people would be exactly that footgun. The
  #     actual removal only happens on POST (process_unsubscribe/2 below).
  #     RFC 8058's one-click automation is unaffected — it lives entirely
  #     at the separate /newsletters/unsubscribe/one-click endpoint.
  #   - %{user_uuid:} (bare — no list_uuid) — user_group broadcast,
  #     signed under the separate "newsletters_user_optout" salt.
  #     verify_token/1 tags a match under that salt as `{:role_optout,
  #     claims}` rather than `{:ok, claims}` specifically so this clause
  #     can't be reached by a flavor-A token: a bare %{user_uuid:}
  #     pattern is a subset of flavor-A's %{user_uuid:, list_uuid:}
  #     claims, so matching on shape alone (both tagged `:ok`) would let
  #     a flavor-A token silently fall through here too. The salt tag
  #     makes the two flavors mutually exclusive regardless of clause
  #     order — see role_optout_unsubscribe_test.exs's "salt/scope
  #     cross-flavor rejection" tests. Renders a confirm page
  #     (render_role_optout_confirm/3) — same never-mutates-on-GET rule.
  def unsubscribe(conn, %{"token" => token}) do
    case verify_token(token) do
      {:ok, %{user_uuid: user_uuid, list_uuid: list_uuid}} ->
        list = Newsletters.get_list(list_uuid)
        all_lists = Newsletters.list_user_subscriptions(user_uuid)

        conn
        |> assign(:token, token)
        |> assign(:list, list)
        |> assign(:all_lists, all_lists)
        |> assign(:user_uuid, user_uuid)
        |> render(:unsubscribe)

      {:ok, %{contact_uuid: contact_uuid, crm_list_uuid: crm_list_uuid}} ->
        render_crm_confirm(conn, token, contact_uuid, crm_list_uuid)

      {:role_optout, %{user_uuid: user_uuid}} ->
        render_role_optout_confirm(conn, token, user_uuid)

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Invalid or expired unsubscribe link.")
        |> redirect(to: Routes.path("/"))
    end
  end

  def unsubscribe(conn, _params) do
    conn
    |> put_flash(:error, "Invalid or expired unsubscribe link.")
    |> redirect(to: Routes.path("/"))
  end

  # POST /newsletters/unsubscribe — process the choice. Flavor-A redirects
  # home with a flash (its own existing UX); the crm_list flavor re-renders
  # the same confirm page in its "unsubscribed" state, since it already
  # carries the list's name for the message.
  def process_unsubscribe(conn, %{"token" => token, "scope" => "list"}) do
    case verify_token(token) do
      {:ok, %{user_uuid: user_uuid, list_uuid: list_uuid}} ->
        case Newsletters.unsubscribe_user(list_uuid, user_uuid) do
          {:ok, _member} ->
            conn
            |> put_flash(:info, "You have been unsubscribed from this list.")
            |> redirect(to: Routes.path("/"))

          {:error, _reason} ->
            conn
            |> put_flash(:error, "We could not unsubscribe you right now. Please try again.")
            |> redirect(to: Routes.path("/"))
        end

      {:ok, %{contact_uuid: contact_uuid, crm_list_uuid: crm_list_uuid}} ->
        handle_crm_list_unsubscribe(conn, token, contact_uuid, crm_list_uuid)

      _ ->
        conn
        |> put_flash(:error, "Invalid link.")
        |> redirect(to: Routes.path("/"))
    end
  end

  # "Unsubscribe from all" — flavor-A goes through the newsletters
  # ListMember table (unchanged); flavor-B (the crm_unsubscribe landing
  # page's secondary button) opts the contact out entirely, which the CRM
  # send path already checks across every list it belongs to. A
  # user_group token can never reach the %{user_uuid: user_uuid} clause
  # below — verify_token/1 tags it `{:role_optout, ...}`, not `{:ok,
  # ...}`, precisely so it isn't absorbed here and misrouted to the
  # ListMember-based unsubscribe_from_all/1 instead of
  # UserGroupSource.record_opt_out/1.
  def process_unsubscribe(conn, %{"token" => token, "scope" => "all"}) do
    case verify_token(token) do
      {:ok, %{contact_uuid: contact_uuid}} ->
        with %{} = contact <- CRMSource.get_contact(contact_uuid),
             {:ok, _contact} <- CRMSource.opt_out(contact) do
          conn
          |> put_flash(:info, "You have been unsubscribed from all newsletters.")
          |> redirect(to: Routes.path("/"))
        else
          nil ->
            conn
            |> put_flash(:error, "Invalid link.")
            |> redirect(to: Routes.path("/"))

          {:error, _reason} ->
            conn
            |> put_flash(:error, "We could not unsubscribe you right now. Please try again.")
            |> redirect(to: Routes.path("/"))
        end

      {:ok, %{user_uuid: user_uuid}} ->
        Newsletters.unsubscribe_from_all(user_uuid)

        conn
        |> put_flash(:info, "You have been unsubscribed from all lists.")
        |> redirect(to: Routes.path("/"))

      _ ->
        conn
        |> put_flash(:error, "Invalid link.")
        |> redirect(to: Routes.path("/"))
    end
  end

  # user_group flavor — a single unconditional action (no list/all
  # choice; a role recipient has no ListMember rows to partially
  # unsubscribe from). Its own scope value, deliberately not "all" —
  # and this clause only accepts a `{:role_optout, ...}` verify_token/1
  # result, not `{:ok, ...}`: a flavor-A (list) token's claims
  # (%{user_uuid:, list_uuid:}) are a superset of this clause's bare
  # %{user_uuid:} pattern, so without the salt tag a flavor-A token
  # posted here (by tampering or a stray form) would silently opt
  # someone out of every role-sourced newsletter over a token meant to
  # unsubscribe them from a single list.
  def process_unsubscribe(conn, %{"token" => token, "scope" => "role_optout"}) do
    case verify_token(token) do
      {:role_optout, %{user_uuid: user_uuid}} ->
        handle_role_optout(conn, token, user_uuid)

      _ ->
        conn
        |> put_flash(:error, "Invalid link.")
        |> redirect(to: Routes.path("/"))
    end
  end

  # Catch-all for invalid/expired tokens or missing parameters
  def process_unsubscribe(conn, _params) do
    conn
    |> put_flash(:error, "Invalid or expired unsubscribe link.")
    |> redirect(to: Routes.path("/"))
  end

  # POST /newsletters/unsubscribe/one-click — the List-Unsubscribe-Post
  # header target (DeliveryWorker), always CSRF-exempt (see Web.Routes)
  # because it must accept a cold, session-less POST straight from the
  # mail client per RFC 8058. Mutation happens ONLY here, only on POST —
  # never on GET (see the GET clause below). Idempotent
  # (CRMSource.remove_from_list/2 no-ops on an already-removed membership)
  # and defensive against any other claim shape or an invalid/expired
  # token — always resolves without raising. Mail clients don't parse the
  # response — always 200, quickly, regardless of what the token held.
  def one_click_unsubscribe(%{method: "POST"} = conn, %{"token" => token}) do
    case verify_token(token) do
      {:ok, %{contact_uuid: contact_uuid, crm_list_uuid: crm_list_uuid}} ->
        with %{} = list <- CRMSource.get_list(crm_list_uuid),
             %{} = contact <- CRMSource.get_contact(contact_uuid) do
          CRMSource.remove_from_list(contact, list)
        end

      {:ok, %{user_uuid: user_uuid, list_uuid: list_uuid}} ->
        Newsletters.unsubscribe_user(list_uuid, user_uuid)

      # user_group flavor — tagged `{:role_optout, ...}` by
      # verify_token/1 (see unsubscribe/2's comment), so this can't be
      # reached by a flavor-A token even though its claims are a subset
      # of flavor-A's.
      {:role_optout, %{user_uuid: user_uuid}} ->
        case Auth.get_user(user_uuid) do
          %{} = user -> UserGroupSource.record_opt_out(user)
          nil -> :ok
        end

      {:error, reason} ->
        Logger.warning(
          "UnsubscribeController: one-click POST with an unverifiable token: #{inspect(reason)}"
        )

      _ ->
        :ok
    end

    send_resp(conn, 200, "")
  end

  def one_click_unsubscribe(%{method: "POST"} = conn, _params), do: send_resp(conn, 200, "")

  # GET /newsletters/unsubscribe/one-click — the List-Unsubscribe header
  # (without -Post) also points here, and a mail client that doesn't
  # support one-click POST falls back to opening this URL in a browser.
  # Deliberately NEVER mutates: this is exactly the footgun already fixed
  # for the body-link flavor (fd7354a) — a corporate link-scanner/
  # antivirus tool GETting every URL it finds, including header values,
  # would otherwise silently unsubscribe people. Redirects to the same
  # interactive confirm landing page the body link uses (same token, so
  # the human still gets a real "are you sure" step and an actual POST
  # button before anything changes).
  def one_click_unsubscribe(conn, %{"token" => token}) do
    redirect(conn, to: Routes.path("/newsletters/unsubscribe?token=#{token}"))
  end

  def one_click_unsubscribe(conn, _params), do: redirect(conn, to: Routes.path("/"))

  # --- Private ---

  # Two salts: "unsubscribe" (flavor-A/flavor-B, both already carry their
  # own claim keys) and "newsletters_user_optout" (user_group flavor,
  # signed by DeliveryWorker.sign_user_optout_token/1). Tried in order;
  # a token only ever verifies under the salt it was actually signed
  # with, so trying both is just "accept either flavor," not a security
  # weakening — Phoenix.Token ties the salt to the signing purpose.
  #
  # A "newsletters_user_optout" match is tagged `{:role_optout, claims}`
  # rather than `{:ok, claims}` — deliberately a different shape, not
  # just a different salt. The user_group flavor's claims
  # (%{user_uuid:}) are a proper subset of flavor-A's
  # (%{user_uuid:, list_uuid:}), so if both flavors returned `{:ok,
  # claims}` here, every call site would have to keep re-deriving safety
  # from clause *order* (more-specific pattern first) to avoid a
  # flavor-A token being silently accepted by a role-flavor clause, or
  # vice versa. Tagging by which salt matched makes that safety
  # independent of order — see role_optout_unsubscribe_test.exs's
  # cross-flavor rejection tests.
  defp verify_token(token) do
    endpoint = PhoenixKit.Config.get(:endpoint, PhoenixKitWeb.Endpoint)

    case Phoenix.Token.verify(endpoint, "unsubscribe", token, max_age: 604_800) do
      {:ok, _claims} = ok ->
        ok

      {:error, _reason} ->
        case Phoenix.Token.verify(endpoint, "newsletters_user_optout", token, max_age: 604_800) do
          {:ok, claims} -> {:role_optout, claims}
          {:error, _reason} = error -> error
        end
    end
  end

  # GET — read-only. Resolves the list/contact and whether the contact is
  # already removed from this list (purely for the message shown; never
  # mutates), then renders one of three states via @crm_state:
  #   :confirm             — not yet unsubscribed, offers the POST button
  #   :already_unsubscribed — already removed, no action needed
  #   :invalid              — list/contact/token doesn't resolve
  defp render_crm_confirm(conn, token, contact_uuid, crm_list_uuid) do
    with %{} = list <- CRMSource.get_list(crm_list_uuid),
         %{} = contact <- CRMSource.get_contact(contact_uuid) do
      state =
        if already_unsubscribed?(crm_list_uuid, contact.email),
          do: :already_unsubscribed,
          else: :confirm

      conn
      |> assign(:token, token)
      |> assign(:crm_list, list)
      |> assign(:crm_state, state)
      |> render(:crm_unsubscribe)
    else
      _ -> render_crm_invalid(conn, token)
    end
  end

  # POST — the actual mutation. Idempotent: CRMSource.remove_from_list/2 is
  # a no-op {:ok, member} on an already-removed membership (a repeat POST,
  # e.g. a double-click, re-renders the same :unsubscribed state rather
  # than crashing or double-decrementing); {:error, :not_member} (a stale/
  # crafted token — the contact was never on this list at all) renders the
  # invalid-link state instead.
  defp handle_crm_list_unsubscribe(conn, token, contact_uuid, crm_list_uuid) do
    with %{} = list <- CRMSource.get_list(crm_list_uuid),
         %{} = contact <- CRMSource.get_contact(contact_uuid),
         {:ok, _member} <- CRMSource.remove_from_list(contact, list) do
      conn
      |> assign(:token, token)
      |> assign(:crm_list, list)
      |> assign(:crm_state, :unsubscribed)
      |> render(:crm_unsubscribe)
    else
      _ -> render_crm_invalid(conn, token)
    end
  end

  defp render_crm_invalid(conn, token) do
    conn
    |> assign(:token, token)
    |> assign(:crm_list, nil)
    |> assign(:crm_state, :invalid)
    |> render(:crm_unsubscribe)
  end

  # Best-effort "was this already removed" check, purely for the landing
  # page's message — looked up by the contact's current email (the
  # membership's own snapshotted email at add/reactivate time, so this
  # can miss if the contact's email changed since; that only affects
  # which message string shows, never whether the actual removal above
  # runs correctly, since that looks the membership up by contact_uuid).
  defp already_unsubscribed?(crm_list_uuid, email) when is_binary(email) do
    match?(%{status: "removed"}, CRMSource.get_member_by_email(crm_list_uuid, email))
  end

  defp already_unsubscribed?(_crm_list_uuid, _email), do: false

  # GET — read-only, same 3-state shape as render_crm_confirm/4:
  #   :confirm             — not yet opted out, offers the POST button
  #   :already_unsubscribed — already opted out (either check
  #                           UserGroupSource.opted_out?/1 makes), no
  #                           action needed
  #   :invalid              — token verifies but the user is gone
  defp render_role_optout_confirm(conn, token, user_uuid) do
    case Auth.get_user(user_uuid) do
      %{} = user ->
        state = if UserGroupSource.opted_out?(user), do: :already_unsubscribed, else: :confirm

        conn
        |> assign(:token, token)
        |> assign(:role_optout_state, state)
        |> render(:role_optout_unsubscribe)

      nil ->
        render_role_optout_invalid(conn, token)
    end
  end

  # POST — the actual mutation. Idempotent: UserGroupSource.record_opt_out/1
  # writes the same custom_fields value on a repeat, and delegates to the
  # already-idempotent CRMSource.opt_out/1 for the linked-contact side.
  defp handle_role_optout(conn, token, user_uuid) do
    case Auth.get_user(user_uuid) do
      %{} = user ->
        case UserGroupSource.record_opt_out(user) do
          {:ok, _updated_user} ->
            conn
            |> assign(:token, token)
            |> assign(:role_optout_state, :unsubscribed)
            |> render(:role_optout_unsubscribe)

          {:error, _reason} ->
            conn
            |> put_flash(:error, "We could not unsubscribe you right now. Please try again.")
            |> redirect(to: Routes.path("/"))
        end

      nil ->
        render_role_optout_invalid(conn, token)
    end
  end

  defp render_role_optout_invalid(conn, token) do
    conn
    |> assign(:token, token)
    |> assign(:role_optout_state, :invalid)
    |> render(:role_optout_unsubscribe)
  end
end
