defmodule PhoenixKit.Newsletters.Web.CSP do
  @moduledoc """
  The package's one door to core's Content-Security-Policy support
  (`PhoenixKitWeb.CSP`), and the nonce stamp for e-mail previews.

  A host may run a policy that allows inline code by nonce only
  (`style-src 'self' 'nonce-…'`). Its pages have to work under it:

    * an inline `<style>` / `<script>` of the package's own takes `nonce/1`;
    * there is no inline event handler (no nonce can cover an attribute);
    * a `live_session` of the package's own takes `live_session/1` and
      `on_mount/4`, so the nonce is still known after the socket connects.

  ## E-mail previews

  An `<iframe srcdoc>` document inherits the embedding page's policy, whatever
  its `sandbox` says, so a `<style>` in a previewed e-mail is refused without
  the page's nonce. `stamp_styles/2` puts it there:

      <iframe srcdoc={CSP.stamp_styles(@preview_html)} sandbox="allow-same-origin">

  Call it in that attribute only. A nonce belongs to one response, so HTML that
  is sent, stored or cached never carries one; the assigns keep the e-mail as
  `PhoenixKit.Newsletters.Render` built it. Inline `style="…"` attributes need
  no stamp (the host allows them with `style-src-attr`). A style sheet or font
  from an origin the host's policy does not allow stays blocked in the preview.

  ## Why a wrapper and not a direct call

  `PhoenixKitWeb.CSP` is newer than this package's core floor, so every call is
  feature-detected and goes through `apply/3`, which both the compiler and
  dialyzer accept on either core. On a core without it `nonce/1` is `nil`, the
  live session gains nothing and previews are left as they are.

  `test/csp_inline_tags_test.exs` guards these rules.
  """

  @core PhoenixKitWeb.CSP

  @type kind :: :script | :style

  @doc """
  The page's nonce for `kind`, or `nil`: the host set none, or the installed
  core has no nonce support.
  """
  @spec nonce(kind) :: String.t() | nil
  def nonce(kind) when kind in [:script, :style] do
    case core(:nonce, [kind], nil) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  @doc """
  `html` with the page's style nonce on every `<style>` tag, for an
  `<iframe srcdoc>` preview. A tag that already has a nonce keeps its own.
  Without a nonce, `html` comes back as it is.

  The nonce is written only where a browser reads a `<style>` tag: not in a
  comment, an attribute's value or the text of a raw-text element, and never on
  another element. This is a reading of the markup, not a parser (SVG's own
  rules, for one, are not followed), so the preview frame's `sandbox` stays
  without `allow-scripts`.

  Never for HTML that is sent, stored or cached.
  """
  @spec stamp_styles(String.t(), String.t() | nil) :: String.t()
  def stamp_styles(html, nonce \\ nonce(:style))

  def stamp_styles(html, nonce) when is_binary(nonce) and nonce != "" do
    attribute = ~s( nonce="#{Plug.HTML.html_escape(nonce)}")

    Regex.replace(token(), html, fn
      token, opening, name, rest, close, content ->
        # `close` is empty for a tag cut off by the end of the input.
        if String.downcase(name) == "style" and close == ">" and not nonced?(rest <> close),
          do: opening <> attribute <> rest <> close <> content,
          else: token
    end)
  end

  def stamp_styles(html, _nonce), do: html

  # The markup is read one token at a time. In order:
  #
  #   * a comment;
  #   * <plaintext>, whose text nothing ends;
  #   * a raw-text element: `<name`, its attributes, `>`, its text;
  #   * any other tag.
  #
  # A quote opens a value only after `=`, as in HTML: the one in `class=it's`
  # must not swallow the tags after it. Whitespace is HTML's, which `\s` is not.
  #
  # Keep it linear: once its opener has matched, a token must not fail, so each
  # end may also be the end of the input. One that failed there would be tried
  # again from every later opener, in time growing with the square of the size.
  #
  # PCRE gives up on a token of a few million bytes (its match limit). The scan
  # stops there: the styles from that token on stay unstamped, nothing is lost.
  defp token do
    ~r/
      <!--(?:-?>|.*?(?:--!?>|\z))
      | <plaintext(?=[ \t\n\f\r\/>]).*+
      | (<(script|style|textarea|title|xmp|iframe|noembed|noframes)(?=[ \t\n\f\r\/>]))
        ((?:=[ \t\n\f\r]*+(?:"[^"]*+"|'[^']*+')|[^>])*+)
        (>|\z)
        (.*?(?=<\/\2[ \t\n\f\r\/>]|\z))
      | <[a-z\/!?](?:=[ \t\n\f\r]*+(?:"[^"]*+"|'[^']*+')|[^>])*+(?:>|\z)
    /isx
  end

  # `rest` is the opening tag after its name. Each value is blanked first, so
  # that only an attribute named `nonce` counts: `title="a nonce=1"` is not one.
  # The space left behind keeps `media="print"nonce=x` two attributes.
  defp nonced?(rest) do
    names =
      Regex.replace(~r/=[ \t\n\f\r]*(?:"[^"]*"|'[^']*'|[^ \t\n\f\r>]+)/, rest, "= ")

    Regex.match?(~r/[ \t\n\f\r\/]nonce(?=[ \t\n\f\r=\/>])/i, names)
  end

  @doc "The `session:` of a live session of this package: the page's nonces."
  @spec live_session(Plug.Conn.t()) :: map
  def live_session(%Plug.Conn{} = conn), do: core(:live_session, [conn], %{})

  @doc false
  # `on_mount PhoenixKit.Newsletters.Web.CSP`: restores the nonces of the session.
  def on_mount(_arg, params, session, socket) do
    core(:on_mount, [:default, params, session, socket], {:cont, socket})
  end

  # The one call into core: `apply/3`, because the core floor has no such
  # module and a direct call would fail the compiler or dialyzer there.
  defp core(function, args, default) do
    if Code.ensure_loaded?(@core) and function_exported?(@core, function, length(args)) do
      apply(@core, function, args)
    else
      default
    end
  end
end
