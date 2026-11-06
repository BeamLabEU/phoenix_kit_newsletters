defmodule PhoenixKit.Newsletters.Web.ProcessUnsubscribeScopeAllTest do
  @moduledoc """
  Tests for `UnsubscribeController.process_unsubscribe/2`'s `scope=all`
  crm_list branch — previously untested (the neighboring
  unsubscribe_controller_test.exs only covers the token-free branches;
  see its trailing comment). This branch used to discard
  `CRMSource.opt_out/1`'s result entirely, so an `{:error, _}` return
  silently rendered the same "unsubscribed from all" success message as a
  real success — code review flagged this.

  The `{:error, _reason}` arm added alongside the fix isn't independently
  exercised here: `CRMSource.opt_out/1`'s underlying changeset
  (`PhoenixKitCRM.Lists.set_consent/3`) doesn't declare any
  `unique_constraint`/`check_constraint` mapping, so a genuine DB-level
  failure surfaces as a raised `Ecto.ConstraintError`/`Ecto.StaleEntryError`
  rather than a graceful `{:error, changeset}` return — not reproducible
  here without mocking. What *is* covered: the branch is no longer a
  silent no-op (proven by the success test asserting the contact is
  actually opted out), and the sibling nil-contact arm of the same `with`
  still renders the correct error state instead of a false success.
  """

  use PhoenixKitNewsletters.DataCase, async: false

  alias PhoenixKit.Newsletters.UserGroupSource
  alias PhoenixKit.Newsletters.Web.UnsubscribeController
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitCRM.Contacts
  alias PhoenixKitNewsletters.Test.Repo

  defp sign_token(contact_uuid) do
    endpoint = PhoenixKit.Config.get(:endpoint, PhoenixKitWeb.Endpoint)
    Phoenix.Token.sign(endpoint, "unsubscribe", %{contact_uuid: contact_uuid})
  end

  defp build_conn do
    session_opts = Plug.Session.init(store: :cookie, key: "_test", signing_salt: "test_salt")

    Plug.Test.conn(:post, "/newsletters/unsubscribe")
    |> Map.put(:secret_key_base, String.duplicate("a", 64))
    |> Plug.Session.call(session_opts)
    |> Plug.Conn.fetch_session()
    |> Plug.Conn.fetch_query_params()
    |> Phoenix.Controller.fetch_flash(%{})
    |> Phoenix.Controller.put_view(html: PhoenixKit.Newsletters.Web.UnsubscribeHTML)
    |> then(&%{&1 | params: Map.put(&1.params, "_format", "html")})
  end

  defp create_contact do
    {:ok, contact} =
      Contacts.create_contact(%{
        name: "Scope All",
        email: "scope-all-#{System.unique_integer([:positive])}@example.com"
      })

    contact
  end

  test "opts the contact out and says so on the page" do
    contact = create_contact()
    token = sign_token(contact.uuid)

    conn =
      build_conn()
      |> UnsubscribeController.process_unsubscribe(%{"token" => token, "scope" => "all"})

    assert conn.status == 200
    assert conn.resp_body =~ "unsubscribed from all newsletters"

    reloaded = Repo.get_by(contact.__struct__, uuid: contact.uuid)
    assert reloaded.opted_out_at
  end

  test "reaches the account holding the address too, so role mail stops as well" do
    {:ok, user} =
      %User{}
      |> User.guest_user_changeset(%{
        email: "account-#{System.unique_integer([:positive])}@example.com"
      })
      |> Repo.insert()

    {:ok, contact} = Contacts.create_contact(%{name: "Same person", email: user.email})

    build_conn()
    |> UnsubscribeController.process_unsubscribe(%{
      "token" => sign_token(contact.uuid),
      "scope" => "all"
    })

    assert UserGroupSource.opted_out?(Repo.get(User, user.uuid))
  end

  test "an unresolvable contact_uuid says the link is invalid, not that it worked" do
    token = sign_token(Ecto.UUID.generate())

    conn =
      build_conn()
      |> UnsubscribeController.process_unsubscribe(%{"token" => token, "scope" => "all"})

    assert conn.resp_body =~ "no longer valid"
    refute conn.resp_body =~ "unsubscribed from all newsletters"
  end
end
