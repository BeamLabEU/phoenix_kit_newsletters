defmodule PhoenixKit.Newsletters.PublicLinksTest.Routes do
  @moduledoc false
  alias PhoenixKit.Newsletters.Web.Routes

  defmacro generated, do: Routes.generate("/")
end

defmodule PhoenixKit.Newsletters.PublicLinksTest.Router do
  @moduledoc false
  use Phoenix.Router, helpers: false

  import Phoenix.LiveView.Router

  alias PhoenixKit.Newsletters.PublicLinksTest.Routes, as: Generated

  require Generated

  pipeline :browser do
    plug(:accepts, ["html"])
  end

  Generated.generated()
end

defmodule PhoenixKit.Newsletters.PublicLinksTest do
  @moduledoc """
  What a multilingual site does to public links. `Routes.path/1` adds a locale
  segment, and the unsubscribe routes exist at the root only, so a link built that
  way 404s: in every mail, and in the form on the page it opens.
  """

  use PhoenixKitNewsletters.DataCase, async: false

  import Swoosh.TestAssertions

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Delivery
  alias PhoenixKit.Newsletters.Paths
  alias PhoenixKit.Newsletters.UnsubscribeToken
  alias PhoenixKit.Newsletters.Workers.DeliveryWorker
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitCRM.Contacts
  alias PhoenixKitCRM.Lists
  alias PhoenixKitNewsletters.Test.Repo

  @router PhoenixKit.Newsletters.PublicLinksTest.Router

  setup :set_swoosh_global

  setup do
    Languages.enable_system()
    previous = Gettext.get_locale(PhoenixKitWeb.Gettext)
    Gettext.put_locale(PhoenixKitWeb.Gettext, "et")
    on_exit(fn -> Gettext.put_locale(PhoenixKitWeb.Gettext, previous) end)
    :ok
  end

  defp no_locale?(path), do: path =~ ~r"(^|/)newsletters/" and not (path =~ "/et/")

  test "the trap: core would put a locale in these paths" do
    assert Routes.path("/newsletters/unsubscribe") =~ "/et/newsletters/unsubscribe"
  end

  test "the paths this module builds carry none" do
    assert no_locale?(Paths.unsubscribe())
    assert no_locale?(Paths.preferences())
    assert no_locale?(Paths.unsubscribe_url("t"))
    assert no_locale?(Paths.one_click_unsubscribe_url("t"))
    assert no_locale?(Paths.preferences_url("t"))
  end

  test "each one is a route that exists" do
    for path <- [Paths.unsubscribe(), Paths.preferences()] do
      assert %{} = Phoenix.Router.route_info(@router, "GET", strip_prefix(path), "host")
    end

    assert %{} =
             Phoenix.Router.route_info(
               @router,
               "POST",
               "/newsletters/unsubscribe/one-click",
               "host"
             )
  end

  test "a dashboard tab's localized path has a route too, because the sidebar builds one" do
    assert %{} =
             Phoenix.Router.route_info(@router, "GET", "/et/newsletters/preferences", "host")
  end

  test "a mail's links reach those routes, and their token still verifies" do
    {:ok, list} = Lists.create_list(%{name: "Weekly #{System.unique_integer([:positive])}"})

    {:ok, contact} =
      Contacts.create_contact(%{
        name: "Member",
        email: "m#{System.unique_integer([:positive])}@example.com"
      })

    {:ok, _member} = Lists.add_contact_to_list(contact, list, source: "manual")

    {:ok, broadcast} =
      Newsletters.create_broadcast(%{
        subject: "Hello",
        status: "sending",
        source_type: "crm_list",
        crm_list_uuid: list.uuid,
        html_body:
          ~s(<a href="{{unsubscribe_url}}">out</a> <a href="{{preferences_url}}">prefs</a>),
        text_body: "Body"
      })

    {:ok, delivery} =
      %Delivery{}
      |> Delivery.changeset(%{
        broadcast_uuid: broadcast.uuid,
        crm_contact_uuid: contact.uuid,
        recipient_email: contact.email
      })
      |> Repo.insert()

    job = %Oban.Job{
      args: %{"delivery_uuid" => delivery.uuid, "broadcast_uuid" => broadcast.uuid}
    }

    assert :ok = DeliveryWorker.perform(job)

    assert_email_sent(fn email ->
      refute email.html_body =~ "/et/newsletters"
      assert email.html_body =~ "/newsletters/unsubscribe?token="
      assert email.html_body =~ "/newsletters/preferences?token="

      assert [_, token] =
               Regex.run(~r"one-click\?token=([^>]+)>", email.headers["List-Unsubscribe"])

      list_uuid = list.uuid
      contact_uuid = contact.uuid

      assert {:ok, %{crm_list_uuid: ^list_uuid, contact_uuid: ^contact_uuid}} =
               UnsubscribeToken.verify(token)
    end)
  end

  # `route_info/4` is asked about the path under the scope; the url prefix is the
  # host's and sits in front of it.
  defp strip_prefix(path),
    do:
      String.replace_prefix(
        path,
        Routes.path("/", locale: :none) |> String.trim_trailing("/"),
        ""
      )
end
