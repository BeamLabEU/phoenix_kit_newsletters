defmodule PhoenixKit.Newsletters.LayoutsTest do
  use PhoenixKitNewsletters.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Layout
  alias PhoenixKit.Newsletters.Layouts
  alias PhoenixKit.Settings
  alias PhoenixKitNewsletters.Test.Repo

  defp create(name, status \\ "active") do
    {:ok, layout} =
      Layouts.create_layout(%{
        "name" => name,
        "status" => status,
        "html_body" => %{"en" => "{{{content}}}"},
        "display_name" => %{"en" => String.capitalize(name)}
      })

    layout
  end

  test "create, list by status, get" do
    a = create("a_layout")
    b = create("b_layout", "archived")

    assert Enum.map(Layouts.list_layouts(), & &1.uuid) == [a.uuid, b.uuid]
    assert Enum.map(Layouts.list_layouts(status: "active"), & &1.uuid) == [a.uuid]
    assert Enum.map(Layouts.list_layouts(status: "archived"), & &1.uuid) == [b.uuid]
    assert Layouts.get_layout(a.uuid).name == "a_layout"
    assert Layouts.get_layout("not-a-uuid") == nil
    assert Layouts.get_layout(nil) == nil
  end

  test "names are unique" do
    create("same_name")

    assert {:error, changeset} =
             Layouts.create_layout(%{
               "name" => "same_name",
               "html_body" => %{"en" => "{{{content}}}"}
             })

    assert %{name: [_]} = errors_on(changeset)
  end

  test "the author comes from the option, never from attrs" do
    author = Ecto.UUID.generate()

    {:ok, layout} =
      Layouts.create_layout(
        %{
          "name" => "authored",
          "html_body" => %{"en" => "{{{content}}}"},
          "created_by_user_uuid" => Ecto.UUID.generate(),
          "metadata" => %{"email_is_system" => true}
        },
        created_by_user_uuid: nil
      )

    assert layout.created_by_user_uuid == nil
    assert layout.metadata == %{}

    changeset =
      Layout.changeset(%Layout{created_by_user_uuid: author}, %{
        "name" => "x",
        "html_body" => %{"en" => "{{{content}}}"}
      })

    assert Ecto.Changeset.get_field(changeset, :created_by_user_uuid) == author
  end

  test "update keeps the language maps whole" do
    layout = create("maps_layout")

    {:ok, updated} =
      Layouts.update_layout(layout, %{
        "html_body" => %{"en" => "{{{content}}}", "de" => "<div>{{{content}}}</div>"}
      })

    assert updated.html_body == %{"en" => "{{{content}}}", "de" => "<div>{{{content}}}</div>"}
  end

  describe "the default layout (newsletters_default_template)" do
    test "set, read back, cleared" do
      layout = create("default_layout")

      assert Layouts.default_layout_uuid() == nil
      assert :ok = Layouts.set_default_layout(layout)
      assert Settings.get_setting("newsletters_default_template") == layout.uuid
      assert Layouts.default_layout_uuid() == layout.uuid

      assert :ok = Layouts.set_default_layout(nil)
      assert Layouts.default_layout_uuid() == nil
    end

    test "only an active layout can be the default" do
      archived = create("archived_layout", "archived")
      assert {:error, :not_active} = Layouts.set_default_layout(archived)
      assert {:error, :not_active} = Layouts.set_default_layout(Ecto.UUID.generate())
    end

    test "a value written before the move still reads, by uuid" do
      layout = create("carried_over")
      Settings.update_setting("newsletters_default_template", layout.uuid)
      assert Layouts.default_layout_uuid() == layout.uuid
    end

    test "a stale value (a system email's uuid) reads as no default" do
      Settings.update_setting("newsletters_default_template", Ecto.UUID.generate())
      assert Layouts.default_layout_uuid() == nil
    end

    test "archiving the default clears it; restore does not bring it back" do
      layout = create("going_away")
      :ok = Layouts.set_default_layout(layout)

      {:ok, archived} = Layouts.archive_layout(layout)
      assert archived.status == "archived"
      assert Layouts.default_layout_uuid() == nil

      {:ok, restored} = Layouts.restore_layout(archived)
      assert restored.status == "active"
      assert Layouts.default_layout_uuid() == nil
    end
  end

  describe "a carried-over system email" do
    # As V2 writes one: metadata is never cast, so it goes in directly.
    defp system_layout do
      Repo.insert!(%Layout{
        name: "test_email",
        status: "archived",
        html_body: %{"en" => "<p>A core email, no body placeholder</p>"},
        metadata: %{"email_is_system" => true}
      })
    end

    defp make_active_behind_changeset(layout) do
      Repo.update_all(from(l in Layout, where: l.uuid == ^layout.uuid), set: [status: "active"])
      Layouts.get_layout(layout.uuid)
    end

    test "cannot be restored" do
      layout = system_layout()
      assert {:error, :system_email} = Layouts.restore_layout(layout)
      assert Layouts.get_layout(layout.uuid).status == "archived"
    end

    test "cannot be the default, and a setting naming it reads as no default" do
      layout = system_layout()
      assert {:error, :not_active} = Layouts.set_default_layout(layout)

      Settings.update_setting("newsletters_default_template", layout.uuid)
      assert Layouts.default_layout_uuid() == nil
    end

    test "is never the default, even if its row were made active behind the changeset" do
      layout = system_layout() |> make_active_behind_changeset()
      assert layout.status == "active"

      # Refused by set_default_layout/1 itself, not only by the archived clause…
      assert {:error, :not_active} = Layouts.set_default_layout(layout)
      assert {:error, :not_active} = Layouts.set_default_layout(layout.uuid)
      assert Settings.get_setting("newsletters_default_template") in [nil, ""]

      # …and ignored if a setting names it anyway.
      Settings.update_setting("newsletters_default_template", layout.uuid)
      assert Layouts.default_layout_uuid() == nil
    end

    test "attrs cannot drop the system flag and then restore it in a second update" do
      layout = system_layout()

      {:ok, updated} =
        Layouts.update_layout(layout, %{"metadata" => %{}, "display_name" => %{"en" => "Test"}})

      assert updated.metadata == %{"email_is_system" => true}
      assert {:error, :system_email} = Layouts.restore_layout(updated)
      assert {:error, _changeset} = Layouts.update_layout(updated, %{"status" => "active"})
    end

    test "stays editable although no language places the body" do
      layout = system_layout()
      assert {:ok, _} = Layouts.update_layout(layout, %{"display_name" => %{"en" => "Test"}})
    end

    test "is not offered to new broadcasts" do
      layout = system_layout()
      refute layout.uuid in Enum.map(Layouts.list_layouts(status: "active"), & &1.uuid)
    end
  end

  test "a setting naming an archived layout reads as no default" do
    layout = create("archived_default", "archived")
    Settings.update_setting("newsletters_default_template", layout.uuid)
    assert Layouts.default_layout_uuid() == nil
  end

  test "an archived layout still renders for the broadcast that uses it" do
    layout = create("in_use")

    {:ok, broadcast} =
      Newsletters.create_broadcast(%{
        subject: "Uses it",
        source_type: "user_group",
        source_params: %{"role_uuids" => [Ecto.UUID.generate()]},
        template_uuid: layout.uuid
      })

    {:ok, _} = Layouts.archive_layout(layout)

    assert %Layout{status: "archived"} =
             Newsletters.get_broadcast_with_template!(broadcast.uuid).template
  end

  test "a broadcast cannot point at something that is not a layout" do
    assert {:error, changeset} =
             Newsletters.create_broadcast(%{
               subject: "Bad ref",
               source_type: "user_group",
               source_params: %{"role_uuids" => [Ecto.UUID.generate()]},
               template_uuid: Ecto.UUID.generate()
             })

    assert %{template_uuid: [_]} = errors_on(changeset)
  end
end
