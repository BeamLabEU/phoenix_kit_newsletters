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
  the page's nonce. `stamp_styles/2` puts it there, except in a message with
  one of the tags it leaves alone (see its doc):

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
  `html` with the page's style nonce on its `<style>` tags that have none, for an
  `<iframe srcdoc>` preview. Without a nonce, `html` comes back as it is.

  The tags that matter here are `<script`, `<svg`, `<math`, `<iframe`, `<frame`,
  `<object`, `<embed`, `<select` and `<template`, in any case of letters:
  a message that has any of these tags anywhere is left as it is; otherwise the
  nonce is added only to `<style>` opening tags.

  What this costs is cosmetic: such a message previews unstyled, even if the tag
  is only in a comment; a token of a few MB stops stamping from there on.

  The preview frame must not allow scripts, which is also how the markup is read
  here: `<noscript>` holds markup.

  Never for HTML that is sent, stored or cached.
  """
  @spec stamp_styles(String.t(), String.t() | nil) :: String.t()
  def stamp_styles(html, nonce \\ nonce(:style))

  def stamp_styles(html, nonce) when is_binary(nonce) and nonce != "" do
    if leave_alone?(html),
      do: html,
      else: stamp(html, ~s( nonce="#{Plug.HTML.html_escape(nonce)}"))
  end

  def stamp_styles(html, _nonce), do: html

  # Whether `html` may hold what the reading below does not follow: a script,
  # foreign content (<svg>, <math>), an embedded document, or where a browser
  # drops a raw-text element's tag and reads its text as markup: in a frameset,
  # in a <select> (parsers by the older rules) and after <template><col>. None
  # of these exists without this text: a NUL in a tag's name becomes U+FFFD,
  # `< svg` is text, and a character reference never opens a tag. Looked for in
  # the whole input, not where that reading finds tags, so that nothing it gets
  # wrong matters here.
  defp leave_alone?(html),
    do: Regex.match?(~r/<(script|svg|math|iframe|frame|object|embed|select|template)/i, html)

  defp stamp(html, attribute) do
    Regex.replace(token(), html, fn
      token, opening, name, rest, close, content ->
        # `close` is empty for a tag cut off by the end of the input.
        if String.downcase(name) == "style" and close == ">" and not nonced?(rest <> close),
          do: opening <> attribute <> rest <> close <> content,
          else: token
    end)
  end

  # The markup is read one token at a time, so that `<style` is rewritten only
  # where a browser reads a tag: not in a comment, in an attribute's value or in
  # the text of a raw-text element. In order:
  #
  #   * a comment;
  #   * <plaintext>, whose text nothing ends;
  #   * a raw-text element: `<name`, its attributes, `>`, its text;
  #   * any other start or end tag;
  #   * what HTML takes for a comment too (`<!x`, `<?`, `</1`), ended by the
  #     first `>`, quotes or not.
  #
  # A tag is read one attribute at a time, as in HTML: a quote opens a value only
  # after the `=` of an attribute. The one in `class=it's`, in `<a=">` or in
  # `<a =">` is part of a value or a name and must not swallow what follows. A
  # quoted value left open runs to the end. Whitespace is HTML's, which `\s` is
  # not.
  #
  # Keep it linear: once its opener has matched, a token must not fail, so each
  # end may also be the end of the input. One that failed there would be tried
  # again from every later opener, in time growing with the square of the size.
  #
  # PCRE gives up on a token of a few million bytes (its match limit). The scan
  # stops there: the styles from that token on stay unstamped, nothing is lost.
  #
  # This is HTML's tokenizer, in part, and no parser. What would put it out of
  # step with a browser never reaches it: see `leave_alone?/1`.
  defp token do
    attributes = ~S"""
    (?: [ \t\n\f\r\/]++
      | [^ \t\n\f\r\/>][^ \t\n\f\r\/>=]*+
        (?:[ \t\n\f\r]*+=[ \t\n\f\r]*+(?:"[^"]*+"?|'[^']*+'?|[^ \t\n\f\r>]*+))?+
    )*+
    """

    ~r/
      <!--(?:-?>|.*?(?:--!?>|\z))
      | <plaintext(?=[ \t\n\f\r\/>]).*+
      | (<(style|textarea|title|xmp|noembed|noframes)(?=[ \t\n\f\r\/>]))
        (#{attributes})
        (>|\z)
        (.*?(?=<\/\2[ \t\n\f\r\/>]|\z))
      | <\/?[a-z][^ \t\n\f\r\/>]*+ #{attributes} (?:>|\z)
      | <[!?\/][^>]*+(?:>|\z)
    /isx
  end

  # `rest` is the opening tag after its name. It is read one attribute at a
  # time, as HTML does, so that only an attribute named `nonce` counts: not a
  # value, and not the end of another name. A quoted value ends its attribute,
  # with or without a space after it; a `=` where a name begins is part of the
  # name.
  defp nonced?(rest) do
    ~r/
      ([^ \t\n\f\r\/>][^ \t\n\f\r\/>=]*+)
      (?:[ \t\n\f\r]*+=[ \t\n\f\r]*+(?:"[^"]*+"|'[^']*+'|[^ \t\n\f\r>]*+))?+
    /x
    |> Regex.scan(rest, capture: :all_but_first)
    |> Enum.any?(fn [name] -> String.downcase(name) == "nonce" end)
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
