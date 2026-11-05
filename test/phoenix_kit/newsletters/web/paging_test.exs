defmodule PhoenixKit.Newsletters.Web.PagingTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Newsletters.Web.Paging

  test "total_pages/1 is never less than one" do
    assert Paging.total_pages(0) == 1
    assert Paging.total_pages(50) == 1
    assert Paging.total_pages(51) == 2
  end

  test "resolve/2 gives the page and where it starts" do
    assert Paging.resolve("2", 120) == {2, 50}
    assert Paging.resolve(nil, 120) == {1, 0}
  end

  test "resolve/2 lands on a real page whatever the URL says" do
    assert Paging.resolve("99", 120) == {3, 100}

    for param <- ["0", "-1", "abc", "2x", "", 7, %{}] do
      assert Paging.resolve(param, 120) == {1, 0}
    end
  end
end
