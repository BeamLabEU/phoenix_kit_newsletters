defmodule PhoenixKit.Newsletters.Workers.DeliveryWorkerTest do
  @moduledoc """
  Tests for the profile-aware DeliveryWorker (Stage D, D4).

  `resolve_send_profile/1` and `build_profile_email/5` are exposed
  (non-`defp`, `@doc false`) specifically for direct unit testing here —
  same rationale as core `PhoenixKit.Mailer.swoosh_config_for/1`. Actual
  delivery through the resolved integration (SES/SMTP/Brevo) is NOT
  exercised here: `deliver_via_integration/3` resolves a real Swoosh
  adapter from the integration's stored provider, so there's no
  Swoosh.Adapters.Test seam for that leg — it's covered live in D5
  against real credentials. What IS fully exercised here, end-to-end
  with Swoosh.Adapters.Test capture, is the *legacy* path (no profile
  resolves) — proving existing user-list broadcasts still send
  identically (backward compatibility).
  """

  use PhoenixKitNewsletters.DataCase, async: false

  import Swoosh.TestAssertions

  alias PhoenixKit.Integrations
  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Broadcast
  alias PhoenixKit.Newsletters.Delivery
  alias PhoenixKit.Newsletters.Workers.DeliveryWorker
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitNewsletters.Test.Repo

  defp add_integration(provider \\ "smtp", name \\ "test connection") do
    {:ok, %{uuid: uuid}} = Integrations.add_connection(provider, name)
    uuid
  end

  defp create_send_profile(attrs) do
    integration_uuid = Map.get(attrs, :integration_uuid) || add_integration()

    base = %{name: "Test profile", integration_uuid: integration_uuid, provider_kind: "smtp"}
    {:ok, profile} = Newsletters.create_send_profile(Map.merge(base, attrs))
    profile
  end

  defp create_send_profile, do: create_send_profile(%{})

  defp create_user do
    {:ok, user} =
      %User{}
      |> User.guest_user_changeset(%{
        email: "recipient-#{System.unique_integer([:positive])}@example.com"
      })
      |> Repo.insert()

    user
  end

  defp create_list do
    {:ok, list} =
      Newsletters.create_list(%{
        name: "Test list",
        slug: "test-list-#{System.unique_integer([:positive])}"
      })

    list
  end

  defp create_broadcast(attrs) do
    list = create_list()

    base = %{
      subject: "Hello",
      list_uuid: list.uuid,
      html_body: "<p>Body</p>",
      text_body: "Body"
    }

    {:ok, broadcast} = Newsletters.create_broadcast(Map.merge(base, attrs))
    broadcast
  end

  defp create_delivery(broadcast, user) do
    {:ok, delivery} =
      %Delivery{}
      |> Delivery.changeset(%{broadcast_uuid: broadcast.uuid, user_uuid: user.uuid})
      |> Repo.insert()

    delivery
  end

  describe "resolve_send_profile/1" do
    test "returns the broadcast's own send profile when it resolves" do
      profile = create_send_profile()
      broadcast = %Broadcast{send_profile_uuid: profile.uuid}

      resolved = DeliveryWorker.resolve_send_profile(broadcast)
      assert resolved.uuid == profile.uuid
    end

    test "falls back to the default profile when the broadcast's uuid doesn't resolve" do
      default_profile = create_send_profile(%{name: "Default"})
      {:ok, _} = Newsletters.set_default_send_profile(default_profile)

      broadcast = %Broadcast{send_profile_uuid: Ecto.UUID.generate()}

      resolved = DeliveryWorker.resolve_send_profile(broadcast)
      assert resolved.uuid == default_profile.uuid
    end

    test "falls back to the default profile when the broadcast has no send_profile_uuid" do
      default_profile = create_send_profile(%{name: "Default"})
      {:ok, _} = Newsletters.set_default_send_profile(default_profile)

      broadcast = %Broadcast{send_profile_uuid: nil}

      resolved = DeliveryWorker.resolve_send_profile(broadcast)
      assert resolved.uuid == default_profile.uuid
    end

    test "returns nil when no profile resolves and there is no default" do
      broadcast = %Broadcast{send_profile_uuid: nil}
      assert DeliveryWorker.resolve_send_profile(broadcast) == nil
    end
  end

  describe "build_profile_email/5" do
    test "uses the profile's identity, reply-to, and appends the signature" do
      profile =
        create_send_profile(%{
          from_name: "Acme News",
          from_email: "news@acme.test",
          reply_to: "support@acme.test",
          signature_html: "<p>Best, Acme</p>",
          signature_text: "Best, Acme"
        })

      broadcast = %Broadcast{subject: "Weekly update"}
      user = %User{email: "reader@example.com"}

      email = DeliveryWorker.build_profile_email(profile, broadcast, user, "<p>Body</p>", "Body")

      assert email.from == {"Acme News", "news@acme.test"}
      assert email.subject == "Weekly update"
      assert email.html_body == "<p>Body</p><p>Best, Acme</p>"
      assert email.text_body == "BodyBest, Acme"
      assert [{_, "reader@example.com"}] = email.to
      assert email.reply_to == {"", "support@acme.test"}
    end

    test "falls back to legacy from-name/email settings and skips reply-to/signature when unset" do
      profile = create_send_profile()

      PhoenixKit.Settings.update_setting("from_name", "Fallback Name")
      PhoenixKit.Settings.update_setting("from_email", "fallback@example.com")

      broadcast = %Broadcast{subject: "Hi"}
      user = %User{email: "x@example.com"}

      email = DeliveryWorker.build_profile_email(profile, broadcast, user, "html", "text")

      assert email.from == {"Fallback Name", "fallback@example.com"}
      assert email.html_body == "html"
      assert email.text_body == "text"
      assert email.reply_to == nil
    end
  end

  describe "perform/1 — legacy path (no profile resolves)" do
    setup :set_swoosh_global

    test "sends identically to the pre-Stage-D behavior" do
      PhoenixKit.Settings.update_setting("from_name", "My Newsletter")
      PhoenixKit.Settings.update_setting("from_email", "news@example.com")

      user = create_user()

      broadcast =
        create_broadcast(%{subject: "Legacy send", html_body: "<p>Hi</p>", text_body: "Hi"})

      delivery = create_delivery(broadcast, user)

      job = %Oban.Job{
        args: %{"delivery_uuid" => delivery.uuid, "broadcast_uuid" => broadcast.uuid}
      }

      assert :ok = DeliveryWorker.perform(job)

      updated_delivery = Repo.get(Delivery, delivery.uuid)
      assert updated_delivery.status == "sent"

      updated_broadcast = Repo.get(Broadcast, broadcast.uuid)
      assert updated_broadcast.sent_count == 1

      assert_email_sent(
        from: {"My Newsletter", "news@example.com"},
        to: user.email,
        subject: "Legacy send"
      )
    end
  end

  describe "permanent_failure?/1 — blocked/unusable sends must not retry nor count as bounces" do
    test "blocklisted recipients and unusable integrations are permanent" do
      assert DeliveryWorker.permanent_failure?({:blocked, :blocklist})
      assert DeliveryWorker.permanent_failure?(:deleted)
      assert DeliveryWorker.permanent_failure?(:not_configured)
      assert DeliveryWorker.permanent_failure?(:unsupported_provider)
      assert DeliveryWorker.permanent_failure?({:unsupported_provider, "nope"})
      assert DeliveryWorker.permanent_failure?({:invalid_smtp_port, "abc"})
    end

    test "ordinary delivery failures stay transient (still retried and counted)" do
      refute DeliveryWorker.permanent_failure?(:timeout)
      refute DeliveryWorker.permanent_failure?({:error, :econnrefused})
      refute DeliveryWorker.permanent_failure?("smtp 421 try again")
    end
  end

  describe "resolve_send_profile/1 honours the `enabled` kill-switch" do
    test "a disabled pinned profile is skipped in favour of the enabled default" do
      integration_uuid = add_integration()

      disabled =
        create_send_profile(%{
          name: "disabled pinned",
          integration_uuid: integration_uuid,
          enabled: false
        })

      default =
        create_send_profile(%{name: "enabled default", integration_uuid: integration_uuid})

      {:ok, default} = Newsletters.set_default_send_profile(default)

      resolved = DeliveryWorker.resolve_send_profile(%Broadcast{send_profile_uuid: disabled.uuid})

      assert resolved.uuid == default.uuid
    end

    test "a disabled DEFAULT profile resolves to nothing (falls back to the legacy path)" do
      profile = create_send_profile(%{name: "default then disabled"})
      {:ok, profile} = Newsletters.set_default_send_profile(profile)
      {:ok, _} = Newsletters.update_send_profile(profile, %{enabled: false})

      assert Newsletters.get_default_send_profile() == nil
      assert DeliveryWorker.resolve_send_profile(%Broadcast{}) == nil
    end
  end
end
