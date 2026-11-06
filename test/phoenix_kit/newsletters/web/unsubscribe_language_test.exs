defmodule PhoenixKit.Newsletters.Web.UnsubscribeLanguageTest do
  @moduledoc """
  The public unsubscribe pages answer in the language of the email the link came
  from: a visitor there has no session to take one from. Drives the real
  templates, because the strings only reach this package's catalogs if the
  controller and the view both name its backend after core's.
  """

  use PhoenixKitNewsletters.DataCase, async: false

  alias PhoenixKit.Newsletters.Gettext, as: NewslettersGettext
  alias PhoenixKit.Newsletters.RecipientLanguage
  alias PhoenixKit.Newsletters.Web.UnsubscribeController
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.RecipientLocale
  alias PhoenixKitCRM.Contacts
  alias PhoenixKitCRM.Lists
  alias PhoenixKitNewsletters.Test.Repo

  @public_msgids [
    "Manage email subscriptions",
    "This unsubscribe link is no longer valid.",
    "Unsubscribe from %{list}?",
    "You were already unsubscribed from %{list}.",
    "You've been unsubscribed from %{list}.",
    "Unsubscribe from this list",
    "OR",
    "Unsubscribe from all newsletters",
    "You've been unsubscribed from all newsletters.",
    "Unsubscribe from these newsletters?",
    "You've already unsubscribed from these newsletters.",
    "You've been unsubscribed from these newsletters.",
    "Unsubscribe",
    "We could not unsubscribe you right now. Please try again."
  ]

  setup do
    enable_crm()
    :ok
  end

  defp build_conn(method) do
    session_opts = Plug.Session.init(store: :cookie, key: "_test", signing_salt: "test_salt")

    Plug.Test.conn(method, "/newsletters/unsubscribe")
    |> Map.put(:secret_key_base, String.duplicate("a", 64))
    |> Plug.Session.call(session_opts)
    |> Plug.Conn.fetch_session()
    |> Plug.Conn.fetch_query_params()
    |> Phoenix.Controller.fetch_flash(%{})
    |> Phoenix.Controller.put_view(html: PhoenixKit.Newsletters.Web.UnsubscribeHTML)
    |> then(&%{&1 | params: Map.put(&1.params, "_format", "html")})
  end

  defp endpoint, do: PhoenixKit.Config.get(:endpoint, PhoenixKitWeb.Endpoint)

  defp crm_token(contact, list) do
    Phoenix.Token.sign(endpoint(), "unsubscribe", %{
      contact_uuid: contact.uuid,
      crm_list_uuid: list.uuid
    })
  end

  defp role_token(user) do
    Phoenix.Token.sign(endpoint(), "newsletters_user_optout", %{user_uuid: user.uuid})
  end

  defp member(contact_locale, list_attrs) do
    {:ok, list} = Lists.create_list(Map.merge(%{name: "Weekly"}, list_attrs))

    {:ok, contact} =
      Contacts.create_contact(%{
        name: "Reader",
        email: "reader-#{System.unique_integer([:positive])}@example.com",
        locale: contact_locale
      })

    {:ok, _} = Lists.add_contact_to_list(contact, list, source: "manual")
    {contact, list}
  end

  defp user(preferred_locale) do
    {:ok, user} =
      %User{}
      |> User.guest_user_changeset(%{
        email: "reader-#{System.unique_integer([:positive])}@example.com"
      })
      |> Repo.insert()

    user
    |> Ecto.Changeset.change(custom_fields: %{"preferred_locale" => preferred_locale})
    |> Repo.update!()
  end

  defp get(token), do: UnsubscribeController.unsubscribe(build_conn(:get), %{"token" => token})

  defp post(token, scope) do
    UnsubscribeController.process_unsubscribe(build_conn(:post), %{
      "token" => token,
      "scope" => scope
    })
  end

  describe "the CRM page" do
    test "is in the contact's language, over the list's" do
      {contact, list} = member("ru", %{locale: "et"})
      html = get(crm_token(contact, list)).resp_body

      assert html =~ "Управление подписками"
      assert html =~ "Отписаться от «Weekly»?"
      assert html =~ "Отписаться от этого списка"
      assert html =~ "Отписаться от всех рассылок"
      refute html =~ "Unsubscribe"
    end

    test "is in the list's language when the contact has none" do
      {contact, list} = member(nil, %{locale: "et"})

      assert get(crm_token(contact, list)).resp_body =~ "Kas loobuda loendist „Weekly”?"
    end

    test "a dialect reads its base language's catalog" do
      {contact, list} = member("ru-RU", %{})

      assert get(crm_token(contact, list)).resp_body =~ "Отписаться от «Weekly»?"
    end

    test "stays in that language through the unsubscribe and after it" do
      {contact, list} = member("ru", %{})
      token = crm_token(contact, list)

      assert post(token, "list").resp_body =~ "Вы были отписаны от «Weekly»."
      assert get(token).resp_body =~ "Вы уже были отписаны от «Weekly»."
    end

    test "unsubscribing from everything answers in that language" do
      {contact, list} = member("ru", %{})

      assert post(crm_token(contact, list), "all").resp_body =~
               "Вы были отписаны от всех рассылок."
    end

    test "escapes a list's name, translated sentence or not" do
      {contact, list} = member("ru", %{name: "<script>x</script>"})
      html = get(crm_token(contact, list)).resp_body

      refute html =~ "<script>x"
      assert html =~ "&lt;script&gt;x"
    end
  end

  describe "the role page" do
    test "is in the user's preferred language, dialect included" do
      token = role_token(user("et-EE"))

      assert get(token).resp_body =~ "Kas loobuda nendest uudiskirjadest?"
      assert post(token, "role_optout").resp_body =~ "Oled nüüd nendest uudiskirjadest loobunud."
      assert get(token).resp_body =~ "Oled nendest uudiskirjadest juba loobunud."
    end
  end

  test "a token that resolves to nobody gets the site's language, not a crash" do
    token = crm_token(%{uuid: Ecto.UUID.generate()}, %{uuid: Ecto.UUID.generate()})

    assert get(token).resp_body =~ "This unsubscribe link is no longer valid."
  end

  test "the locale is put back: a keep-alive connection reuses this process" do
    {contact, list} = member("ru", %{})
    before = {Gettext.get_locale(), Gettext.get_locale(PhoenixKitWeb.Gettext)}

    assert get(crm_token(contact, list)).resp_body =~ "Отписаться"

    assert {Gettext.get_locale(), Gettext.get_locale(PhoenixKitWeb.Gettext)} == before
  end

  describe "RecipientLanguage.for_contact/2" do
    test "takes the contact's, then the list's, then the site's" do
      assert RecipientLanguage.for_contact(%{locale: "ru"}, %{locale: "et"}) == "ru"
      assert RecipientLanguage.for_contact(%{locale: nil}, %{locale: "et"}) == "et"

      assert RecipientLanguage.for_contact(%{locale: ""}, nil) ==
               RecipientLocale.for_rendering(nil)
    end
  end

  test "every string on these pages is translated" do
    for locale <- ~w(ru et), msgid <- @public_msgids do
      translated =
        Gettext.with_locale(NewslettersGettext, locale, fn ->
          Gettext.dgettext(NewslettersGettext, "default", msgid, list: "x")
        end)

      refute translated == String.replace(msgid, "%{list}", "x"),
             "#{inspect(msgid)} has no #{locale} translation"
    end
  end
end
