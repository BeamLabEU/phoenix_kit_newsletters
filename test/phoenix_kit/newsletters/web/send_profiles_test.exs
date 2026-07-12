defmodule PhoenixKit.Newsletters.Web.SendProfilesTest do
  @moduledoc """
  Unit tests for the Send Settings admin LiveViews (Stage D, D3):
  the send-profiles list (`SendProfiles`) and the new/edit form
  (`SendProfileEditor`). This package ships no Endpoint/Router, so
  there's no `Phoenix.LiveViewTest` harness available standalone — the
  callbacks are exercised directly against a hand-built socket instead,
  same as `PhoenixKit.Modules.Emails.Web.SettingsTest` (Stage B, B3).
  """

  use PhoenixKitNewsletters.DataCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Web.SendProfileEditor
  alias PhoenixKit.Newsletters.Web.SendProfiles

  defp bare_socket(extra_assigns \\ %{}) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}, flash: %{}}, extra_assigns),
      private: %{live_temp: %{}}
    }
  end

  defp add_integration(provider \\ "smtp", name \\ "test connection") do
    {:ok, %{uuid: uuid}} = Integrations.add_connection(provider, name)
    uuid
  end

  describe "SendProfiles.handle_params/3 — list" do
    test "loads all send profiles into assigns" do
      integration_uuid = add_integration()

      {:ok, profile} =
        Newsletters.create_send_profile(%{
          name: "Marketing",
          integration_uuid: integration_uuid,
          provider_kind: "smtp"
        })

      assert {:noreply, socket} = SendProfiles.handle_params(%{}, "/", bare_socket())

      uuids = Enum.map(socket.assigns.send_profiles, & &1.uuid)
      assert profile.uuid in uuids
    end
  end

  describe "SendProfiles.handle_event(\"make_default\", ...)" do
    test "makes the target profile the default and clears any previous default" do
      integration_uuid = add_integration()

      {:ok, first} =
        Newsletters.create_send_profile(%{
          name: "First",
          integration_uuid: integration_uuid,
          provider_kind: "smtp"
        })

      {:ok, second} =
        Newsletters.create_send_profile(%{
          name: "Second",
          integration_uuid: integration_uuid,
          provider_kind: "smtp"
        })

      {:ok, _} = Newsletters.set_default_send_profile(first)

      assert {:noreply, socket} =
               SendProfiles.handle_event(
                 "make_default",
                 %{"uuid" => second.uuid},
                 bare_socket()
               )

      updated =
        Enum.find(socket.assigns.send_profiles, &(&1.uuid == second.uuid))

      assert updated.is_default
      refute Newsletters.get_send_profile!(first.uuid).is_default
    end
  end

  describe "SendProfileEditor.handle_event(\"save\", ...) — create" do
    test "persists a new send profile, resolving provider_kind from the chosen integration" do
      integration_uuid = add_integration("brevo_api", "Primary Brevo")

      socket =
        bare_socket(%{
          send_profile: nil,
          connections_by_provider: %{
            "aws_ses" => [],
            "smtp" => [],
            "brevo_api" => Integrations.list_connections("brevo_api")
          }
        })

      params = %{
        "name" => "Marketing",
        "integration_uuid" => integration_uuid,
        "from_name" => "Acme News",
        "from_email" => "news@example.com",
        "rate_per_hour" => "100",
        "rate_per_day" => "1000",
        "pause_seconds" => "2",
        "advanced" => "",
        "enabled" => "true"
      }

      assert {:noreply, socket} =
               SendProfileEditor.handle_event("save", %{"send_profile" => params}, socket)

      assert socket.assigns.flash["info"] =~ "saved"

      [saved] = Newsletters.list_send_profiles()
      assert saved.name == "Marketing"
      assert saved.integration_uuid == integration_uuid
      assert saved.provider_kind == "brevo_api"
      assert saved.from_email == "news@example.com"
      assert saved.rate_per_hour == 100
      assert saved.advanced == %{}
    end

    test "re-renders the form with errors when required fields are missing" do
      socket =
        bare_socket(%{
          send_profile: nil,
          connections_by_provider: %{"aws_ses" => [], "smtp" => [], "brevo_api" => []}
        })

      assert {:noreply, socket} =
               SendProfileEditor.handle_event("save", %{"send_profile" => %{}}, socket)

      refute socket.assigns.form.source.valid?
      assert Newsletters.list_send_profiles() == []
    end
  end
end
