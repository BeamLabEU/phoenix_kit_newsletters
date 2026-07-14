defmodule PhoenixKit.Newsletters.Web.SendProfileEditor do
  @moduledoc """
  LiveView for creating and editing newsletter send profiles ("Send Settings").
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKit.Newsletters.Gettext

  import PhoenixKitWeb.Components.Core.AdminPageHeader
  import PhoenixKitWeb.Components.Core.Checkbox
  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.Input
  import PhoenixKitWeb.Components.Core.PkLink
  import PhoenixKitWeb.Components.Core.Textarea

  alias PhoenixKit.Integrations
  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.ProviderOptions
  alias PhoenixKit.Newsletters.SendProfile
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    if Newsletters.enabled?() do
      socket =
        socket
        |> assign(:send_profile, nil)
        |> assign(:project_title, Settings.get_project_title())
        |> assign(:connections_by_provider, load_connections())

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Newsletters module is not enabled"))
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    send_profile = Newsletters.get_send_profile!(id)

    {:noreply,
     socket
     |> assign(:page_title, gettext("Edit send profile: %{name}", name: send_profile.name))
     |> assign(:send_profile, send_profile)
     |> assign_form(SendProfile.changeset(send_profile, %{}))}
  rescue
    Ecto.NoResultsError ->
      {:noreply,
       socket
       |> put_flash(:error, gettext("Send profile not found"))
       |> push_navigate(to: Routes.path("/admin/newsletters/send-settings"))}
  end

  def handle_params(_params, _url, socket) do
    {:noreply,
     socket
     |> assign(:page_title, gettext("New send profile"))
     |> assign(:send_profile, nil)
     |> assign_form(SendProfile.changeset(%SendProfile{}, %{}))}
  end

  @impl true
  def handle_event("validate", %{"send_profile" => params}, socket) do
    params = normalize_params(params, socket.assigns.connections_by_provider)
    target = socket.assigns.send_profile || %SendProfile{}
    changeset = SendProfile.changeset(target, params) |> Map.put(:action, :validate)
    {:noreply, assign_form(socket, changeset)}
  end

  @impl true
  def handle_event("save", %{"send_profile" => params}, socket) do
    params = normalize_params(params, socket.assigns.connections_by_provider)

    result =
      case socket.assigns.send_profile do
        nil -> Newsletters.create_send_profile(params)
        send_profile -> Newsletters.update_send_profile(send_profile, params)
      end

    case result do
      {:ok, _send_profile} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Send profile saved successfully"))
         |> push_navigate(to: Routes.path("/admin/newsletters/send-settings"))}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  # --- Private ---

  # Which per-provider fields to render follows the provider the changeset
  # resolved to, so the form can't offer a setting the chosen provider (and
  # therefore its Swoosh adapter) doesn't understand.
  defp assign_form(socket, changeset) do
    provider_kind = Ecto.Changeset.get_field(changeset, :provider_kind)

    socket
    |> assign(:form, to_form(changeset))
    |> assign(:provider_kind, provider_kind)
    |> assign(:provider_fields, ProviderOptions.fields_for(provider_kind))
    |> assign(:advanced, Ecto.Changeset.get_field(changeset, :advanced) || %{})
  end

  # Every email provider the Integrations registry knows about — not a
  # hardcoded three — so a newly registered sender shows up here on its own.
  defp load_connections do
    Map.new(SendProfile.valid_provider_kinds(), fn provider ->
      {provider, Integrations.list_connections(provider)}
    end)
  end

  defp normalize_params(params, connections_by_provider) do
    params
    |> resolve_provider_kind(connections_by_provider)
    # A provider with no settings of its own (SMTP) renders no inputs, so the
    # key is simply absent. Default it to empty rather than leaving it out:
    # that makes the schema re-cast `advanced` on every save, which is what
    # prunes a stale SES configuration set after a profile is repointed at
    # an SMTP connection.
    |> Map.put_new("advanced", %{})
  end

  # The form only exposes an integration picker (grouped by provider) —
  # provider_kind isn't a separate field the admin fills in. Derive it
  # server-side from which provider group the chosen connection belongs
  # to, so it can never drift from the integration it's paired with.
  defp resolve_provider_kind(%{"integration_uuid" => uuid} = params, connections_by_provider)
       when is_binary(uuid) and uuid != "" do
    case find_provider(uuid, connections_by_provider) do
      nil -> params
      provider -> Map.put(params, "provider_kind", provider)
    end
  end

  defp resolve_provider_kind(params, _connections_by_provider), do: params

  defp find_provider(uuid, connections_by_provider) do
    Enum.find_value(connections_by_provider, fn {provider, connections} ->
      if Enum.any?(connections, &(&1.uuid == uuid)), do: provider
    end)
  end

  # Human-readable optgroup label for the integration picker — sourced
  # from the provider registry so it stays in sync with whatever name
  # Integrations registers the provider under, rather than duplicating it.
  defp provider_label(provider_key) do
    case Enum.find(Integrations.list_providers(), &(&1.key == provider_key)) do
      %{name: name} -> name
      _ -> provider_key
    end
  end
end
