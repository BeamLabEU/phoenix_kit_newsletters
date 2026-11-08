defmodule PhoenixKit.Newsletters.RenderTest do
  use PhoenixKitNewsletters.DataCase, async: false

  alias PhoenixKit.Email.Branding
  alias PhoenixKit.Newsletters.Layout
  alias PhoenixKit.Newsletters.Render
  alias PhoenixKit.Settings
  alias PhoenixKit.Templates.Overrides

  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  defp layout(html_by_language, subject \\ %{}) do
    %Layout{
      uuid: Ecto.UUID.generate(),
      name: "acme_layout",
      html_body: html_by_language,
      subject: subject
    }
  end

  describe "html/4 with a layout" do
    test "picks the reader's language and places the body", %{tmp_dir: dir} do
      layout = layout(%{"en" => "<i>EN</i>{{{content}}}", "de" => "<i>DE</i>{{{content}}}"})

      assert Render.html("<p>Hallo</p>", layout, %{}, locale: "de-AT", paths: [dir]) ==
               "<i>DE</i><p>Hallo</p>"

      assert Render.html("<p>Hi</p>", layout, %{}, locale: "en", paths: [dir]) ==
               "<i>EN</i><p>Hi</p>"
    end

    test "places core's header, footer and branding (render_parts/2)", %{tmp_dir: dir} do
      layout =
        layout(%{
          "en" =>
            ~s(<div style="color:{{accent_color}}" data-logo="{{logo_url}}">[{{{header}}}]{{{content}}}[{{{footer}}}]</div>)
        })

      html = Render.html("<p>Body</p>", layout, %{}, locale: "en", subject: "Hi", paths: [dir])

      site = escape(PhoenixKit.Settings.get_project_title())
      branding = Branding.variables()

      assert html =~ ~s(style="color:#{branding["accent_color"]}")
      assert html =~ ~s(data-logo="#{branding["logo_url"]}")
      assert html =~ "[#{site}]<p>Body</p>["
      refute html =~ "{{"
    end

    test "markup in the site's name is escaped in the header", %{tmp_dir: dir} do
      PhoenixKit.Settings.update_setting("project_title", "Acme <b>&</b>")
      layout = layout(%{"en" => "{{{header}}}|{{{content}}}"})

      html = Render.html("B", layout, %{}, locale: "en", paths: [dir])

      assert html =~ "Acme &lt;b&gt;&amp;&lt;/b&gt;|B"
      refute html =~ "<b>&</b>"
    end

    test "the header is _header-newsletters, then _header, per locale", %{tmp_dir: dir} do
      write(dir, "_header-newsletters/html.de.html", "Kopf {{site_name}}")
      write(dir, "_header/html.html", "Shared head")
      write(dir, "_footer-newsletters/html.html", "   ")

      layout = layout(%{"en" => "{{{header}}}|{{{content}}}|{{{footer}}}"})
      opts = [paths: [dir]]

      site = escape(PhoenixKit.Settings.get_project_title())

      assert Render.html("B", layout, %{}, [locale: "de"] ++ opts) =~ "Kopf #{site}|B|"
      assert Render.html("B", layout, %{}, [locale: "en"] ++ opts) =~ "Shared head|B|"

      # A blank group footer counts as missing: core's own footer is used.
      assert Render.html("B", layout, %{}, [locale: "en"] ++ opts) =~ ~r/\|B\|#{site}<br>/
    after
      Overrides.reset_cache()
    end

    test "{{name}} is escaped, {{{name}}} is raw, values are never rescanned", %{tmp_dir: dir} do
      layout = layout(%{"en" => "{{content}}<a href=\"{{unsubscribe_url}}\">x</a>"})

      vars = %{
        "name" => "<Ada & {{email}}>",
        "email" => "a@example.com",
        "unsubscribe_url" => "https://x/u?a=1&b=2"
      }

      html = Render.html("<p>{{name}} / {{{name}}}</p>", layout, vars, locale: "en", paths: [dir])

      assert html ==
               "<p>&lt;Ada &amp; {{email}}&gt; / <Ada & {{email}}></p>" <>
                 ~s(<a href="https://x/u?a=1&amp;b=2">x</a>)
    end

    test "a body with backslashes and dollar signs lands as written", %{tmp_dir: dir} do
      layout = layout(%{"en" => "<div>{{{content}}}</div>"})
      body = ~S(<p>C:\path\1 costs $1 \0</p>)

      assert Render.html(body, layout, %{}, locale: "en", paths: [dir]) == "<div>#{body}</div>"
    end
  end

  describe "a host's own header and footer files" do
    # The obvious home for an unsubscribe link, and core renders those parts first.
    @variables %{"unsubscribe_url" => "https://site.example/out", "name" => "Jane"}

    test "can place a recipient's variables under a layout", %{tmp_dir: dir} do
      write(dir, "_footer-newsletters/html.html", ~s(<a href="{{unsubscribe_url}}">Out</a>))
      layout = layout(%{"en" => "{{{content}}}{{{footer}}}"})

      html = Render.html("Body", layout, @variables, locale: "en", paths: [dir])

      assert html =~ ~s(href="https://site.example/out")
      refute html =~ "{{unsubscribe_url}}"
    end

    test "and with no layout at all", %{tmp_dir: dir} do
      write(dir, "_footer-newsletters/html.html", ~s(<a href="{{unsubscribe_url}}">Out</a>))

      html = Render.html("<p>Body</p>", nil, @variables, locale: "en", paths: [dir])

      assert html =~ ~s(href="https://site.example/out")
    end

    test "the header reads them too", %{tmp_dir: dir} do
      write(dir, "_header-newsletters/html.html", "Hello {{name}}")
      layout = layout(%{"en" => "{{{header}}}{{{content}}}"})

      assert Render.html("B", layout, @variables, locale: "en", paths: [dir]) =~ "Hello Jane"
    end

    # A colour of its own: the default would pass with the site's setting lost.
    test "passing them on keeps the site's colour", %{tmp_dir: dir} do
      {:ok, _setting} = Settings.update_setting(Branding.accent_color_key(), "#123456")
      write(dir, "_header-newsletters/html.html", "{{accent_color}}")
      layout = layout(%{"en" => "{{{header}}}{{{content}}}"})

      assert Render.html("B", layout, @variables, locale: "en", paths: [dir]) =~ "#123456"
    end
  end

  describe "html/4 without a usable layout" do
    test "warnings remember the latest edit and the resolved language under one key",
         %{tmp_dir: dir} do
      layout = layout(%{"en" => "<p>only chrome</p>"})
      key = {Render, :without_content, layout.uuid}
      on_exit(fn -> :persistent_term.erase(key) end)

      render = fn layout, locale ->
        capture_log(fn -> Render.html("Body", layout, %{}, locale: locale, paths: [dir]) end)
      end

      assert render.(layout, "en") =~ "has no {{{content}}}"
      refute render.(layout, "en-US") =~ "has no {{{content}}}"

      for edit <- 1..3 do
        edited = %{layout | html_body: %{"en" => "<p>edit #{edit}</p>"}}
        assert render.(edited, "en") =~ "has no {{{content}}}"
        refute render.(edited, "en-GB") =~ "has no {{{content}}}"
      end

      keys =
        for {{Render, :without_content, uuid} = key, _} <- :persistent_term.get(),
            uuid == layout.uuid,
            do: key

      assert keys == [key]
    end

    test "nil: core's standard layout, newsletters group", %{tmp_dir: dir} do
      html = Render.html("<p>Body</p>", nil, %{}, locale: "en", subject: "News", paths: [dir])

      assert html =~ "<!DOCTYPE html>"
      assert html =~ "<title>News</title>"
      assert html =~ "<p>Body</p>"
    end

    test "the reader's own data is escaped in the standard layout too", %{tmp_dir: dir} do
      html =
        Render.html("<p>Hi {{name}}</p>", nil, %{"name" => "<script>x</script>"},
          locale: "en",
          paths: [dir]
        )

      assert html =~ "<p>Hi &lt;script&gt;x&lt;/script&gt;</p>"
      refute html =~ "<script>"
    end

    test "a host's _layout-newsletters frames it", %{tmp_dir: dir} do
      write(dir, "_layout-newsletters/html.html", "<main class=\"nl\">{{{content}}}</main>")

      assert Render.html("<p>Body</p>", nil, %{}, locale: "en", paths: [dir]) ==
               "<main class=\"nl\"><p>Body</p></main>"
    after
      Overrides.reset_cache()
    end

    test "a layout whose resolved language does not place the body", %{tmp_dir: dir} do
      layout = layout(%{"en" => "<p>only chrome</p>"})
      html = Render.html("<p>Body</p>", layout, %{}, locale: "en", paths: [dir])

      assert html =~ "<!DOCTYPE html>"
      assert html =~ "<p>Body</p>"
      refute html =~ "only chrome"
    end

    test "a body that is already a document is sent as it is", %{tmp_dir: dir} do
      doc = "<!doctype html><html><body>{{name}}</body></html>"

      assert Render.html(doc, nil, %{"name" => "Ada"}, locale: "en", paths: [dir]) ==
               "<!doctype html><html><body>Ada</body></html>"
    end
  end

  describe "subject/4" do
    test "an unusable HTML translation also falls back to the broadcast's subject" do
      for html <- [%{}, %{"en" => "<p>only chrome</p>"}] do
        layout = layout(html, %{"en" => "[Legacy] {{subject}}"})
        assert Render.subject("News", layout, "en") == "News"
      end
    end

    test "the layout's pattern for the language, around the broadcast's subject" do
      layout =
        layout(%{"en" => "{{{content}}}", "de" => "{{{content}}}"}, %{
          "de" => "[DE] {{subject}}",
          "en" => "{{subject}} — Acme"
        })

      assert Render.subject("News", layout, "de") == "[DE] News"
      assert Render.subject("News", layout, "en") == "News — Acme"
    end

    test "the subject is read in the language the HTML is picked in, never another" do
      # A pt reader gets the English HTML (site default); the only pattern
      # is German, so the subject stays the broadcast's own.
      layout = layout(%{"en" => "{{{content}}}"}, %{"de" => "[DE] {{subject}}"})
      assert Render.subject("News", layout, "pt") == "News"
    end

    test "no pattern, or one without {{subject}}, keeps the broadcast's subject" do
      assert Render.subject("News", nil, "de") == "News"
      assert Render.subject("News", layout(%{}, %{"en" => "Fixed"}), "en") == "News"
    end

    test "line breaks never reach the header" do
      layout = layout(%{"en" => "{{{content}}}"}, %{"en" => "{{subject}}\r\n{{name}}"})
      assert Render.subject("News", layout, "en", %{"name" => "Ada"}) == "News Ada"
      assert Render.subject("News\r\nInjected", nil, "en") == "News Injected"
    end
  end

  test "text/2 fills variables and never wraps" do
    assert Render.text("Hi {{name}} {{{name}}}", %{"name" => "<Ada>"}) == "Hi <Ada> <Ada>"
    assert Render.text(nil, %{}) == ""
  end

  defp write(dir, relative, content) do
    path = Path.join(dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  describe "the site's variables outside a layout" do
    test "site_variables/0 are the values core's layout binds" do
      assert Render.site_variables() ==
               nil |> Render.chrome() |> Map.fetch!(:variables) |> Map.delete("subject")
    end

    test "a layout's subject pattern can use them" do
      layout = %Layout{
        html_body: %{"en" => "<div>{{{content}}}</div>"},
        subject: %{"en" => "{{subject}} | {{site_name}}"}
      }

      assert Render.subject("Hello", layout, "en", %{"site_name" => "Acme"}) == "Hello | Acme"
    end

    test "a body without a layout can use them, and its subject" do
      html =
        Render.html("<p>{{site_name}}: {{subject}}</p>", nil, %{"site_name" => "Acme"},
          subject: "News"
        )

      assert html =~ "<p>Acme: News</p>"
    end

    test "the text part can use them" do
      assert Render.text("From {{site_name}}", %{"site_name" => "Acme"}) == "From Acme"
    end
  end

  describe "the unsubscribe link" do
    @url "https://site.example/out?token=abc"
    @out %{"unsubscribe_url" => @url}
    @tag_link ~s(<a href="{{unsubscribe_url}}">Leave</a>)

    defp links(html), do: length(:binary.matches(html, ~s(href="#{@url}")))

    test "a body with no layout gets one, before the end of the document", %{tmp_dir: dir} do
      html = Render.html("<p>Hello</p>", nil, @out, locale: "en", paths: [dir])

      assert links(html) == 1
      assert html =~ ~r{>Unsubscribe</a></p>\s*</body>}
    end

    test "a layout without one gets one, inside its body", %{tmp_dir: dir} do
      layout = layout(%{"en" => "<html><body>{{{content}}}<p>Foot</p></body></html>"})

      html = Render.html("Hi", layout, @out, locale: "en", paths: [dir])

      assert links(html) == 1

      assert html =~
               ~r{<p>Foot</p><p style="[^"]*"><a href="[^"]*"[^>]*>Unsubscribe</a></p></body>}
    end

    test "the last end of body is the one, whatever its case", %{tmp_dir: dir} do
      layout = layout(%{"en" => "{{{content}}}</body><i>tail</i></BODY >"})

      html = Render.html("Hi", layout, @out, locale: "en", paths: [dir])

      assert html =~ ~r{</body><i>tail</i><p style=.*</p></BODY >$}
    end

    test "a layout that is only a fragment gets it at the end", %{tmp_dir: dir} do
      layout = layout(%{"en" => "<div>{{{content}}}</div>"})

      html = Render.html("Hi", layout, @out, locale: "en", paths: [dir])

      assert links(html) == 1
      assert String.ends_with?(html, "</a></p>")
    end

    test "a body that is a whole document gets one", %{tmp_dir: dir} do
      html = Render.html("<html><body><p>Mine</p></body></html>", nil, @out, paths: [dir])

      assert links(html) == 1
      assert html =~ ~r{</p></body></html>$}
    end

    test "is not added when the body has it, as a tag or a Markdown link", %{tmp_dir: dir} do
      html = Render.html("<p>#{@tag_link}</p>", nil, @out, paths: [dir])

      assert links(html) == 1
      assert html =~ ">Leave</a>"
      refute html =~ ">Unsubscribe</a>"
    end

    test "is not added when the layout has it", %{tmp_dir: dir} do
      layout = layout(%{"en" => "{{{content}}}#{@tag_link}"})

      html = Render.html("Hi", layout, @out, locale: "en", paths: [dir])

      assert links(html) == 1
      refute html =~ ">Unsubscribe</a>"
    end

    test "is not added when a host's footer file has it", %{tmp_dir: dir} do
      write(dir, "_footer-newsletters/html.html", @tag_link)

      without_layout = Render.html("Hi", nil, @out, locale: "en", paths: [dir])

      under_layout =
        Render.html("Hi", layout(%{"en" => "{{{content}}}{{{footer}}}"}), @out,
          locale: "en",
          paths: [dir]
        )

      for html <- [without_layout, under_layout] do
        assert links(html) == 1
        refute html =~ ">Unsubscribe</a>"
      end
    end

    test "an address printed as text counts: the reader can use it", %{tmp_dir: dir} do
      html = Render.html("<p>Leave: {{{unsubscribe_url}}}</p>", nil, @out, paths: [dir])

      refute html =~ ">Unsubscribe</a>"
    end

    test "either escaping of an address with an ampersand counts", %{tmp_dir: dir} do
      url = "https://site.example/out?a=1&b=2"
      out = %{"unsubscribe_url" => url}

      for tag <- ["{{unsubscribe_url}}", "{{{unsubscribe_url}}}"] do
        html = Render.html(~s(<a href="#{tag}">Leave</a>), nil, out, paths: [dir])

        refute html =~ ">Unsubscribe</a>"
      end
    end

    test "the address it adds is escaped", %{tmp_dir: dir} do
      out = %{"unsubscribe_url" => ~s(https://site.example/out?a=1&b="2)}

      html = Render.html("Hi", nil, out, paths: [dir])

      assert html =~ ~s(href="https://site.example/out?a=1&amp;b=&quot;2")
    end

    test "a commented-out link is not one a reader can see", %{tmp_dir: dir} do
      layout = layout(%{"en" => "{{{content}}}<!-- #{@tag_link} --><body></body>"})

      html = Render.html("Hi", layout, @out, locale: "en", paths: [dir])

      assert html =~ ">Unsubscribe</a>"
    end

    test "a preferences link does not stand in for it: that token expires", %{tmp_dir: dir} do
      variables = Map.put(@out, "preferences_url", "https://site.example/prefs")
      layout = layout(%{"en" => ~s({{{content}}}<a href="{{preferences_url}}">Prefs</a>)})

      html = Render.html("Hi", layout, variables, locale: "en", paths: [dir])

      assert links(html) == 1
      assert html =~ ">Unsubscribe</a>"
    end

    test "with no address there is nothing to link to", %{tmp_dir: dir} do
      for variables <- [%{}, %{"unsubscribe_url" => ""}, %{"unsubscribe_url" => nil}] do
        refute Render.html("Hi", nil, variables, paths: [dir]) =~ ">Unsubscribe</a>"
      end
    end

    test "atom keys count, as for every other variable", %{tmp_dir: dir} do
      assert Render.html("Hi", nil, %{unsubscribe_url: @url}, paths: [dir]) =~ ">Unsubscribe</a>"
    end

    test "is in the reader's language, dialects included", %{tmp_dir: dir} do
      assert Render.html("Hi", nil, @out, locale: "et", paths: [dir]) =~ ">Loobu tellimusest</a>"
      assert Render.html("Hi", nil, @out, locale: "ru-RU", paths: [dir]) =~ ">Отписаться</a>"
    end

    test "leaves the process's language as it found it", %{tmp_dir: dir} do
      before = Gettext.get_locale()

      Render.html("Hi", nil, @out, locale: "ru", paths: [dir])

      assert Gettext.get_locale() == before
    end
  end

  describe "the text part's unsubscribe address" do
    @url "https://site.example/out?token=abc"
    @out %{"unsubscribe_url" => @url}

    test "follows the text, on a line of its own" do
      assert Render.text("Hello\n\n", @out) == "Hello\n\nUnsubscribe: #{@url}"
    end

    test "is in the reader's language" do
      assert Render.text("Hi", @out, locale: "et") == "Hi\n\nLoobu tellimusest: #{@url}"
    end

    test "is not repeated when the text already holds it" do
      text = "Leave: {{unsubscribe_url}}"

      assert Render.text(text, @out) == "Leave: #{@url}"
    end

    test "with no address the text is left as it is" do
      assert Render.text("Hi", %{}) == "Hi"
      assert Render.text("Hi", %{"unsubscribe_url" => ""}) == "Hi"
    end

    test "a blank text stays blank, the HTML having the link" do
      assert Render.text(nil, @out) == ""
      assert Render.text("  \n", @out) == "  \n"
    end
  end

  describe "a send profile's signature" do
    @url "https://site.example/out?token=abc"
    @out %{"unsubscribe_url" => @url}

    test "goes into the layout's content slot, after the body", %{tmp_dir: dir} do
      layout = layout(%{"en" => "<html><body><div>{{{content}}}</div><p>Foot</p></body></html>"})

      html =
        Render.html("<p>Hi</p>", layout, @out,
          locale: "en",
          paths: [dir],
          signature: "<p>Sig</p>"
        )

      assert html =~ ~r{<div><p>Hi</p><p>Sig</p></div><p>Foot</p><p style=[^>]*><a href=}
    end

    test "inside core's standard layout, never after the document", %{tmp_dir: dir} do
      html = Render.html("<p>Hi</p>", nil, @out, paths: [dir], signature: "<p>Sig</p>")

      assert html =~ ~r{<p>Hi</p><p>Sig</p>}
      assert html =~ ~r{</html>\s*$}
    end

    test "before the end of a body that is a whole document", %{tmp_dir: dir} do
      html =
        Render.html("<html><body><p>Hi</p></body></html>", nil, %{},
          paths: [dir],
          signature: "<p>S</p>"
        )

      assert html == "<html><body><p>Hi</p><p>S</p></body></html>"
    end

    test "has its variables filled in like the body", %{tmp_dir: dir} do
      html =
        Render.html("Hi", nil, %{"name" => "<Ada>"}, paths: [dir], signature: "<p>{{name}}</p>")

      assert html =~ "<p>&lt;Ada&gt;</p>"
    end

    test "stands on lines of its own in the text, before the unsubscribe address" do
      assert Render.text("Hi\n", @out, signature: "\nBest, Acme\n") ==
               "Hi\n\nBest, Acme\n\nUnsubscribe: #{@url}"
    end

    test "is left out of a blank text, and a blank signature adds nothing" do
      assert Render.text("", %{}, signature: "Best") == ""
      assert Render.text("Hi", %{}, signature: "  ") == "Hi"
      assert Render.text("Hi", %{}, signature: nil) == "Hi"
      assert Render.html("<p>Hi</p>", "{{{content}}}", %{}, signature: "") == "<p>Hi</p>"
    end
  end
end
