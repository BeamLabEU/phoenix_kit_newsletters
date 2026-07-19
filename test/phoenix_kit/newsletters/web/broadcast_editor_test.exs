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
      __changed__: %{}
    }

    %Phoenix.LiveView.Socket{assigns: Map.merge(base, assigns)}
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
end
