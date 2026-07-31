defmodule PhoenixKit.Newsletters.Web.SendError do
  @moduledoc """
  Renders `PhoenixKit.Newsletters.Broadcaster.send/1`'s error reasons as
  operator-facing sentences.

  Shared by both surfaces that call `send/1` — the editor's "Send now" and
  the details page's "Retry send" — so the same refusal can't read as a
  sentence on one page and as a raw Elixir term on the other.
  """

  use Gettext, backend: PhoenixKit.Newsletters.Gettext

  @doc """
  A localized message for a `Broadcaster.send/1` reason.

  The catch-all keeps `inspect/1` so an unmapped reason stays diagnosable
  rather than silently generic.
  """
  @spec message(term()) :: String.t()
  def message({:crm_list_not_active, status}) do
    gettext("Cannot send: the CRM list is %{status}, not active.", status: status)
  end

  def message({:invalid_status, status}) do
    gettext("Cannot send a broadcast with status %{status}.", status: status)
  end

  def message(reason) do
    gettext("Failed to send: %{reason}", reason: inspect(reason))
  end
end
