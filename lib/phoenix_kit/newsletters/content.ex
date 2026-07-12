defmodule PhoenixKit.Newsletters.Content do
  @moduledoc """
  Content rendering utilities for newsletters.

  Converts markdown to HTML and HTML to plain text for email delivery.
  """

  @doc """
  Renders markdown to HTML. Returns the HTML string on both success and
  error (falls back to an empty string if MDEx cannot produce output).
  """
  @spec render_markdown(String.t()) :: String.t()
  def render_markdown(markdown) do
    case MDEx.to_html(markdown || "") do
      {:ok, html} -> html
      {:error, _error} -> ""
    end
  end

  @doc """
  Renders markdown to HTML, returning an ok/error tuple.

  Returns `{:ok, html}` on success or `{:error, errors}` when MDEx
  cannot produce valid output.
  """
  @spec render_markdown_strict(String.t()) :: {:ok, String.t()} | {:error, list()}
  def render_markdown_strict(markdown) do
    case MDEx.to_html(markdown || "") do
      {:ok, html} -> {:ok, html}
      {:error, error} -> {:error, [error]}
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
end
