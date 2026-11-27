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

    test "never touches a <script>, a similar tag name or an inline style attribute" do
      html =
        ~s[<script>run()</script><script src="a.js"></script>] <>
          ~s[<styles></styles><style-guide></style-guide><p style="color:red">style</p>] <>
          ~s[&lt;style&gt;]

      assert CSP.stamp_styles(html, "n0nce") == html
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
