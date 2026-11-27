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

  # A style element's opening tag: the name, then its attributes, a quoted value
  # (which may hold a `>`) taken whole. The group around the name also keeps
  # this line from reading as a tag to the inline-tag lint.
  @style_tag ~r/<(style)(?=[\s\/>])((?:"[^"]*"|'[^']*'|[^'">])*)>/i
  @quoted_value ~r/"[^"]*"|'[^']*'/
  @nonce_attribute ~r/(?:^|[\s\/"'])nonce(?:$|[\s\/=])/i

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
  `html` with the page's style nonce on every `<style>` element, for an
  `<iframe srcdoc>` preview. A tag that already has a nonce keeps its own.
  Without a nonce, `html` comes back as it is.

  Never for HTML that is sent, stored or cached.
  """
  @spec stamp_styles(String.t(), String.t() | nil) :: String.t()
  def stamp_styles(html, nonce \\ nonce(:style))

  def stamp_styles(html, nonce) when is_binary(nonce) and nonce != "" do
    attribute = ~s( nonce="#{Plug.HTML.html_escape(nonce)}")

    Regex.replace(@style_tag, html, fn tag, name, attributes ->
      if nonce?(attributes), do: tag, else: "<" <> name <> attribute <> attributes <> ">"
    end)
  end

  def stamp_styles(html, _nonce), do: html

  # Quoted values are emptied first: `title="a nonce=1"` is not a nonce.
  defp nonce?(attributes) do
    Regex.match?(@nonce_attribute, Regex.replace(@quoted_value, attributes, ~s("")))
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
