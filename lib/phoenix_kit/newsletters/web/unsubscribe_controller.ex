defmodule PhoenixKit.Newsletters.Web.UnsubscribeController do
  @moduledoc false

  use PhoenixKitWeb, :controller

  require Logger

  alias PhoenixKit.Newsletters.CRMSource
  alias PhoenixKit.Newsletters.UserGroupSource
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  plug(:put_view, html: PhoenixKit.Newsletters.Web.UnsubscribeHTML)

  # GET /newsletters/unsubscribe?token=...
  #
  # The token carries one of two claim shapes, set at send time by
  # DeliveryWorker.build_unsubscribe_url/2:
  #   - %{contact_uuid:, crm_list_uuid:} — crm_list broadcast. Renders a
  #     confirm page (see render_crm_confirm/4) — never mutates on GET:
  #     corporate link-scanners/antivirus tools routinely GET every link
  #     found in an email body, and a GET that silently unsubscribed
  #     people would be exactly that footgun. The actual removal only
  #     happens on POST (process_unsubscribe/2 below). RFC 8058's
  #     one-click automation is unaffected — it lives entirely at the
  #     separate /newsletters/unsubscribe/one-click endpoint.
  #   - %{user_uuid:} — user_group broadcast, signed under the separate
  #     "newsletters_user_optout" salt. verify_token/1 tags a match
  #     under that salt as `{:role_optout, claims}` rather than `{:ok,
  #     claims}`. Renders a confirm page (render_role_optout_confirm/3)
  #     — same never-mutates-on-GET rule.
  #
  # A THIRD shape can still show up here even though nothing signs it
  # anymore: %{user_uuid:, list_uuid:}, the retired newsletters_list
  # flavor's token, under the "unsubscribe" salt these two current
  # shapes also use. Phoenix.Token has no expiry shorter than
  # `max_age` (604_800s / 7 days) and no way to invalidate one flavor
  # of a salt without invalidating all of them, so a link sent before
  # this removal keeps verifying successfully — just with claims that
  # don't match either `{:ok, ...}` clause below. The catch-all
  # degrades it to the same friendly "link no longer valid" redirect
  # every other invalid/expired token already gets, instead of a
  # CaseClauseError (no matching branch — a 500) if it fell through
  # every clause unhandled.
  def unsubscribe(conn, %{"token" => token}) do
    case verify_token(token) do
      {:ok, %{contact_uuid: contact_uuid, crm_list_uuid: crm_list_uuid}} ->
        render_crm_confirm(conn, token, contact_uuid, crm_list_uuid)

      {:role_optout, %{user_uuid: user_uuid}} ->
        render_role_optout_confirm(conn, token, user_uuid)

      _ ->
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

  # POST /newsletters/unsubscribe (scope=list) — crm_unsubscribe.html.heex's
  # "unsubscribe from this list" button; re-renders the same confirm page
  # in its "unsubscribed" state, since it already carries the list's name
  # for the message. The retired newsletters_list flavor used to have its
  # own clause here too (a real %{user_uuid:, list_uuid:} claim, not the
  # crm_list flavor's %{contact_uuid:, crm_list_uuid:}) — gone along with
  # that flavor; a stray old link with that claim shape doesn't match
  # this clause's pattern and falls through to process_unsubscribe/2's
  # catch-all below, same graceful "invalid link" redirect every other
  # unrecognized POST already gets.
  def process_unsubscribe(conn, %{"token" => token, "scope" => "list"}) do
    case verify_token(token) do
      {:ok, %{contact_uuid: contact_uuid, crm_list_uuid: crm_list_uuid}} ->
        handle_crm_list_unsubscribe(conn, token, contact_uuid, crm_list_uuid)

      _ ->
        conn
        |> put_flash(:error, "Invalid link.")
        |> redirect(to: Routes.path("/"))
    end
  end

  # "Unsubscribe from all" (scope=all) — crm_unsubscribe.html.heex's
  # secondary button.
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

      _ ->
        conn
        |> put_flash(:error, "Invalid link.")
        |> redirect(to: Routes.path("/"))
    end
  end

  # user_group flavor — a single unconditional action. Its own scope
  # value, deliberately not "all" — and this clause only accepts a
  # `{:role_optout, ...}` verify_token/1 result, not `{:ok, ...}`.
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

      # A stray old newsletters_list-flavor token (%{user_uuid:,
      # list_uuid:}, retired but still verifiable — see unsubscribe/2's
      # comment) falls through to the catch-all below, `:ok` and a no-op
      # — same graceful degrade RFC 8058 already requires for any
      # unresolvable one-click token.
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
  # just a different salt. This dates back to when the "unsubscribe"
  # salt also signed a now-retired newsletters_list flavor
  # (%{user_uuid:, list_uuid:}), whose claims were a proper superset of
  # user_group's bare %{user_uuid:} — tagging by salt kept the two from
  # ever colliding regardless of clause order, instead of every call
  # site re-deriving safety from clause order alone. Still relevant
  # today for a different reason: an already-sent email can still carry
  # a valid old-flavor "unsubscribe"-salted token (Phoenix.Token has no
  # way to invalidate one flavor of a salt without invalidating all of
  # it), and the tag keeps that stray shape from being silently accepted
  # by a clause it was never meant for.
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
