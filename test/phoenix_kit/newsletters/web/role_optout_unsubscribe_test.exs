defmodule PhoenixKit.Newsletters.Web.RoleOptoutUnsubscribeTest do
  @moduledoc """
  Tests for the `user_group` broadcast recipient's unsubscribe path —
  fixes an external-review MAJOR finding on PR#22: a role-sourced
  delivery (`user_uuid` + `recipient_email: nil`) used to fall into the
  newsletters-list token clause with `list_uuid: nil`, minting a token
  that verified fine but resolved to nothing on every action
  (`Newsletters.unsubscribe_user/2` against a nil list_uuid matches no
  `ListMember` row), and — critically — never wrote the
  `contact.opted_out_at` that `UserGroupSource.opted_out?/1` reads. The
  mail carried a `List-Unsubscribe` header/link that could not actually
  opt the recipient out of what they received.

  Covers both opt-out paths `UserGroupSource.record_opt_out/1` writes:
  always `custom_fields["newsletters_opted_out_at"]` on the user, and
  additionally the linked CRM contact's `opted_out_at` when one exists
  (`phoenix_kit_crm` is a test-only dependency — see mix.exs — so this
  is exercised against the real CRM schema, not simulated).
  """

  use PhoenixKitNewsletters.DataCase, async: false

  alias PhoenixKit.Newsletters.UserGroupSource
  alias PhoenixKit.Newsletters.Web.UnsubscribeController
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Roles
  alias PhoenixKitCRM.Contacts
  alias PhoenixKitCRM.Schemas.Contact
  alias PhoenixKitNewsletters.Test.Repo

  defp sign_token(user_uuid) do
    endpoint = PhoenixKit.Config.get(:endpoint, PhoenixKitWeb.Endpoint)
    Phoenix.Token.sign(endpoint, "newsletters_user_optout", %{user_uuid: user_uuid})
  end

  # A flavor-A (newsletters_list) token — same claim key (user_uuid) the
  # role flavor uses, plus list_uuid, signed under the *other* salt.
  # Its claims are a superset of the role flavor's bare %{user_uuid:},
  # which is exactly the shape overlap verify_token/1's salt tagging
  # exists to defuse — see the cross-flavor rejection tests below.
  defp sign_list_flavor_token(user_uuid, list_uuid) do
    endpoint = PhoenixKit.Config.get(:endpoint, PhoenixKitWeb.Endpoint)
    Phoenix.Token.sign(endpoint, "unsubscribe", %{user_uuid: user_uuid, list_uuid: list_uuid})
  end

  defp build_conn(method, path) do
    session_opts = Plug.Session.init(store: :cookie, key: "_test", signing_salt: "test_salt")

    Plug.Test.conn(method, path)
    |> Map.put(:secret_key_base, String.duplicate("a", 64))
    |> Plug.Session.call(session_opts)
    |> Plug.Conn.fetch_session()
    |> Plug.Conn.fetch_query_params()
    |> Phoenix.Controller.fetch_flash(%{})
    # The action functions are called directly here (bypassing the
    # router/Phoenix.Controller.Pipeline, same as every other test in
    # this suite), so neither the module-level `plug(:put_view, ...)`
    # nor a `plug :accepts` ever actually runs — render/2 needs both the
    # view and conn.params["_format"] set some other way, or it raises.
    # Mirrors what that pipeline would have done.
    |> Phoenix.Controller.put_view(html: PhoenixKit.Newsletters.Web.UnsubscribeHTML)
    |> then(&%{&1 | params: Map.put(&1.params, "_format", "html")})
  end

  defp create_user(attrs \\ %{}) do
    base = %{email: "role-optout-#{System.unique_integer([:positive])}@example.com"}

    {:ok, user} =
      %User{}
      |> User.guest_user_changeset(Map.merge(base, attrs))
      |> Repo.insert()

    user
  end

  defp link_contact(user) do
    {:ok, contact} =
      Contacts.create_contact(%{
        name: "Contact",
        email: "role-optout-contact-#{System.unique_integer()}@example.com"
      })

    contact |> Contact.link_user_changeset(user.uuid) |> Repo.update!()
  end

  describe "GET — must never mutate" do
    test "renders the confirm state without writing any opt-out" do
      user = create_user()
      token = sign_token(user.uuid)

      conn =
        build_conn(:get, "/newsletters/unsubscribe")
        |> UnsubscribeController.unsubscribe(%{"token" => token})

      assert conn.status == 200
      assert conn.assigns.role_optout_state == :confirm

      reloaded = Repo.get(User, user.uuid)
      refute UserGroupSource.opted_out?(reloaded)
    end

    test "renders already_unsubscribed for a user already opted out, still without mutating further" do
      user = create_user()
      {:ok, user} = UserGroupSource.record_opt_out(user)
      token = sign_token(user.uuid)

      conn =
        build_conn(:get, "/newsletters/unsubscribe")
        |> UnsubscribeController.unsubscribe(%{"token" => token})

      assert conn.status == 200
      assert conn.assigns.role_optout_state == :already_unsubscribed
    end

    test "renders invalid for a well-signed token whose user no longer exists" do
      token = sign_token(Ecto.UUID.generate())

      conn =
        build_conn(:get, "/newsletters/unsubscribe")
        |> UnsubscribeController.unsubscribe(%{"token" => token})

      assert conn.status == 200
      assert conn.assigns.role_optout_state == :invalid
    end
  end

  describe "POST /newsletters/unsubscribe (scope=role_optout) — without a linked CRM contact" do
    test "writes custom_fields[newsletters_opted_out_at] and excludes the user from the next resolve" do
      {:ok, role} = Roles.create_role(%{name: "Role#{System.unique_integer()}"})
      user = create_user()
      {:ok, _assignment} = Roles.assign_role(user, role.name)
      token = sign_token(user.uuid)

      assert UserGroupSource.sendable_recipients([role.uuid]) == [
               %{user_uuid: user.uuid, email: user.email}
             ]

      conn =
        build_conn(:post, "/newsletters/unsubscribe")
        |> UnsubscribeController.process_unsubscribe(%{
          "token" => token,
          "scope" => "role_optout"
        })

      assert conn.status == 200
      assert conn.assigns.role_optout_state == :unsubscribed

      reloaded = Repo.get(User, user.uuid)
      assert reloaded.custom_fields["newsletters_opted_out_at"]
      assert UserGroupSource.opted_out?(reloaded)

      # The resolver excludes the now-opted-out user from the exact same
      # role it included them in a moment ago.
      assert UserGroupSource.sendable_recipients([role.uuid]) == []
    end

    test "idempotent — a repeat POST doesn't crash and leaves the same opted-out state" do
      user = create_user()
      token = sign_token(user.uuid)

      assert %{status: 200} =
               build_conn(:post, "/newsletters/unsubscribe")
               |> UnsubscribeController.process_unsubscribe(%{
                 "token" => token,
                 "scope" => "role_optout"
               })

      conn =
        build_conn(:post, "/newsletters/unsubscribe")
        |> UnsubscribeController.process_unsubscribe(%{
          "token" => token,
          "scope" => "role_optout"
        })

      assert conn.status == 200
      assert conn.assigns.role_optout_state == :unsubscribed

      reloaded = Repo.get(User, user.uuid)
      assert UserGroupSource.opted_out?(reloaded)
    end
  end

  describe "POST /newsletters/unsubscribe (scope=role_optout) — with a linked CRM contact" do
    test "also opts the linked contact out, keeping both opt-out paths consistent" do
      user = create_user()
      contact = link_contact(user)
      token = sign_token(user.uuid)

      conn =
        build_conn(:post, "/newsletters/unsubscribe")
        |> UnsubscribeController.process_unsubscribe(%{
          "token" => token,
          "scope" => "role_optout"
        })

      assert conn.status == 200

      reloaded_user = Repo.get(User, user.uuid)
      assert reloaded_user.custom_fields["newsletters_opted_out_at"]

      reloaded_contact = Repo.get(Contact, contact.uuid)
      assert reloaded_contact.opted_out_at
    end
  end

  describe "one-click POST — the List-Unsubscribe-Post header target" do
    test "opts the user out and returns a blank 200" do
      user = create_user()
      token = sign_token(user.uuid)

      conn =
        build_conn(:post, "/newsletters/unsubscribe/one-click")
        |> UnsubscribeController.one_click_unsubscribe(%{"token" => token})

      assert conn.status == 200
      assert conn.resp_body == ""

      reloaded = Repo.get(User, user.uuid)
      assert UserGroupSource.opted_out?(reloaded)
    end

    test "GET falls back to the interactive confirm page and does not mutate" do
      user = create_user()
      token = sign_token(user.uuid)

      conn =
        build_conn(:get, "/newsletters/unsubscribe/one-click")
        |> UnsubscribeController.one_click_unsubscribe(%{"token" => token})

      assert conn.status == 302
      [location] = Plug.Conn.get_resp_header(conn, "location")
      assert location =~ "/newsletters/unsubscribe"

      reloaded = Repo.get(User, user.uuid)
      refute UserGroupSource.opted_out?(reloaded)
    end
  end

  describe "preflight — an opted-out user is counted as unsendable" do
    test "reflects the opt-out immediately after record_opt_out/1" do
      {:ok, role} = Roles.create_role(%{name: "Role#{System.unique_integer()}"})
      user = create_user()
      {:ok, _assignment} = Roles.assign_role(user, role.name)

      assert %{sendable: 1, unsendable: 0} = UserGroupSource.preflight([role.uuid])

      {:ok, _user} = UserGroupSource.record_opt_out(Repo.get(User, user.uuid))

      assert %{sendable: 0, unsendable: 1} = UserGroupSource.preflight([role.uuid])
    end
  end

  describe "cross-flavor rejection — verify_token/1's salt tag is load-bearing" do
    test "a flavor-A (newsletters_list) token is rejected by scope=role_optout, not treated as a role opt-out" do
      user = create_user()
      # A real list to reference no longer exists at all (core V156
      # dropped the tables) — the token only needs the CLAIM SHAPE a
      # genuine pre-removal flavor-A token had; verify_token/1 doesn't
      # look the list up to accept the "unsubscribe" salt.
      token = sign_list_flavor_token(user.uuid, Ecto.UUID.generate())

      conn =
        build_conn(:post, "/newsletters/unsubscribe")
        |> UnsubscribeController.process_unsubscribe(%{
          "token" => token,
          "scope" => "role_optout"
        })

      assert conn.status == 302

      reloaded = Repo.get(User, user.uuid)
      refute UserGroupSource.opted_out?(reloaded)
    end

    test "a role_optout token is not absorbed by scope=all's crm_list-based opt-out" do
      user = create_user()
      token = sign_token(user.uuid)

      conn =
        build_conn(:post, "/newsletters/unsubscribe")
        |> UnsubscribeController.process_unsubscribe(%{"token" => token, "scope" => "all"})

      assert conn.status == 302

      # Not opted out via the role-optout path — scope=all's only
      # remaining clause requires a contact_uuid claim, which this
      # token doesn't carry, so it falls to the catch-all "invalid
      # link" branch rather than silently succeeding at nothing.
      reloaded = Repo.get(User, user.uuid)
      refute UserGroupSource.opted_out?(reloaded)
    end
  end
end
