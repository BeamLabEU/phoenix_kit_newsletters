defmodule PhoenixKit.Newsletters.Web.UnsubscribeController do
  @moduledoc false

  use PhoenixKitWeb, :controller

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.CRMSource
  alias PhoenixKit.Utils.Routes

  plug(:put_view, html: PhoenixKit.Newsletters.Web.UnsubscribeHTML)

  # GET /newsletters/unsubscribe?token=...
  #
  # The token carries one of two claim shapes, set at send time by
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
        Newsletters.unsubscribe_user(list_uuid, user_uuid)

        conn
        |> put_flash(:info, "You have been unsubscribed from this list.")
        |> redirect(to: Routes.path("/"))

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
  # send path already checks across every list it belongs to.
  def process_unsubscribe(conn, %{"token" => token, "scope" => "all"}) do
    case verify_token(token) do
      {:ok, %{contact_uuid: contact_uuid}} ->
        case CRMSource.get_contact(contact_uuid) do
          %{} = contact ->
            CRMSource.opt_out(contact)

            conn
            |> put_flash(:info, "You have been unsubscribed from all newsletters.")
            |> redirect(to: Routes.path("/"))

          nil ->
            conn
            |> put_flash(:error, "Invalid link.")
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

  # Catch-all for invalid/expired tokens or missing parameters
  def process_unsubscribe(conn, _params) do
    conn
    |> put_flash(:error, "Invalid or expired unsubscribe link.")
    |> redirect(to: Routes.path("/"))
  end

  # GET/POST /newsletters/unsubscribe/one-click — the List-Unsubscribe and
  # List-Unsubscribe-Post header target (DeliveryWorker). This is a
  # dedicated, always-CSRF-exempt endpoint (see Web.Routes) precisely
  # because it must accept a cold, session-less POST straight from the
  # mail client per RFC 8058 — the interactive /newsletters/unsubscribe
  # route above stays behind the host's normal :browser/CSRF pipeline and
  # is unaffected. Idempotent (CRMSource.remove_from_list/2 no-ops on an
  # already-removed membership) and defensive against any other claim
  # shape or an invalid/expired token — always resolves without raising.
  def one_click_unsubscribe(conn, %{"token" => token}) do
    case verify_token(token) do
      {:ok, %{contact_uuid: contact_uuid, crm_list_uuid: crm_list_uuid}} ->
        with %{} = list <- CRMSource.get_list(crm_list_uuid),
             %{} = contact <- CRMSource.get_contact(contact_uuid) do
          CRMSource.remove_from_list(contact, list)
        end

      _ ->
        :ok
    end

    respond_one_click(conn)
  end

  def one_click_unsubscribe(conn, _params), do: respond_one_click(conn)

  # Mail clients POST here and don't parse the response — always 200,
  # quickly, regardless of what the token held. A human's browser landing
  # here via a GET fallback (a mail client that doesn't support one-click
  # POST but does open the List-Unsubscribe URL) gets sent home instead.
  defp respond_one_click(%{method: "POST"} = conn), do: send_resp(conn, 200, "")
  defp respond_one_click(conn), do: redirect(conn, to: Routes.path("/"))

  # --- Private ---

  defp verify_token(token) do
    Phoenix.Token.verify(
      PhoenixKit.Config.get(:endpoint, PhoenixKitWeb.Endpoint),
      "unsubscribe",
      token,
      max_age: 604_800
    )
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
end
