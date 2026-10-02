defmodule PhoenixKit.Newsletters.RenderTest do
  use PhoenixKitNewsletters.DataCase, async: false

  alias PhoenixKit.Email.Branding
  alias PhoenixKit.Newsletters.Layout
  alias PhoenixKit.Newsletters.Render
  alias PhoenixKit.Templates.Overrides

  @moduletag :tmp_dir

  # Stands in for a core that has `Layout.render_parts/2`: whatever it
  # returns is what a layout must place.
  defmodule CoreWithParts do
    @moduledoc false
    def render_parts(subject, opts) do
      send(self(), {:render_parts, subject, opts})

      %{
        header: "<b>STUB HEADER</b>",
        footer: "STUB FOOTER",
        variables: %{
          "logo_url" => "https://cdn.example.com/logo.png",
          "accent_color" => "#123456"
        },
        sources: %{}
      }
    end
  end

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

    test "places core's parts and branding, through render_parts/2 when core has it",
         %{tmp_dir: dir} do
      layout =
        layout(%{
          "en" =>
            ~s(<div style="color:{{accent_color}}"><img src="{{logo_url}}">{{{header}}}{{{content}}}{{{footer}}}</div>)
        })

      html =
        Render.html("<p>Body</p>", layout, %{},
          locale: "en",
          subject: "Hi",
          paths: [dir],
          layout_module: CoreWithParts
        )

      assert html ==
               ~s(<div style="color:#123456"><img src="https://cdn.example.com/logo.png">) <>
                 ~s(<b>STUB HEADER</b><p>Body</p>STUB FOOTER</div>)

      assert_received {:render_parts, "Hi", opts}
      assert opts[:group] == "newsletters"
      assert opts[:locale] == "en"
      assert opts[:paths] == [dir]
    end

    test "builds the parts itself while core has no render_parts/2", %{tmp_dir: dir} do
      layout = layout(%{"en" => "[{{{header}}}]{{{content}}}[{{{footer}}}]|{{accent_color}}"})

      html =
        Render.html("<p>Body</p>", layout, %{}, locale: "en", paths: [dir], layout_module: Nope)

      site = escape(PhoenixKit.Settings.get_project_title())
      assert html =~ "[#{site}]<p>Body</p>["
      assert html =~ "|#{Branding.variables()["accent_color"]}"
    end

    test "the fallback reads _header-newsletters, then _header, per locale", %{tmp_dir: dir} do
      write(dir, "_header-newsletters/html.de.html", "Kopf {{site_name}}")
      write(dir, "_header/html.html", "Shared head")
      write(dir, "_footer-newsletters/html.html", "   ")

      layout = layout(%{"en" => "{{{header}}}|{{{content}}}|{{{footer}}}"})
      opts = [paths: [dir], layout_module: Nope]

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

  describe "html/4 without a usable layout" do
    test "nil: core's standard layout, newsletters group", %{tmp_dir: dir} do
      html = Render.html("<p>Body</p>", nil, %{}, locale: "en", subject: "News", paths: [dir])

      assert html =~ "<!DOCTYPE html>"
      assert html =~ "<title>News</title>"
      assert html =~ "<p>Body</p>"
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
      layout = layout(%{}, %{"en" => "{{subject}}\r\n{{name}}"})
      assert Render.subject("News", layout, "en", %{"name" => "Ada"}) == "News Ada"
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
end
