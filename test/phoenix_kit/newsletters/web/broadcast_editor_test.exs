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

  defp socket(assigns) do
    base = %{
      subject: "",
      source_type: "newsletters_list",
      list_uuid: "",
      crm_list_uuid: "",
      template_uuid: "",
      scheduled_at: "",
      markdown_content: "",
      templates: [],
      preflight: nil,
      crm_list_archived?: false,
      broadcast: nil,
      saving: false,
      tz_offset: "0",
      tz_label: "UTC+0",
      flash: %{},
      __changed__: %{}
    }

    %Phoenix.LiveView.Socket{assigns: Map.merge(base, assigns)}
  end

  defp create_list do
    {:ok, list} =
      Newsletters.create_list(%{
        name: "Test list",
        slug: "test-list-#{System.unique_integer([:positive])}"
      })

    list
  end

  test "switching from newsletters_list to crm_list clears the stale list_uuid" do
    socket = socket(%{source_type: "newsletters_list", list_uuid: "some-newsletters-list-uuid"})

    {:noreply, updated} =
      BroadcastEditor.handle_event("validate", %{"source_type" => "crm_list"}, socket)

    assert updated.assigns.source_type == "crm_list"
    assert updated.assigns.list_uuid == ""
  end

  test "switching from crm_list to newsletters_list clears the stale crm_list_uuid" do
    socket = socket(%{source_type: "crm_list", crm_list_uuid: "some-crm-list-uuid"})

    {:noreply, updated} =
      BroadcastEditor.handle_event("validate", %{"source_type" => "newsletters_list"}, socket)

    assert updated.assigns.source_type == "newsletters_list"
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
    test "positive offset (UTC+3): local evening converts to UTC same day" do
      list = create_list()

      socket =
        socket(%{
          subject: "Hello",
          list_uuid: list.uuid,
          scheduled_at: "2026-07-20T21:58",
          tz_offset: "3"
        })

      {:noreply, updated} = BroadcastEditor.handle_event("schedule", %{}, socket)

      assert updated.assigns.broadcast.status == "scheduled"
      assert updated.assigns.broadcast.scheduled_at == ~U[2026-07-20 18:58:00Z]
    end

    test "negative offset (UTC-5): local late night rolls over to the next UTC day" do
      list = create_list()

      socket =
        socket(%{
          subject: "Hello",
          list_uuid: list.uuid,
          scheduled_at: "2026-07-20T23:30",
          tz_offset: "-5"
        })

      {:noreply, updated} = BroadcastEditor.handle_event("schedule", %{}, socket)

      assert updated.assigns.broadcast.status == "scheduled"
      assert updated.assigns.broadcast.scheduled_at == ~U[2026-07-21 04:30:00Z]
    end

    test "positive offset near midnight rolls back to the previous UTC day" do
      list = create_list()

      socket =
        socket(%{
          subject: "Hello",
          list_uuid: list.uuid,
          scheduled_at: "2026-07-20T00:30",
          tz_offset: "3"
        })

      {:noreply, updated} = BroadcastEditor.handle_event("schedule", %{}, socket)

      assert updated.assigns.broadcast.status == "scheduled"
      assert updated.assigns.broadcast.scheduled_at == ~U[2026-07-19 21:30:00Z]
    end

    test "zero offset (no personal/system timezone configured) preserves the old UTC-as-typed behavior" do
      list = create_list()

      socket =
        socket(%{
          subject: "Hello",
          list_uuid: list.uuid,
          scheduled_at: "2026-07-20T21:58",
          tz_offset: "0"
        })

      {:noreply, updated} = BroadcastEditor.handle_event("schedule", %{}, socket)

      assert updated.assigns.broadcast.status == "scheduled"
      assert updated.assigns.broadcast.scheduled_at == ~U[2026-07-20 21:58:00Z]
    end

    test "an unparseable schedule value flashes an error instead of saving" do
      list = create_list()

      socket =
        socket(%{
          subject: "Hello",
          list_uuid: list.uuid,
          scheduled_at: "not-a-date",
          tz_offset: "3"
        })

      {:noreply, updated} = BroadcastEditor.handle_event("schedule", %{}, socket)

      assert updated.assigns.broadcast == nil
      assert Phoenix.Flash.get(updated.assigns.flash, :error) =~ "valid schedule"
    end
  end

  describe "handle_params(:edit) — restores the schedule field in the viewer's local time" do
    test "a UTC scheduled_at is displayed shifted into the viewer's timezone" do
      list = create_list()

      {:ok, broadcast} =
        Newsletters.create_broadcast(%{
          subject: "Hello",
          list_uuid: list.uuid,
          status: "scheduled",
          scheduled_at: ~U[2026-07-20 18:58:00Z]
        })

      socket =
        %Phoenix.LiveView.Socket{
          assigns: %{
            tz_offset: "3",
            tz_label: "UTC+3",
            lists: [],
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

  describe "schedule_preview/3" do
    test "shows the local time typed, its label, and the resolved UTC time" do
      preview = BroadcastEditor.schedule_preview("2026-07-20T21:58", "+3", "UTC+3")

      assert preview == "Sends at 21:58 (UTC+3) · 18:58 UTC"
    end

    test "reflects a negative offset, including the day rollover in the UTC time" do
      preview = BroadcastEditor.schedule_preview("2026-07-20T23:30", "-5", "UTC-5")

      assert preview == "Sends at 23:30 (UTC-5) · 04:30 UTC"
    end

    test "is nil for an empty value" do
      assert BroadcastEditor.schedule_preview("", "+3", "UTC+3") == nil
    end

    test "is nil for an unparseable value" do
      assert BroadcastEditor.schedule_preview("not-a-date", "+3", "UTC+3") == nil
    end
  end
end
