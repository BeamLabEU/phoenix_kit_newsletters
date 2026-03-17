defmodule PhoenixKitNewslettersTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Newsletters

  describe "behaviour implementation" do
    test "implements PhoenixKit.Module" do
      behaviours =
        Newsletters.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert PhoenixKit.Module in behaviours
    end

    test "has @phoenix_kit_module attribute for auto-discovery" do
      attrs = Newsletters.__info__(:attributes)
      assert Keyword.get(attrs, :phoenix_kit_module) == [true]
    end
  end

  describe "required callbacks" do
    test "module_key/0 returns a non-empty string" do
      key = Newsletters.module_key()
      assert is_binary(key)
      assert key != ""
    end

    test "module_name/0 returns a non-empty string" do
      name = Newsletters.module_name()
      assert is_binary(name)
      assert name != ""
    end

    test "enabled?/0 returns a boolean" do
      assert is_boolean(Newsletters.enabled?())
    end

    test "enable_system/0 is exported" do
      assert function_exported?(Newsletters, :enable_system, 0)
    end

    test "disable_system/0 is exported" do
      assert function_exported?(Newsletters, :disable_system, 0)
    end

    test "required_modules includes emails" do
      assert "emails" in Newsletters.required_modules()
    end
  end

  describe "permission_metadata/0" do
    test "returns a map with required fields" do
      meta = Newsletters.permission_metadata()
      assert is_map(meta)
      assert Map.has_key?(meta, :key)
      assert Map.has_key?(meta, :label)
      assert Map.has_key?(meta, :icon)
      assert Map.has_key?(meta, :description)
    end

    test "key matches module_key" do
      assert Newsletters.permission_metadata().key == Newsletters.module_key()
    end

    test "icon uses hero- prefix" do
      icon = Newsletters.permission_metadata().icon
      assert String.starts_with?(icon, "hero-")
    end
  end

  describe "admin_tabs/0" do
    test "returns a list of Tab structs" do
      assert [_ | _] = Newsletters.admin_tabs()
    end

    test "admin_tabs returns a non-empty list" do
      assert [_ | _] = Newsletters.admin_tabs()
    end

    test "admin_tabs contains expected tab IDs" do
      tab_ids = Newsletters.admin_tabs() |> Enum.map(& &1.id)
      assert :admin_newsletters in tab_ids
      assert :admin_newsletters_broadcasts in tab_ids
      assert :admin_newsletters_lists in tab_ids
    end

    test "first tab has id :admin_newsletters" do
      first = hd(Newsletters.admin_tabs())
      assert first.id == :admin_newsletters
    end

    test "first tab has correct label" do
      first = hd(Newsletters.admin_tabs())
      assert first.label == "Newsletters"
    end

    test "first tab is a navigation section without live_view" do
      first = hd(Newsletters.admin_tabs())
      assert first.live_view == nil
    end

    test "admin tab IDs are namespaced with admin_newsletters" do
      for tab <- Newsletters.admin_tabs() do
        assert tab.id |> to_string() |> String.starts_with?("admin_newsletters"),
               "Tab #{inspect(tab.id)} is not namespaced"
      end
    end

    test "visible child tabs have live_view set" do
      [_parent | children] = Newsletters.admin_tabs()

      for tab <- children, tab.visible != false do
        assert tab.live_view != nil,
               "Visible tab #{inspect(tab.id)} has no live_view — auto-routing won't work"
      end
    end

    test "tab paths use hyphens not underscores" do
      for tab <- Newsletters.admin_tabs() do
        path = tab.path || ""
        static_part = path |> String.split(":") |> List.first()

        refute String.contains?(static_part, "_"),
               "Tab path #{path} uses underscores — use hyphens"
      end
    end
  end

  describe "version/0" do
    test "returns a version string" do
      version = Newsletters.version()
      assert is_binary(version)
      assert version =~ ~r/^\d+\.\d+\.\d+/
    end

    test "version/0 returns a valid semver string" do
      version = Newsletters.version()
      assert is_binary(version)
      assert String.match?(version, ~r/^\d+\.\d+\.\d+/)
    end
  end

  describe "optional callbacks have defaults" do
    test "get_config/0 returns a map" do
      config = Newsletters.get_config()
      assert is_map(config)
    end

    test "get_config/0 map has :enabled field" do
      config = Newsletters.get_config()
      assert Map.has_key?(config, :enabled)
    end

    test "settings_tabs/0 returns empty list" do
      assert Newsletters.settings_tabs() == []
    end

    test "user_dashboard_tabs/0 returns empty list" do
      assert Newsletters.user_dashboard_tabs() == []
    end

    test "children/0 returns empty list" do
      assert Newsletters.children() == []
    end

    test "route_module/0 returns Newsletters.Web.Routes" do
      assert Newsletters.route_module() == PhoenixKit.Newsletters.Web.Routes
    end
  end

  describe "enabled?" do
    test "returns false when DB unavailable" do
      refute Newsletters.enabled?()
    end
  end
end
