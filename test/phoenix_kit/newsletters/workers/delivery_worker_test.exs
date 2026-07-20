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

  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Integrations
  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Broadcast
  alias PhoenixKit.Newsletters.Delivery
  alias PhoenixKit.Newsletters.Workers.DeliveryWorker
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitCRM.Contacts, as: CRMContacts
  alias PhoenixKitCRM.Lists, as: CRMLists
  alias PhoenixKitNewsletters.Test.Repo

  defp add_integration(provider \\ "smtp", name \\ "test connection") do
    {:ok, %{uuid: uuid}} = Integrations.add_connection(provider, name)
    uuid
  end

  defp create_send_profile(attrs) do
    integration_uuid = Map.get(attrs, :integration_uuid) || add_integration()

    base = %{name: "Test profile", integration_uuid: integration_uuid, provider_kind: "smtp"}
    {:ok, profile} = SendProfiles.create_send_profile(Map.merge(base, attrs))
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
      {:ok, _} = SendProfiles.set_default_send_profile(default_profile)

      broadcast = %Broadcast{send_profile_uuid: Ecto.UUID.generate()}

      resolved = DeliveryWorker.resolve_send_profile(broadcast)
      assert resolved.uuid == default_profile.uuid
    end

    test "falls back to the default profile when the broadcast has no send_profile_uuid" do
      default_profile = create_send_profile(%{name: "Default"})
      {:ok, _} = SendProfiles.set_default_send_profile(default_profile)

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

  describe "perform/1 — recipient_email path (Stage 4, CRM-sourced delivery)" do
    setup :set_swoosh_global

    test "sends using recipient_email when the delivery has no user_uuid at all" do
      PhoenixKit.Settings.update_setting("from_name", "My Newsletter")
      PhoenixKit.Settings.update_setting("from_email", "news@example.com")

      broadcast =
        create_broadcast(%{subject: "CRM send", html_body: "<p>Hi</p>", text_body: "Hi"})

      {:ok, delivery} =
        %Delivery{}
        |> Delivery.changeset(%{
          broadcast_uuid: broadcast.uuid,
          recipient_email: "crm-recipient@example.com"
        })
        |> Repo.insert()

      assert delivery.user_uuid == nil

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
        to: "crm-recipient@example.com",
        subject: "CRM send"
      )
    end

    test "substitutes {{preferences_url}} with a resolved preference-center link for a real CRM member" do
      PhoenixKit.Settings.update_setting("from_name", "My Newsletter")
      PhoenixKit.Settings.update_setting("from_email", "news@example.com")

      {:ok, crm_list} =
        CRMLists.create_list(%{name: "Test CRM list #{System.unique_integer([:positive])}"})

      {:ok, contact} =
        CRMContacts.create_contact(%{name: "Recipient", email: "crm-prefs@example.com"})

      {:ok, _member} = CRMLists.add_contact_to_list(contact, crm_list, source: "manual")

      broadcast =
        create_broadcast(%{
          subject: "CRM send with preferences link",
          source_type: "crm_list",
          crm_list_uuid: crm_list.uuid,
          list_uuid: nil,
          html_body: "<p>Manage: {{preferences_url}}</p>",
          text_body: "Manage: {{preferences_url}}"
        })

      {:ok, delivery} =
        %Delivery{}
        |> Delivery.changeset(%{broadcast_uuid: broadcast.uuid, recipient_email: contact.email})
        |> Repo.insert()

      job = %Oban.Job{
        args: %{"delivery_uuid" => delivery.uuid, "broadcast_uuid" => broadcast.uuid}
      }

      assert :ok = DeliveryWorker.perform(job)

      assert_email_sent(fn email ->
        assert email.html_body =~ "/newsletters/preferences?token="
        refute email.html_body =~ "{{preferences_url}}"
      end)
    end
  end

  describe "maybe_put_list_unsubscribe_headers/3" do
    test "adds List-Unsubscribe + List-Unsubscribe-Post for a crm_list broadcast with a resolved url" do
      broadcast = %Broadcast{source_type: "crm_list"}
      email = Swoosh.Email.new()

      result =
        DeliveryWorker.maybe_put_list_unsubscribe_headers(
          email,
          broadcast,
          "https://example.com/newsletters/unsubscribe/one-click?token=abc"
        )

      assert result.headers["List-Unsubscribe"] ==
               "<https://example.com/newsletters/unsubscribe/one-click?token=abc>"

      assert result.headers["List-Unsubscribe-Post"] == "List-Unsubscribe=One-Click"
    end

    test "adds nothing for a crm_list broadcast when the url didn't resolve (empty string)" do
      broadcast = %Broadcast{source_type: "crm_list"}
      email = Swoosh.Email.new()

      result = DeliveryWorker.maybe_put_list_unsubscribe_headers(email, broadcast, "")

      refute Map.has_key?(result.headers, "List-Unsubscribe")
      refute Map.has_key?(result.headers, "List-Unsubscribe-Post")
    end

    test "adds List-Unsubscribe + List-Unsubscribe-Post for a newsletters_list broadcast with a resolved url too" do
      broadcast = %Broadcast{source_type: "newsletters_list"}
      email = Swoosh.Email.new()

      result =
        DeliveryWorker.maybe_put_list_unsubscribe_headers(
          email,
          broadcast,
          "https://example.com/newsletters/unsubscribe/one-click?token=abc"
        )

      assert result.headers["List-Unsubscribe"] ==
               "<https://example.com/newsletters/unsubscribe/one-click?token=abc>"

      assert result.headers["List-Unsubscribe-Post"] == "List-Unsubscribe=One-Click"
    end

    test "adds nothing for a newsletters_list broadcast when the url didn't resolve (empty string)" do
      broadcast = %Broadcast{source_type: "newsletters_list"}
      email = Swoosh.Email.new()

      result = DeliveryWorker.maybe_put_list_unsubscribe_headers(email, broadcast, "")

      refute Map.has_key?(result.headers, "List-Unsubscribe")
      refute Map.has_key?(result.headers, "List-Unsubscribe-Post")
    end
  end

  describe "perform/1 — List-Unsubscribe headers on the sent email" do
    setup :set_swoosh_global

    test "a crm_list send with no resolvable link adds no headers and doesn't crash; a newsletters_list send is unaffected" do
      PhoenixKit.Settings.update_setting("from_name", "My Newsletter")
      PhoenixKit.Settings.update_setting("from_email", "news@example.com")

      # crm_list broadcast — recipient_email path. CRM isn't installed in
      # this suite (see CRMSourceTest's moduledoc), so the personalized
      # link can never resolve here; this proves that degrades safely
      # (no crash, no header with an empty url) rather than the
      # header-adding logic itself — that's maybe_put_list_unsubscribe_headers/3
      # above, tested directly with a synthetic resolved url.
      crm_broadcast =
        create_broadcast(%{
          subject: "CRM send",
          source_type: "crm_list",
          crm_list_uuid: Ecto.UUID.generate(),
          list_uuid: nil,
          html_body: "<p>Hi</p>",
          text_body: "Hi"
        })

      {:ok, crm_delivery} =
        %Delivery{}
        |> Delivery.changeset(%{
          broadcast_uuid: crm_broadcast.uuid,
          recipient_email: "crm-recipient@example.com"
        })
        |> Repo.insert()

      assert :ok =
               DeliveryWorker.perform(%Oban.Job{
                 args: %{
                   "delivery_uuid" => crm_delivery.uuid,
                   "broadcast_uuid" => crm_broadcast.uuid
                 }
               })

      assert_email_sent(fn email ->
        assert email.to == [{"", "crm-recipient@example.com"}]
        assert Map.has_key?(email.headers, "List-Unsubscribe") == false
      end)

      # newsletters_list broadcast — a core User recipient always resolves
      # a personalized link, so this now gets the same headers as the
      # crm_list flavor.
      user = create_user()
      list_broadcast = create_broadcast(%{subject: "List send", html_body: "<p>Hi</p>"})
      list_delivery = create_delivery(list_broadcast, user)

      assert :ok =
               DeliveryWorker.perform(%Oban.Job{
                 args: %{
                   "delivery_uuid" => list_delivery.uuid,
                   "broadcast_uuid" => list_broadcast.uuid
                 }
               })

      assert_email_sent(fn email ->
        assert email.to == [{"", user.email}]
        assert email.headers["List-Unsubscribe"] =~ "/newsletters/unsubscribe/one-click?token="
        assert email.headers["List-Unsubscribe-Post"] == "List-Unsubscribe=One-Click"
      end)
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

      {:ok, default} = SendProfiles.set_default_send_profile(default)

      resolved = DeliveryWorker.resolve_send_profile(%Broadcast{send_profile_uuid: disabled.uuid})

      assert resolved.uuid == default.uuid
    end

    test "a disabled DEFAULT profile resolves to nothing (falls back to the legacy path)" do
      profile = create_send_profile(%{name: "default then disabled"})
      {:ok, profile} = SendProfiles.set_default_send_profile(profile)
      {:ok, _} = SendProfiles.update_send_profile(profile, %{enabled: false})

      assert SendProfiles.get_default_send_profile() == nil
      assert DeliveryWorker.resolve_send_profile(%Broadcast{}) == nil
    end
  end

  describe "perform/1 — idempotency and bounce-counter correctness under retry" do
    setup do
      PhoenixKit.Settings.update_setting("from_name", "My Newsletter")
      PhoenixKit.Settings.update_setting("from_email", "news@example.com")
      :ok
    end

    test "a delivery already marked sent is not re-sent, even if perform/1 runs again" do
      user = create_user()
      broadcast = create_broadcast(%{subject: "Already sent", html_body: "<p>Hi</p>"})
      delivery = create_delivery(broadcast, user)

      {:ok, delivery} =
        Newsletters.update_delivery_status(delivery, "sent", %{
          sent_at: DateTime.utc_now(),
          message_id: "already-sent-message-id"
        })

      job = %Oban.Job{
        args: %{"delivery_uuid" => delivery.uuid, "broadcast_uuid" => broadcast.uuid}
      }

      assert :ok = DeliveryWorker.perform(job)

      refute_email_sent()

      updated_broadcast = Repo.get(Broadcast, broadcast.uuid)
      assert updated_broadcast.sent_count == 0

      updated_delivery = Repo.get(Delivery, delivery.uuid)
      assert updated_delivery.message_id == "already-sent-message-id"
    end

    test "a non-terminal transient failure (more retries left) keeps the delivery pending, records the error, and does not bump bounced_count" do
      user = create_user()
      broadcast = create_broadcast(%{subject: "Will fail", html_body: "<p>Hi</p>"})
      delivery = create_delivery(broadcast, user)

      DeliveryWorker.handle_failure(delivery.uuid, broadcast.uuid, "timeout", false)

      updated_delivery = Repo.get(Delivery, delivery.uuid)
      # Must stay "pending" — the only status
      # Delivery.non_terminal_broadcast_uuids_query/0 treats as incomplete —
      # so a broadcast whose last delivery hits a still-retryable failure
      # isn't finalized to "sent" out from under the queued retry.
      assert updated_delivery.status == "pending"
      assert updated_delivery.error == "\"timeout\""

      updated_broadcast = Repo.get(Broadcast, broadcast.uuid)
      assert updated_broadcast.bounced_count == 0
    end

    test "a terminal transient failure (last attempt) marks the delivery failed and bumps bounced_count exactly once" do
      user = create_user()
      broadcast = create_broadcast(%{subject: "Will fail terminally", html_body: "<p>Hi</p>"})
      delivery = create_delivery(broadcast, user)

      DeliveryWorker.handle_failure(delivery.uuid, broadcast.uuid, "timeout", true)

      updated_delivery = Repo.get(Delivery, delivery.uuid)
      assert updated_delivery.status == "failed"

      updated_broadcast = Repo.get(Broadcast, broadcast.uuid)
      assert updated_broadcast.bounced_count == 1
    end

    test "perform/1 threads a real transient failure through to handle_failure/4 (wiring check)" do
      user = create_user()
      broadcast = create_broadcast(%{subject: "Wired through perform/1", html_body: "<p>Hi</p>"})
      delivery = create_delivery(broadcast, user)

      # Point the job at a broadcast_uuid that doesn't exist so
      # get_broadcast/1 fails transiently (:broadcast_not_found — not one of
      # permanent_failure?/1's atoms) without needing to corrupt the
      # delivery itself — the delivery stays a normal, valid row
      # throughout, proving perform/1's `attempt`/`max_attempts` field
      # destructuring and the {:error, reason} -> handle_failure/4 wiring
      # compile and run end-to-end. The terminal?-gated bounce-count logic
      # itself is covered precisely by the two handle_failure/4 unit tests
      # above (this job's broadcast_uuid doesn't exist, so
      # maybe_bump_counter/2 here is a real no-op, not a meaningful
      # assertion).
      job = %Oban.Job{
        args: %{"delivery_uuid" => delivery.uuid, "broadcast_uuid" => Ecto.UUID.generate()},
        attempt: 3,
        max_attempts: 3
      }

      assert {:error, _reason} = DeliveryWorker.perform(job)

      updated_delivery = Repo.get(Delivery, delivery.uuid)
      assert updated_delivery.status == "failed"
    end

    test "a successful retry after a non-terminal failure sends exactly once and never inflates bounced_count" do
      user = create_user()
      broadcast = create_broadcast(%{subject: "Recovers on retry", html_body: "<p>Hi</p>"})
      delivery = create_delivery(broadcast, user)

      # Simulate attempt 1 having failed for an unrelated transient reason —
      # same terminal-ness bookkeeping as a real Oban retry, just without
      # actually forcing send_email/6 to fail (there's no seam for that on
      # the legacy path's real Swoosh call besides no-recipient, which
      # would leave the delivery unsendable on the retry too).
      {:ok, delivery} =
        Newsletters.update_delivery_status(delivery, "failed", %{error: "timeout"})

      job = %Oban.Job{
        args: %{"delivery_uuid" => delivery.uuid, "broadcast_uuid" => broadcast.uuid},
        attempt: 2,
        max_attempts: 3
      }

      assert :ok = DeliveryWorker.perform(job)

      updated_delivery = Repo.get(Delivery, delivery.uuid)
      assert updated_delivery.status == "sent"

      updated_broadcast = Repo.get(Broadcast, broadcast.uuid)
      assert updated_broadcast.sent_count == 1
      assert updated_broadcast.bounced_count == 0

      assert_email_sent(to: user.email, subject: "Recovers on retry")
    end
  end

  describe "update_delivery_result/5 — delivery status and broadcast counter commit atomically" do
    test "a failed status write (unique_constraint violation) leaves the counter unbumped" do
      broadcast = create_broadcast(%{subject: "Atomicity", html_body: "<p>Hi</p>"})

      other_user = create_user()
      other_delivery = create_delivery(broadcast, other_user)

      {:ok, _} =
        DeliveryWorker.update_delivery_result(
          other_delivery,
          "sent",
          %{sent_at: DateTime.utc_now(), message_id: "dup-message-id"},
          broadcast.uuid,
          :sent_count
        )

      user = create_user()
      delivery = create_delivery(broadcast, user)

      # Delivery.changeset/2's unique_constraint(:message_id) now names the
      # constraint after the real DB index from core migration V79
      # ("idx_newsletters_deliveries_message_id"), so the violation is
      # caught and surfaces as a graceful {:error, changeset} instead of a
      # raised Ecto.ConstraintError. The transaction still rolls back —
      # that's what this test verifies.
      assert {:error, changeset} =
               DeliveryWorker.update_delivery_result(
                 delivery,
                 "sent",
                 %{sent_at: DateTime.utc_now(), message_id: "dup-message-id"},
                 broadcast.uuid,
                 :sent_count
               )

      assert %{message_id: ["has already been taken"]} = errors_on(changeset)

      updated_delivery = Repo.get(Delivery, delivery.uuid)
      updated_broadcast = Repo.get(Broadcast, broadcast.uuid)

      # Neither write landed for the failed delivery: status is still
      # "pending" and sent_count reflects only the other (separately
      # successful) delivery — proving the failed status write rolled
      # back its paired counter increment instead of silently
      # undercounting.
      assert updated_delivery.status == "pending"
      assert updated_broadcast.sent_count == 1
    end

    test "a successful status write increments the paired counter in the same call" do
      broadcast = create_broadcast(%{subject: "Atomicity ok", html_body: "<p>Hi</p>"})
      user = create_user()
      delivery = create_delivery(broadcast, user)

      assert {:ok, _delivery} =
               DeliveryWorker.update_delivery_result(
                 delivery,
                 "sent",
                 %{
                   sent_at: DateTime.utc_now(),
                   message_id: "unique-#{System.unique_integer([:positive])}"
                 },
                 broadcast.uuid,
                 :sent_count
               )

      updated_delivery = Repo.get(Delivery, delivery.uuid)
      updated_broadcast = Repo.get(Broadcast, broadcast.uuid)

      assert updated_delivery.status == "sent"
      assert updated_broadcast.sent_count == 1
    end
  end
end
