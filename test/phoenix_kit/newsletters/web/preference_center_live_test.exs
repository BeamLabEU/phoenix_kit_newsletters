defmodule PhoenixKit.Newsletters.Web.PreferenceCenterLiveTest do
  @moduledoc """
  Direct callback-invocation unit tests for `PreferenceCenterLive` — no
  connected LiveView process needed (this package ships no real
  `PhoenixKitWeb.Endpoint`, so `Phoenix.LiveViewTest.live/2` isn't
  available here; see `BroadcastEditorTest`'s moduledoc for the same
  rationale).
  """

  use PhoenixKitNewsletters.DataCase, async: false

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.CRMSource
  alias PhoenixKit.Newsletters.PreferenceToken
  alias PhoenixKit.Newsletters.UserGroupSource
  alias PhoenixKit.Newsletters.Web.PreferenceCenterLive
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitCRM.Contacts
  alias PhoenixKitCRM.Lists
  alias PhoenixKitNewsletters.Test.Repo

  setup do
    Newsletters.enable_system()
    :ok
  end

  defp socket(assigns \\ %{}) do
    base = %{flash: %{}, __changed__: %{}}
    %Phoenix.LiveView.Socket{assigns: Map.merge(base, assigns), transport_pid: self()}
  end

  # Token verification, contact resolution, and the account-path's
  # find-or-create write all live in handle_params now (mount only does
  # the enabled?/0 gate) — mirrors the real LiveView lifecycle, where
  # handle_params always runs right after mount unless mount already
  # redirected. Every test below drives the callbacks through this same
  # sequence instead of assuming mount alone resolves `mode`/`contact`/`lists`.
  defp mount_and_resolve(params, session, socket) do
    case PreferenceCenterLive.mount(params, session, socket) do
      {:ok, %{redirected: redirected} = socket} when not is_nil(redirected) ->
        {:ok, socket}

      {:ok, socket} ->
        {:noreply, socket} = PreferenceCenterLive.handle_params(params, "/", socket)
        {:ok, socket}
    end
  end

  defp create_user do
    {:ok, user} =
      %User{}
      |> User.guest_user_changeset(%{
        email: "prefs-user-#{System.unique_integer([:positive])}@example.com"
      })
      |> Repo.insert()

    user
  end

  defp confirmed(user) do
    user
    |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!()
  end

  defp add_contact(attrs \\ %{}) do
    base = %{name: "Contact", email: "contact-#{System.unique_integer([:positive])}@example.com"}
    {:ok, contact} = Contacts.create_contact(Map.merge(base, attrs))
    contact
  end

  defp subscribable_list(attrs \\ %{}) do
    base = %{name: "List #{System.unique_integer([:positive])}", subscribable: true}
    {:ok, list} = Lists.create_list(Map.merge(base, attrs))
    list
  end

  describe "mount + handle_params — token access (no login required)" do
    test "a valid token loads the named contact's subscribable lists, mode: :token" do
      contact = add_contact()
      list = subscribable_list()
      token = PreferenceToken.sign(contact.uuid)

      {:ok, updated} = mount_and_resolve(%{"token" => token}, %{}, socket())

      assert updated.assigns.mode == :token
      assert updated.assigns.contact.uuid == contact.uuid
      assert Enum.any?(updated.assigns.lists, fn %{list: l} -> l.uuid == list.uuid end)
    end

    test "a visitor with no session/scope assign at all still gets full token access" do
      contact = add_contact()
      token = PreferenceToken.sign(contact.uuid)

      {:ok, updated} = mount_and_resolve(%{"token" => token}, %{}, socket())

      assert updated.assigns.mode == :token
      refute updated.redirected
    end

    test "an invalid/garbage token yields mode: :invalid_token, not a crash" do
      {:ok, updated} = mount_and_resolve(%{"token" => "garbage"}, %{}, socket())

      assert updated.assigns.mode == :invalid_token
      assert updated.assigns.contact == nil
    end

    test "a well-formed token naming a nonexistent contact yields mode: :invalid_token — no data leaked" do
      token = PreferenceToken.sign(Ecto.UUID.generate())

      {:ok, updated} = mount_and_resolve(%{"token" => token}, %{}, socket())

      assert updated.assigns.mode == :invalid_token
    end
  end

  describe "mount + handle_params — logged-in account access" do
    test "lazily creates and links a contact on first visit, then reuses it on a later mount" do
      user = confirmed(create_user())
      scope = Scope.for_user(user)

      {:ok, first} =
        mount_and_resolve(%{}, %{}, socket(%{phoenix_kit_current_scope: scope}))

      assert first.assigns.mode == :account
      assert first.assigns.contact.user_uuid == user.uuid

      {:ok, second} =
        mount_and_resolve(%{}, %{}, socket(%{phoenix_kit_current_scope: scope}))

      assert second.assigns.contact.uuid == first.assigns.contact.uuid
      assert length(Contacts.list_by_email(user.email)) == 1
    end

    test "no token and no authenticated scope redirects to login, without crashing" do
      {:ok, updated} = mount_and_resolve(%{}, %{}, socket())

      assert updated.redirected != nil
    end

    test "no token and an explicitly unauthenticated scope also redirects to login" do
      {:ok, updated} =
        mount_and_resolve(
          %{},
          %{},
          socket(%{phoenix_kit_current_scope: %Scope{authenticated?: false}})
        )

      assert updated.redirected != nil
    end
  end

  describe "an account's first visit" do
    test "writes nothing on the plain GET, and waits for the socket" do
      user = confirmed(create_user())
      scope = Scope.for_user(user)
      dead = %{socket(%{phoenix_kit_current_scope: scope}) | transport_pid: nil}

      {:ok, updated} = mount_and_resolve(%{}, %{}, dead)

      assert updated.assigns.mode == :loading
      assert Contacts.list_by_email(user.email) == []
    end

    test "an unconfirmed account cannot take the contact holding its address" do
      user = create_user()
      existing = add_contact(%{email: user.email})
      scope = Scope.for_user(user)

      {:ok, updated} = mount_and_resolve(%{}, %{}, socket(%{phoenix_kit_current_scope: scope}))

      assert updated.assigns.mode == :unconfirmed
      assert updated.assigns.contact == nil
      assert CRMSource.get_contact(existing.uuid).user_uuid == nil
    end
  end

  describe "with the module switched off" do
    test "says so here, rather than redirecting to a `/` that may not exist" do
      Newsletters.disable_system()

      {:ok, updated} = mount_and_resolve(%{}, %{}, socket())

      assert updated.assigns.mode == :unavailable
      assert updated.redirected == nil
    end
  end

  describe "unsubscribe from all, and back" do
    test "reaches every contact at the address and the account" do
      user = create_user()
      contact = add_contact(%{email: user.email})
      twin = add_contact(%{email: user.email})
      token = PreferenceToken.sign(contact.uuid)

      {:ok, socket} = mount_and_resolve(%{"token" => token}, %{}, socket())
      {:noreply, _socket} = PreferenceCenterLive.handle_event("unsubscribe_all", %{}, socket)

      assert CRMSource.get_contact(twin.uuid).opted_out_at
      assert UserGroupSource.opted_out?(Repo.get(User, user.uuid))
    end

    test "resubscribing brings all of it back" do
      user = create_user()
      contact = add_contact(%{email: user.email})
      token = PreferenceToken.sign(contact.uuid)

      {:ok, socket} = mount_and_resolve(%{"token" => token}, %{}, socket())
      {:noreply, socket} = PreferenceCenterLive.handle_event("unsubscribe_all", %{}, socket)
      {:noreply, _socket} = PreferenceCenterLive.handle_event("resubscribe", %{}, socket)

      refute CRMSource.get_contact(contact.uuid).opted_out_at
      refute UserGroupSource.opted_out?(Repo.get(User, user.uuid))
    end
  end

  describe "handle_event/3 toggle_list" do
    test "subscribes when not yet subscribed, then unsubscribes on a second toggle" do
      contact = add_contact()
      list = subscribable_list()

      {:ok, mounted} =
        mount_and_resolve(
          %{"token" => PreferenceToken.sign(contact.uuid)},
          %{},
          socket()
        )

      {:noreply, after_subscribe} =
        PreferenceCenterLive.handle_event("toggle_list", %{"list_uuid" => list.uuid}, mounted)

      assert CRMSource.subscribed?(contact, list)
      assert [%{subscribed?: true}] = after_subscribe.assigns.lists

      {:noreply, after_unsubscribe} =
        PreferenceCenterLive.handle_event(
          "toggle_list",
          %{"list_uuid" => list.uuid},
          after_subscribe
        )

      refute CRMSource.subscribed?(contact, list)
      assert [%{subscribed?: false}] = after_unsubscribe.assigns.lists
    end

    test "a list_uuid outside the loaded set is rejected without crashing or acting" do
      contact = add_contact()
      _list = subscribable_list()

      {:ok, mounted} =
        mount_and_resolve(
          %{"token" => PreferenceToken.sign(contact.uuid)},
          %{},
          socket()
        )

      {:noreply, updated} =
        PreferenceCenterLive.handle_event(
          "toggle_list",
          %{"list_uuid" => Ecto.UUID.generate()},
          mounted
        )

      assert Phoenix.Flash.get(updated.assigns.flash, :error)
    end
  end

  describe "handle_event/3 unsubscribe_all and resubscribe" do
    test "unsubscribe_all sets the contact-level opted_out_at, resubscribe clears it" do
      contact = add_contact()
      _list = subscribable_list()

      {:ok, mounted} =
        mount_and_resolve(
          %{"token" => PreferenceToken.sign(contact.uuid)},
          %{},
          socket()
        )

      {:noreply, opted_out} = PreferenceCenterLive.handle_event("unsubscribe_all", %{}, mounted)
      assert opted_out.assigns.contact.opted_out_at != nil
      assert CRMSource.get_contact(contact.uuid).opted_out_at != nil

      {:noreply, resubscribed} = PreferenceCenterLive.handle_event("resubscribe", %{}, opted_out)
      assert resubscribed.assigns.contact.opted_out_at == nil
      assert CRMSource.get_contact(contact.uuid).opted_out_at == nil
    end
  end

  # Core's mount sets the locale from the URL or the site default, never from the
  # recipient, so a token visitor needs the contact's language put in its place.
  describe "a token visitor's language" do
    test "is the contact's own, for this package and for core's wrapper" do
      contact = add_contact(%{locale: "ru"})

      {:ok, socket} =
        mount_and_resolve(%{"token" => PreferenceToken.sign(contact.uuid)}, %{}, socket())

      assert socket.assigns.mode == :token
      assert Gettext.get_locale() == "ru"
      assert Gettext.get_locale(PhoenixKitWeb.Gettext) == "ru"
      assert socket.assigns.page_title == "Настройки рассылок"
    end

    test "stays what core's mount chose when the contact states none" do
      Gettext.put_locale("et")
      contact = add_contact()

      {:ok, _socket} =
        mount_and_resolve(%{"token" => PreferenceToken.sign(contact.uuid)}, %{}, socket())

      assert Gettext.get_locale() == "et"
    end

    test "an invalid token changes nothing" do
      Gettext.put_locale("et")
      {:ok, socket} = mount_and_resolve(%{"token" => "nope"}, %{}, socket())

      assert socket.assigns.mode == :invalid_token
      assert Gettext.get_locale() == "et"
    end
  end
end
