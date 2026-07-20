defmodule PhoenixKit.Newsletters.BroadcastTest do
  @moduledoc """
  Changeset tests for the Stage-4 recipient sources (`source_type` /
  `crm_list_uuid` / `source_params`). Pure changeset validation — no DB
  needed.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Newsletters.Broadcast

  describe "changeset/2 — source_type defaults and requirements" do
    test "defaults to newsletters_list and requires list_uuid" do
      changeset = Broadcast.changeset(%Broadcast{}, %{subject: "Hi"})

      refute changeset.valid?
      assert %{list_uuid: ["can't be blank"]} = errors_on(changeset)
      assert Ecto.Changeset.get_field(changeset, :source_type) == "newsletters_list"
    end

    test "newsletters_list source is valid with a list_uuid" do
      changeset =
        Broadcast.changeset(%Broadcast{}, %{subject: "Hi", list_uuid: Ecto.UUID.generate()})

      assert changeset.valid?
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
          list_uuid: Ecto.UUID.generate(),
          source_type: "bogus"
        })

      refute changeset.valid?
      assert %{source_type: ["is invalid"]} = errors_on(changeset)
    end

    test "user_group source requires at least one role name, not list_uuid/crm_list_uuid" do
      changeset = Broadcast.changeset(%Broadcast{}, %{subject: "Hi", source_type: "user_group"})

      refute changeset.valid?
      assert %{source_params: ["select at least one role"]} = errors_on(changeset)
    end

    test "user_group source is invalid with an empty role_names list" do
      changeset =
        Broadcast.changeset(%Broadcast{}, %{
          subject: "Hi",
          source_type: "user_group",
          source_params: %{"role_names" => []}
        })

      refute changeset.valid?
      assert %{source_params: ["select at least one role"]} = errors_on(changeset)
    end

    test "user_group source is valid with at least one role name and no list_uuid/crm_list_uuid" do
      changeset =
        Broadcast.changeset(%Broadcast{}, %{
          subject: "Hi",
          source_type: "user_group",
          source_params: %{"role_names" => ["Admin"]}
        })

      assert changeset.valid?
    end
  end

  describe "role_names/1" do
    test "reads role_names out of a %Broadcast{}'s source_params" do
      broadcast = %Broadcast{source_params: %{"role_names" => ["Admin", "SupportAgent"]}}
      assert Broadcast.role_names(broadcast) == ["Admin", "SupportAgent"]
    end

    test "reads role_names out of a plain source_params map" do
      assert Broadcast.role_names(%{"role_names" => ["User"]}) == ["User"]
    end

    test "is [] for nil, an empty map, or a map without the key" do
      assert Broadcast.role_names(nil) == []
      assert Broadcast.role_names(%{}) == []
      assert Broadcast.role_names(%{"other_key" => "x"}) == []
    end
  end

  test "valid_source_types/0 lists all three sources" do
    assert Broadcast.valid_source_types() == ["newsletters_list", "crm_list", "user_group"]
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
