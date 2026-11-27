defmodule PhoenixKit.Newsletters.Web.CSPTest do
  @moduledoc """
  `Web.CSP.stamp_styles/2`: the page's nonce on the `<style>` elements of an
  e-mail preview, and nothing else changed.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Newsletters.Web.CSP

  describe "stamp_styles/2" do
    test "puts the nonce on a plain <style>" do
      assert CSP.stamp_styles("<style>.a{}</style>", "n0nce") ==
               ~s(<style nonce="n0nce">.a{}</style>)
    end

    test "keeps the attributes a tag already has" do
      assert CSP.stamp_styles(~s(<style media="screen" type="text/css">), "n0nce") ==
               ~s(<style nonce="n0nce" media="screen" type="text/css">)
    end

    test "matches the tag name in any case" do
      assert CSP.stamp_styles("<STYLE>a{}</STYLE><Style\nmedia=print>", "n0nce") ==
               ~s(<STYLE nonce="n0nce">a{}</STYLE><Style nonce="n0nce"\nmedia=print>)
    end

    test "stamps every <style> of the document" do
      html = "<head><style>a{}</style></head><body><style>b{}</style></body>"

      assert CSP.stamp_styles(html, "n0nce") ==
               ~s(<head><style nonce="n0nce">a{}</style></head>) <>
                 ~s(<body><style nonce="n0nce">b{}</style></body>)
    end

    test "leaves a tag that already has a nonce alone" do
      for html <- [
            ~s(<style nonce="other">),
            ~s(<style media="print" NONCE='other'>),
            ~s(<style media="print"nonce=other>),
            ~s(<style data-a='x'nonce="y">),
            ~s(<style/nonce=own>),
            ~s(<style\nnonce = "own">),
            ~s(<style/= nonce>),
            ~s(<style nonce>)
          ] do
        assert CSP.stamp_styles(html, "n0nce") == html
      end
    end

    test "does not take a nonce written inside another attribute's value for one" do
      html = ~s(<style title="a nonce=1 > b" data-nonce="2">)

      assert CSP.stamp_styles(html, "n0nce") ==
               ~s(<style nonce="n0nce" title="a nonce=1 > b" data-nonce="2">)
    end

    # A = where a name begins is part of that name, quotes and all.
    test "does not take a value or a name after a bare = for a nonce" do
      for attributes <- [
            "\t= title='a nonce=1'",
            ~s( title="x"data-nonce="y"),
            ~s( a=b="x"nonce),
            ~s( ="x"nonce),
            ~s( a="1"="x"nonce)
          ] do
        assert CSP.stamp_styles("<style#{attributes}>a{}</style>", "n0nce") ==
                 ~s(<style nonce="n0nce"#{attributes}>a{}</style>)
      end
    end

    test "never touches a <script>, a similar tag name or an inline style attribute" do
      html =
        ~s[<script>run()</script><script src="a.js"></script>] <>
          ~s[<styles></styles><style-guide></style-guide><p style="color:red">style</p>] <>
          ~s[&lt;style&gt;]

      assert CSP.stamp_styles(html, "n0nce") == html
    end

    # The nonce goes only where a browser reads a `<style>` tag. Anywhere else it
    # would break the markup around it, or land on another element: in the first
    # one, on the `<script>`, whose attribute `<style` merely looks like a tag.
    test "leaves text that only looks like a tag as it was" do
      for html <- [
            ~s(<script x=<style src=//evil.example/a.js></script>),
            ~s|<script>document.write("<style>a{}</style>")</script>|,
            ~s(<a title="<style>">x</a>),
            ~s(<div data-x='<style media="print">'>x</div>),
            "<!-- <style>a{}</style> -->",
            "<textarea><style></textarea>",
            "<title><style></title>",
            "a < style > b"
          ] do
        assert CSP.stamp_styles(html, "n0nce") == html
      end
    end

    test "leaves the text of the other raw-text elements as it was" do
      for element <- ~w(xmp noembed noframes) do
        html = "<#{element}><style></#{element}>"

        assert CSP.stamp_styles(html <> "<style></style>", "n0nce") ==
                 html <> ~s(<style nonce="n0nce"></style>)
      end

      # Nothing ends <plaintext>.
      html = "<plaintext></plaintext><style>a{}</style>"
      assert CSP.stamp_styles(html, "n0nce") == html
    end

    # No markup makes a script element without this text, so none can ever be
    # given the nonce, however the rest is read.
    test "leaves a message containing <script wholly unstamped" do
      trap_ = ~s|<script z='">' <style src=//e/a.js>|

      for html <- [
            "<style>a{}</style><script></script>",
            "<SCRIPT>x()</SCRIPT><style>a{}</style>",
            "<ScRiPt src=x.js></ScRiPt><style></style>",
            "<svg><script></script></svg><style></style>",
            ~s(<svg><![CDATA[><a x="]]>) <> trap_,
            ~s(<script><!--<script></script><a x="</script>) <> trap_,
            ~s(<!x a="><script z='">' <style src=//e/a.js>),
            # Wherever the text is: this is not a reading of the markup.
            "<!-- <script> --><style></style>",
            ~s(<img alt="<script>"><style></style>)
          ] do
        assert CSP.stamp_styles(html, "n0nce") == html
      end
    end

    # Foreign content and embedded documents follow rules of their own.
    test "leaves a message with svg, math or an embedded document unstamped" do
      for html <- [
            # A script in the nested document, written as character references.
            ~s(<svg><![CDATA[><a x="]]><iframe srcdoc='&lt;script z=">" <style src=//e/a.js>'>),
            # A <link> in this one.
            ~s(<svg><![CDATA[><a x="]]><link rel=stylesheet z='">' <style href=//e/a.css>),
            "<SVG></SVG><style></style>",
            "<style></style><math></math>",
            "<IFrame></IFrame><style></style>",
            "<frameset><frame></frameset><style></style>",
            "<object></object><style></style>",
            "<embed src=x><style></style>",
            ~s(<img alt="<svg>"><style></style>)
          ] do
        assert CSP.stamp_styles(html, "n0nce") == html
      end
    end

    # Parsers by the older rules ignore a raw-text element's tag inside <select>,
    # and after <template><col> a browser drops it.
    test "leaves a message with a select or a template unstamped" do
      for html <- [
            ~s(<select><xmp></select><link rel=stylesheet z='</xmp>' <style href=//e/a.css>),
            "<style></style><SELECT></SELECT>",
            ~s(<template><col><style></stylex></table></template><link z='</style>' <style href=u>),
            ~s(<template><col><xmp></xmpx></table></template><link z='</xmp>' <style href=u>),
            "<style></style><TEMPLATE></TEMPLATE>"
          ] do
        assert CSP.stamp_styles(html, "n0nce") == html
      end
    end

    test "stamps a message that only speaks of those tags" do
      for before <- [
            "<p>&lt;svg&gt; &lt;iframe&gt; < object> svg math embed select template</p>",
            "<noscript>script</noscript><p>&lt;script&gt; < script></p>"
          ] do
        assert CSP.stamp_styles(before <> "<style>a{}</style>", "n0nce") ==
                 before <> ~s(<style nonce="n0nce">a{}</style>)
      end
    end

    # In each of the next two, a browser reads `<style href=…>` as attributes of
    # the <link>: a nonce written there would be the link's.
    @link ~s|<link z='">' <style href=//e/a.css>|

    # `<!x`, `<?` and the like are comments to a browser, ended by the first >.
    test "ends a bogus comment at the first >, quotes or not" do
      for opener <- [
            ~s(<!x a=">),
            ~s(<?x a=">),
            ~s(</ a=">),
            ~s(</1 a=">),
            ~s(<!DOCTYPE a=">),
            ~s(<![CDATA[ a=">)
          ] do
        assert CSP.stamp_styles(opener <> @link, "n0nce") == opener <> @link

        assert CSP.stamp_styles(opener <> "<style>a{}</style>", "n0nce") ==
                 opener <> ~s(<style nonce="n0nce">a{}</style>)
      end

      single = ~s(<!x a='>) <> ~s|<link z="'>" <style href=//e/a.css>|
      assert CSP.stamp_styles(single, "n0nce") == single
    end

    # A = where a name begins is part of the name, and so is a quote after it.
    test "opens a quoted value only where a tag has a value" do
      for tag <- [
            ~s(<a =">),
            ~s(<a=">),
            ~s(<a/=">),
            ~s(<a b="1"=">),
            ~s(</a =">)
          ] do
        assert CSP.stamp_styles(tag <> @link, "n0nce") == tag <> @link
      end

      # The same in a raw-text element's tag, which must still end at its >.
      before = ~s(<textarea =">x</textarea><i q='">'></i>)

      assert CSP.stamp_styles(before <> "<style>a{}</style>", "n0nce") ==
               before <> ~s(<style nonce="n0nce">a{}</style>)
    end

    # A browser drops a tag whose quoted value is never closed, all it holds
    # included.
    test "reads an unclosed quoted value to the end" do
      for html <- [~s(<a x="><style>a{}</style>), ~s(<xmp x='><style></style>)] do
        assert CSP.stamp_styles(html, "n0nce") == html
      end
    end

    test "copes with an unclosed tag or quote after a <style>" do
      for rest <- ["<a", ~s(<a x="abc), "<a x='abc>", "<textarea>", "</"] do
        assert CSP.stamp_styles("<style></style>" <> rest, "n0nce") ==
                 ~s(<style nonce="n0nce"></style>) <> rest
      end
    end

    test "leaves the text of a <style> as it was" do
      assert CSP.stamp_styles(~s|<style>a::after{content:"<style>"}</style>|, "n0nce") ==
               ~s|<style nonce="n0nce">a::after{content:"<style>"}</style>|
    end

    # A stray quote or comment opener must not swallow the styles after it.
    test "still reaches a <style> after sloppy markup" do
      for before <- [
            "<p class=it's>x</p>",
            "<!-->",
            "<!--->",
            "<!-- c --!>",
            ~s(<!DOCTYPE html><?xml version="1.0"?>),
            "<p>1 < 2, don't</p>"
          ] do
        assert CSP.stamp_styles(before <> "<style>a{}</style><p>'</p>", "n0nce") ==
                 before <> ~s(<style nonce="n0nce">a{}</style><p>'</p>)
      end
    end

    test "takes only HTML's whitespace as the end of a tag name" do
      # A vertical tab is part of the name to a browser: not a <style>.
      assert CSP.stamp_styles("<style\v>a{}</style>", "n0nce") == "<style\v>a{}</style>"

      for space <- [" ", "\t", "\n", "\f", "\r"] do
        assert CSP.stamp_styles("<style#{space}>a{}</style>", "n0nce") ==
                 ~s(<style nonce="n0nce"#{space}>a{}</style>)
      end
    end

    test "does not take part of an unquoted value for a nonce" do
      assert CSP.stamp_styles("<style media=/nonce/x>a{}</style>", "n0nce") ==
               ~s(<style nonce="n0nce" media=/nonce/x>a{}</style>)
    end

    # As in a browser, what is not closed runs to the end of the document.
    test "reads what is cut off at the end as a browser does" do
      for html <- [
            "<!-- <style>a{}</style>",
            "<!-- x> <style>a{}</style>",
            "<!--[if mso]> <style>a{}</style>",
            "<style",
            "<style ",
            ~s(<style media="print"),
            "<p><style media=print"
          ] do
        assert CSP.stamp_styles(html, "n0nce") == html
      end

      assert CSP.stamp_styles("<style>a{}", "n0nce") == ~s(<style nonce="n0nce">a{})
    end

    test "stamps large messages" do
      big = String.duplicate("a", 1_000_000)

      for before <- [
            "<!--#{big}-->",
            ~s(<img src="data:image/png;base64,#{big}">),
            "<style>#{big}</style>"
          ] do
        assert CSP.stamp_styles(before <> "<style>b{}</style>", "n0nce") =~
                 ~s(<style nonce="n0nce">b{}</style>)
      end
    end

    # Runs in the editor on every preview change, on text with no size limit. Each
    # of these takes seconds when every opener is tried to the end of the input
    # and given up: the time grows with the square of the size. The bound is far
    # above the milliseconds a linear reading takes, for a slow machine.
    test "reads hostile input in linear time" do
      for {name, html} <- [
            unmatched_quote: String.duplicate("<style ", 5_000) <> ~s(">),
            tags: String.duplicate("<a", 8_000) <> ~s( x=">"),
            comments: String.duplicate("<!-- a>", 5_000),
            conditional_comments: String.duplicate("<!--[if mso]>", 4_000),
            bogus_comments: String.duplicate("<!x", 8_000),
            quotes: String.duplicate(~s(<a x=">), 5_000),
            stray_equals: "<a " <> String.duplicate(~s(=" ), 10_000)
          ] do
        {microseconds, _stamped} = :timer.tc(fn -> CSP.stamp_styles(html, "n0nce") end)

        assert microseconds < 2_000_000, "#{name}: #{div(microseconds, 1000)} ms"
      end
    end

    test "escapes the nonce into the attribute" do
      assert CSP.stamp_styles("<style>", ~s(a"b)) == ~s(<style nonce="a&quot;b">)
    end

    test "leaves the HTML as it is without a nonce" do
      html = "<style>a{}</style>"

      assert CSP.stamp_styles(html, nil) == html
      assert CSP.stamp_styles(html, "") == html
      assert CSP.stamp_styles(html) == html
    end
  end
end
