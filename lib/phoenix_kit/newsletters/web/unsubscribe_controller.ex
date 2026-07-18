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
  #     flavor). Shows the list/all choice page — unchanged.
  #   - %{contact_uuid:, crm_list_uuid:} — crm_list broadcast. No
  #     newsletters ListMember/User exists for the contact, so this
  #     flavor unsubscribes from the specific list immediately on GET
  #     (see handle_crm_unsubscribe/4) and offers "unsubscribe from all"
  #     as a secondary action on the confirmation page.
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
        handle_crm_unsubscribe(conn, token, contact_uuid, crm_list_uuid)

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

  # POST /newsletters/unsubscribe — process the choice (flavor-A "list" is
  # only ever reached from that flavor's own page; a crm_list token never
  # renders the button that would submit this).
  def process_unsubscribe(conn, %{"token" => token, "scope" => "list"}) do
    case verify_token(token) do
      {:ok, %{user_uuid: user_uuid, list_uuid: list_uuid}} ->
        Newsletters.unsubscribe_user(list_uuid, user_uuid)

        conn
        |> put_flash(:info, "You have been unsubscribed from this list.")
        |> redirect(to: Routes.path("/"))

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

  # Removes the contact from the one list immediately (no confirmation
  # step — clicking the emailed link IS the action, matching standard
  # one-click-unsubscribe UX), then renders a confirmation with a
  # secondary "unsubscribe from all" action. Idempotent either way:
  # Lists.remove_from_list/3 is a no-op {:ok, member} on an already-removed
  # membership, and {:error, :not_member} (a stale/crafted token — the
  # contact was never on this list at all) renders the invalid-link state
  # instead of crashing.
  defp handle_crm_unsubscribe(conn, token, contact_uuid, crm_list_uuid) do
    with %{} = list <- CRMSource.get_list(crm_list_uuid),
         %{} = contact <- CRMSource.get_contact(contact_uuid),
         already? = already_unsubscribed?(crm_list_uuid, contact.email),
         {:ok, _member} <- CRMSource.remove_from_list(contact, list) do
      conn
      |> assign(:token, token)
      |> assign(:crm_list, list)
      |> assign(:crm_invalid, false)
      |> assign(:crm_already_unsubscribed?, already?)
      |> render(:crm_unsubscribe)
    else
      _ ->
        conn
        |> assign(:token, token)
        |> assign(:crm_list, nil)
        |> assign(:crm_invalid, true)
        |> assign(:crm_already_unsubscribed?, false)
        |> render(:crm_unsubscribe)
    end
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
