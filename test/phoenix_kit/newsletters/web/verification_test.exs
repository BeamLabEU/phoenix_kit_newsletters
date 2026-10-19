defmodule PhoenixKit.Newsletters.Web.VerificationTest do
  @moduledoc """
  The address-verification page, driven callback by callback on a hand-built
  socket (see `BroadcastsTest` for why), with the engine replaced by
  `FakeVerificationEngine` so the tests are about this page: what it resolves,
  what it asks the engine for, what it shows. The real engine is exercised
  by the `:requires_emails_verification` tests at the end.
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
    Application.put_env(:phoenix_kit_newsletters, @engine_key, Fake)
    on_exit(fn -> Application.delete_env(:phoenix_kit_newsletters, @engine_key) end)
    :ok
  end

  defp socket(extra \\ %{}) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}, flash: %{}, phoenix_kit_current_user: nil}, extra)
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

    test "the engine state is :unavailable when the Emails module is absent" do
      Application.put_env(:phoenix_kit_newsletters, @engine_key, PhoenixKit.Modules.Emails.Nope)
      assert mounted().assigns.engine == :unavailable
    end
  end

  describe "degraded states" do
    test "an alert explains that the Emails module is required" do
      Application.put_env(:phoenix_kit_newsletters, @engine_key, PhoenixKit.Modules.Emails.Nope)
      html = socket() |> mounted() |> then(&visit(%{}, &1)) |> render_page()

      assert html =~ ~s(id="verification-unavailable")
      assert html =~ "needs the Emails module"
      refute html =~ "verification-audience-form"
    end

    test "an alert says verification is switched off" do
      Fake.put(:enabled, false)
      html = mounted() |> then(&visit(%{}, &1)) |> render_page()

      assert html =~ ~s(id="verification-disabled")
      refute html =~ "verification-audience-form"
    end

    test "a warning says the host's Oban config lacks the queue" do
      Fake.put(:queue_configured, false)
      html = mounted() |> then(&visit(%{}, &1)) |> render_page()

      assert html =~ ~s(id="verification-queue-warning")
      assert html =~ "email_verification"
      assert html =~ "verification-audience-form"
    end

    test "no warning when the queue is configured" do
      refute mounted() |> then(&visit(%{}, &1)) |> render_page() =~ "verification-queue-warning"
    end

    test "an engine that is not there never gets asked for anything" do
      Application.put_env(:phoenix_kit_newsletters, @engine_key, PhoenixKit.Modules.Emails.Nope)
      socket = mounted() |> then(&visit(%{"source" => "user_group"}, &1))
      assert socket.assigns.emails == []
      refute_received {:results_for, _}
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
    test "asks the engine for the audience's addresses under a role-group source" do
      role = audience(["a@example.com", "b@example.com"])
      user = %User{uuid: Ecto.UUID.generate()}

      socket =
        visit(
          %{"source" => "user_group", "roles" => [role.uuid]},
          mounted(socket(%{phoenix_kit_current_user: user}))
        )

      {:noreply, socket} = Verification.handle_event("start_batch", %{}, socket)

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
      {:noreply, _} = Verification.handle_event("start_batch", %{}, socket)

      assert_received {:start_batch, [email], "newsletters_crm_list", ref, opts}
      assert email == contact.email
      assert ref == list.uuid
      assert opts[:title] == "Batch list"
    end

    test "subscribes to the new batch once the socket is connected" do
      role = audience(["a@example.com"])

      socket =
        visit(%{"source" => "user_group", "roles" => [role.uuid]}, mounted(connected_socket()))

      {:noreply, socket} = Verification.handle_event("start_batch", %{}, socket)

      assert_received {:subscribe_batch, uuid}
      assert uuid == socket.assigns.batch.uuid
    end

    test "reports an empty audience without calling the engine" do
      socket = visit(%{"source" => "user_group"})
      {:noreply, socket} = Verification.handle_event("start_batch", %{}, socket)

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
        {:noreply, socket} = Verification.handle_event("start_batch", %{}, socket)

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
      {:noreply, _socket} = Verification.handle_event("start_batch", %{}, socket)
      assert_received {:start_batch, ["a@example.com"], _, _, _}
    end

    test "does not start unless the engine is ready" do
      role = audience(["a@example.com"])
      socket = visit(%{"source" => "user_group", "roles" => [role.uuid]})
      assert_received {:latest_batch, _, _}

      for engine <- [:disabled, :unavailable] do
        socket = %{socket | assigns: %{socket.assigns | engine: engine}}
        {:noreply, socket} = Verification.handle_event("start_batch", %{}, socket)

        assert socket.assigns.flash["error"]
        refute_received {:start_batch, _, _, _, _}
        refute_received {:latest_batch, _, _}
      end
    end

    test "says the verification failed to start when the engine raised" do
      role = audience(["a@example.com"])
      socket = visit(%{"source" => "user_group", "roles" => [role.uuid]})

      Fake.put(:start_batch, {:error, {:engine_error, "boom"}})
      {:noreply, socket} = Verification.handle_event("start_batch", %{}, socket)

      assert socket.assigns.flash["error"] =~ "failed to start"
      refute socket.assigns.flash["error"] =~ "not available"
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
        {:noreply, socket} = Verification.handle_event("start_batch", %{}, socket)
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

  describe "against the real engine" do
    @describetag :requires_emails_verification

    # Not an alias: see EmailVerificationTest.
    defp engine, do: Module.concat(["PhoenixKit.Modules.Emails.Verification"])

    setup do
      Application.delete_env(:phoenix_kit_newsletters, @engine_key)
      :ok
    end

    test "shows the stored verdicts, with the domain-ok badge for an unprobed mailbox" do
      role = audience(["real-ok@example.com", "real-bad@example.zzzz", "real-new@example.com"])
      {:ok, _} = engine().verify("real-ok@example.com")
      {:ok, _} = engine().verify("real-bad@example.zzzz")

      socket = visit(%{"source" => "user_group", "roles" => [role.uuid]})

      assert Map.new(socket.assigns.rows, &{&1.email, &1.status}) == %{
               "real-ok@example.com" => :not_sure,
               "real-bad@example.zzzz" => :invalid,
               "real-new@example.com" => :unchecked
             }

      assert socket.assigns.summary == %{valid: 0, invalid: 1, temp: 0, not_sure: 1, unchecked: 1}
      html = render_page(socket)
      assert html =~ "Domain OK (no SMTP)"
      assert html =~ "Unknown top-level domain"
    end

    test "a filtered view works on the real statuses and still shows the full verdict" do
      role = audience(["real-ok@example.com", "real-bad@example.zzzz"])
      {:ok, _} = engine().verify("real-ok@example.com")
      {:ok, _} = engine().verify("real-bad@example.zzzz")

      socket =
        visit(%{"source" => "user_group", "roles" => [role.uuid], "status" => "invalid"})

      assert [%{email: "real-bad@example.zzzz", status: :invalid, result: result}] =
               socket.assigns.rows

      assert result.reason == "bad_tld"
      assert Map.has_key?(result, :log)
    end

    test "runs a batch end to end and follows it to the end" do
      start_supervised!({Oban, repo: Repo, testing: :manual, queues: [], plugins: false})
      role = audience(["e2e-1@example.com", "e2e-2@example.com", "e2e-3@nomx-domain.example"])

      socket =
        visit(%{"source" => "user_group", "roles" => [role.uuid]}, mounted(connected_socket()))

      {:noreply, socket} = Verification.handle_event("start_batch", %{}, socket)
      batch = socket.assigns.batch
      assert batch.total == 3

      assert %{success: 4, failure: 0} =
               Oban.drain_queue(queue: :email_verification, with_recursion: true)

      final = engine().get_batch(batch.uuid)
      assert final.state == "done"
      assert final.processed == 3

      # The last PubSub message is the "done" one; feed it to the page.
      assert_receive {:email_verify_batch, %{uuid: uuid, state: "done"} = snapshot}, 1_000
      assert uuid == batch.uuid
      {:noreply, socket} = Verification.handle_info({:email_verify_batch, snapshot}, socket)

      assert socket.assigns.batch.state == "done"
      assert socket.assigns.summary == %{valid: 0, invalid: 1, temp: 0, not_sure: 2, unchecked: 0}
      assert render_page(socket) =~ "Last verification finished"
    end
  end
end
