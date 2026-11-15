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

    # Comma-separated, as the page reads them: repeated `roles[]` keys would not
    # survive the page's own patches.
    test "encodes scalars, and a list of roles as one comma-separated value" do
      path =
        Paths.verification_index(%{"source" => "user_group", "roles" => ["a", "b"], "page" => 2})

      query = path |> URI.parse() |> Map.fetch!(:query) |> Query.decode()

      assert query == %{"source" => "user_group", "roles" => "a,b", "page" => "2"}
    end

    test "leaves out an empty list of roles" do
      assert Paths.verification_index(%{"source" => "user_group", "roles" => []}) =~
               ~r{\?source=user_group$}
    end
  end
end
