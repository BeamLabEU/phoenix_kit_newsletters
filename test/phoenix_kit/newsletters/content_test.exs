defmodule PhoenixKit.Newsletters.ContentTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Newsletters.Content
  alias PhoenixKit.Newsletters.Render

  describe "render_markdown/1" do
    test "converts markdown to HTML" do
      assert "<p>Hello <strong>world</strong></p>" =
               Content.render_markdown("Hello **world**")
    end

    test "handles nil input" do
      assert "" = Content.render_markdown(nil)
    end

    test "handles empty string" do
      assert "" = Content.render_markdown("")
    end

    test "strips script tags embedded as raw HTML" do
      html = Content.render_markdown("Hi\n\n<script>alert(1)</script>")
      refute html =~ "<script"
    end

    test "strips event-handler attributes embedded as raw HTML" do
      html = Content.render_markdown(~s|<img src="x" onerror="alert(1)">|)
      refute html =~ "onerror"
    end
  end

  describe "task lists" do
    # The sanitizer removes a checkbox `<input>`, so as a task list the two would
    # be the same bullet.
    test "keep the difference between done and not done" do
      html = Content.render_markdown("- [x] Paid\n- [ ] Due\n")

      assert html =~ "[x] Paid"
      assert html =~ "[ ] Due"
    end
  end

  describe "render_markdown_strict/1" do
    test "returns {:ok, html} on valid markdown" do
      assert {:ok, html} = Content.render_markdown_strict("Hello **world**")
      assert html =~ "Hello"
      assert html =~ "<strong>world</strong>"
    end

    test "handles nil input" do
      assert {:ok, ""} = Content.render_markdown_strict(nil)
    end
  end

  describe "strip_html/1" do
    test "removes HTML tags" do
      assert "Hello world" = Content.strip_html("<p>Hello <strong>world</strong></p>")
    end

    test "converts br tags to newlines" do
      assert "Line one\nLine two\nLine three" =
               Content.strip_html("Line one<br>Line two<br/>Line three")
    end

    test "converts paragraph closing tags to double newlines" do
      assert "First\n\nSecond" = Content.strip_html("<p>First</p><p>Second</p>")
    end

    test "returns empty string for empty input" do
      assert "" = Content.strip_html("")
    end
  end

  describe "render_markdown/1 |> strip_html/1 pipeline" do
    test "full markdown-to-text pipeline" do
      text =
        "Hello **world**"
        |> Content.render_markdown()
        |> Content.strip_html()

      assert text =~ "Hello world"
    end
  end

  describe "placeholders in Markdown links" do
    # Through the render a send uses: what matters is the address in the mail.
    defp sent_html(markdown, variables) do
      markdown
      |> Content.render_markdown()
      |> Render.html("<div>{{{content}}}</div>", variables)
    end

    test "a link's placeholder is filled in, not left percent-encoded" do
      html =
        sent_html("[Unsubscribe]({{unsubscribe_url}})", %{
          "unsubscribe_url" => "https://example.com/u?token=abc"
        })

      assert html =~ ~s(href="https://example.com/u?token=abc")
      refute html =~ "%7B"
    end

    test "an image's placeholder is filled in" do
      assert sent_html("![Logo]({{logo_url}})", %{"logo_url" => "https://example.com/l.png"}) =~
               ~s(src="https://example.com/l.png")
    end

    test "a placeholder inside a longer address is filled in" do
      assert sent_html("[Hi](https://example.com/?who={{email}})", %{"email" => "a@b.example"}) =~
               ~s(href="https://example.com/?who=a@b.example")
    end

    test "an ampersand in the value stays valid in the attribute" do
      assert sent_html("[x]({{unsubscribe_url}})", %{
               "unsubscribe_url" => "https://e.com/?a=1&b=2"
             }) =~
               ~s(href="https://e.com/?a=1&amp;b=2")
    end

    test "the spaced form written with angle brackets is restored too" do
      assert Content.render_markdown("[x](<{{ unsubscribe_url }}>)") =~
               ~s(href="{{ unsubscribe_url }}")
    end

    test "the strict render does the same" do
      assert {:ok, html} = Content.render_markdown_strict("[x]({{preferences_url}})")
      assert html =~ ~s(href="{{preferences_url}}")
    end

    test "an address that merely contains encoded braces keeps them" do
      assert Content.render_markdown("[x](https://example.com/%7Bid%7D)") =~
               ~s(href="https://example.com/%7Bid%7D")
    end

    test "encoded text outside a link attribute is the author's, and stays" do
      assert Content.render_markdown("Write `%7B%7Bname%7D%7D` to get a name.") =~
               "%7B%7Bname%7D%7D"
    end
  end

  describe "strip_html/1 — the text part" do
    test "keeps a link's address after its text" do
      assert Content.strip_html(~s(<p><a href="https://example.com/a">Read more</a></p>)) ==
               "Read more (https://example.com/a)"
    end

    test "writes a link whose text is its address once" do
      assert Content.strip_html(~s(<a href="https://example.com">https://example.com</a>)) ==
               "https://example.com"
    end

    test "uses the address for a link with no text of its own" do
      assert Content.strip_html(~s(<a href="https://example.com"><img src="x.png"></a>)) ==
               "https://example.com"
    end

    test "sees through markup inside a link" do
      assert Content.strip_html(~s(<a href="https://example.com"><strong>Bold</strong></a>)) ==
               "Bold (https://example.com)"
    end

    test "leaves the unsubscribe placeholder for substitution" do
      text =
        "[Unsubscribe]({{unsubscribe_url}})" |> Content.render_markdown() |> Content.strip_html()

      assert text == "Unsubscribe ({{unsubscribe_url}})"

      assert Render.text(text, %{"unsubscribe_url" => "https://e.com/u?a=1&b=2"}) ==
               "Unsubscribe (https://e.com/u?a=1&b=2)"
    end

    test "decodes entities" do
      assert Content.strip_html("<p>AT&amp;T &lt;3 &gt; &quot;you&quot; &#39;s &#x41;</p>") ==
               ~s(AT&T <3 > "you" 's A)
    end

    test "decodes once, so what the author wrote as an entity stays one" do
      assert Content.strip_html("<p>Write &amp;lt; for less-than</p>") ==
               "Write &lt; for less-than"
    end

    test "an ampersand in an address comes out plain" do
      assert Content.strip_html(~s(<a href="https://e.com/?a=1&amp;b=2">Go</a>)) ==
               "Go (https://e.com/?a=1&b=2)"
    end

    test "leaves what is not a character as written" do
      assert Content.strip_html("&#0; &#xD800; &#9999999; &unknown;") ==
               "&#0; &#xD800; &#9999999; &unknown;"
    end
  end
end
