defmodule PhoenixKit.Newsletters.Web.SendProfiles do
  @moduledoc """
  LiveView for managing newsletter send profiles ("Send Settings").
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKit.Newsletters.Gettext

  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.PkLink
  import PhoenixKitWeb.Components.Core.TableDefault

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    if Newsletters.enabled?() do
      socket =
        socket
        |> assign(:page_title, gettext("Send Settings"))
        |> assign(
          :page_subtitle,
          gettext("Manage send profiles used to deliver newsletter broadcasts")
        )
        |> assign(:project_title, Settings.get_project_title())
        |> assign(:send_profiles, [])
        |> assign(:show_confirm_modal, false)
        |> assign(:confirm_action, nil)
        |> assign(:confirm_target, nil)
        |> assign(:confirm_title, "")
        |> assign(:confirm_message, "")

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Newsletters module is not enabled"))
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, assign(socket, :send_profiles, Newsletters.list_send_profiles())}
  end

  @impl true
  def handle_event("make_default", %{"uuid" => uuid}, socket) do
    send_profile = Newsletters.get_send_profile!(uuid)

    case Newsletters.set_default_send_profile(send_profile) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Default send profile updated"))
         |> assign(:send_profiles, Newsletters.list_send_profiles())}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not set default send profile"))}
    end
  end

  @impl true
  def handle_event("show_confirm", %{"action" => "delete", "uuid" => uuid}, socket) do
    {:noreply,
     socket
     |> assign(:show_confirm_modal, true)
     |> assign(:confirm_action, :delete)
     |> assign(:confirm_target, uuid)
     |> assign(:confirm_title, gettext("Delete send profile"))
     |> assign(
       :confirm_message,
       gettext("This send profile will be permanently deleted.")
     )}
  end

  @impl true
  def handle_event("hide_confirm", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_confirm_modal, false)
     |> assign(:confirm_action, nil)
     |> assign(:confirm_target, nil)}
  end

  @impl true
  def handle_event("confirm_action", _params, socket) do
    socket = assign(socket, :show_confirm_modal, false)

    case socket.assigns.confirm_action do
      :delete ->
        handle_delete(socket, socket.assigns.confirm_target)

      _ ->
        {:noreply, socket}
    end
  end

  defp handle_delete(socket, uuid) do
    send_profile = Newsletters.get_send_profile!(uuid)

    case Newsletters.delete_send_profile(send_profile) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Send profile deleted"))
         |> assign(:send_profiles, Newsletters.list_send_profiles())}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Cannot delete send profile"))}
    end
  end
end
