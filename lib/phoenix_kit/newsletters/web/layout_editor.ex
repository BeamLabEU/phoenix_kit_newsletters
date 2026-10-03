defmodule PhoenixKit.Newsletters.Web.LayoutEditor do
  @moduledoc """
  LiveView for creating and editing a broadcast layout: one tab per
  language for the display name, subject pattern, HTML and text, and a
  preview of the HTML in the selected language through the same
  `PhoenixKit.Newsletters.Render` a send uses.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKit.Newsletters.Gettext

  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.PkLink

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Layout
  alias PhoenixKit.Newsletters.Layouts
  alias PhoenixKit.Newsletters.Paths
  alias PhoenixKit.Newsletters.Render
  alias PhoenixKit.Newsletters.Web.LanguageOptions
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @fields ~w(display_name subject html_body text_body)

  @impl true
  def mount(_params, _session, socket) do
    if Newsletters.enabled?() do
      {:ok,
       socket
       |> assign(:page_title, gettext("New layout"))
       |> assign(:page_subtitle, nil)
       |> assign(:page_section, gettext("Layouts"))
       |> assign(:page_section_path, Paths.layouts_index())
       |> assign(:project_title, Settings.get_project_title())
       |> assign_new(:current_locale, fn -> nil end)
       |> assign_new(:phoenix_kit_current_user, fn -> nil end)
       |> assign(:layout, nil)
       |> assign(:name, "")
       |> assign(:translations, Map.new(@fields, &{&1, %{}}))
       |> assign(:languages, [])
       |> assign(:editor_locale, nil)
       |> assign(:errors, [])
       |> assign(:preview_html, "")}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Newsletters module is not enabled"))
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    case Layouts.get_layout(id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Layout not found"))
         |> push_navigate(to: Paths.layouts_index())}

      layout ->
        languages = LanguageOptions.with_languages(all_languages(layout))

        {:noreply,
         socket
         |> assign(:page_title, gettext("Edit"))
         |> assign(:page_subtitle, layout.name)
         |> assign(:layout, layout)
         |> assign(:name, layout.name)
         |> assign(
           :translations,
           Map.new(@fields, &{&1, Map.get(layout, String.to_existing_atom(&1)) || %{}})
         )
         |> assign(:languages, languages)
         |> assign(:editor_locale, List.first(languages))
         |> assign_preview()}
    end
  end

  def handle_params(_params, _url, socket) do
    languages = LanguageOptions.site_languages()
    first = List.first(languages)

    {:noreply,
     socket
     |> assign(:languages, languages)
     |> assign(:editor_locale, first)
     |> assign(:translations, %{
       "display_name" => %{},
       "subject" => %{},
       "html_body" => %{first => starter_html()},
       "text_body" => %{}
     })
     |> assign_preview()}
  end

  @impl true
  def handle_event("validate", params, socket) do
    {:noreply, socket |> apply_params(params) |> assign_preview()}
  end

  def handle_event("switch_language", %{"language" => language}, socket) do
    if language in socket.assigns.languages do
      {:noreply, socket |> assign(:editor_locale, language) |> assign_preview()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save", params, socket) do
    socket = apply_params(socket, params)
    attrs = attrs(socket)

    result =
      case socket.assigns.layout do
        nil ->
          Layouts.create_layout(attrs, created_by_user_uuid: current_user_uuid(socket))

        layout ->
          Layouts.update_layout(layout, attrs)
      end

    case result do
      {:ok, _layout} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Layout saved"))
         |> push_navigate(to: Paths.layouts_index())}

      {:error, changeset} ->
        {:noreply, assign(socket, :errors, error_messages(changeset))}
    end
  end

  # ── internals ──────────────────────────────────────────────────────────

  # The form carries the name and the CURRENT language's fields only; the
  # other languages live in `translations` until save.
  defp apply_params(socket, params) do
    locale = socket.assigns.editor_locale
    fields = params["fields"] || %{}

    translations =
      Enum.reduce(@fields, socket.assigns.translations, fn field, acc ->
        case Map.fetch(fields, field) do
          {:ok, value} -> Map.update!(acc, field, &Map.put(&1, locale, value))
          :error -> acc
        end
      end)

    socket
    |> assign(:name, params["name"] || socket.assigns.name)
    |> assign(:translations, translations)
  end

  defp attrs(socket) do
    Map.merge(%{"name" => socket.assigns.name}, socket.assigns.translations)
  end

  defp assign_preview(socket) do
    locale = socket.assigns.editor_locale
    html = Map.get(socket.assigns.translations["html_body"], locale)

    preview =
      if is_binary(html) and String.trim(html) != "" do
        subject =
          Render.subject(
            gettext("Sample subject"),
            %Layout{
              subject: socket.assigns.translations["subject"],
              html_body: socket.assigns.translations["html_body"]
            },
            locale
          )

        # The preview shows this language's own HTML, not a fallback: an
        # empty tab previews as empty.
        Render.html(sample_body(), html, %{}, locale: locale, subject: subject)
      else
        ""
      end

    assign(socket, :preview_html, preview)
  end

  defp sample_body do
    "<h1>" <>
      gettext("Sample broadcast") <>
      "</h1><p>" <>
      gettext("This is where the broadcast's own text goes.") <> "</p>"
  end

  defp all_languages(layout) do
    @fields
    |> Enum.flat_map(fn field ->
      Map.keys(Map.get(layout, String.to_existing_atom(field)) || %{})
    end)
    |> Enum.uniq()
  end

  defp current_user_uuid(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} -> uuid
      _ -> nil
    end
  end

  defp error_messages(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&translate_error/1)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, &"#{field_label(field)}: #{&1}")
    end)
  end

  # Layout's messages are this package's msgids (`gettext_noop`); Ecto's own
  # ("can't be blank", …) are not in the catalogue and come back as written.
  defp translate_error({message, opts}) do
    bindings = for {key, value} <- opts, scalar?(value), into: %{}, do: {key, value}
    Gettext.dgettext(PhoenixKit.Newsletters.Gettext, "default", message, bindings)
  end

  defp scalar?(value), do: is_binary(value) or is_number(value) or is_atom(value)

  defp field_label(:name), do: gettext("Name")
  defp field_label(:display_name), do: gettext("Display name")
  defp field_label(:subject), do: gettext("Subject")
  defp field_label(:html_body), do: gettext("HTML")
  defp field_label(:text_body), do: gettext("Text")
  defp field_label(other), do: to_string(other)

  @doc false
  # What a new layout starts with: core's header and footer around the
  # broadcast, in a card with the site's accent colour on top.
  def starter_html do
    """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>{{subject}}</title>
    </head>
    <body style="margin:0;padding:0;background-color:#f4f4f5;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#f4f4f5;">
    <tr><td align="center" style="padding:24px 12px;">
    <table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="width:100%;max-width:600px;background-color:#ffffff;border-top:3px solid {{accent_color}};">
    <tr><td style="padding:20px 32px;font-family:Helvetica,Arial,sans-serif;font-size:18px;font-weight:bold;">{{{header}}}</td></tr>
    <tr><td style="padding:24px 32px;font-family:Helvetica,Arial,sans-serif;font-size:15px;line-height:1.6;">{{{content}}}</td></tr>
    <tr><td style="padding:16px 32px;font-family:Helvetica,Arial,sans-serif;font-size:12px;color:#71717a;">{{{footer}}}<br><a href="{{unsubscribe_url}}" style="color:#71717a;">Unsubscribe</a></td></tr>
    </table>
    </td></tr>
    </table>
    </body>
    </html>
    """
  end
end
