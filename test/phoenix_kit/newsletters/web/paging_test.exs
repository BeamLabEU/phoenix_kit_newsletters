defmodule PhoenixKit.Newsletters.Web.PagingTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Newsletters.Web.Paging

  test "total_pages/2 is never less than one" do
    assert Paging.total_pages(0, 25) == 1
    assert Paging.total_pages(25, 25) == 1
    assert Paging.total_pages(26, 25) == 2
    assert Paging.total_pages(120, 50) == 3
  end

  test "resolve/3 gives the page and where it starts" do
    assert Paging.resolve(2, 120, 50) == {2, 50}
    assert Paging.resolve(3, 120, 10) == {3, 20}
  end

  test "resolve/3 lands on a real page past the end, or of an empty list" do
    assert Paging.resolve(99, 120, 50) == {3, 100}
    assert Paging.resolve(4, 0, 25) == {1, 0}
  end
end
