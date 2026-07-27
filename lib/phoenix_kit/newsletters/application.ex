defmodule PhoenixKit.Newsletters.Application do
  @moduledoc """
  Supervision tree for the newsletters package.

  The package is otherwise a pure library — it borrows the host app's Repo,
  Mailer, Endpoint and Oban instance and starts nothing of its own. The one
  thing it does need a process for is
  `PhoenixKit.Newsletters.AttachmentCache`: an ETS table dies with its
  owner, so a cache meant to be shared across short-lived Oban job
  processes needs an owner that outlives them. See that module for the full
  rationale.

  Started automatically — `mix.exs` declares this as the application's
  `:mod`, so a host app gets it by depending on the package; there is
  nothing to add to the host's own supervision tree.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [PhoenixKit.Newsletters.AttachmentCache]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: PhoenixKit.Newsletters.Supervisor
    )
  end
end
