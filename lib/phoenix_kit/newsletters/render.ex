defmodule PhoenixKit.Newsletters.Render do
  @moduledoc """
  Builds the subject, HTML and text of one broadcast email for one reader.

  ## HTML

  With a layout (`PhoenixKit.Newsletters.Layout`), the layout's HTML in the
  reader's language (`Layout.translation/3`) is the document:

    1. the broadcast body goes where the layout places `{{{content}}}` —
       or the older `{{content}}`, which layouts carried over from the
       email-templates table use;
    2. then **one** pass substitutes every other placeholder. `{{name}}`
       is HTML-escaped; `{{{name}}}` is inserted as it is
       (`PhoenixKit.Templates.Substitution`).

  Because the body is inserted before that pass, the body's own
  placeholders (`{{name}}`, `{{unsubscribe_url}}`) are filled by the same
  pass as the layout's — and a value is never scanned again, so a reader
  named `{{email}}` stays `{{email}}`.

  Besides the broadcast's own variables (`name`, `email`,
  `unsubscribe_url`, `preferences_url`), a layout can place the site's
  email chrome from core (`PhoenixKit.Email.Layout`, group `"newsletters"`):

  | placeholder | value |
  |---|---|
  | `{{{header}}}` | core's rendered header — `_header-newsletters`, `_header` or core's own |
  | `{{{footer}}}` | core's rendered footer, likewise |
  | `{{logo_url}}` | `PhoenixKit.Email.Branding` — `""` without a logo |
  | `{{accent_color}}` | `PhoenixKit.Email.Branding` — `#rrggbb` |
  | `{{site_name}}`, `{{site_url}}`, `{{subject}}` | as core's layout binds them |

  `header` and `footer` must be written with three braces: they are HTML.

  Without a layout — none chosen, the row is gone, it has no HTML at all,
  or the language it resolves to does not place the body — the body is
  wrapped in core's standard email layout for the `"newsletters"` group
  (`Layout.wrap/3`), so a host's `_layout-newsletters`/`_layout` file, or
  core's own card, frames it. A body that is already a whole document is
  sent as it is.

  ## Subject

  A layout's subject for the reader's language, when it places
  `{{subject}}`, is a pattern around the broadcast's subject; otherwise the
  broadcast's subject is sent unchanged. Line breaks never reach the header.

  ## Text

  The text part is the broadcast's own text with its variables filled in,
  never wrapped.
  """

  use Gettext, backend: PhoenixKit.Newsletters.Gettext

  alias PhoenixKit.Email.Branding
  alias PhoenixKit.Email.Content, as: EmailContent
  alias PhoenixKit.Email.Layout, as: CoreLayout
  alias PhoenixKit.Newsletters.Layout
  alias PhoenixKit.Settings
  alias PhoenixKit.Templates.Overrides
  alias PhoenixKit.Templates.Substitution
  alias PhoenixKit.Utils.Routes

  require Logger

  @group "newsletters"

  @content ~r/\{\{\{\s*content\s*\}\}\}|\{\{\s*content\s*\}\}/

  @typedoc "Variables keyed by placeholder name."
  @type variables :: %{String.t() => term()}

  @doc "The core email-layout group broadcasts are rendered in."
  @spec group() :: String.t()
  def group, do: @group

  @doc """
  The HTML of one email.

  `layout` is a `Layout`, a layout's HTML as a string, or `nil`.

  ## Options

    * `:locale` — the reader's language; picks the layout's translation
      and core's chrome.
    * `:subject` — the email's subject, for core's `{{subject}}`.
    * `:paths` — template override roots (default: core's).
    * `:layout_module` — the core layout module; a test seam.
  """
  @spec html(String.t(), Layout.t() | String.t() | nil, variables(), keyword()) :: String.t()
  def html(body_html, layout, variables, opts \\ []) when is_binary(body_html) do
    locale = Keyword.get(opts, :locale)

    case wrapper(layout, locale) do
      {:ok, wrapper} ->
        chrome = chrome(Keyword.get(opts, :subject), opts)

        bound =
          chrome.variables
          |> Map.merge(%{"header" => chrome.header, "footer" => chrome.footer})
          |> Map.merge(stringify(variables))

        wrapper
        |> insert_content(body_html)
        |> Substitution.substitute(bound, escape: true)

      :none ->
        body = Substitution.substitute(body_html, stringify(variables), escape: true)

        if CoreLayout.document?(body) do
          body
        else
          CoreLayout.wrap(body, Keyword.get(opts, :subject),
            locale: locale,
            group: @group,
            paths: paths(opts)
          )
        end
    end
  end

  @doc """
  The subject of one email: the layout's subject pattern around the
  broadcast's `subject`, when the layout has one that places `{{subject}}`
  in the language its HTML is picked in for `locale`; `subject` otherwise.
  Read in the HTML's language, not resolved on its own, so a reader never
  gets a subject in one language over a body in another.
  """
  @spec subject(String.t(), Layout.t() | nil, String.t() | nil, variables()) :: String.t()
  def subject(subject, layout, locale, variables \\ %{})

  def subject(subject, %Layout{subject: patterns, html_body: html}, locale, variables)
      when is_map(patterns) do
    language = Layout.translation_key(html, locale) || Layout.translation_key(patterns, locale)
    pattern = Map.get(patterns, language)

    if Layout.subject_pattern?(pattern) do
      bound = variables |> stringify() |> Map.put("subject", subject)

      pattern
      |> Substitution.substitute(bound)
      |> String.replace(~r/[\r\n]+/, " ")
      |> String.trim()
    else
      subject
    end
  end

  def subject(subject, _layout, _locale, _variables), do: subject

  @doc "The text part: the broadcast's own text with its variables filled in."
  @spec text(String.t() | nil, variables()) :: String.t()
  def text(nil, _variables), do: ""
  def text(text, variables), do: Substitution.substitute(text, stringify(variables))

  @doc """
  A sample broadcast for core's email preview (`email_templates/0`): what a
  broadcast without a layout of its own looks like in the standard layout.
  """
  @spec preview_defaults() :: %{subject: String.t(), html: String.t(), text: String.t()}
  def preview_defaults do
    %{
      subject: gettext("Our latest news"),
      html:
        "<h1>" <>
          gettext("Hello {{name}},") <>
          "</h1><p>" <>
          gettext("This is where the broadcast's own text goes.") <>
          ~s(</p><p><a href="{{unsubscribe_url}}">) <>
          gettext("Unsubscribe") <> "</a></p>",
      text:
        gettext("Hello {{name}},") <>
          "\n\n" <>
          gettext("This is where the broadcast's own text goes.") <> "\n\n{{unsubscribe_url}}"
    }
  end

  @doc "Sample variables for `preview_defaults/0`."
  @spec preview_variables() :: variables()
  def preview_variables do
    %{
      "name" => "Jane Doe",
      "email" => "jane.doe@example.com",
      "unsubscribe_url" => Routes.url("/newsletters/unsubscribe?token=sample")
    }
  end

  @doc """
  Core's header, footer and branding variables for one email, in the
  `"newsletters"` group.

  Uses `PhoenixKit.Email.Layout.render_parts/2` when core has it. Until
  then the parts are built here from the same public pieces core's layout
  uses — the override files `_header-newsletters` / `_header` (and the
  footer's), core's default parts, `Branding` — so a layout sees what
  core's own layout would place. That fallback is temporary and goes once
  the core floor includes `render_parts/2`.
  """
  @spec chrome(String.t() | nil, keyword()) :: %{
          header: String.t(),
          footer: String.t(),
          variables: variables()
        }
  def chrome(subject, opts \\ []) do
    layout_module = Keyword.get(opts, :layout_module, CoreLayout)
    core_opts = [locale: Keyword.get(opts, :locale), group: @group, paths: paths(opts)]

    if Code.ensure_loaded?(layout_module) and function_exported?(layout_module, :render_parts, 2) do
      subject |> layout_module.render_parts(core_opts) |> Map.take([:header, :footer, :variables])
    else
      local_chrome(subject, core_opts)
    end
  end

  # ── internals ──────────────────────────────────────────────────────────

  defp wrapper(nil, _locale), do: :none

  defp wrapper(%Layout{} = layout, locale) do
    case Layout.translation(layout.html_body, locale) do
      nil ->
        :none

      html ->
        if Layout.places_content?(html) do
          {:ok, html}
        else
          warn_once_without_content(layout, locale)
          :none
        end
    end
  end

  defp wrapper(html, _locale) when is_binary(html) do
    if Layout.places_content?(html), do: {:ok, html}, else: :none
  end

  # A function replacement, not a string one: a replacement string would
  # read `\1`-style sequences in the body as back-references.
  defp insert_content(wrapper, body), do: Regex.replace(@content, wrapper, fn _ -> body end)

  # Rendered once per recipient, so a broken layout would log once per
  # recipient; once per layout, version and locale for the life of the VM is
  # enough to be seen. Keyed on `updated_at`, so a fixed-then-broken-again
  # layout warns again.
  defp warn_once_without_content(layout, locale) do
    key = {__MODULE__, :without_content, layout.uuid, layout.updated_at, locale}

    unless :persistent_term.get(key, false) do
      :persistent_term.put(key, true)

      Logger.warning(
        "Newsletters layout #{layout.name} (#{layout.uuid}) has no {{{content}}} " <>
          "for locale #{inspect(locale)}; sending with the standard layout instead"
      )
    end
  end

  defp local_chrome(subject, opts) do
    locale = Keyword.fetch!(opts, :locale)
    paths = Keyword.fetch!(opts, :paths)
    site_url = Routes.base_url()

    variables =
      Map.merge(Branding.variables(), %{
        "subject" => subject || "",
        "site_name" => Settings.get_project_title(),
        "site_url" => site_url
      })

    logo? = present?(variables["logo_url"])

    header =
      part(
        CoreLayout.header_name(),
        CoreLayout.default_header_html(logo: logo?),
        variables,
        locale,
        paths
      )

    footer =
      part(
        CoreLayout.footer_name(),
        CoreLayout.default_footer_html(link: Regex.match?(~r{\Ahttps?://\S}i, site_url)),
        variables,
        locale,
        paths
      )

    %{header: header, footer: footer, variables: variables}
  end

  # The group's file, the shared file, core's default — the first with
  # something in it, as core's layout picks its own header and footer.
  defp part(base, default, variables, locale, paths) do
    template =
      Enum.find_value(["#{base}-#{@group}", base], &override(paths, &1, locale))

    Substitution.substitute(template || default, variables, escape: true)
  end

  # A host file with something in it; an empty one counts as missing.
  defp override(paths, name, locale) do
    case Overrides.locate(paths, name, :html, locale) do
      {_path, content} -> if present?(content), do: content
      nil -> nil
    end
  end

  defp paths(opts), do: Keyword.get(opts, :paths) || EmailContent.override_paths()

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp stringify(variables), do: Map.new(variables, fn {k, v} -> {to_string(k), v} end)
end
