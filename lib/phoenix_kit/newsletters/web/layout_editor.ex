defmodule PhoenixKit.Newsletters.Web.LayoutEditor do
  @moduledoc """
  LiveView for creating and editing a broadcast layout: one tab per site
  language for the display name, subject pattern, HTML and text, and a
  preview of the HTML in the selected language through the same
  `PhoenixKit.Newsletters.Render` a send uses.

  A tab reads and writes, for each field, the key the layout already stores
  its language under (`Layout.language_tabs/2`): a site language `en-US` over
  a layout that stores `en` is one tab, and a save writes `en` back rather
  than adding an `en-US` key beside it. The subject is stored under the key of
  the tab's HTML, because that is where a send reads it. A save puts a
  dialect key beside a base key only when the site has two languages with the
  same base over one stored key (`en-GB` + `en-US`, or `en` + `en-US`, over a
  stored `en`): one tab keeps `en` (the exact spelling first, else the first in
  the site's order), the other starts its own key. A stored key no site
  language claims gets a tab of its own after the site's.
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
       |> assign(:edited_layout, nil)
       |> assign(:name, "")
       |> assign(:translations, Map.new(@fields, &{&1, %{}}))
       |> assign(:tabs, [])
       |> assign(:languages, [])
       |> assign(:editor_locale, nil)
       |> assign(:editor_keys, %{})
       |> assign(:editor_tab, nil)
       |> assign(:suggested_name, nil)
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
        translations =
          Map.new(@fields, &{&1, Map.get(layout, String.to_existing_atom(&1)) || %{}})

        {:noreply,
         socket
         |> assign(:page_title, gettext("Edit"))
         |> assign(:page_subtitle, layout.name)
         |> assign(:edited_layout, layout)
         |> assign(:name, layout.name)
         |> assign_tabs(
           Layout.language_tabs(LanguageOptions.site_languages(), translations),
           translations
         )
         |> assign_preview()}
    end
  end

  def handle_params(_params, _url, socket) do
    empty = Map.new(@fields, &{&1, %{}})

    [%{keys: %{"html_body" => key}} | _] =
      tabs = Layout.language_tabs(LanguageOptions.site_languages(), empty)

    {:noreply,
     socket
     |> assign_tabs(tabs, %{empty | "html_body" => %{key => starter_html()}})
     |> assign_preview()}
  end

  @impl true
  def handle_event("validate", params, socket) do
    socket = socket |> apply_params(params) |> refresh_errors()

    {:noreply, assign_preview(socket)}
  end

  def handle_event("switch_language", %{"language" => language}, socket) do
    if language in socket.assigns.languages do
      {:noreply, socket |> select_tab(language) |> assign_preview()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("use_suggested_name", _params, socket) do
    case socket.assigns.suggested_name do
      nil ->
        {:noreply, socket}

      name ->
        socket = socket |> assign(:name, name) |> assign(:suggested_name, nil)
        {:noreply, refresh_errors(socket)}
    end
  end

  def handle_event("save", params, socket) do
    socket = apply_params(socket, params)
    attrs = attrs(socket)

    result =
      case socket.assigns.edited_layout do
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

  # Once a save has put errors on the screen, they follow the form.
  defp refresh_errors(socket) do
    if socket.assigns.errors == [] do
      socket
    else
      changeset =
        Layouts.change_layout(socket.assigns.edited_layout || %Layout{}, attrs(socket))

      assign(socket, :errors, error_messages(changeset))
    end
  end

  # The form carries the name and the CURRENT tab's fields only; the other
  # tabs live in `translations` until save. `translations` is keyed, per
  # field, by the key a tab stores its language under, not by the tab's own
  # code. A field the tab has no key for is not rendered editable and writes
  # nothing.
  defp apply_params(socket, params) do
    keys = socket.assigns.editor_keys
    fields = params["fields"] || %{}

    translations =
      Enum.reduce(@fields, socket.assigns.translations, fn field, acc ->
        with key when is_binary(key) <- keys[field],
             {:ok, value} <- Map.fetch(fields, field) do
          Map.update!(acc, field, &Map.put(&1, key, value))
        else
          _ -> acc
        end
      end)

    socket
    |> assign(:name, params["name"] || socket.assigns.name)
    |> assign(:translations, translations)
    |> assign_suggested_name()
  end

  defp assign_tabs(socket, tabs, translations) do
    socket
    |> assign(:tabs, tabs)
    |> assign(:languages, Enum.map(tabs, & &1.language))
    |> assign(:translations, translations)
    |> select_tab(initial_language(tabs, translations))
  end

  defp select_tab(socket, language) do
    tab = Enum.find(socket.assigns.tabs, &(&1.language == language))

    socket
    |> assign(:editor_locale, language)
    |> assign(:editor_keys, tab.keys)
    |> assign(:editor_tab, tab)
  end

  # The site's default language when it has content, else the first tab that
  # does, else the first: never open an empty tab over a layout that has
  # something to show.
  defp initial_language(tabs, translations) do
    tab = Enum.find(tabs, &has_content?(translations, &1.keys)) || List.first(tabs)
    tab.language
  end

  defp has_content?(translations, keys) do
    Enum.any?(@fields, fn field ->
      case get_in(translations, [field, keys[field]]) do
        value when is_binary(value) -> String.trim(value) != ""
        _ -> false
      end
    end)
  end

  # With no name typed yet, a name made from the display name: this tab's if
  # it has one, else the first tab's that does.
  defp assign_suggested_name(socket) do
    suggestion =
      if String.trim(socket.assigns.name) == "" do
        display_names = socket.assigns.translations["display_name"]

        [socket.assigns.editor_keys | Enum.map(socket.assigns.tabs, & &1.keys)]
        |> Enum.find_value(&Layout.suggest_name(display_names[&1["display_name"]]))
      end

    assign(socket, :suggested_name, suggestion)
  end

  defp attrs(socket) do
    Map.merge(%{"name" => socket.assigns.name}, socket.assigns.translations)
  end

  defp assign_preview(socket) do
    locale = socket.assigns.editor_tab.locale
    keys = socket.assigns.editor_keys
    html = Map.get(socket.assigns.translations["html_body"], keys["html_body"])

    preview =
      if is_binary(html) and String.trim(html) != "" do
        subject =
          Render.subject(
            gettext("Sample subject"),
            %Layout{
              subject:
                language_map(socket.assigns.translations["subject"], keys["subject"], locale),
              html_body: %{locale => html}
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

  # The tab's value under the tab's own language, so the preview reads this
  # tab alone and never a fallback from another one.
  defp language_map(map, key, language) do
    case Map.get(map, key) do
      value when is_binary(value) -> %{language => value}
      _ -> %{}
    end
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
