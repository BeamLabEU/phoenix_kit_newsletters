defmodule PhoenixKit.Newsletters.Web.ProcessUnsubscribeScopeAllTest do
  @moduledoc """
  Tests for `UnsubscribeController.process_unsubscribe/2`'s `scope=all`
  crm_list branch — previously untested (the neighboring
  unsubscribe_controller_test.exs only covers the token-free branches;
  see its trailing comment). This branch used to discard
  `CRMSource.opt_out/1`'s result entirely, so an `{:error, _}` return
  silently rendered the same "unsubscribed from all" success flash as a
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

  alias PhoenixKit.Newsletters.Web.UnsubscribeController
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
  end

  defp create_contact do
    {:ok, contact} =
      Contacts.create_contact(%{
        name: "Scope All",
        email: "scope-all-#{System.unique_integer([:positive])}@example.com"
      })

    contact
  end

  test "opts the contact out and shows the success flash" do
    contact = create_contact()
    token = sign_token(contact.uuid)

    conn =
      build_conn()
      |> UnsubscribeController.process_unsubscribe(%{"token" => token, "scope" => "all"})

    assert conn.status == 302
    assert conn.assigns[:flash]["info"] =~ "unsubscribed from all newsletters"
    refute conn.assigns[:flash]["error"]

    reloaded = Repo.get_by(contact.__struct__, uuid: contact.uuid)
    assert reloaded.opted_out_at
  end

  test "an unresolvable contact_uuid shows an error flash, not the success text" do
    token = sign_token(Ecto.UUID.generate())

    conn =
      build_conn()
      |> UnsubscribeController.process_unsubscribe(%{"token" => token, "scope" => "all"})

    assert conn.status == 302
    assert conn.assigns[:flash]["error"] =~ "Invalid link."
    refute conn.assigns[:flash]["info"]
  end
end
