defmodule PhoenixKit.Newsletters.BroadcastTest do
  @moduledoc """
  Changeset tests for the Stage-4 recipient sources (`source_type` /
  `crm_list_uuid` / `source_params`). Pure changeset validation — no DB
  needed.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Newsletters.Broadcast

  describe "changeset/2 — source_type defaults and requirements" do
    test "defaults to crm_list and requires crm_list_uuid" do
      changeset = Broadcast.changeset(%Broadcast{}, %{subject: "Hi"})

      refute changeset.valid?
      assert %{crm_list_uuid: ["can't be blank"]} = errors_on(changeset)
      assert Ecto.Changeset.get_field(changeset, :source_type) == "crm_list"
    end

    test "crm_list source requires crm_list_uuid, not list_uuid" do
      changeset = Broadcast.changeset(%Broadcast{}, %{subject: "Hi", source_type: "crm_list"})

      refute changeset.valid?
      assert %{crm_list_uuid: ["can't be blank"]} = errors_on(changeset)
    end

    test "crm_list source is valid with a crm_list_uuid and no list_uuid" do
      changeset =
        Broadcast.changeset(%Broadcast{}, %{
          subject: "Hi",
          source_type: "crm_list",
          crm_list_uuid: Ecto.UUID.generate()
        })

      assert changeset.valid?
    end

    test "rejects an unknown source_type" do
      changeset =
        Broadcast.changeset(%Broadcast{}, %{
          subject: "Hi",
          source_type: "bogus"
        })

      refute changeset.valid?
      assert %{source_type: ["is invalid"]} = errors_on(changeset)
    end

    test "user_group source requires at least one role uuid, not list_uuid/crm_list_uuid" do
      changeset = Broadcast.changeset(%Broadcast{}, %{subject: "Hi", source_type: "user_group"})

      refute changeset.valid?
      assert %{source_params: ["select at least one role"]} = errors_on(changeset)
    end

    test "user_group source is invalid with an empty role_uuids list" do
      changeset =
        Broadcast.changeset(%Broadcast{}, %{
          subject: "Hi",
          source_type: "user_group",
          source_params: %{"role_uuids" => []}
        })

      refute changeset.valid?
      assert %{source_params: ["select at least one role"]} = errors_on(changeset)
    end

    test "user_group source is valid with at least one role uuid and no list_uuid/crm_list_uuid" do
      changeset =
        Broadcast.changeset(%Broadcast{}, %{
          subject: "Hi",
          source_type: "user_group",
          source_params: %{"role_uuids" => [Ecto.UUID.generate()]}
        })

      assert changeset.valid?
    end
  end

  describe "role_uuids/1" do
    test "reads role_uuids out of a %Broadcast{}'s source_params" do
      uuid_a = Ecto.UUID.generate()
      uuid_b = Ecto.UUID.generate()
      broadcast = %Broadcast{source_params: %{"role_uuids" => [uuid_a, uuid_b]}}
      assert Broadcast.role_uuids(broadcast) == [uuid_a, uuid_b]
    end

    test "reads role_uuids out of a plain source_params map" do
      uuid = Ecto.UUID.generate()
      assert Broadcast.role_uuids(%{"role_uuids" => [uuid]}) == [uuid]
    end

    test "is [] for nil, an empty map, or a map without the key" do
      assert Broadcast.role_uuids(nil) == []
      assert Broadcast.role_uuids(%{}) == []
      assert Broadcast.role_uuids(%{"other_key" => "x"}) == []
    end
  end

  describe "role_names_snapshot/1" do
    test "reads the snapshot out of a %Broadcast{}'s source_params, independent of role_uuids" do
      broadcast = %Broadcast{
        source_params: %{
          "role_uuids" => [Ecto.UUID.generate()],
          "role_names_snapshot" => ["Admin", "SupportAgent"]
        }
      }

      assert Broadcast.role_names_snapshot(broadcast) == ["Admin", "SupportAgent"]
    end

    test "is [] for nil, an empty map, or a map without the key" do
      assert Broadcast.role_names_snapshot(nil) == []
      assert Broadcast.role_names_snapshot(%{}) == []
      assert Broadcast.role_names_snapshot(%{"role_uuids" => [Ecto.UUID.generate()]}) == []
    end
  end

  test "valid_source_types/0 lists both sources" do
    assert Broadcast.valid_source_types() == ["crm_list", "user_group"]
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
