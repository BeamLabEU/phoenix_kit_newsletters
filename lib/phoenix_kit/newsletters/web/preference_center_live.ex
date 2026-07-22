defmodule PhoenixKit.Newsletters.Web.PreferenceCenterLive do
  @moduledoc """
  Subscription preference center (spec §7) — the single self-service page
  reachable two ways:

    * from any broadcast email, via a signed `contact_uuid` token
      (`?token=...`) — never requires login;
    * from a logged-in user's account navigation, with no token — the
      contact is lazily found/created and linked to the current user
      (`CRMSource.find_or_link_contact_for_user/1`), never a placeholder
      registration.

  Shows every `subscribable` CRM list as a toggle (subscribed /
  available), plus "unsubscribe from all" (the contact-level opt-out,
  §4.2) and its inverse, resubscribe — allowed from this same view
  (spec §8: re-consent happens exactly here). Degrades to an
  informational message, never a crash, when CRM isn't installed — the
  CRM dependency is optional everywhere else in this package
  (`CRMSource`), and this page is no exception.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKit.Newsletters.Gettext

  import PhoenixKitWeb.Components.Core.Icon

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.CRMSource
  alias PhoenixKit.Newsletters.PreferenceToken
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    socket = assign(socket, :page_title, gettext("Email preferences"))

    if Newsletters.enabled?() do
      {:ok, assign(socket, mode: :loading, contact: nil, lists: [])}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Newsletters module is not enabled"))
       |> push_navigate(to: Routes.path("/"))}
    end
  end

  # Token verification, contact resolution, and the account-path's
  # find-or-create write all belong in handle_params, not mount — mount
  # runs twice per connection (disconnected HTTP render, then the
  # connected websocket one), which would double every read here and,
  # worse, run the account-path's contact-creation INSERT/UPDATE during
  # the plain disconnected GET. Mirrors BroadcastEditor/BroadcastDetails's
  # assign_tz/1 pattern in this same package.
  @impl true
  def handle_params(params, _url, %{assigns: %{mode: :loading}} = socket) do
    socket =
      if CRMSource.available?() do
        resolve_access(socket, params)
      else
        assign(socket, mode: :unavailable, contact: nil, lists: [])
      end

    {:noreply, socket}
  end

  def handle_params(_params, _url, socket), do: {:noreply, socket}

  # Token entry — works with or without an active login session, exactly
  # so a one-click link from an email never requires a password.
  defp resolve_access(socket, %{"token" => token}) when is_binary(token) and token != "" do
    with {:ok, contact_uuid} <- PreferenceToken.verify(token),
         %{} = contact <- CRMSource.get_contact(contact_uuid) do
      load_lists(socket, :token, contact)
    else
      _ -> assign(socket, mode: :invalid_token, contact: nil, lists: [])
    end
  end

  # Account-nav entry — no token, requires an authenticated scope. Lazily
  # finds/links the contact for this user; never mints a placeholder user
  # (CRMSource.find_or_link_contact_for_user/1 never goes through
  # PhoenixKitCRM.Contacts.connect_user/2).
  defp resolve_access(socket, _params) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    if scope && Scope.authenticated?(scope) do
      user = Scope.user(scope)

      case CRMSource.find_or_link_contact_for_user(%{uuid: user.uuid, email: user.email}) do
        {:ok, contact} -> load_lists(socket, :account, contact)
        {:error, _} -> assign(socket, mode: :error, contact: nil, lists: [])
      end
    else
      return_to = URI.encode_www_form(Routes.path("/newsletters/preferences"))

      socket
      |> put_flash(:error, gettext("Please log in to manage your email subscriptions"))
      |> push_navigate(to: Routes.path("/phoenix_kit/users/log-in") <> "?return_to=#{return_to}")
    end
  end

  defp load_lists(socket, mode, contact) do
    lists =
      Enum.map(CRMSource.list_subscribable_lists(), fn list ->
        %{list: list, subscribed?: CRMSource.subscribed?(contact, list)}
      end)

    assign(socket, mode: mode, contact: contact, lists: lists)
  end

  @impl true
  # Only acts on a list_uuid present in the already-loaded subscribable
  # set (assigns.lists) — a public/anonymous page must not trust a
  # client-supplied list_uuid for anything beyond what was actually
  # rendered to it.
  def handle_event("toggle_list", %{"list_uuid" => list_uuid}, socket) do
    case Enum.find(socket.assigns.lists, fn %{list: l} -> l.uuid == list_uuid end) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("That list is no longer available."))}

      %{list: list, subscribed?: subscribed?} ->
        contact = socket.assigns.contact

        result =
          if subscribed? do
            CRMSource.remove_from_list(contact, list)
          else
            CRMSource.subscribe(contact, list)
          end

        case result do
          {:ok, _} ->
            {:noreply, load_lists(socket, socket.assigns.mode, contact)}

          {:error, _reason} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("Could not update that subscription — please try again.")
             )}
        end
    end
  end

  def handle_event("unsubscribe_all", _params, socket) do
    case CRMSource.opt_out(socket.assigns.contact, source: "preference_center") do
      {:ok, contact} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("You've been unsubscribed from all newsletters."))
         |> load_lists(socket.assigns.mode, contact)}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, gettext("Could not process that request — please try again."))}
    end
  end

  def handle_event("resubscribe", _params, socket) do
    case CRMSource.opt_in(socket.assigns.contact, source: "preference_center") do
      {:ok, contact} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Welcome back — you can now choose which lists to receive."))
         |> load_lists(socket.assigns.mode, contact)}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, gettext("Could not process that request — please try again."))}
    end
  end
end
