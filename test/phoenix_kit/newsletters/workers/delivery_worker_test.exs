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
  with Swoosh.Adapters.Test capture, is the no-profile-resolves path
  (`create_broadcast/1`'s default fixture is a `user_group` broadcast
  addressed to a real core User — same recipient shape the legacy
  newsletters_list flavor used to exercise here, before its removal).
  """

  use PhoenixKitNewsletters.DataCase, async: false

  import Swoosh.TestAssertions

  alias PhoenixKit.Email.Branding
  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Manager, as: StorageManager
  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Broadcast
  alias PhoenixKit.Newsletters.Delivery
  alias PhoenixKit.Newsletters.Layouts
  alias PhoenixKit.Newsletters.UnsubscribeToken
  alias PhoenixKit.Newsletters.UserGroupSource
  alias PhoenixKit.Newsletters.Workers.DeliveryWorker
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Role
  alias PhoenixKit.Users.Roles
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

  # Defaults to "sending", not the schema default "draft". Broadcaster commits
  # the flip to "sending" together with the jobs, so "sending" is the only
  # status a DeliveryWorker job has ever run under —
  # a "draft" broadcast with queued deliveries is not a state the system can
  # reach. Fixtures that built one were a fixture smell, and the worker's
  # allow-list guard now (correctly) refuses to send from it.
  #
  # A real role, held by every user create_delivery/2 is given: the worker asks
  # the audience again just before sending, so a fixture recipient has to be one.
  defp create_broadcast(attrs) do
    {:ok, role} = Roles.create_role(%{name: "Role #{System.unique_integer([:positive])}"})

    base = %{
      subject: "Hello",
      status: "sending",
      source_type: "user_group",
      source_params: %{"role_uuids" => [role.uuid], "role_names_snapshot" => [role.name]},
      html_body: "<p>Body</p>",
      text_body: "Body"
    }

    {:ok, broadcast} = Newsletters.create_broadcast(Map.merge(base, attrs))
    broadcast
  end

  defp create_delivery(broadcast, user) do
    for role_uuid <- Broadcast.role_uuids(broadcast) do
      {:ok, _assignment} = Roles.assign_role(user, Repo.get!(Role, role_uuid).name)
    end

    {:ok, delivery} =
      %Delivery{}
      |> Delivery.changeset(%{broadcast_uuid: broadcast.uuid, user_uuid: user.uuid})
      |> Repo.insert()

    delivery
  end

  # A subscribed member of a real list, and a delivery to them: what the
  # broadcaster inserts for a crm_list audience.
  defp create_crm_delivery(broadcast_attrs \\ %{}) do
    unique = System.unique_integer([:positive])
    {:ok, crm_list} = CRMLists.create_list(%{name: "Audience #{unique}"})

    {:ok, contact} =
      CRMContacts.create_contact(%{name: "Member", email: "m#{unique}@example.com"})

    {:ok, _member} = CRMLists.add_contact_to_list(contact, crm_list, source: "manual")

    broadcast =
      create_broadcast(
        Map.merge(%{source_type: "crm_list", crm_list_uuid: crm_list.uuid}, broadcast_attrs)
      )

    {:ok, delivery} =
      %Delivery{}
      |> Delivery.changeset(%{
        broadcast_uuid: broadcast.uuid,
        crm_contact_uuid: contact.uuid,
        recipient_email: contact.email
      })
      |> Repo.insert()

    %{list: crm_list, contact: contact, broadcast: broadcast, delivery: delivery}
  end

  defp job_for(delivery, attrs \\ %{}) do
    struct(
      %Oban.Job{
        args: %{"delivery_uuid" => delivery.uuid, "broadcast_uuid" => delivery.broadcast_uuid}
      },
      attrs
    )
  end

  # A real, readable file: a local-provider bucket backed by a temp dir,
  # actual bytes written through Manager.store_file/2, and matching
  # File/FileInstance rows — StorageManager.retrieve_file/2 (what
  # DeliveryWorker.build_attachment/1 calls) genuinely finds and copies
  # these bytes, no mocking. Manager.retrieve_file/2 tries every enabled
  # bucket by priority, not one tied to a specific file, so a single
  # enabled local bucket is enough regardless of which fixture created it.
  defp create_local_bucket! do
    {:ok, bucket} =
      Storage.create_bucket(%{
        name: "Test bucket #{System.unique_integer([:positive])}",
        provider: "local",
        endpoint:
          Path.join(System.tmp_dir!(), "nl_attach_bucket_#{System.unique_integer([:positive])}"),
        enabled: true,
        priority: 0
      })

    # StorageManager.get_enabled_buckets/0 (private) caches the enabled-bucket
    # list in :persistent_term for 5 minutes — a genuine process-global cache,
    # not scoped to the Ecto sandbox transaction. Without erasing it here, a
    # bucket created by an EARLIER test (already rolled back) can still be
    # "seen" by a later test's retrieve_file/2 call, or this test's own
    # brand-new bucket can be invisible until the cache expires. Test-only
    # workaround — doesn't touch core, doesn't affect production behavior.
    :persistent_term.erase(:phoenix_kit_buckets_cache)

    bucket
  end

  defp create_attachment_file!(opts) do
    bytes = Keyword.get(opts, :bytes, "hello attachment")
    filename = Keyword.get(opts, :filename, "report.txt")
    bucket = create_local_bucket!()

    source_path =
      Path.join(System.tmp_dir!(), "nl_attach_src_#{System.unique_integer([:positive])}.txt")

    File.write!(source_path, bytes)

    path_prefix = "test/attachments/#{Ecto.UUID.generate()}.txt"

    # Forces this exact fixture's bucket rather than letting store_file/2
    # auto-select among every currently-enabled priority-0 bucket (which,
    # if any other bucket happens to be enabled — e.g. a real default
    # bucket seeded outside this test's own transaction — could otherwise
    # write to a DIFFERENT bucket than the one this test's retrieve calls
    # will look in, and could land bytes under the repo's own priv/media/
    # instead of the intended temp dir).
    {:ok, %{destination_path: stored_path}} =
      StorageManager.store_file(source_path,
        path_prefix: path_prefix,
        priority_buckets: [bucket.uuid]
      )

    File.rm(source_path)

    {:ok, file} =
      Storage.create_file(%{
        original_file_name: filename,
        file_name: filename,
        mime_type: "text/plain",
        file_type: "document",
        ext: "txt",
        file_checksum: "sha256:test-#{System.unique_integer([:positive])}",
        user_file_checksum: "user-sha256:test-#{System.unique_integer([:positive])}",
        size: byte_size(bytes),
        status: "active",
        user_uuid: create_user().uuid
      })

    {:ok, _instance} =
      Storage.create_file_instance(%{
        file_uuid: file.uuid,
        variant_name: "original",
        file_name: stored_path,
        mime_type: "text/plain",
        ext: "txt",
        checksum: "sha256:test-instance-#{System.unique_integer([:positive])}",
        size: byte_size(bytes)
      })

    file
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

  describe "perform/1 — no profile resolves" do
    # create_broadcast/1 does a real Broadcast INSERT — needs core V158's
    # attachments column; see test_helper.exs's :requires_v158 exclusion.
    @describetag :requires_v158
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

  describe "the unsubscribe link in a sent email" do
    defp sent_email(attrs, user \\ create_user()) do
      broadcast = create_broadcast(attrs)
      delivery = create_delivery(broadcast, user)

      assert :ok = DeliveryWorker.perform(job_for(delivery))

      assert_email_sent(fn email ->
        send(self(), {:sent, email})
        true
      end)

      assert_received {:sent, email}
      email
    end

    test "a broadcast with no layout carries a working one in both parts" do
      email = sent_email(%{html_body: "<p>Hi</p>", text_body: "Hi"})

      [_, url] = Regex.run(~r/<a href="([^"]+)"[^>]*>Unsubscribe<\/a>/, email.html_body)

      assert %{"token" => token} = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert {:role_optout, _claims} = UnsubscribeToken.verify(token)
      assert email.text_body == "Hi\n\nUnsubscribe: #{url}"
    end

    test "an author's own link is not doubled in either part" do
      email =
        sent_email(%{
          html_body: ~s(<a href="{{unsubscribe_url}}">Leave</a>),
          text_body: "Leave: {{unsubscribe_url}}"
        })

      assert email.html_body =~ ">Leave</a>"
      refute email.html_body =~ ">Unsubscribe</a>"
      refute email.text_body =~ "Unsubscribe:"
    end

    test "both parts are in the reader's language" do
      email = sent_email(%{html_body: "<p>Hi</p>", text_body: "Hi"}, create_user_in("et"))

      assert email.html_body =~ ">Loobu tellimusest</a>"
      assert email.text_body =~ "Loobu tellimusest: http"
    end
  end

  describe "build_attachment/1" do
    test "reads a real stored file into a Swoosh.Attachment" do
      file = create_attachment_file!(bytes: "the actual file bytes", filename: "invoice.txt")

      assert {:ok, attachment} = DeliveryWorker.build_attachment(file.uuid)
      assert %Swoosh.Attachment{} = attachment
      assert attachment.filename == "invoice.txt"
      assert attachment.content_type == "text/plain"
      assert attachment.data == "the actual file bytes"
      assert attachment.type == :attachment
    end

    test "returns an error tuple (not a crash) for a uuid that doesn't resolve to a file" do
      missing_uuid = Ecto.UUID.generate()

      assert {:error, :file_not_found, ^missing_uuid} =
               DeliveryWorker.build_attachment(missing_uuid)
    end
  end

  describe "resolve_attachments/1" do
    test "is [] for a broadcast with no attachments" do
      assert DeliveryWorker.resolve_attachments(%Broadcast{attachments: []}) == []
    end

    test "resolves every good uuid and silently drops an unreadable one" do
      good = create_attachment_file!(filename: "good.txt")
      missing_uuid = Ecto.UUID.generate()

      broadcast = %Broadcast{attachments: [good.uuid, missing_uuid]}
      resolved = DeliveryWorker.resolve_attachments(broadcast)

      assert [%Swoosh.Attachment{filename: "good.txt"}] = resolved
    end
  end

  describe "cross-job attachment cache" do
    # A counting wrapper around the real fetch, injected as `fetch_fun` —
    # proves the cache short-circuits a second lookup without needing two
    # genuinely separate (and non-deterministic-to-assert-on) Storage
    # round trips.
    defp counting_fetcher do
      counter = :counters.new(1, [])

      fetch_fun = fn file_uuid ->
        :counters.add(counter, 1, 1)
        DeliveryWorker.fetch_and_build_attachment(file_uuid)
      end

      {fetch_fun, counter}
    end

    test "build_attachment/2: two calls for the same uuid — one real fetch" do
      file = create_attachment_file!(filename: "cached.txt")
      {fetch_fun, counter} = counting_fetcher()

      assert {:ok, %Swoosh.Attachment{filename: "cached.txt"}} =
               DeliveryWorker.build_attachment(file.uuid, fetch_fun)

      assert {:ok, %Swoosh.Attachment{filename: "cached.txt"}} =
               DeliveryWorker.build_attachment(file.uuid, fetch_fun)

      assert :counters.get(counter, 1) == 1
    end

    test "resolve_attachments/2: two broadcasts sharing a file uuid — one real fetch" do
      file = create_attachment_file!(filename: "shared.txt")
      {fetch_fun, counter} = counting_fetcher()

      broadcast_a = %Broadcast{attachments: [file.uuid]}
      broadcast_b = %Broadcast{attachments: [file.uuid]}

      assert [%Swoosh.Attachment{filename: "shared.txt"}] =
               DeliveryWorker.resolve_attachments(broadcast_a, fetch_fun)

      assert [%Swoosh.Attachment{filename: "shared.txt"}] =
               DeliveryWorker.resolve_attachments(broadcast_b, fetch_fun)

      assert :counters.get(counter, 1) == 1
    end

    test "a cache miss is not cached — an unreadable uuid is retried every call" do
      missing_uuid = Ecto.UUID.generate()
      {fetch_fun, counter} = counting_fetcher()

      assert {:error, :file_not_found, ^missing_uuid} =
               DeliveryWorker.build_attachment(missing_uuid, fetch_fun)

      assert {:error, :file_not_found, ^missing_uuid} =
               DeliveryWorker.build_attachment(missing_uuid, fetch_fun)

      assert :counters.get(counter, 1) == 2
    end
  end

  describe "perform/1 — attachments" do
    @describetag :requires_v158
    setup :set_swoosh_global

    test "attachments reach the sent email" do
      file = create_attachment_file!(bytes: "attached bytes", filename: "flyer.txt")
      user = create_user()

      broadcast =
        create_broadcast(%{
          subject: "With attachment",
          html_body: "<p>Hi</p>",
          text_body: "Hi",
          attachments: [file.uuid]
        })

      delivery = create_delivery(broadcast, user)

      job = %Oban.Job{
        args: %{"delivery_uuid" => delivery.uuid, "broadcast_uuid" => broadcast.uuid}
      }

      assert :ok = DeliveryWorker.perform(job)
      assert Repo.get(Delivery, delivery.uuid).status == "sent"

      assert_email_sent(fn email ->
        assert [%Swoosh.Attachment{filename: "flyer.txt", data: "attached bytes"}] =
                 email.attachments
      end)
    end

    test "an unreadable attachment is skipped — the send still succeeds with the rest" do
      good = create_attachment_file!(filename: "good.txt")
      missing_uuid = Ecto.UUID.generate()
      user = create_user()

      broadcast =
        create_broadcast(%{
          subject: "Partial attachments",
          html_body: "<p>Hi</p>",
          text_body: "Hi",
          attachments: [good.uuid, missing_uuid]
        })

      delivery = create_delivery(broadcast, user)

      job = %Oban.Job{
        args: %{"delivery_uuid" => delivery.uuid, "broadcast_uuid" => broadcast.uuid}
      }

      assert :ok = DeliveryWorker.perform(job)
      assert Repo.get(Delivery, delivery.uuid).status == "sent"

      assert_email_sent(fn email ->
        assert [%Swoosh.Attachment{filename: "good.txt"}] = email.attachments
      end)
    end

    test "no attachments on the broadcast — the email has none" do
      user = create_user()

      broadcast =
        create_broadcast(%{subject: "No attachments", html_body: "<p>Hi</p>", text_body: "Hi"})

      delivery = create_delivery(broadcast, user)

      job = %Oban.Job{
        args: %{"delivery_uuid" => delivery.uuid, "broadcast_uuid" => broadcast.uuid}
      }

      assert :ok = DeliveryWorker.perform(job)
      assert_email_sent(fn email -> assert email.attachments == [] end)
    end
  end

  describe "compose_html/4 — layout ordering and escaping" do
    test "body lands inside the layout and layout-side variables resolve" do
      wrapper =
        ~s(<div class="wrap">{{content}}<footer><a href="{{unsubscribe_url}}">Unsubscribe</a></footer></div>)

      vars = %{"name" => "Ada", "unsubscribe_url" => "https://x/unsub?t=1"}

      html = DeliveryWorker.compose_html("<p>Hello {{name}}</p>", wrapper, vars)

      # The regression this pins: substitution used to run BEFORE the
      # wrap, leaving every layout-side tag a literal in the sent mail.
      assert html =~ ~s(<div class="wrap"><p>Hello Ada</p>)
      assert html =~ ~s(href="https://x/unsub?t=1")
      refute html =~ "{{content}}"
      refute html =~ "{{unsubscribe_url}}"
      refute html =~ "{{name}}"
    end

    test "{{{content}}} places the body too" do
      html = DeliveryWorker.compose_html("<p>Body</p>", "<main>{{{content}}}</main>", %{})
      assert html == "<main><p>Body</p></main>"
    end

    test "a variable VALUE containing another {{tag}} is not re-substituted" do
      vars = %{"name" => "{{unsubscribe_url}}", "unsubscribe_url" => "https://x/u"}

      html = DeliveryWorker.compose_html("<p>{{name}}</p>", "{{content}}", vars)

      # Single-pass substitution: the mischievous value lands verbatim, and being
      # no link to anything, the real one still follows it.
      assert String.starts_with?(html, "<p>{{unsubscribe_url}}</p><p style=")
    end

    test "{{variable}} values are HTML-escaped, {{{variable}}} are not" do
      vars = %{"name" => "<b>Ada & Co</b>"}

      assert DeliveryWorker.compose_html("<p>{{name}}</p>", "{{{content}}}", vars) ==
               "<p>&lt;b&gt;Ada &amp; Co&lt;/b&gt;</p>"

      assert DeliveryWorker.compose_html("<p>{{{name}}}</p>", "{{{content}}}", vars) ==
               "<p><b>Ada & Co</b></p>"
    end

    test "an unknown {{tag}} stays literal" do
      assert DeliveryWorker.compose_html("Hi {{nope}}", "{{content}}", %{"name" => "Ada"}) ==
               "Hi {{nope}}"
    end

    test "no layout (nil) — the body goes into core's standard layout, variables resolved" do
      html = DeliveryWorker.compose_html("<p>Hi {{name}}</p>", nil, %{"name" => "Ada"})

      assert html =~ "<!DOCTYPE html>"
      assert html =~ "<p>Hi Ada</p>"
      refute html =~ "{{"
    end

    test "a layout that does not place the body is not used — the body is never dropped" do
      html = DeliveryWorker.compose_html("<p>Body</p>", "<p>No placeholder here</p>", %{})

      assert html =~ "<p>Body</p>"
      refute html =~ "No placeholder here"
    end
  end

  describe "perform/1 — recipient_email path (Stage 4, CRM-sourced delivery)" do
    @describetag :requires_v158
    setup :set_swoosh_global

    test "sends using recipient_email when the delivery has no user_uuid at all" do
      PhoenixKit.Settings.update_setting("from_name", "My Newsletter")
      PhoenixKit.Settings.update_setting("from_email", "news@example.com")

      %{broadcast: broadcast, contact: contact, delivery: delivery} =
        create_crm_delivery(%{subject: "CRM send", html_body: "<p>Hi</p>", text_body: "Hi"})

      assert delivery.user_uuid == nil

      assert :ok = DeliveryWorker.perform(job_for(delivery))

      updated_delivery = Repo.get(Delivery, delivery.uuid)
      assert updated_delivery.status == "sent"

      updated_broadcast = Repo.get(Broadcast, broadcast.uuid)
      assert updated_broadcast.sent_count == 1

      assert_email_sent(
        from: {"My Newsletter", "news@example.com"},
        to: contact.email,
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

      # NOTE: the last expression in this lambda must be an `assert` —
      # assert_email_sent/1 asserts on the lambda's return value, and a
      # bare `refute` does not reliably return a truthy value.
      assert_email_sent(fn email ->
        refute email.html_body =~ "{{preferences_url}}"
        assert email.html_body =~ "/newsletters/preferences?token="
      end)
    end
  end

  describe "{{preferences_url}} — unresolved cases leave the placeholder unsubstituted" do
    @describetag :requires_v158
    setup :set_swoosh_global

    test "user_group recipient: same catch-all, same unsubstituted placeholder" do
      PhoenixKit.Settings.update_setting("from_name", "My Newsletter")
      PhoenixKit.Settings.update_setting("from_email", "news@example.com")

      user = create_user()

      broadcast =
        create_broadcast(%{
          subject: "Legacy send",
          html_body: "<p>Manage: {{preferences_url}}</p>",
          text_body: "Manage: {{preferences_url}}"
        })

      delivery = create_delivery(broadcast, user)

      job = %Oban.Job{
        args: %{"delivery_uuid" => delivery.uuid, "broadcast_uuid" => broadcast.uuid}
      }

      assert :ok = DeliveryWorker.perform(job)

      assert_email_sent(fn email ->
        assert email.html_body =~ "{{preferences_url}}"
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
  end

  describe "perform/1 — List-Unsubscribe headers on the sent email" do
    @describetag :requires_v158
    setup :set_swoosh_global

    test "a crm_list and a user_group send both carry the one-click headers" do
      PhoenixKit.Settings.update_setting("from_name", "My Newsletter")
      PhoenixKit.Settings.update_setting("from_email", "news@example.com")

      %{contact: contact, delivery: crm_delivery} =
        create_crm_delivery(%{subject: "CRM send", html_body: "<p>Hi</p>", text_body: "Hi"})

      assert :ok = DeliveryWorker.perform(job_for(crm_delivery))

      assert_email_sent(fn email ->
        assert email.to == [{"", contact.email}]
        assert email.headers["List-Unsubscribe"] =~ "/newsletters/unsubscribe/one-click?token="
      end)

      # user_group broadcast — a core User recipient always resolves a
      # personalized link, so this gets the same headers as the crm_list
      # flavor above.
      user = create_user()
      role_broadcast = create_broadcast(%{subject: "Role send", html_body: "<p>Hi</p>"})
      role_delivery = create_delivery(role_broadcast, user)

      assert :ok =
               DeliveryWorker.perform(%Oban.Job{
                 args: %{
                   "delivery_uuid" => role_delivery.uuid,
                   "broadcast_uuid" => role_broadcast.uuid
                 }
               })

      assert_email_sent(fn email ->
        assert email.to == [{"", user.email}]
        assert email.headers["List-Unsubscribe"] =~ "/newsletters/unsubscribe/one-click?token="
        assert email.headers["List-Unsubscribe-Post"] == "List-Unsubscribe=One-Click"
      end)
    end
  end

  describe "perform/1 — a recipient who stopped being sendable after enqueue" do
    @describetag :requires_v158
    setup :set_swoosh_global

    # Nothing left, nothing counted, and the broadcast still finishes.
    defp assert_blocked(delivery) do
      assert {:cancel, _reason} = DeliveryWorker.perform(job_for(delivery))

      assert_no_email_sent()
      assert %Delivery{status: "blocked", message_id: nil} = Repo.get(Delivery, delivery.uuid)

      assert %Broadcast{status: "sent", sent_count: 0, bounced_count: 0} =
               Repo.get(Broadcast, delivery.broadcast_uuid)
    end

    defp role_delivery do
      user = create_user()
      broadcast = create_broadcast(%{})
      {user, create_delivery(broadcast, user)}
    end

    test "a contact who opted out" do
      %{contact: contact, delivery: delivery} = create_crm_delivery()
      {:ok, _contact} = CRMLists.opt_out(contact)

      assert_blocked(delivery)
    end

    test "a member removed from the list" do
      %{contact: contact, list: list, delivery: delivery} = create_crm_delivery()
      {:ok, _member} = CRMLists.remove_from_list(contact, list, [])

      assert_blocked(delivery)
    end

    test "a contact trashed in the CRM" do
      %{contact: contact, delivery: delivery} = create_crm_delivery()
      {:ok, _contact} = CRMContacts.trash_contact(contact)

      assert_blocked(delivery)
    end

    test "a contact deleted from the CRM" do
      %{contact: contact, delivery: delivery} = create_crm_delivery()
      {:ok, _contact} = CRMContacts.delete_contact(contact)

      assert_blocked(delivery)
    end

    test "a list archived mid-send" do
      %{list: list, delivery: delivery} = create_crm_delivery()
      {:ok, _list} = CRMLists.archive_list(list)

      assert_blocked(delivery)
    end

    test "an address the list has no member for" do
      broadcast =
        create_broadcast(%{source_type: "crm_list", crm_list_uuid: Ecto.UUID.generate()})

      {:ok, delivery} =
        %Delivery{}
        |> Delivery.changeset(%{
          broadcast_uuid: broadcast.uuid,
          recipient_email: "no-match@example.com"
        })
        |> Repo.insert()

      assert_blocked(delivery)
    end

    test "a user deactivated" do
      {user, delivery} = role_delivery()
      user |> Ecto.Changeset.change(is_active: false) |> Repo.update!()

      assert_blocked(delivery)
    end

    test "a user who opted out" do
      {user, delivery} = role_delivery()
      {:ok, _user} = UserGroupSource.record_opt_out(user)

      assert_blocked(delivery)
    end

    test "a user taken out of the audience's role" do
      {user, delivery} = role_delivery()

      [role_uuid] =
        delivery.broadcast_uuid |> Newsletters.get_broadcast!() |> Broadcast.role_uuids()

      {:ok, _removed} = Roles.remove_role(user, Repo.get!(Role, role_uuid).name)

      assert_blocked(delivery)
    end

    test "only that recipient: the rest of the audience still goes out" do
      user = create_user()
      other = create_user()
      broadcast = create_broadcast(%{})
      stopped = create_delivery(broadcast, user)
      kept = create_delivery(broadcast, other)
      {:ok, _user} = UserGroupSource.record_opt_out(user)

      assert {:cancel, _reason} = DeliveryWorker.perform(job_for(stopped))
      assert :ok = DeliveryWorker.perform(job_for(kept))

      assert_email_sent(to: other.email)
      assert Repo.get(Delivery, stopped.uuid).status == "blocked"
      assert %Broadcast{status: "sent", sent_count: 1} = Repo.get(Broadcast, broadcast.uuid)
    end
  end

  describe "perform/1 — a delivery that has already concluded is never sent again" do
    @describetag :requires_v158
    setup :set_swoosh_global

    for status <- ~w(sent delivered opened bounced failed blocked) do
      test "#{status} stays #{status}, with no second mail" do
        user = create_user()
        broadcast = create_broadcast(%{})
        delivery = create_delivery(broadcast, user)

        {:ok, _delivery} = Newsletters.update_delivery_status(delivery, unquote(status))

        assert :ok = DeliveryWorker.perform(job_for(delivery))

        assert_no_email_sent()
        assert Repo.get(Delivery, delivery.uuid).status == unquote(status)
      end
    end
  end

  describe "record_accepted/3 — what core answers once it has the message" do
    @describetag :requires_v158

    defp pending_pair do
      broadcast = create_broadcast(%{})

      {broadcast, create_delivery(broadcast, create_user()),
       create_delivery(broadcast, create_user())}
    end

    test "suppressed mail reached nobody: blocked, uncounted, and the id is not stored" do
      {broadcast, first, second} = pending_pair()
      suppressed = %{id: "no-deliverable-recipients", suppressed: true}

      assert :ok = DeliveryWorker.record_accepted(first, suppressed, broadcast.uuid)
      assert :ok = DeliveryWorker.record_accepted(second, suppressed, broadcast.uuid)

      for delivery <- [first, second] do
        assert %Delivery{status: "blocked", message_id: nil, error: error} =
                 Repo.get(Delivery, delivery.uuid)

        assert error =~ "no-deliverable-recipients"
      end

      # Core's id is the same every time: this is what used to strand a broadcast.
      assert %Broadcast{status: "sent", sent_count: 0} = Repo.get(Broadcast, broadcast.uuid)
    end

    test "an id another delivery holds costs the id, not the delivery" do
      {broadcast, first, second} = pending_pair()

      assert :ok = DeliveryWorker.record_accepted(first, %{id: "same-id"}, broadcast.uuid)
      assert :ok = DeliveryWorker.record_accepted(second, %{id: "same-id"}, broadcast.uuid)

      assert %Delivery{status: "sent", message_id: "same-id"} = Repo.get(Delivery, first.uuid)
      assert %Delivery{status: "sent", message_id: nil} = Repo.get(Delivery, second.uuid)
      assert %Broadcast{status: "sent", sent_count: 2} = Repo.get(Broadcast, broadcast.uuid)
    end

    test "a write that raises does not fail the job, because a retry would send again" do
      {broadcast, first, _second} = pending_pair()
      Repo.delete!(first)

      assert :ok = DeliveryWorker.record_accepted(first, %{id: "gone"}, broadcast.uuid)
    end
  end

  describe "perform/1 — a job that raises" do
    @describetag :requires_v158
    setup :set_swoosh_global

    # A role uuid that cannot be cast raises in the recipient check, a real path
    # for a crafted row, and it runs after everything else has been read.
    defp doomed_delivery do
      broadcast = create_broadcast(%{source_params: %{"role_uuids" => ["not-a-uuid"]}})

      {:ok, delivery} =
        %Delivery{}
        |> Delivery.changeset(%{broadcast_uuid: broadcast.uuid, user_uuid: create_user().uuid})
        |> Repo.insert()

      delivery
    end

    test "on the last attempt the delivery ends failed and the broadcast finishes" do
      delivery = doomed_delivery()

      assert_raise Ecto.Query.CastError, fn ->
        DeliveryWorker.perform(job_for(delivery, attempt: 3, max_attempts: 3))
      end

      assert %Delivery{status: "failed", error: error} = Repo.get(Delivery, delivery.uuid)
      assert error =~ "CastError"

      # A crash in this code is not the provider refusing the address.
      assert %Broadcast{status: "sent", bounced_count: 0} =
               Repo.get(Broadcast, delivery.broadcast_uuid)
    end

    test "before the last attempt the retry still owns the delivery" do
      delivery = doomed_delivery()

      assert_raise Ecto.Query.CastError, fn ->
        DeliveryWorker.perform(job_for(delivery, attempt: 1, max_attempts: 3))
      end

      assert Repo.get(Delivery, delivery.uuid).status == "pending"
      assert Repo.get(Broadcast, delivery.broadcast_uuid).status == "sending"
    end
  end

  describe "backoff/1" do
    test "gives a provider outage about half an hour to clear" do
      assert DeliveryWorker.backoff(%Oban.Job{attempt: 1}) == 300
      assert DeliveryWorker.backoff(%Oban.Job{attempt: 2}) == 1_800
    end

    test "never runs out of delays" do
      assert DeliveryWorker.backoff(%Oban.Job{attempt: 9}) == 1_800
    end
  end

  describe "what the mail says to its reader" do
    @describetag :requires_v158
    setup :set_swoosh_global

    defp sent_for(delivery) do
      assert :ok = DeliveryWorker.perform(job_for(delivery))
      assert_received {:email, email}
      email
    end

    test "{{name}} is a CRM contact's name, not its address" do
      %{delivery: delivery} =
        create_crm_delivery(%{html_body: "<p>Hello {{name}}</p>", text_body: "Hello {{name}}"})

      email = sent_for(delivery)

      assert email.html_body =~ "Hello Member"
      assert email.text_body =~ "Hello Member"
    end

    test "a contact with no name is greeted by address, as before" do
      %{delivery: delivery, contact: contact} =
        create_crm_delivery(%{text_body: "Hello {{name}}"})

      {:ok, _contact} =
        contact |> Ecto.Changeset.change(name: "  ") |> Repo.update()

      assert sent_for(delivery).text_body =~ "Hello #{delivery.recipient_email}"
    end

    test "{{name}} is a user's full name when they have one" do
      broadcast = create_broadcast(%{text_body: "Hello {{name}}"})

      user =
        create_user()
        |> Ecto.Changeset.change(first_name: "Jane", last_name: "Doe")
        |> Repo.update!()

      assert sent_for(create_delivery(broadcast, user)).text_body =~ "Hello Jane Doe"
    end

    test "{{subject}} works in the text part as it does in the HTML" do
      broadcast =
        create_broadcast(%{
          subject: "Spring sale",
          html_body: "<p>Re: {{subject}}</p>",
          text_body: "Re: {{subject}}"
        })

      email = sent_for(create_delivery(broadcast, create_user()))

      assert email.html_body =~ "Re: Spring sale"
      assert email.text_body =~ "Re: Spring sale"
    end

    test "one lookup still gives a CRM recipient their language" do
      %{delivery: delivery, contact: contact} = create_crm_delivery(%{html_body: "<p>Hi</p>"})
      {:ok, _contact} = contact |> Ecto.Changeset.change(locale: "ru") |> Repo.update()

      assert :ok = DeliveryWorker.perform(job_for(delivery))
      assert_received {:email, _email}
    end
  end

  describe "error text" do
    @describetag :requires_v158

    test "an address quoted by the relay does not reach the delivery row" do
      broadcast = create_broadcast(%{})
      delivery = create_delivery(broadcast, create_user())

      DeliveryWorker.handle_failure(
        delivery.uuid,
        broadcast.uuid,
        {:smtp, "550 rejected <jane.doe@example.com>"},
        true
      )

      error = Repo.get(Delivery, delivery.uuid).error
      refute error =~ "jane.doe"
      assert error =~ "j***@example.com"
    end
  end

  describe "perform/1 — a managed organization" do
    @describetag :requires_v158
    setup :set_swoosh_global

    test "gets its mail at its contact address, not its login" do
      user =
        create_user()
        |> Ecto.Changeset.change(
          email: "org-#{System.unique_integer([:positive])}@organization.invalid",
          account_type: "organization",
          managed_by_members: true,
          contact_email: "office@example.com"
        )
        |> Repo.update!()

      broadcast = create_broadcast(%{html_body: "<p>Hi {{email}}</p>"})
      delivery = create_delivery(broadcast, user)

      assert :ok = DeliveryWorker.perform(job_for(delivery))

      assert_email_sent(fn email ->
        assert email.to == [{"", "office@example.com"}]
        assert email.html_body =~ "office@example.com"
      end)
    end

    test "with no contact address it gets nothing, and the broadcast finishes" do
      user =
        create_user()
        |> Ecto.Changeset.change(
          email: "org-#{System.unique_integer([:positive])}@organization.invalid",
          account_type: "organization",
          managed_by_members: true
        )
        |> Repo.update!()

      broadcast = create_broadcast(%{})
      delivery = create_delivery(broadcast, user)

      assert {:cancel, _reason} = DeliveryWorker.perform(job_for(delivery))
      assert_no_email_sent()
      assert Repo.get(Delivery, delivery.uuid).status == "blocked"
      assert Repo.get(Broadcast, broadcast.uuid).status == "sent"
    end
  end

  describe "perform/1 — the emails package's queue" do
    @describetag :requires_v158
    setup :set_swoosh_global

    defmodule QueueingProvider do
      @moduledoc false
      alias PhoenixKit.Email.DefaultProvider

      def maybe_enqueue(_email, _opts), do: {:queued, "queue-ref"}
      defdelegate intercept_before_send(email, opts), to: DefaultProvider
      defdelegate handle_after_send(email, result), to: DefaultProvider
      defdelegate adapter_to_provider_name(adapter, default), to: DefaultProvider
      defdelegate get_aws_region(), to: DefaultProvider
      defdelegate get_aws_access_key(), to: DefaultProvider
      defdelegate get_aws_secret_key(), to: DefaultProvider
      defdelegate aws_configured?(), to: DefaultProvider
    end

    setup do
      previous = Application.get_env(:phoenix_kit, :email_provider)
      Application.put_env(:phoenix_kit, :email_provider, QueueingProvider)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:phoenix_kit, :email_provider, previous),
          else: Application.delete_env(:phoenix_kit, :email_provider)
      end)
    end

    test "is passed by: the mail leaves here, and no queue reference is stored as its id" do
      user = create_user()
      broadcast = create_broadcast(%{})
      delivery = create_delivery(broadcast, user)

      assert :ok = DeliveryWorker.perform(job_for(delivery))

      assert_email_sent(to: user.email)
      assert %Delivery{status: "sent", message_id: id} = Repo.get(Delivery, delivery.uuid)
      refute id == "queue-ref"
    end

    # The path where queueing does real harm: the queue re-sends through the
    # default integration, off the profile chosen for this broadcast. No relay
    # listens here, so a send on this process fails, and only a queued one could
    # come back as a success.
    test "is passed by on a send profile too: the profile's own relay is what answers" do
      integration_uuid = add_integration("smtp", "Dead relay")

      {:ok, _connection} =
        Integrations.save_setup(integration_uuid, %{
          "host" => "127.0.0.1",
          "port" => "1",
          "username" => "relay-user",
          "password" => "relay-password"
        })

      profile = create_send_profile(%{integration_uuid: integration_uuid})
      broadcast = create_broadcast(%{send_profile_uuid: profile.uuid})
      delivery = create_delivery(broadcast, create_user())

      assert {:error, _reason} = DeliveryWorker.perform(job_for(delivery, attempt: 1))

      assert %Delivery{status: "pending", message_id: nil} = Repo.get(Delivery, delivery.uuid)
    end
  end

  describe "perform/1 — the site's variables" do
    @describetag :requires_v158
    setup :set_swoosh_global

    defp delivered_with(broadcast_attrs) do
      broadcast = create_broadcast(broadcast_attrs)
      delivery = create_delivery(broadcast, create_user())

      assert :ok = DeliveryWorker.perform(job_for(delivery))
    end

    test "reach a layout's subject pattern, so no literal tag goes in the Subject header" do
      {:ok, layout} =
        Layouts.create_layout(%{
          "name" => "site_subject_#{System.unique_integer([:positive])}",
          "html_body" => %{"en" => "<div>{{{content}}}</div>"},
          "subject" => %{"en" => "{{subject}} | {{site_name}}"}
        })

      delivered_with(%{subject: "News", template_uuid: layout.uuid})

      assert_email_sent(subject: "News | #{Settings.get_project_title()}")
    end

    test "reach a body sent without a layout, and the text part" do
      delivered_with(%{html_body: "<p>From {{site_name}}</p>", text_body: "From {{site_name}}"})

      site = Settings.get_project_title()

      assert_email_sent(fn email ->
        assert email.html_body =~ "<p>From #{site}</p>"
        assert String.starts_with?(email.text_body, "From #{site}\n\nUnsubscribe: ")
      end)
    end
  end

  describe "the finish check looks at its own broadcast" do
    @describetag :requires_v158

    test "another broadcast's pending delivery does not hold this one open" do
      broadcast = create_broadcast(%{})
      other = create_broadcast(%{})
      delivery = create_delivery(broadcast, create_user())
      _still_pending = create_delivery(other, create_user())

      assert {:ok, _delivery} =
               DeliveryWorker.update_delivery_result(delivery, "sent", %{}, broadcast.uuid, nil)

      assert Repo.get(Broadcast, broadcast.uuid).status == "sent"
      assert Repo.get(Broadcast, other.uuid).status == "sending"
    end

    test "its own pending delivery does" do
      broadcast = create_broadcast(%{})
      delivery = create_delivery(broadcast, create_user())
      _still_pending = create_delivery(broadcast, create_user())

      assert {:ok, _delivery} =
               DeliveryWorker.update_delivery_result(delivery, "sent", %{}, broadcast.uuid, nil)

      assert Repo.get(Broadcast, broadcast.uuid).status == "sending"
    end
  end

  describe "permanent_failure?/1 — blocked/unusable sends must not retry nor count as bounces" do
    test "blocklisted recipients and unusable integrations are permanent" do
      assert DeliveryWorker.permanent_failure?({:blocked, :blocklist})
      assert DeliveryWorker.permanent_failure?(:deleted)
      assert DeliveryWorker.permanent_failure?(:not_configured)
      assert DeliveryWorker.permanent_failure?({:incomplete_credentials, ["host"]})
      assert DeliveryWorker.permanent_failure?({:invalid_security, "tls9"})
      assert DeliveryWorker.permanent_failure?({:invalid_verify_cert, "maybe"})
      assert DeliveryWorker.permanent_failure?({:invalid_auth, "sometimes"})
      assert DeliveryWorker.permanent_failure?({:invalid_timeout, "soon"})
      assert DeliveryWorker.permanent_failure?(:invalid_ca_cert)
      assert DeliveryWorker.permanent_failure?(:no_ca_store)
      assert DeliveryWorker.permanent_failure?({:smtp_endpoint_refused, :blocked_port})
      assert DeliveryWorker.permanent_failure?(:delivery_not_found)
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
    @describetag :requires_v158
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

      # Simulate attempt 1 having failed for an unrelated transient reason: what
      # handle_failure/4 leaves behind, a delivery still "pending" with the error
      # on it, without actually forcing send_email/6 to fail (there's no seam for
      # that on the legacy path's real Swoosh call besides no-recipient, which
      # would leave the delivery unsendable on the retry too).
      {:ok, delivery} =
        Newsletters.update_delivery_status(delivery, "pending", %{error: "timeout"})

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

  describe "perform/1 — a cancelled broadcast stops its already-enqueued deliveries" do
    @describetag :requires_v158
    setup do
      PhoenixKit.Settings.update_setting("from_name", "My Newsletter")
      PhoenixKit.Settings.update_setting("from_email", "news@example.com")
      :ok
    end

    # The defect this covers: "Cancel broadcast" writes status "cancelled" on
    # the broadcast row and nothing else. Every DeliveryWorker job already in
    # the queue used to sail straight past it and send, and because the
    # throttle schedules job N minutes-to-hours out, that queue is exactly
    # where a mid-send cancellation finds most of its recipients.
    test "a broadcast cancelled after the job was enqueued sends no email" do
      user = create_user()
      broadcast = create_broadcast(%{subject: "Cancelled mid-send", html_body: "<p>Hi</p>"})
      {:ok, broadcast} = Newsletters.update_broadcast(broadcast, %{status: "sending"})
      delivery = create_delivery(broadcast, user)

      # The job is built while the broadcast is still healthy — as a real
      # enqueued job is — and only then does the operator cancel. Nothing
      # rewrites the job or the delivery row, so the worker's own re-read is
      # the only thing that can notice.
      job = %Oban.Job{
        args: %{"delivery_uuid" => delivery.uuid, "broadcast_uuid" => broadcast.uuid},
        attempt: 1,
        max_attempts: 3
      }

      {:ok, _cancelled} = Newsletters.update_broadcast(broadcast, %{status: "cancelled"})

      # Plain :ok, matching the already-sent skip: Oban must not retry this
      # job and must not count it as a failure.
      assert :ok = DeliveryWorker.perform(job)

      refute_email_sent()

      # "pending" is Delivery's only non-terminal status and stays the honest
      # one — the send never happened. A terminal status here would both lie
      # and (as "failed") inflate bounced_count.
      updated_delivery = Repo.get(Delivery, delivery.uuid)
      assert updated_delivery.status == "pending"
      assert updated_delivery.sent_at == nil
      assert updated_delivery.message_id == nil

      updated_broadcast = Repo.get(Broadcast, broadcast.uuid)
      assert updated_broadcast.status == "cancelled"
      assert updated_broadcast.sent_count == 0
      assert updated_broadcast.bounced_count == 0
    end

    test "a broadcast marked failed also stops its queued deliveries" do
      user = create_user()
      broadcast = create_broadcast(%{subject: "Failed broadcast", html_body: "<p>Hi</p>"})
      delivery = create_delivery(broadcast, user)
      {:ok, broadcast} = Newsletters.update_broadcast(broadcast, %{status: "failed"})

      job = %Oban.Job{
        args: %{"delivery_uuid" => delivery.uuid, "broadcast_uuid" => broadcast.uuid},
        attempt: 1,
        max_attempts: 3
      }

      assert :ok = DeliveryWorker.perform(job)

      refute_email_sent()
      assert Repo.get(Delivery, delivery.uuid).status == "pending"
    end

    # The allow-list's real point. A deny-list of ["cancelled", "failed"] would
    # send here; "draft" is not a status a broadcast with queued jobs can
    # legitimately be in, and treating an unexpected status as sendable is the
    # failure mode that matters for mass email.
    test "a broadcast in an unexpected status does not send" do
      user = create_user()
      broadcast = create_broadcast(%{subject: "Draft", status: "draft"})
      delivery = create_delivery(broadcast, user)

      job = %Oban.Job{
        args: %{"delivery_uuid" => delivery.uuid, "broadcast_uuid" => broadcast.uuid},
        attempt: 1,
        max_attempts: 3
      }

      assert :ok = DeliveryWorker.perform(job)

      refute_email_sent()
      assert Repo.get(Delivery, delivery.uuid).status == "pending"
    end

    # The other half of the guard, and the one that would turn a fix into an
    # outage if it were wrong: "sending" is the status a broadcast holds for
    # the entire duration of a normal send, so it must NOT halt.
    test "a broadcast still sending delivers normally" do
      user = create_user()
      broadcast = create_broadcast(%{subject: "Still sending", html_body: "<p>Hi</p>"})
      {:ok, broadcast} = Newsletters.update_broadcast(broadcast, %{status: "sending"})
      delivery = create_delivery(broadcast, user)

      job = %Oban.Job{
        args: %{"delivery_uuid" => delivery.uuid, "broadcast_uuid" => broadcast.uuid},
        attempt: 1,
        max_attempts: 3
      }

      assert :ok = DeliveryWorker.perform(job)

      assert_email_sent(to: user.email, subject: "Still sending")
      assert Repo.get(Delivery, delivery.uuid).status == "sent"
    end
  end

  describe "update_delivery_result/5 — delivery status and broadcast counter commit atomically" do
    @describetag :requires_v158
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

  describe "extract_message_id/1 — per-adapter {:ok, result} shapes" do
    test "API-adapter map (AmazonSES/Brevo) yields its :id" do
      assert DeliveryWorker.extract_message_id(%{id: "abc-123"}) == "abc-123"
    end

    test "SMTP receipt string with angle brackets yields the enclosed id" do
      receipt = "2.0.0 OK: queued as <f6c3a644@e75f4d56dc25>\r\n"
      assert DeliveryWorker.extract_message_id(receipt) == "f6c3a644@e75f4d56dc25"
    end

    test "SMTP receipt string without angle brackets still yields the id" do
      assert DeliveryWorker.extract_message_id("250 2.0.0 Ok: queued as ABC123XYZ") ==
               "ABC123XYZ"
    end

    test "Exim receipt (id=<id>) yields the id" do
      assert DeliveryWorker.extract_message_id("250 OK id=1a2b3c-000abc-XY") == "1a2b3c-000abc-XY"
    end

    test "Amazon SES SMTP receipt — as gen_smtp actually returns it, '250 ' stripped" do
      assert DeliveryWorker.extract_message_id("Ok 01000191abcdef-1234-5678\r\n") ==
               "01000191abcdef-1234-5678"
    end

    test "SES receipt with angle brackets and status-code prefix variant" do
      assert DeliveryWorker.extract_message_id("Ok <01000191abcdef-1234-5678>\r\n") ==
               "01000191abcdef-1234-5678"

      # Some relays keep an enhanced status code before Ok.
      assert DeliveryWorker.extract_message_id("2.0.0 Ok 01000191abcdef-1234-5678") ==
               "01000191abcdef-1234-5678"
    end

    test "an unrecognized string is nil, never a crash" do
      assert DeliveryWorker.extract_message_id("250 OK") == nil
    end

    test "a map without :id and non-map/non-binary shapes are nil" do
      assert DeliveryWorker.extract_message_id(%{"MessageId" => "x"}) == nil
      assert DeliveryWorker.extract_message_id(:ok) == nil
      assert DeliveryWorker.extract_message_id(nil) == nil
    end
  end

  describe "perform/1 — the layout in the reader's language, with core's chrome" do
    @describetag :requires_v158
    setup :set_swoosh_global

    setup do
      PhoenixKit.Settings.update_setting("from_name", "Acme")
      PhoenixKit.Settings.update_setting("from_email", "news@example.com")

      wrapper = fn tag ->
        ~s(<html><body data-accent="{{accent_color}}" data-logo="{{logo_url}}">) <>
          ~s(<header>{{{header}}}</header><p>#{tag}</p>{{{content}}}<footer>{{{footer}}}</footer>) <>
          ~s(</body></html>)
      end

      {:ok, layout} =
        Layouts.create_layout(%{
          "name" => "welcome_layout",
          "html_body" => %{"en" => wrapper.("ENGLISH"), "de" => wrapper.("DEUTSCH")},
          "subject" => %{"de" => "[DE] {{subject}}"}
        })

      {:ok, layout: layout}
    end

    defp create_user_in(locale) do
      {:ok, user} =
        %User{}
        |> User.guest_user_changeset(%{
          email: "reader-#{System.unique_integer([:positive])}@example.com"
        })
        |> Ecto.Changeset.put_change(:custom_fields, %{"preferred_locale" => locale})
        |> Repo.insert()

      user
    end

    defp send_to(broadcast, delivery) do
      job = %Oban.Job{
        args: %{"delivery_uuid" => delivery.uuid, "broadcast_uuid" => broadcast.uuid}
      }

      assert :ok = DeliveryWorker.perform(job)
    end

    test "a reader in de gets the German layout and subject", %{layout: layout} do
      user = create_user_in("de-AT")
      broadcast = create_broadcast(%{subject: "Hello", template_uuid: layout.uuid})
      send_to(broadcast, create_delivery(broadcast, user))

      assert_email_sent(fn email ->
        assert email.subject == "[DE] Hello"
        assert email.html_body =~ "DEUTSCH"
        refute email.html_body =~ "ENGLISH"
        assert email.html_body =~ "<p>Body</p>"
      end)
    end

    test "a reader in a language the layout lacks falls back", %{layout: layout} do
      user = create_user_in("pt-BR")
      broadcast = create_broadcast(%{subject: "Hello", template_uuid: layout.uuid})
      send_to(broadcast, create_delivery(broadcast, user))

      assert_email_sent(fn email ->
        # No pt: the site's content language (en in this suite).
        assert email.subject == "Hello"
        assert email.html_body =~ "ENGLISH"
      end)
    end

    test "header, footer, logo and accent colour come from core", %{layout: layout} do
      user = create_user_in("en")
      broadcast = create_broadcast(%{subject: "Hello", template_uuid: layout.uuid})
      send_to(broadcast, create_delivery(broadcast, user))

      site = Settings.get_project_title()
      branding = Branding.variables()

      assert_email_sent(fn email ->
        refute email.html_body =~ "{{"
        assert email.html_body =~ ~s(data-accent="#{branding["accent_color"]}")
        assert email.html_body =~ ~s(data-logo="#{branding["logo_url"]}")

        assert email.html_body =~
                 "<header>#{Phoenix.HTML.html_escape(site) |> Phoenix.HTML.safe_to_string()}"

        assert email.html_body =~ ~r{<footer>.+</footer>}s
      end)
    end

    test "without a layout the broadcast goes out in core's standard layout" do
      user = create_user_in("en")
      broadcast = create_broadcast(%{subject: "Plain", html_body: "<p>Only body</p>"})
      send_to(broadcast, create_delivery(broadcast, user))

      assert_email_sent(fn email ->
        assert email.html_body =~ "<!DOCTYPE html>"
        assert email.html_body =~ "<title>Plain</title>"
        assert email.html_body =~ "<p>Only body</p>"
      end)
    end

    test "the text part is never wrapped", %{layout: layout} do
      user = create_user_in("de")
      broadcast = create_broadcast(%{template_uuid: layout.uuid, text_body: "Hi {{email}}"})
      send_to(broadcast, create_delivery(broadcast, user))

      # Nothing around it: the text, then only the unsubscribe line.
      text = "Hi #{user.email}"

      assert_email_sent(fn email ->
        assert [^text, "Unsubscribe: http" <> _url] = String.split(email.text_body, "\n\n")
      end)
    end

    test "a CRM contact in de gets the German layout", %{layout: layout} do
      {:ok, crm_list} =
        CRMLists.create_list(%{name: "Locale list #{System.unique_integer([:positive])}"})

      {:ok, contact} =
        CRMContacts.create_contact(%{
          name: "Leser",
          email: "leser-#{System.unique_integer([:positive])}@example.com",
          locale: "de"
        })

      {:ok, _member} = CRMLists.add_contact_to_list(contact, crm_list, source: "manual")

      broadcast =
        create_broadcast(%{
          source_type: "crm_list",
          crm_list_uuid: crm_list.uuid,
          template_uuid: layout.uuid
        })

      {:ok, delivery} =
        %Delivery{}
        |> Delivery.changeset(%{broadcast_uuid: broadcast.uuid, recipient_email: contact.email})
        |> Repo.insert()

      send_to(broadcast, delivery)

      assert_email_sent(fn email -> assert email.html_body =~ "DEUTSCH" end)
    end
  end
end
