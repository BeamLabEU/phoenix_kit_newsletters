defmodule PhoenixKit.Newsletters.ContentTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Newsletters.Content

  describe "render_markdown/1" do
    test "converts markdown to HTML" do
      assert "<p>\nHello <strong>world</strong></p>\n" =
               Content.render_markdown("Hello **world**")
    end

    test "handles nil input" do
      assert "" = Content.render_markdown(nil)
    end

    test "handles empty string" do
      assert "" = Content.render_markdown("")
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
end
