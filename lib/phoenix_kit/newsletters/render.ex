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

  A usable layout's subject for the reader's language, when it places
  `{{subject}}`, is a pattern around the broadcast's subject; otherwise the
  broadcast's subject is sent unchanged. Line breaks never reach the header.

  ## Text

  The text part is the broadcast's own text with its variables filled in,
  never wrapped.
  """

  use Gettext, backend: PhoenixKit.Newsletters.Gettext

  alias PhoenixKit.Email.Content, as: EmailContent
  alias PhoenixKit.Email.Layout, as: CoreLayout
  alias PhoenixKit.Newsletters.Layout
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
    language = Layout.translation_key(html, locale)
    translation = if language, do: Map.fetch!(html, language)
    pattern = Map.get(patterns, language)

    rendered =
      if Layout.places_content?(translation) and
           Layout.subject_pattern?(pattern) do
        bound = variables |> stringify() |> Map.put("subject", subject)
        Substitution.substitute(pattern, bound)
      else
        subject
      end

    clean_subject(rendered)
  end

  def subject(subject, _layout, _locale, _variables), do: clean_subject(subject)

  defp clean_subject(subject), do: subject |> String.replace(~r/[\r\n]+/, " ") |> String.trim()

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
  `"newsletters"` group — `PhoenixKit.Email.Layout.render_parts/2`, so a
  layout places exactly what core's own layout would: `_header-newsletters`
  / `_header` / core's part (and the footer's), per locale and override
  root, with `Branding`'s logo and accent colour.
  """
  @spec chrome(String.t() | nil, keyword()) :: %{
          header: String.t(),
          footer: String.t(),
          variables: variables()
        }
  def chrome(subject, opts \\ []) do
    subject
    |> CoreLayout.render_parts(
      locale: Keyword.get(opts, :locale),
      group: @group,
      paths: paths(opts)
    )
    |> Map.take([:header, :footer, :variables])
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
  # recipient; remember only the latest version under one key per layout.
  # Track the resolved translation, so arbitrary recipient dialects that
  # fall back to the same HTML do not grow the cache or repeat the warning.
  defp warn_once_without_content(layout, locale) do
    key = {__MODULE__, :without_content, layout.uuid}
    version = {layout.updated_at, layout.html_body}
    language = Layout.translation_key(layout.html_body, locale)

    warned =
      case :persistent_term.get(key, nil) do
        {^version, languages} -> languages
        _ -> MapSet.new()
      end

    unless MapSet.member?(warned, language) do
      :persistent_term.put(key, {version, MapSet.put(warned, language)})

      Logger.warning(
        "Newsletters layout #{layout.name} (#{layout.uuid}) has no {{{content}}} " <>
          "for locale #{inspect(locale)}; sending with the standard layout instead"
      )
    end
  end

  defp paths(opts), do: Keyword.get(opts, :paths) || EmailContent.override_paths()

  defp stringify(variables), do: Map.new(variables, fn {k, v} -> {to_string(k), v} end)
end
