defmodule PhoenixKitNewsletters.DataCase do
  @moduledoc """
  Setup for tests that touch the database (via core phoenix_kit's
  Settings/Integrations, and the newsletters schemas themselves —
  backed by `PhoenixKitNewsletters.Test.Repo`).

  Mirrors core phoenix_kit's `PhoenixKit.DataCase` and
  `phoenix_kit_emails`'s `PhoenixKitEmails.DataCase`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import PhoenixKitNewsletters.DataCase, only: [errors_on: 1]

      @moduletag :integration
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitNewsletters.Test.Repo

  setup tags do
    pid = Sandbox.start_owner!(Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc """
  Transforms changeset errors into a map of messages, e.g.
  `%{name: ["can't be blank"]}` (standard Phoenix DataCase helper).
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
