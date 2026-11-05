defmodule PhoenixKit.Newsletters.FileReferencesTest do
  @moduledoc """
  A broadcast's attachments against core's real orphan query: a file a broadcast
  will read at send time must not be handed to the delete job.
  """

  use PhoenixKitNewsletters.DataCase, async: false

  @moduletag :requires_v158

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Newsletters
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitNewsletters.Test.Repo

  defp create_file do
    {:ok, user} =
      %User{}
      |> User.guest_user_changeset(%{
        email: "owner-#{System.unique_integer([:positive])}@example.com"
      })
      |> Repo.insert()

    unique = System.unique_integer([:positive])

    {:ok, file} =
      Storage.create_file(%{
        original_file_name: "report.txt",
        file_name: "report-#{unique}.txt",
        mime_type: "text/plain",
        file_type: "document",
        ext: "txt",
        file_checksum: "sha256:#{unique}",
        user_file_checksum: "user-sha256:#{unique}",
        size: 5,
        status: "active",
        user_uuid: user.uuid
      })

    file
  end

  defp create_broadcast(attrs) do
    base = %{
      subject: "Hello",
      source_type: "user_group",
      source_params: %{"role_uuids" => [Ecto.UUID.generate()], "role_names_snapshot" => []}
    }

    {:ok, broadcast} = Newsletters.create_broadcast(Map.merge(base, attrs))
    broadcast
  end

  defp orphans(supplied) do
    query = Storage.orphaned_files_query(supplied)
    Repo.all(from(f in query, select: f.uuid))
  end

  test "core collects this module's references, with no error" do
    assert {:ok, [{"phoenix_kit_newsletters_broadcasts", _condition}]} =
             Map.fetch!(ModuleRegistry.all_file_references(), :phoenix_kit_newsletters)
  end

  test "an attached file is kept, and a loose one is still an orphan" do
    attached = create_file()
    loose = create_file()
    create_broadcast(%{attachments: [attached.uuid]})

    found = orphans(ModuleRegistry.all_file_references())

    refute attached.uuid in found
    assert loose.uuid in found
  end

  test "without the references the attached file would be taken for an orphan" do
    attached = create_file()
    create_broadcast(%{attachments: [attached.uuid]})

    assert attached.uuid in orphans(%{})
  end

  test "a sent broadcast's attachment is still referenced" do
    attached = create_file()
    create_broadcast(%{attachments: [attached.uuid], status: "sent"})

    refute attached.uuid in orphans(ModuleRegistry.all_file_references())
  end
end
