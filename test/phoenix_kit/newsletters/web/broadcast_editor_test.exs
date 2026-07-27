defmodule PhoenixKit.Newsletters.Web.BroadcastEditorTest do
  @moduledoc """
  Direct callback-invocation unit tests for `BroadcastEditor` — no
  connected LiveView process needed (this package ships no real
  `PhoenixKitWeb.Endpoint`, so `Phoenix.LiveViewTest.live/2` isn't
  available here; see `config/test.exs`'s `:endpoint` comment). Uses
  `DataCase` because `handle_event("validate", ...)` always recomputes
  the CRM preflight (a real query) whenever `crm_list_uuid` is non-empty.
  """

  use PhoenixKitNewsletters.DataCase, async: false

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Web.BroadcastEditor
  alias PhoenixKitCRM.Lists

  defp socket(assigns) do
    base = %{
      subject: "",
      source_type: "crm_list",
      crm_list_uuid: "",
      crm_lists: [],
      stranded_crm_list: nil,
      template_uuid: "",
      scheduled_at: "",
      markdown_content: "",
      templates: [],
      preflight: nil,
      crm_list_archived?: false,
      broadcast: nil,
      saving: false,
      attachments: [],
      tz_offset: "0",
      tz_label: "UTC+0",
      flash: %{},
      __changed__: %{}
    }

    %Phoenix.LiveView.Socket{assigns: Map.merge(base, assigns)}
  end

  test "switching from crm_list to user_group clears the stale crm_list_uuid" do
    socket = socket(%{source_type: "crm_list", crm_list_uuid: "some-crm-list-uuid"})

    {:noreply, updated} =
      BroadcastEditor.handle_event("validate", %{"source_type" => "user_group"}, socket)

    assert updated.assigns.source_type == "user_group"
    assert updated.assigns.crm_list_uuid == ""
  end

  test "picking a value without changing source_type doesn't clear anything" do
    socket = socket(%{source_type: "crm_list", crm_list_uuid: ""})
    picked_uuid = Ecto.UUID.generate()

    {:noreply, updated} =
      BroadcastEditor.handle_event(
        "validate",
        %{"source_type" => "crm_list", "crm_list_uuid" => picked_uuid},
        socket
      )

    assert updated.assigns.crm_list_uuid == picked_uuid
  end

  describe "handle_event(\"schedule\", ...) — local time is interpreted in the viewer's timezone" do
    # Reaches save_broadcast/3 (a real Broadcast INSERT) — needs core V158's
    # attachments column; see test_helper.exs's :requires_v158 exclusion.
    @tag :requires_v158
    test "positive offset (UTC+3): local evening converts to UTC same day" do
      socket =
        socket(%{
          subject: "Hello",
          crm_list_uuid: Ecto.UUID.generate(),
          scheduled_at: "2026-07-20T21:58",
          tz_offset: "3"
        })

      {:noreply, updated} = BroadcastEditor.handle_event("schedule", %{}, socket)

      assert updated.assigns.broadcast.status == "scheduled"
      assert updated.assigns.broadcast.scheduled_at == ~U[2026-07-20 18:58:00Z]
    end

    @tag :requires_v158
    test "negative offset (UTC-5): local late night rolls over to the next UTC day" do
      socket =
        socket(%{
          subject: "Hello",
          crm_list_uuid: Ecto.UUID.generate(),
          scheduled_at: "2026-07-20T23:30",
          tz_offset: "-5"
        })

      {:noreply, updated} = BroadcastEditor.handle_event("schedule", %{}, socket)

      assert updated.assigns.broadcast.status == "scheduled"
      assert updated.assigns.broadcast.scheduled_at == ~U[2026-07-21 04:30:00Z]
    end

    @tag :requires_v158
    test "positive offset near midnight rolls back to the previous UTC day" do
      socket =
        socket(%{
          subject: "Hello",
          crm_list_uuid: Ecto.UUID.generate(),
          scheduled_at: "2026-07-20T00:30",
          tz_offset: "3"
        })

      {:noreply, updated} = BroadcastEditor.handle_event("schedule", %{}, socket)

      assert updated.assigns.broadcast.status == "scheduled"
      assert updated.assigns.broadcast.scheduled_at == ~U[2026-07-19 21:30:00Z]
    end

    @tag :requires_v158
    test "zero offset (no personal/system timezone configured) preserves the old UTC-as-typed behavior" do
      socket =
        socket(%{
          subject: "Hello",
          crm_list_uuid: Ecto.UUID.generate(),
          scheduled_at: "2026-07-20T21:58",
          tz_offset: "0"
        })

      {:noreply, updated} = BroadcastEditor.handle_event("schedule", %{}, socket)

      assert updated.assigns.broadcast.status == "scheduled"
      assert updated.assigns.broadcast.scheduled_at == ~U[2026-07-20 21:58:00Z]
    end

    test "an unparseable schedule value flashes an error instead of saving" do
      socket =
        socket(%{
          subject: "Hello",
          crm_list_uuid: Ecto.UUID.generate(),
          scheduled_at: "not-a-date",
          tz_offset: "3"
        })

      {:noreply, updated} = BroadcastEditor.handle_event("schedule", %{}, socket)

      assert updated.assigns.broadcast == nil
      assert Phoenix.Flash.get(updated.assigns.flash, :error) =~ "valid schedule"
    end
  end

  describe "handle_params(:edit) — restores the schedule field in the viewer's local time" do
    @tag :requires_v158
    test "a UTC scheduled_at is displayed shifted into the viewer's timezone" do
      {:ok, broadcast} =
        Newsletters.create_broadcast(%{
          subject: "Hello",
          source_type: "crm_list",
          crm_list_uuid: Ecto.UUID.generate(),
          status: "scheduled",
          scheduled_at: ~U[2026-07-20 18:58:00Z]
        })

      socket =
        %Phoenix.LiveView.Socket{
          assigns: %{
            phoenix_kit_current_user: %{user_timezone: "3"},
            crm_lists: [],
            templates: [],
            page_title: "",
            __changed__: %{}
          }
        }

      {:noreply, updated} =
        BroadcastEditor.handle_params(
          %{"id" => broadcast.uuid},
          "/admin/newsletters/broadcasts/#{broadcast.uuid}/edit",
          %{socket | assigns: Map.put(socket.assigns, :live_action, :edit)}
        )

      assert updated.assigns.scheduled_at == "2026-07-20T21:58"
    end
  end

  describe "attachments — a uuid that no longer resolves to a file" do
    # Storage.get_files/1 silently drops any uuid with no matching row —
    # load_attachment_files/1 must NOT let that silently shrink the chip
    # list (a deleted-from-Storage file becoming invisible, with no way to
    # specifically remove it): the missing uuid still appears, paired with
    # `nil` instead of a file.
    @tag :requires_v158
    test "shows up as a {uuid, nil} pair, not silently dropped" do
      missing_uuid = Ecto.UUID.generate()

      {:ok, broadcast} =
        Newsletters.create_broadcast(%{
          subject: "Hello",
          source_type: "crm_list",
          crm_list_uuid: Ecto.UUID.generate(),
          attachments: [missing_uuid]
        })

      socket =
        %Phoenix.LiveView.Socket{
          assigns: %{
            phoenix_kit_current_user: nil,
            crm_lists: [],
            templates: [],
            page_title: "",
            __changed__: %{}
          }
        }

      {:noreply, updated} =
        BroadcastEditor.handle_params(
          %{"id" => broadcast.uuid},
          "/admin/newsletters/broadcasts/#{broadcast.uuid}/edit",
          %{socket | assigns: Map.put(socket.assigns, :live_action, :edit)}
        )

      assert updated.assigns.attachments == [missing_uuid]
      assert updated.assigns.attachment_files == [{missing_uuid, nil}]
    end
  end

  describe "schedule_preview/3" do
    test "shows the local time typed, its label, and the resolved UTC time" do
      preview = BroadcastEditor.schedule_preview("2026-07-20T21:58", "3", "UTC+3")

      assert preview == "Sends at 21:58 (UTC+3) · 18:58 UTC"
    end

    test "reflects a negative offset, including the day rollover in the UTC time" do
      preview = BroadcastEditor.schedule_preview("2026-07-20T23:30", "-5", "UTC-5")

      assert preview == "Sends at 23:30 (UTC-5) · 04:30 UTC"
    end

    test "is nil for an empty value" do
      assert BroadcastEditor.schedule_preview("", "3", "UTC+3") == nil
    end

    test "is nil for an unparseable value" do
      assert BroadcastEditor.schedule_preview("not-a-date", "3", "UTC+3") == nil
    end
  end

  describe "handle_params(:new) — resolves the viewer's timezone from the current user" do
    test "tz_offset/tz_label come from phoenix_kit_current_user.user_timezone" do
      socket =
        %Phoenix.LiveView.Socket{
          assigns: %{
            phoenix_kit_current_user: %{user_timezone: "5"},
            crm_lists: [],
            templates: [],
            template_uuid: "",
            page_title: "",
            live_action: :new,
            __changed__: %{}
          }
        }

      {:noreply, updated} =
        BroadcastEditor.handle_params(%{}, "/admin/newsletters/broadcasts/new", socket)

      assert updated.assigns.tz_offset == "5"
      assert updated.assigns.tz_label =~ "UTC+5"
    end
  end

  describe "submit routing — submitter buttons carry the full form" do
    # The regression this pins: Send now / Schedule used to be phx-click
    # buttons whose events carry NO form data, so the params-authoritative
    # role_uuids resolution wiped the selected roles to [] and every
    # user_group send failed changeset validation. As submit buttons the
    # full serialized form (role checkboxes included) reaches the handler.
    @tag :requires_v158
    test "submit with action=save_draft keeps role_uuids from the form params" do
      role_uuid = Ecto.UUID.generate()

      socket =
        socket(%{
          source_type: "user_group",
          role_uuids: [],
          subject: "wipe check",
          markdown_content: "hi",
          saving: false,
          broadcast: nil,
          tz_offset: "0",
          available_roles: []
        })

      params = %{
        "action" => "save_draft",
        "subject" => "wipe check",
        "source_type" => "user_group",
        "role_uuids" => [role_uuid]
      }

      {:noreply, updated} = BroadcastEditor.handle_event("submit", params, socket)

      # save_broadcast runs and fails downstream (no template etc.) or
      # succeeds — either way the assigns must carry the submitted roles,
      # not a wiped [].
      assert updated.assigns.role_uuids == [role_uuid]
    end

    test "submit with an unknown/missing action falls back to save_draft" do
      socket =
        socket(%{
          source_type: "crm_list",
          crm_list_uuid: "",
          role_uuids: [],
          subject: "",
          markdown_content: "",
          saving: false,
          broadcast: nil,
          tz_offset: "0",
          available_roles: []
        })

      assert {:noreply, _} = BroadcastEditor.handle_event("submit", %{}, socket)
    end
  end

  describe "stranded CRM selection — a pick that fell out of the picker's options" do
    test "a selection missing from the options is kept as the stranded list" do
      {:ok, ops} =
        Lists.create_list(%{
          name: "Suppliers #{System.unique_integer([:positive])}",
          subscribable: false
        })

      # @crm_lists holds only subscribable lists, so this selection is absent
      # from the options — it must survive as the disabled <option selected>,
      # or the next save silently resets crm_list_uuid to "".
      socket = socket(%{source_type: "crm_list", crm_lists: []})

      {:noreply, updated} =
        BroadcastEditor.handle_event(
          "validate",
          %{"source_type" => "crm_list", "crm_list_uuid" => ops.uuid},
          socket
        )

      assert updated.assigns.stranded_crm_list.uuid == ops.uuid
      refute updated.assigns.crm_list_archived?
    end

    test "a selection present in the options is not stranded" do
      {:ok, sub} =
        Lists.create_list(%{
          name: "Mailing #{System.unique_integer([:positive])}",
          subscribable: true
        })

      socket = socket(%{source_type: "crm_list", crm_lists: [sub]})

      {:noreply, updated} =
        BroadcastEditor.handle_event(
          "validate",
          %{"source_type" => "crm_list", "crm_list_uuid" => sub.uuid},
          socket
        )

      assert updated.assigns.stranded_crm_list == nil
    end

    test "an archived selection is both stranded and flagged archived" do
      {:ok, list} =
        Lists.create_list(%{
          name: "Old campaign #{System.unique_integer([:positive])}",
          subscribable: true
        })

      {:ok, archived} = Lists.archive_list(list)

      socket = socket(%{source_type: "crm_list", crm_lists: []})

      {:noreply, updated} =
        BroadcastEditor.handle_event(
          "validate",
          %{"source_type" => "crm_list", "crm_list_uuid" => archived.uuid},
          socket
        )

      assert updated.assigns.stranded_crm_list.uuid == archived.uuid
      assert updated.assigns.crm_list_archived?
    end

    test "a uuid that resolves to nothing strands nothing and is not archived" do
      socket = socket(%{source_type: "crm_list", crm_lists: []})

      {:noreply, updated} =
        BroadcastEditor.handle_event(
          "validate",
          %{"source_type" => "crm_list", "crm_list_uuid" => Ecto.UUID.generate()},
          socket
        )

      assert updated.assigns.stranded_crm_list == nil
      refute updated.assigns.crm_list_archived?
    end
  end
end
