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

  A token visitor is the recipient of the email the link came from, so a
  contact with a language of its own sees the page in it, logged in or not.
  The token names no list, so a contact without one keeps what core's mount
  chose, like the account path.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKit.Newsletters.Gettext

  import PhoenixKitWeb.Components.Core.Checkbox
  import PhoenixKitWeb.Components.Core.Icon

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.CRMSource
  alias PhoenixKit.Newsletters.Paths
  alias PhoenixKit.Newsletters.PreferenceToken
  alias PhoenixKit.Newsletters.RecipientLanguage
  alias PhoenixKit.Newsletters.UserGroupSource
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.RecipientLocale
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    socket = assign(socket, :page_title, gettext("Email preferences"))

    # A public page, so no redirect: a site's `/` may not exist under its prefix.
    mode = if Newsletters.enabled?(), do: :loading, else: :unavailable

    {:ok, assign(socket, mode: mode, contact: nil, lists: [])}
  end

  # Token verification and contact resolution belong in handle_params, not
  # mount. handle_params also runs twice, once for the plain GET and once
  # connected, so the account path's write waits for the connected pass: see
  # resolve_access/2.
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
      socket
      |> use_language_of(contact)
      |> load_lists(:token, contact)
    else
      _ -> assign(socket, mode: :invalid_token, contact: nil, lists: [])
    end
  end

  # Account-nav entry — no token, requires an authenticated scope. Lazily
  # finds/links the contact for this user; never mints a placeholder user
  # (CRMSource.find_or_link_contact_for_user/1 never goes through
  # PhoenixKitCRM.Contacts.connect_user/2). That can write, and a plain GET must
  # not, so the page stays on its spinner until the socket connects.
  defp resolve_access(socket, _params) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    cond do
      is_nil(scope) or not Scope.authenticated?(scope) -> send_to_log_in(socket)
      connected?(socket) -> load_account(socket, Scope.user(scope))
      true -> socket
    end
  end

  defp load_account(socket, user) do
    case CRMSource.find_or_link_contact_for_user(user) do
      {:ok, contact} -> load_lists(socket, :account, contact)
      {:error, :unconfirmed} -> assign(socket, mode: :unconfirmed, contact: nil, lists: [])
      {:error, _} -> assign(socket, mode: :error, contact: nil, lists: [])
    end
  end

  defp send_to_log_in(socket) do
    return_to = URI.encode_www_form(Paths.preferences())

    socket
    |> put_flash(:error, gettext("Please log in to manage your email subscriptions"))
    |> push_navigate(to: Routes.path("/users/log-in") <> "?return_to=#{return_to}")
  end

  # Set on the process, not wrapped in `in_locale/2`: this process goes on to
  # render and to answer events, as with core's own `put_gettext_locale`. Both
  # locales, because the page's wrapper reads core's backend and this package's
  # reads the global one. `mount/3` has already translated the title.
  defp use_language_of(socket, contact) do
    case RecipientLanguage.stated(contact) do
      nil ->
        socket

      language ->
        locale = RecipientLocale.gettext_locale(language)
        Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
        Gettext.put_locale(locale)
        assign(socket, :page_title, gettext("Email preferences"))
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
  #
  # The click means "the other way from what I see", so the direction is the
  # page's, and a list already that way (changed from another tab or email) is
  # not an error. The contact is read again, as for every write here.
  def handle_event("toggle_list", %{"list_uuid" => list_uuid}, socket) do
    with %{list: list, subscribed?: subscribed?} <-
           Enum.find(socket.assigns.lists, fn %{list: l} -> l.uuid == list_uuid end),
         %{} = contact <- current_contact(socket) do
      case toggle(contact, list, subscribed?) do
        :ok ->
          {:noreply, load_lists(socket, socket.assigns.mode, contact)}

        # Reloaded, because the usual reason is that this page is out of date.
        :error ->
          {:noreply,
           socket
           |> put_flash(:error, gettext("Could not update that subscription — please try again."))
           |> load_lists(socket.assigns.mode, contact)}
      end
    else
      _gone ->
        {:noreply, put_flash(socket, :error, gettext("That list is no longer available."))}
    end
  end

  def handle_event("unsubscribe_all", _params, socket) do
    with %{} = contact <- current_contact(socket),
         {:ok, contact} <- UserGroupSource.opt_out_contact(contact, source: "preference_center") do
      {:noreply,
       socket
       |> put_flash(:info, gettext("You've been unsubscribed from all newsletters."))
       |> load_lists(socket.assigns.mode, contact)}
    else
      _error ->
        {:noreply,
         put_flash(socket, :error, gettext("Could not process that request — please try again."))}
    end
  end

  def handle_event("resubscribe", _params, socket) do
    with %{} = contact <- current_contact(socket),
         {:ok, contact} <- UserGroupSource.opt_in_contact(contact, source: "preference_center") do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Welcome back — you can now choose which lists to receive."))
       |> load_lists(socket.assigns.mode, contact)}
    else
      _error ->
        {:noreply,
         put_flash(socket, :error, gettext("Could not process that request — please try again."))}
    end
  end

  # The contact as it is now, not as the page loaded it: CRM judges an opt-out or
  # opt-in on the struct it is given and writes the consent log from it, so a copy
  # as old as the tab would erase what an email link or an admin recorded since,
  # and the first opt-out's time with it. `nil` when there is none (any more).
  defp current_contact(%{assigns: %{contact: %{uuid: uuid}}}), do: CRMSource.get_contact(uuid)
  defp current_contact(_socket), do: nil

  # Idempotent; a contact never on the list is already where the click wants it.
  defp toggle(contact, list, true = _subscribed?) do
    case CRMSource.remove_from_list(contact, list) do
      {:ok, _member} -> :ok
      {:error, :not_member} -> :ok
    end
  end

  defp toggle(contact, list, false = _subscribed?) do
    case CRMSource.subscribe(contact, list) do
      {:ok, _member} -> :ok
      {:error, :already_member} -> :ok
      {:error, _reason} -> :error
    end
  end
end
