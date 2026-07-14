defmodule PhoenixKit.Newsletters.Content do
  @moduledoc """
  Content rendering utilities for newsletters.

  Converts markdown to HTML and HTML to plain text for email delivery.
  """

  alias PhoenixKit.Utils.HtmlSanitizer

  # Mirrors PhoenixKitWeb.Components.Core.Markdown's GFM + smart-typography
  # options. Newsletter HTML goes out to every list member by email (not just
  # a trusted-admin preview), so the output is always run through
  # HtmlSanitizer below rather than relying on comrak's tagfilter.
  @mdex_options [
    extension: [strikethrough: true, table: true, autolink: true, tasklist: true],
    parse: [smart: true],
    render: [unsafe: true]
  ]

  @doc """
  Renders markdown to HTML. Returns the HTML string on both success and
  parse failure (falls back to escaped plain text on failure).
  """
  @spec render_markdown(String.t()) :: String.t()
  def render_markdown(markdown) do
    case MDEx.to_html(markdown || "", @mdex_options) do
      {:ok, html} -> HtmlSanitizer.sanitize(html)
      {:error, _reason} -> escape(markdown)
    end
  end

  @doc """
  Renders markdown to HTML, returning an ok/error tuple.

  Returns `{:ok, html}` on success or `{:error, reason}` when MDEx
  cannot produce valid output.
  """
  @spec render_markdown_strict(String.t()) :: {:ok, String.t()} | {:error, term()}
  def render_markdown_strict(markdown) do
    case MDEx.to_html(markdown || "", @mdex_options) do
      {:ok, html} -> {:ok, HtmlSanitizer.sanitize(html)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Converts HTML to plain text for the text/plain part of emails.

  Converts `<br>` tags to newlines, `</p>` to double newlines,
  and strips all remaining HTML tags.
  """
  @spec strip_html(String.t()) :: String.t()
  def strip_html(html) do
    html
    |> String.replace(~r/<br\s*\/?>/, "\n")
    |> String.replace(~r/<\/p>/, "\n\n")
    |> String.replace(~r/<[^>]+>/, "")
    |> String.trim()
  end

  defp escape(nil), do: ""

  defp escape(markdown) do
    markdown
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end
end
