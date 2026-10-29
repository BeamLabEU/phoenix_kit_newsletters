defmodule PhoenixKit.Newsletters.Web.VerificationTest do
  @moduledoc """
  The address-verification page, driven callback by callback on a hand-built
  socket (see `BroadcastsTest` for why), with the engine replaced by
  `FakeVerificationEngine` so the tests are about this page: what it resolves,
  what it asks the engine for, what it shows.
  """

  use PhoenixKitNewsletters.DataCase, async: false

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Web.Verification
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Roles
  alias PhoenixKitCRM.Contacts
  alias PhoenixKitCRM.Lists
  alias PhoenixKitNewsletters.Test.FakeVerificationEngine, as: Fake
  alias PhoenixKitNewsletters.Test.Repo

  @engine_key :email_verification_engine
  @role_uuid "11111111-1111-4111-8111-111111111111"

  setup do
    Newsletters.enable_system()
    enable_crm()
    Application.put_env(:phoenix_kit_newsletters, @engine_key, Fake)
    on_exit(fn -> Application.delete_env(:phoenix_kit_newsletters, @engine_key) end)
    :ok
  end

  defp socket(extra \\ %{}) do
    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            flash: %{},
            phoenix_kit_current_user: nil,
            phoenix_kit_current_scope: full_scope()
          },
          extra
        )
    }
  end

  defp connected_socket(extra \\ %{}), do: %{socket(extra) | transport_pid: self()}

  defp mounted(socket \\ socket()) do
    {:ok, socket} = Verification.mount(%{}, %{}, socket)
    socket
  end

  defp visit(params, socket \\ nil) do
    {:noreply, socket} =
      Verification.handle_params(params, "/", socket || mounted())

    socket
  end

  # The click, then the batch start it runs in a task: waits for the task's
  # result and hands it to `handle_async/3`, as the LiveView process would.
  defp start_via_event(socket) do
    {:noreply, socket} =
      Verification.handle_event("start_batch", %{}, %{socket | transport_pid: self()})

    if socket.assigns.starting do
      receive do
        {_prefix, :async_result, {:start, {_ref, _cid, :start_batch, result}}} ->
          Verification.handle_async(:start_batch, result, socket)
      after
        1_000 -> flunk("the batch start did not report")
      end
    else
      {:noreply, socket}
    end
  end

  defp render_page(socket) do
    socket.assigns
    |> Map.merge(%{url_path: "/admin/newsletters/verification", phoenix_kit_current_scope: nil})
    |> Verification.render()
    |> rendered_to_string()
  end

  defp create_role do
    {:ok, role} = Roles.create_role(%{name: "VRole#{System.unique_integer([:positive])}"})
    role
  end

  defp create_user(role, email) do
    {:ok, user} = %User{} |> User.guest_user_changeset(%{email: email}) |> Repo.insert()
    {:ok, _} = Roles.assign_role(user, role.name)
    user
  end

  defp audience(emails) do
    role = create_role()
    Enum.each(emails, &create_user(role, &1))
    role
  end

  defp result(status, extra \\ %{}) do
    Map.merge(
      %{
        status: status,
        reason: nil,
        level: "mx",
        free: false,
        role: false,
        disposable: false,
        checked_at: nil
      },
      extra
    )
  end

  describe "mount/3" do
    test "redirects with a flash when the module is disabled" do
      Newsletters.disable_system()
      assert {:ok, socket} = Verification.mount(%{}, %{}, socket())
      assert {:live, :redirect, _} = socket.redirected
      assert socket.assigns.flash["error"] =~ "not enabled"
    end

    test "assigns the page chrome and the engine state" do
      socket = mounted()
      assert socket.assigns.page_title == "Address verification"
      assert socket.assigns.engine == :ready
      assert socket.assigns.queue_configured
    end

    test "the engine state is :disabled when verification is switched off" do
      Fake.put(:enabled, false)
      assert mounted().assigns.engine == :disabled
    end

    test "the engine state is :unavailable when no engine is configured" do
      Application.delete_env(:phoenix_kit_newsletters, @engine_key)
      assert mounted().assigns.engine == :unavailable
    end

    test "the engine state is :unavailable when the configured module is not there" do
      Application.put_env(:phoenix_kit_newsletters, @engine_key, PhoenixKitNewsletters.Test.Nope)
      assert mounted().assigns.engine == :unavailable
    end

    test "without an engine the page state is empty and neutral" do
      Application.delete_env(:phoenix_kit_newsletters, @engine_key)
      socket = mounted()

      refute socket.assigns.queue_configured
      assert socket.assigns.summary == nil
      assert socket.assigns.rows == []
    end
  end

  describe "degraded states" do
    test "an alert says that no verification engine is available" do
      Application.delete_env(:phoenix_kit_newsletters, @engine_key)
      html = socket() |> mounted() |> then(&visit(%{}, &1)) |> render_page()

      assert html =~ ~s(id="verification-unavailable")
      assert html =~ "verification engine is not available"
      assert html =~ ":email_verification_engine"
      refute html =~ "verification-audience-form"
    end

    test "the same alert for a configured module that is not there" do
      Application.put_env(:phoenix_kit_newsletters, @engine_key, PhoenixKitNewsletters.Test.Nope)
      html = socket() |> mounted() |> then(&visit(%{}, &1)) |> render_page()

      assert html =~ ~s(id="verification-unavailable")
      refute html =~ "verification-audience-form"
    end

    test "an alert says verification is switched off" do
      Fake.put(:enabled, false)
      html = mounted() |> then(&visit(%{}, &1)) |> render_page()

      assert html =~ ~s(id="verification-disabled")
      assert html =~ "verification engine has to be switched on"
      refute html =~ "verification-audience-form"
    end

    test "a warning says the host's Oban config lacks the queue" do
      Fake.put(:queue_configured, false)
      html = mounted() |> then(&visit(%{}, &1)) |> render_page()

      assert html =~ ~s(id="verification-queue-warning")
      assert html =~ "does not declare the queue the verification engine runs its batches in"
      assert html =~ "verification-audience-form"
    end

    test "no warning when the queue is configured" do
      refute mounted() |> then(&visit(%{}, &1)) |> render_page() =~ "verification-queue-warning"
    end

    test "an engine that is not there never gets asked for anything" do
      Application.delete_env(:phoenix_kit_newsletters, @engine_key)
      socket = mounted() |> then(&visit(%{"source" => "user_group"}, &1))
      assert socket.assigns.emails == []
      refute_received {:results_for, _}
    end

    test "with no engine every event answers with a flash, not a crash" do
      Application.delete_env(:phoenix_kit_newsletters, @engine_key)
      role = audience(["a@example.com"])
      socket = visit(%{"source" => "user_group", "roles" => [role.uuid]})

      assert socket.assigns.emails == []

      {:noreply, socket} = start_via_event(socket)
      assert socket.assigns.flash["error"] =~ "verification engine is not available"

      {:noreply, socket} =
        Verification.handle_event("filter_status", %{"status" => "valid"}, socket)

      assert {:live, :patch, _} = socket.redirected

      assert {:noreply, _socket} = Verification.handle_info(:refresh_runner, socket)

      assert {:noreply, _socket} =
               Verification.handle_info({:email_verify_batch, %{uuid: "x"}}, socket)
    end
  end

  describe "handle_params/3 with a role audience" do
    test "lists the sendable addresses with their verdicts" do
      role = audience(["a@example.com", "b@example.com", "c@example.com"])

      Fake.put(:results, %{
        "a@example.com" => result("valid", %{level: "smtp"}),
        "b@example.com" => result("not_sure", %{reason: "smtp_disabled", free: true})
      })

      socket = visit(%{"source" => "user_group", "roles" => [role.uuid]})

      assert Enum.map(socket.assigns.rows, &{&1.email, &1.status}) ==
               [
                 {"a@example.com", :valid},
                 {"b@example.com", :not_sure},
                 {"c@example.com", :unchecked}
               ]

      assert socket.assigns.summary == %{valid: 1, invalid: 0, temp: 0, not_sure: 1, unchecked: 1}
      assert socket.assigns.total == 3

      html = render_page(socket)
      assert html =~ "Domain OK (no SMTP)"
      assert html =~ "Not checked"
      assert html =~ "Free"
      assert html =~ "Mailbox not probed (SMTP check is off)"
      assert html =~ "a@example.com"
    end

    test "an address waiting for the SMTP stage has its own badge, apart from smtp_disabled" do
      role = audience(["a@example.com", "b@example.com"])

      Fake.put(:results, %{
        "a@example.com" => result("not_sure", %{reason: "smtp_pending"}),
        "b@example.com" => result("not_sure", %{reason: "smtp_disabled"})
      })

      socket = visit(%{"source" => "user_group", "roles" => [role.uuid]})
      html = render_page(socket)

      assert html =~ "Waiting for SMTP"
      assert html =~ "Domain OK (no SMTP)"
      assert html =~ "Waiting for the SMTP check"
      assert html =~ "Mailbox not probed (SMTP check is off)"
      refute html =~ "smtp_pending"

      assert Verification.status_badge_class(:smtp_pending) !=
               Verification.status_badge_class(:mx_ok)

      assert Verification.status_badge_class(:smtp_pending) !=
               Verification.status_badge_class(:not_sure)
    end

    test "the SMTP verdict reasons are spelled out, never shown as codes" do
      reasons =
        ~w(catch_all mailbox_unknown mailbox_full greylisted smtp_blocked smtp_timeout
           smtp_connect_failed mail_from_rejected smtp_unavailable smtp_ok smtp_reset)

      role = audience(Enum.map(reasons, &"#{&1}@example.com"))

      Fake.put(
        :results,
        Map.new(reasons, &{"#{&1}@example.com", result("not_sure", %{reason: &1})})
      )

      html = render_page(visit(%{"source" => "user_group", "roles" => [role.uuid]}))

      for reason <- reasons do
        label = Verification.reason_label(reason)
        assert label != reason
        assert html =~ label
      end

      assert html =~ "Catch-all"
    end

    test "a verdict a batch job gave up on (temp, no level) is shown with its reason" do
      role = audience(["a@example.com"])

      Fake.put(:results, %{
        "a@example.com" => result("temp", %{reason: "job_failed", level: nil})
      })

      socket = visit(%{"source" => "user_group", "roles" => [role.uuid]})
      assert [%{status: :temp}] = socket.assigns.rows

      html = render_page(socket)
      assert html =~ "Temporary problem"
      assert html =~ "Verification failed, will need a re-run"
      refute html =~ "job_failed"
    end

    test "the status filter narrows the rows, and the summary still counts everyone" do
      role = audience(["a@example.com", "b@example.com", "c@example.com"])

      Fake.put(:results, %{
        "a@example.com" => result("invalid", %{reason: "no_mx"}),
        "b@example.com" => result("valid"),
        "c@example.com" => result("invalid", %{reason: "syntax"})
      })

      socket = visit(%{"source" => "user_group", "roles" => [role.uuid], "status" => "invalid"})

      assert Enum.map(socket.assigns.rows, & &1.email) == ["a@example.com", "c@example.com"]
      assert socket.assigns.status_filter == "invalid"
      assert socket.assigns.summary.valid == 1
    end

    test "a filtered view reads statuses for the audience and full results for the page only" do
      role = audience(["a@example.com", "b@example.com", "c@example.com"])

      Fake.put(:results, %{
        "a@example.com" => result("invalid", %{reason: "no_mx"}),
        "b@example.com" => result("valid"),
        "c@example.com" => result("invalid", %{reason: "syntax"})
      })

      socket = visit(%{"source" => "user_group", "roles" => [role.uuid], "status" => "invalid"})

      assert_received {:statuses_for, audience}
      assert Enum.sort(audience) == ["a@example.com", "b@example.com", "c@example.com"]
      assert_received {:results_for, page}
      assert Enum.sort(page) == ["a@example.com", "c@example.com"]
      refute_received {:results_for, _}

      assert Enum.map(socket.assigns.rows, &{&1.email, &1.result.reason}) ==
               [{"a@example.com", "no_mx"}, {"c@example.com", "syntax"}]
    end

    test "an unknown status in the URL is ignored" do
      role = audience(["a@example.com"])
      socket = visit(%{"source" => "user_group", "roles" => [role.uuid], "status" => "bogus"})
      assert socket.assigns.status_filter == ""
      assert length(socket.assigns.rows) == 1
    end

    test "without a filter only the shown page is looked up" do
      role = audience(["a@example.com", "b@example.com"])
      visit(%{"source" => "user_group", "roles" => [role.uuid]})
      assert_received {:results_for, emails}
      assert Enum.sort(emails) == ["a@example.com", "b@example.com"]
    end

    test "a filter or page patch over the same audience does not count the audience again" do
      role = audience(["a@example.com", "b@example.com"])
      Fake.put(:results, %{"a@example.com" => result("invalid", %{reason: "no_mx"})})
      params = %{"source" => "user_group", "roles" => [role.uuid]}

      socket = visit(params)
      assert_received {:summary, counted}
      assert Enum.sort(counted) == ["a@example.com", "b@example.com"]

      filtered = visit(Map.put(params, "status", "invalid"), socket)

      assert Enum.map(filtered.assigns.rows, & &1.email) == ["a@example.com"]
      assert filtered.assigns.summary == socket.assigns.summary
      refute_received {:summary, _}

      # Another audience is counted afresh.
      other = audience(["c@example.com"])
      visit(%{"source" => "user_group", "roles" => [other.uuid]}, filtered)
      assert_received {:summary, ["c@example.com"]}
    end

    test "a status or page change does not resolve the audience again" do
      role = audience(["a@example.com"])
      params = %{"source" => "user_group", "roles" => [role.uuid]}
      socket = visit(params)
      assert_received {:latest_batch, _, _}

      visit(Map.put(params, "status", "valid"), socket)
      refute_received {:latest_batch, _, _}
    end

    test "garbage in the URL shows an empty audience instead of crashing" do
      socket = visit(%{"source" => "user_group", "roles" => ["not-a-uuid", 7, nil]})
      assert socket.assigns.role_uuids == []
      assert socket.assigns.emails == []
      assert render_page(socket) =~ "No addresses to verify"
    end

    test "a deleted role contributes nothing" do
      socket = visit(%{"source" => "user_group", "roles" => [Ecto.UUID.generate()]})
      assert socket.assigns.emails == []
    end

    test "a page past the end is clamped" do
      role = audience(["a@example.com"])
      socket = visit(%{"source" => "user_group", "roles" => [role.uuid], "page" => "9"})
      assert socket.assigns.page == 1
    end
  end

  describe "handle_params/3 with a CRM audience" do
    setup do
      {:ok, list} =
        Lists.create_list(%{
          name: "VList #{System.unique_integer([:positive])}",
          subscribable: true
        })

      {:ok, contact} =
        Contacts.create_contact(%{
          name: "C",
          email: "crm-#{System.unique_integer([:positive])}@example.com"
        })

      {:ok, _} = Lists.add_contact_to_list(contact, list, source: "manual")
      %{list: list, contact: contact}
    end

    test "offers a non-subscribable list in the picker and keeps it selected" do
      {:ok, ops} =
        Lists.create_list(%{
          name: "Ops #{System.unique_integer([:positive])}",
          subscribable: false
        })

      socket = visit(%{"source" => "crm_list", "list" => ops.uuid})

      assert ops.uuid in Enum.map(socket.assigns.crm_lists, & &1.uuid)
      assert socket.assigns.crm_list_uuid == ops.uuid
    end

    test "resolves the list's sendable recipients", %{list: list, contact: contact} do
      socket = visit(%{"source" => "crm_list", "list" => list.uuid})
      assert socket.assigns.source == "crm_list"
      assert socket.assigns.emails == [contact.email]
    end

    test "CRM is the default audience when CRM is installed" do
      assert mounted() |> then(&visit(%{}, &1)) |> then(& &1.assigns.source) == "crm_list"
    end

    test "the page offers the CRM lists", %{list: list} do
      html = render_page(visit(%{"source" => "crm_list"}))
      assert html =~ list.name
      assert html =~ ~s(name="list")
    end

    test "a garbage list uuid is an empty audience" do
      socket = visit(%{"source" => "crm_list", "list" => "x'; drop"})
      assert socket.assigns.crm_list_uuid == ""
      assert socket.assigns.emails == []
    end
  end

  describe "handle_event/3" do
    test "select_audience patches the URL with the chosen source" do
      {:noreply, socket} =
        Verification.handle_event(
          "select_audience",
          %{"source" => "user_group", "roles" => [@role_uuid]},
          mounted()
        )

      assert {:live, :patch, %{to: to}} = socket.redirected
      assert URI.parse(to).path =~ "/admin/newsletters/verification"

      assert URI.decode_query(URI.parse(to).query) == %{
               "source" => "user_group",
               "roles[]" => @role_uuid
             }
    end

    test "select_audience drops the other source's fields" do
      {:noreply, socket} =
        Verification.handle_event(
          "select_audience",
          %{"source" => "crm_list", "list" => @role_uuid, "roles" => [@role_uuid]},
          mounted()
        )

      assert {:live, :patch, %{to: to}} = socket.redirected

      assert URI.decode_query(URI.parse(to).query) == %{
               "source" => "crm_list",
               "list" => @role_uuid
             }
    end

    test "filter_status patches with the status and keeps the audience, dropping the page" do
      role = audience(["a@example.com"])
      socket = visit(%{"source" => "user_group", "roles" => [role.uuid], "page" => "1"})

      {:noreply, socket} =
        Verification.handle_event("filter_status", %{"status" => "valid"}, socket)

      assert {:live, :patch, %{to: to}} = socket.redirected
      query = URI.decode_query(URI.parse(to).query)
      assert query["status"] == "valid"
      assert query["source"] == "user_group"
      assert query["roles[]"] == role.uuid
      refute Map.has_key?(query, "page")
    end

    test "filter_status with the blank option clears the filter" do
      {:noreply, socket} =
        Verification.handle_event("filter_status", %{"status" => ""}, mounted())

      assert {:live, :patch, %{to: to}} = socket.redirected
      refute to =~ "status="
    end
  end

  describe "starting a batch" do
    test "rechecks the configured engine before starting from an already open page" do
      role = audience(["a@example.com"])
      socket = visit(%{"source" => "user_group", "roles" => [role.uuid]})

      Fake.put(:enabled, false)
      {:noreply, disabled} = start_via_event(socket)
      assert disabled.assigns.engine == :disabled
      assert disabled.assigns.flash["error"] =~ "switched off"
      refute_received {:start_batch, _, _, _, _}

      Application.delete_env(:phoenix_kit_newsletters, @engine_key)
      {:noreply, unavailable} = start_via_event(socket)
      assert unavailable.assigns.engine == :unavailable
      assert unavailable.assigns.flash["error"] =~ "not available"
      refute_received {:start_batch, _, _, _, _}
    end

    test "asks the engine for the audience's addresses under a role-group source" do
      role = audience(["a@example.com", "b@example.com"])
      user = %User{uuid: Ecto.UUID.generate()}

      socket =
        visit(
          %{"source" => "user_group", "roles" => [role.uuid]},
          mounted(socket(%{phoenix_kit_current_user: user}))
        )

      {:noreply, socket} = start_via_event(socket)

      assert_received {:start_batch, emails, "newsletters_user_group", ref, opts}
      assert Enum.sort(emails) == ["a@example.com", "b@example.com"]
      assert ref == Verification.roles_ref([role.uuid])
      assert ref =~ ~r/^roles:[0-9a-f]{32}$/
      assert opts[:title] == role.name
      assert opts[:created_by_uuid] == user.uuid
      assert socket.assigns.flash["info"] =~ "started"
      assert socket.assigns.batch.state == "queued"
    end

    test "the roles ref does not depend on the order of the roles" do
      assert Verification.roles_ref(["a", "b"]) == Verification.roles_ref(["b", "a", "a"])
      refute Verification.roles_ref(["a"]) == Verification.roles_ref(["b"])
    end

    test "uses the list's uuid as the ref for a CRM audience" do
      {:ok, list} = Lists.create_list(%{name: "Batch list"})

      {:ok, contact} =
        Contacts.create_contact(%{
          name: "C",
          email: "b-#{System.unique_integer([:positive])}@example.com"
        })

      {:ok, _} = Lists.add_contact_to_list(contact, list, source: "manual")

      socket = visit(%{"source" => "crm_list", "list" => list.uuid})
      {:noreply, _} = start_via_event(socket)

      assert_received {:start_batch, [email], "newsletters_crm_list", ref, opts}
      assert email == contact.email
      assert ref == list.uuid
      assert opts[:title] == "Batch list"
    end

    test "subscribes to the new batch once the socket is connected" do
      role = audience(["a@example.com"])

      socket =
        visit(%{"source" => "user_group", "roles" => [role.uuid]}, mounted(connected_socket()))

      {:noreply, socket} = start_via_event(socket)

      assert_received {:subscribe_batch, uuid}
      assert uuid == socket.assigns.batch.uuid
    end

    test "reports an empty audience without calling the engine" do
      socket = visit(%{"source" => "user_group"})
      {:noreply, socket} = start_via_event(socket)

      assert socket.assigns.flash["error"] =~ "no sendable addresses"
      refute_received {:start_batch, _, _, _, _}
    end

    test "does not start while the latest batch is queued or running" do
      role = audience(["a@example.com"])

      for state <- ~w(queued running) do
        Fake.put(:latest_batch, %{
          uuid: Ecto.UUID.generate(),
          state: state,
          processed: 0,
          total: 1,
          counts: %{},
          finished_at: nil
        })

        socket = visit(%{"source" => "user_group", "roles" => [role.uuid]})
        {:noreply, socket} = start_via_event(socket)

        assert socket.assigns.flash["error"] =~ "already running"
        refute_received {:start_batch, _, _, _, _}
      end
    end

    test "starts again once the latest batch is done" do
      role = audience(["a@example.com"])

      Fake.put(:latest_batch, %{
        uuid: Ecto.UUID.generate(),
        state: "done",
        processed: 1,
        total: 1,
        counts: %{},
        finished_at: DateTime.utc_now()
      })

      socket = visit(%{"source" => "user_group", "roles" => [role.uuid]})
      {:noreply, _socket} = start_via_event(socket)
      assert_received {:start_batch, ["a@example.com"], _, _, _}
    end

    test "does not start unless the engine is ready" do
      role = audience(["a@example.com"])
      socket = visit(%{"source" => "user_group", "roles" => [role.uuid]})
      assert_received {:latest_batch, _, _}

      for engine <- [:disabled, :unavailable] do
        socket = %{socket | assigns: %{socket.assigns | engine: engine}}
        {:noreply, socket} = start_via_event(socket)

        assert socket.assigns.flash["error"]
        refute_received {:start_batch, _, _, _, _}
        refute_received {:latest_batch, _, _}
      end
    end

    test "says verification is switched off when it is, and the module is missing when it is" do
      role = audience(["a@example.com"])
      socket = visit(%{"source" => "user_group", "roles" => [role.uuid]})

      disabled = %{socket | assigns: %{socket.assigns | engine: :disabled}}
      {:noreply, disabled} = start_via_event(disabled)
      assert disabled.assigns.flash["error"] =~ "switched off"
      refute disabled.assigns.flash["error"] =~ "not available"

      missing = %{socket | assigns: %{socket.assigns | engine: :unavailable}}
      {:noreply, missing} = start_via_event(missing)
      assert missing.assigns.flash["error"] =~ "verification engine is not available"
    end

    test "says the verification failed to start when the engine raised" do
      role = audience(["a@example.com"])
      socket = visit(%{"source" => "user_group", "roles" => [role.uuid]})

      Fake.put(:start_batch, {:error, {:engine_error, "boom"}})
      {:noreply, socket} = start_via_event(socket)

      assert socket.assigns.flash["error"] =~ "failed to start"
      assert socket.assigns.flash["error"] =~ "verification engine reported an error"
      refute socket.assigns.flash["error"] =~ "not available"
    end

    test "the engine is called from a task, not the page, and the page waits for the answer" do
      role = audience(["a@example.com"])
      socket = visit(%{"source" => "user_group", "roles" => [role.uuid]})

      {:noreply, started} =
        Verification.handle_event("start_batch", %{}, %{socket | transport_pid: self()})

      assert started.assigns.starting
      assert started.assigns.batch == nil
      assert render_page(started) =~ ~r/id="verification-start"[^>]*disabled/

      # A second click while the first is in flight is refused, not run twice.
      {:noreply, again} =
        Verification.handle_event("start_batch", %{}, started)

      assert again.assigns.flash["error"] =~ "already running"

      assert_receive {_prefix, :async_result, {:start, {_ref, _cid, :start_batch, result}}}, 1_000
      assert_received {:start_batch, ["a@example.com"], _, _, _}
      refute_received {:start_batch, _, _, _, _}

      {:noreply, done} = Verification.handle_async(:start_batch, result, started)
      refute done.assigns.starting
      assert done.assigns.batch.state == "queued"
      assert done.assigns.flash["info"] =~ "started"
    end

    test "a crashed start releases the button and says it failed" do
      role = audience(["a@example.com"])
      socket = visit(%{"source" => "user_group", "roles" => [role.uuid]})
      socket = %{socket | assigns: %{socket.assigns | starting: true}}

      {:noreply, socket} = Verification.handle_async(:start_batch, {:exit, :boom}, socket)

      refute socket.assigns.starting
      assert socket.assigns.flash["error"] =~ "failed to start"
    end

    test "switching the audience back does not subscribe to a batch twice" do
      role = audience(["a@example.com"])
      other = audience(["b@example.com"])

      running = %{
        uuid: Ecto.UUID.generate(),
        state: "running",
        processed: 0,
        total: 1,
        counts: %{},
        finished_at: nil
      }

      Fake.put(:latest_batch, running)
      Fake.put(:batch, running)

      params = %{"source" => "user_group", "roles" => [role.uuid]}
      socket = visit(params, mounted(connected_socket()))
      socket = visit(%{"source" => "user_group", "roles" => [other.uuid]}, socket)
      visit(params, socket)

      uuid = running.uuid
      assert_received {:subscribe_batch, ^uuid}
      refute_received {:subscribe_batch, ^uuid}
    end

    test "turns the engine's errors into messages" do
      role = audience(["a@example.com"])
      socket = visit(%{"source" => "user_group", "roles" => [role.uuid]})

      for {reply, text} <- [
            {{:error, :too_many_emails}, "too large"},
            {{:error, :unavailable}, "not available"},
            {{:error, :boom}, "Could not start"}
          ] do
        Fake.put(:start_batch, reply)
        {:noreply, socket} = start_via_event(socket)
        assert socket.assigns.flash["error"] =~ text
      end
    end
  end

  describe "progress" do
    setup do
      role = audience(["a@example.com", "b@example.com"])
      uuid = Ecto.UUID.generate()

      batch = %{
        uuid: uuid,
        state: "running",
        processed: 1,
        total: 2,
        counts: %{"valid" => 1},
        finished_at: nil
      }

      Fake.put(:latest_batch, batch)

      socket =
        visit(%{"source" => "user_group", "roles" => [role.uuid]}, mounted(connected_socket()))

      %{socket: socket, batch: batch}
    end

    test "the latest batch is shown on load, and followed while it runs", %{
      socket: socket,
      batch: batch
    } do
      assert socket.assigns.batch.uuid == batch.uuid
      assert_received {:subscribe_batch, subscribed}
      assert subscribed == batch.uuid

      html = render_page(socket)
      assert html =~ "Verifying: 1 of 2"
      assert html =~ ~s(value="50")
    end

    test "the bar is labelled by the progress text", %{socket: socket} do
      html = render_page(socket)

      assert html =~ ~s(aria-labelledby="verification-progress-label")
      assert html =~ ~s(id="verification-progress-label")
      assert html =~ "50%"
    end

    test "the number of addresses waiting for SMTP is shown", %{socket: socket, batch: batch} do
      refute render_page(socket) =~ "waiting for the SMTP check"

      {:noreply, socket} =
        Verification.handle_info(
          {:email_verify_batch,
           %{
             uuid: batch.uuid,
             state: "running",
             processed: 1,
             total: 5,
             counts: %{},
             awaiting_smtp: 3
           }},
          socket
        )

      assert socket.assigns.batch.awaiting_smtp == 3
      assert render_page(socket) =~ "3 addresses waiting for the SMTP check"
    end

    test "a batch snapshot from an engine without the SMTP stage shows no count", %{
      socket: socket,
      batch: batch
    } do
      {:noreply, socket} =
        Verification.handle_info(
          {:email_verify_batch,
           %{uuid: batch.uuid, state: "running", processed: 2, total: 3, counts: %{}}},
          socket
        )

      refute render_page(socket) =~ "waiting for the SMTP check"
    end

    test "a runner that is not online is named in the progress, with a link to the engine's settings page",
         %{batch: batch} do
      role = audience(["w@example.com"])
      Fake.put(:smtp_mode, "runner")
      Fake.put(:runner_status, %{state: :offline})
      Fake.put(:latest_batch, Map.put(batch, :awaiting_smtp, 2))
      Fake.put(:settings_path, "/admin/verification/settings")

      socket =
        visit(%{"source" => "user_group", "roles" => [role.uuid]}, mounted(connected_socket()))

      assert socket.assigns.smtp_wait
      assert socket.assigns.settings_path == "/admin/verification/settings"
      html = render_page(socket)

      assert html =~ "SMTP is waiting for the runner - see the verification settings"
      assert html =~ ~r/<a [^>]*id="verification-runner-offline"/
      assert html =~ ~s(href="/admin/verification/settings")
    end

    test "an engine without a settings page gets the runner hint as plain text", %{batch: batch} do
      role = audience(["w@example.com"])
      Fake.put(:smtp_mode, "runner")
      Fake.put(:runner_status, %{state: :offline})
      Fake.put(:latest_batch, Map.put(batch, :awaiting_smtp, 2))

      socket =
        visit(%{"source" => "user_group", "roles" => [role.uuid]}, mounted(connected_socket()))

      assert socket.assigns.smtp_wait
      assert socket.assigns.settings_path == nil
      html = render_page(socket)

      assert html =~
               ~r/<span [^>]*id="verification-runner-offline"[^>]*>\s*SMTP is waiting for the runner\s*</

      refute html =~ ~r/<a [^>]*id="verification-runner-offline"/
      refute html =~ "verification settings"
    end

    test "no runner hint when the runner is online, or the mode is not runner", %{batch: batch} do
      role = audience(["w@example.com"])
      Fake.put(:latest_batch, Map.put(batch, :awaiting_smtp, 2))

      for {mode, state} <- [{"runner", :online}, {"local", :offline}, {"off", :never_connected}] do
        Fake.put(:smtp_mode, mode)
        Fake.put(:runner_status, %{state: state})

        socket =
          visit(%{"source" => "user_group", "roles" => [role.uuid]}, mounted(connected_socket()))

        refute socket.assigns.smtp_wait, "#{mode} #{state}"
        assert socket.assigns.settings_path == nil, "#{mode} #{state}"
        refute render_page(socket) =~ "waiting for the runner", "#{mode} #{state}"
      end
    end

    test "a running batch has a runner timer pending, a dead render or a finished one none", %{
      socket: socket,
      batch: batch
    } do
      assert socket.assigns.runner_tick

      # An unconnected (dead-render) page never schedules one.
      refute visit(%{"source" => "user_group", "roles" => socket.assigns.role_uuids}).assigns.runner_tick

      # A tick clears the pending flag and schedules the next while the batch runs.
      {:noreply, ticked} = Verification.handle_info(:refresh_runner, socket)
      assert ticked.assigns.runner_tick

      # Visiting the page again with a timer pending does not schedule another.
      assert visit(%{"source" => "user_group", "roles" => ticked.assigns.role_uuids}, ticked).assigns.runner_tick

      done = %{batch | state: "done", finished_at: DateTime.utc_now()}
      Fake.put(:batch, done)

      {:noreply, ticked} =
        Verification.handle_info(
          {:email_verify_batch,
           %{uuid: batch.uuid, state: "done", processed: 2, total: 2, counts: %{}}},
          ticked
        )

      {:noreply, ticked} = Verification.handle_info(:refresh_runner, ticked)
      refute ticked.assigns.runner_tick
    end

    test "the runner state is read again on a timer while the batch runs", %{
      socket: socket,
      batch: batch
    } do
      Fake.put(:smtp_mode, "runner")
      Fake.put(:runner_status, %{state: :offline})

      refute socket.assigns.smtp_wait
      {:noreply, socket} = Verification.handle_info(:refresh_runner, socket)
      assert socket.assigns.smtp_wait

      Fake.put(:runner_status, %{state: :online})
      {:noreply, socket} = Verification.handle_info(:refresh_runner, socket)
      refute socket.assigns.smtp_wait

      # A finished batch has nothing to wait for.
      Fake.put(:runner_status, %{state: :offline})
      Fake.put(:batch, %{batch | state: "done", finished_at: DateTime.utc_now()})

      {:noreply, socket} =
        Verification.handle_info(
          {:email_verify_batch,
           %{uuid: batch.uuid, state: "done", processed: 2, total: 2, counts: %{}}},
          socket
        )

      refute socket.assigns.smtp_wait
      refute render_page(socket) =~ "waiting for the runner"
    end

    test "a progress message moves the bar without re-reading the table", %{
      socket: socket,
      batch: batch
    } do
      message =
        {:email_verify_batch,
         %{uuid: batch.uuid, state: "running", processed: 2, total: 3, counts: %{}}}

      {:noreply, socket} = Verification.handle_info(message, socket)

      assert socket.assigns.batch.processed == 2
      assert socket.assigns.batch.total == 3
    end

    test "a snapshot older than the one held is ignored", %{socket: socket, batch: batch} do
      {:noreply, socket} =
        Verification.handle_info(
          {:email_verify_batch,
           %{uuid: batch.uuid, state: "running", processed: 2, total: 2, counts: %{}}},
          socket
        )

      {:noreply, socket} =
        Verification.handle_info(
          {:email_verify_batch,
           %{uuid: batch.uuid, state: "running", processed: 1, total: 2, counts: %{}}},
          socket
        )

      assert socket.assigns.batch.processed == 2
    end

    test "late active snapshots cannot reopen a finished or cancelled batch", %{
      socket: socket,
      batch: batch
    } do
      for state <- ~w(done cancelled) do
        terminal = %{batch | state: state, finished_at: DateTime.utc_now()}
        Fake.put(:batch, terminal)

        {:noreply, finished} =
          Verification.handle_info({:email_verify_batch, terminal}, socket)

        for processed <- [batch.processed, batch.processed + 1] do
          late = %{batch | processed: processed}

          assert {:noreply, ^finished} =
                   Verification.handle_info({:email_verify_batch, late}, finished)
        end
      end
    end

    test "the end of the batch re-reads the batch and the table", %{socket: socket, batch: batch} do
      Fake.put(:results, %{
        "a@example.com" => result("valid"),
        "b@example.com" => result("invalid")
      })

      done = %{batch | state: "done", processed: 2, finished_at: DateTime.utc_now()}
      Fake.put(:batch, done)

      {:noreply, socket} =
        Verification.handle_info(
          {:email_verify_batch,
           %{uuid: batch.uuid, state: "done", processed: 2, total: 2, counts: %{}}},
          socket
        )

      assert socket.assigns.batch.state == "done"
      assert socket.assigns.summary == %{valid: 1, invalid: 1, temp: 0, not_sure: 0, unchecked: 0}
      assert Enum.map(socket.assigns.rows, & &1.status) == [:valid, :invalid]
      assert render_page(socket) =~ "Last verification finished"
    end

    test "a message about another batch is ignored", %{socket: socket} do
      message =
        {:email_verify_batch,
         %{uuid: Ecto.UUID.generate(), state: "done", processed: 9, total: 9, counts: %{}}}

      assert {:noreply, ^socket} = Verification.handle_info(message, socket)
      assert {:noreply, ^socket} = Verification.handle_info(:something_else, socket)
    end

    test "subscribes to the batch before reading its state, so a finish in between is seen", %{
      batch: batch
    } do
      done = %{batch | state: "done", processed: 2, finished_at: DateTime.utc_now()}
      Fake.put(:batch, done)
      role = audience(["y@example.com"])

      socket =
        visit(%{"source" => "user_group", "roles" => [role.uuid]}, mounted(connected_socket()))

      # The setup's own visit left its messages in the mailbox; look at the last pair.
      messages = Process.info(self(), :messages) |> elem(1)

      subscribed =
        messages |> Enum.with_index() |> Enum.filter(&match?({{:subscribe_batch, _}, _}, &1))

      read = messages |> Enum.with_index() |> Enum.filter(&match?({{:get_batch, _}, _}, &1))

      assert {_, subscribe_at} = List.last(subscribed)
      assert {_, read_at} = List.last(read)
      assert subscribe_at < read_at
      assert socket.assigns.batch.state == "done"
      assert render_page(socket) =~ "Last verification finished"
    end

    test "a finished batch is shown but not followed" do
      # The describe's setup already followed a running batch; take that message out.
      assert_received {:subscribe_batch, _running}
      role = audience(["z@example.com"])

      Fake.put(:latest_batch, %{
        uuid: Ecto.UUID.generate(),
        state: "cancelled",
        processed: 1,
        total: 5,
        counts: %{},
        finished_at: nil
      })

      socket =
        visit(%{"source" => "user_group", "roles" => [role.uuid]}, mounted(connected_socket()))

      refute_received {:subscribe_batch, _}
      assert render_page(socket) =~ "cancelled after 1 of 5"
    end
  end

  defp start_button(html) do
    [tag] = Regex.run(~r{<button[^>]*id="verification-start"[^>]*>}, html)
    tag
  end

  describe "rendering" do
    test "the status filter and the audience selector are forms, and the rows are linked to the summary" do
      role = audience(["a@example.com"])
      html = visit(%{"source" => "user_group", "roles" => [role.uuid]}) |> render_page()

      assert html =~
               ~r{<form[^>]*id="verification-audience-form"[^>]*phx-change="select_audience"}

      assert html =~ ~r{<form[^>]*id="verification-status-filter"[^>]*phx-change="filter_status"}
      assert html =~ ~s(id="verification-summary-valid")
      assert html =~ ~s(id="verification-start")
    end

    test "the start button is enabled when no batch runs" do
      role = audience(["a@example.com"])
      html = visit(%{"source" => "user_group", "roles" => [role.uuid]}) |> render_page()
      refute start_button(html) =~ "disabled"
    end

    test "the start button is disabled while the latest batch is queued or running" do
      role = audience(["a@example.com"])

      for state <- ~w(queued running) do
        Fake.put(:latest_batch, %{
          uuid: Ecto.UUID.generate(),
          state: state,
          processed: 0,
          total: 1,
          counts: %{},
          finished_at: nil
        })

        html = visit(%{"source" => "user_group", "roles" => [role.uuid]}) |> render_page()
        assert start_button(html) =~ "disabled"
      end
    end

    test "the audience source radios are visible controls a keyboard can reach" do
      html = visit(%{"source" => "user_group"}) |> render_page()

      radios = Regex.scan(~r{<input[^>]*type="radio"[^>]*>}, html) |> List.flatten()
      assert length(radios) == 2

      for radio <- radios do
        refute radio =~ ~r{class="[^"]*\bhidden\b}
        assert radio =~ "btn"
        assert radio =~ "aria-label="
      end
    end

    test "the page is translated" do
      role = audience(["a@example.com"])
      original = Gettext.get_locale(PhoenixKit.Newsletters.Gettext)
      Gettext.put_locale(PhoenixKit.Newsletters.Gettext, "ru")
      on_exit(fn -> Gettext.put_locale(PhoenixKit.Newsletters.Gettext, original) end)

      html = visit(%{"source" => "user_group", "roles" => [role.uuid]}) |> render_page()
      assert html =~ "Проверить список"
      assert html =~ "Не проверен"
    end

    test "an empty page shows a hint and no table" do
      html = visit(%{"source" => "user_group"}) |> render_page()
      assert html =~ "No addresses to verify"
      refute html =~ "verification-table"
    end

    test "a filter that matches nothing says so and keeps the filter" do
      role = audience(["a@example.com"])

      html =
        visit(%{"source" => "user_group", "roles" => [role.uuid], "status" => "valid"})
        |> render_page()

      assert html =~ "No addresses with this status."
      assert html =~ "verification-status-filter"
    end

    test "page_params/4 takes explicit values, not the assigns" do
      assert Verification.page_params("user_group", "", [@role_uuid], "valid") ==
               %{
                 "source" => "user_group",
                 "list" => "",
                 "roles" => [@role_uuid],
                 "status" => "valid"
               }
    end

    test "pagination links keep the audience and the filter" do
      role = audience(for i <- 1..3, do: "p#{i}@example.com")
      socket = visit(%{"source" => "user_group", "roles" => [role.uuid], "status" => "unchecked"})
      socket = %{socket | assigns: %{socket.assigns | total_pages: 2}}

      html = render_page(socket)
      assert html =~ ~s(id="verification-pagination")
      assert html =~ "page=2"
      assert html =~ "status=unchecked"
      assert html =~ "Page 1 of 2"
    end
  end
end
