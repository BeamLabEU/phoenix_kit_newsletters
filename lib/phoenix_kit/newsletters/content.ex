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

  @html_tag ~r/<[^>]+>/
  @link ~r/<a\b[^>]*?\bhref="([^"]*)"[^>]*>(.*?)<\/a>/s
  @entity ~r/&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);/
  @named_entities %{
    "amp" => "&",
    "lt" => "<",
    "gt" => ">",
    "quot" => "\"",
    "apos" => "'",
    "nbsp" => " "
  }

  @doc """
  Renders markdown to HTML. Returns the HTML string on both success and
  parse failure (falls back to escaped plain text on failure).
  """
  @spec render_markdown(String.t()) :: String.t()
  def render_markdown(markdown) do
    case MDEx.to_html(markdown || "", @mdex_options) do
      {:ok, html} -> clean(html)
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
      {:ok, html} -> {:ok, clean(html)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp clean(html), do: html |> HtmlSanitizer.sanitize() |> restore_link_placeholders()

  @link_attribute ~r/\b(href|src)="([^"]*)"/
  @encoded_placeholder ~r/(?:%7B){2,3}(?:%20)*[a-zA-Z_][a-zA-Z0-9_]*(?:%20)*(?:%7D){2,3}/i

  # comrak percent-encodes a link's destination, so `[Unsubscribe]({{unsubscribe_url}})`
  # reaches the substitution pass as `%7B%7Bunsubscribe_url%7D%7D`, which it cannot
  # see, and the email goes out with a dead link. Put back only what is a whole
  # placeholder in an href or src. After sanitizing, so the sanitizer judges the
  # encoded form and nothing it has not seen comes out of this.
  defp restore_link_placeholders(html) do
    Regex.replace(@link_attribute, html, fn _attribute, name, value ->
      ~s(#{name}="#{Regex.replace(@encoded_placeholder, value, &URI.decode/1)}")
    end)
  end

  @doc """
  Converts HTML to plain text for the text/plain part of emails.

  Converts `<br>` tags to newlines and `</p>` to double newlines, keeps each
  link's address after its text, strips the remaining tags and decodes entities.
  A reader of this part has nothing else to follow a link with, the unsubscribe
  link included.
  """
  @spec strip_html(String.t()) :: String.t()
  def strip_html(html) do
    html
    |> keep_link_addresses()
    |> String.replace(~r/<br\s*\/?>/, "\n")
    |> String.replace(~r/<\/p>/, "\n\n")
    |> String.replace(@html_tag, "")
    |> decode_entities()
    |> String.trim()
  end

  defp keep_link_addresses(html) do
    Regex.replace(@link, html, fn _link, address, inner ->
      case inner |> String.replace(@html_tag, "") |> String.trim() do
        text when text in ["", address] -> address
        text -> "#{text} (#{address})"
      end
    end)
  end

  # One pass, so `&amp;lt;` comes out as the literal `&lt;` the author wrote and
  # is not decoded a second time.
  defp decode_entities(text) do
    Regex.replace(@entity, text, fn entity, name ->
      decode_entity(name) || entity
    end)
  end

  defp decode_entity("#x" <> hex), do: codepoint(Integer.parse(hex, 16))
  defp decode_entity("#X" <> hex), do: codepoint(Integer.parse(hex, 16))
  defp decode_entity("#" <> decimal), do: codepoint(Integer.parse(decimal))
  defp decode_entity(name), do: Map.get(@named_entities, name)

  # Only what is a character and can be stored: a surrogate or a value past the
  # end of Unicode has no UTF-8 form, and Postgres refuses a NUL in text. Such an
  # entity stays as written.
  defp codepoint({code, ""}) when code in 1..0xD7FF or code in 0xE000..0x10FFFF,
    do: <<code::utf8>>

  defp codepoint(_parsed), do: nil

  defp escape(nil), do: ""

  defp escape(markdown) do
    markdown
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end
end
