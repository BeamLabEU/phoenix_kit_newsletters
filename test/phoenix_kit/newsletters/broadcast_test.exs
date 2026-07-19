defmodule PhoenixKit.Newsletters.BroadcastTest do
  @moduledoc """
  Changeset tests for the Stage-4 CRM list source (`source_type` /
  `crm_list_uuid`). Pure changeset validation — no DB needed.
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
  end

  test "valid_source_types/0 lists both sources" do
    assert Broadcast.valid_source_types() == ["newsletters_list", "crm_list"]
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
