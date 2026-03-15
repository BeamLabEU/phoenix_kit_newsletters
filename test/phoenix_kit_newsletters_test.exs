defmodule PhoenixKitNewslettersTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Newsletters

  test "module_key returns newsletters" do
    assert Newsletters.module_key() == "newsletters"
  end

  test "module_name returns Newsletters" do
    assert Newsletters.module_name() == "Newsletters"
  end

  test "required_modules includes emails" do
    assert "emails" in Newsletters.required_modules()
  end

  test "permission_metadata key matches module_key" do
    assert Newsletters.permission_metadata().key == Newsletters.module_key()
  end

  test "admin_tabs returns list of Tab structs" do
    tabs = Newsletters.admin_tabs()
    assert is_list(tabs)
    assert tabs != []
  end

  test "admin tab IDs are namespaced with admin_newsletters" do
    for tab <- Newsletters.admin_tabs() do
      assert tab.id |> to_string() |> String.starts_with?("admin_newsletters"),
             "Tab #{inspect(tab.id)} is not namespaced"
    end
  end

  test "admin tab paths use hyphens not underscores" do
    for tab <- Newsletters.admin_tabs() do
      path = tab.path || ""
      # Only check the static part (before :id params)
      static_part = path |> String.split(":") |> List.first()

      refute String.contains?(static_part, "_"),
             "Tab path #{path} uses underscores — use hyphens"
    end
  end

  test "enabled? returns false when DB unavailable" do
    # Rescues when no DB is running in test
    refute Newsletters.enabled?()
  end

  test "route_module is defined" do
    assert Newsletters.route_module() == PhoenixKit.Modules.Newsletters.Web.Routes
  end

  test "visible tabs have live_view set" do
    for tab <- Newsletters.admin_tabs(), tab.visible != false do
      assert tab.live_view != nil,
             "Visible tab #{inspect(tab.id)} has no live_view — auto-routing won't work"
    end
  end
end
