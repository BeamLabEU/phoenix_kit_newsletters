defmodule PhoenixKit.Newsletters.PathsTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Newsletters.Paths
  alias Plug.Conn.Query

  describe "verification_index/1" do
    test "is the bare page without parameters" do
      assert Paths.verification_index() =~ ~r{/admin/newsletters/verification$}
    end

    test "drops blank values" do
      assert Paths.verification_index(%{"status" => "", "list" => nil, "roles" => []}) =~
               ~r{/verification$}
    end

    test "encodes scalars and lists" do
      path =
        Paths.verification_index(%{"source" => "user_group", "roles" => ["a", "b"], "page" => 2})

      query = path |> URI.parse() |> Map.fetch!(:query) |> Query.decode()

      assert query == %{"source" => "user_group", "roles" => ["a", "b"], "page" => "2"}
    end
  end
end
