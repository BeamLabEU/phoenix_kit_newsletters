defmodule PhoenixKit.Newsletters.Web.SendError do
  @moduledoc """
  Renders the error reasons of `PhoenixKit.Newsletters.Broadcaster.send/1` and
  `resend_failed/1` as operator-facing sentences.

  Shared by every surface that calls them — the editor's "Send now" and the
  details page's "Retry send" and "Resend failed deliveries" — so the same
  refusal can't read as a sentence on one page and as a raw Elixir term on
  another.
  """

  use Gettext, backend: PhoenixKit.Newsletters.Gettext

  alias PhoenixKit.Newsletters.Web.FormErrors

  @doc """
  A localized message for a `Broadcaster.send/1` or `resend_failed/1` reason.

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

  def message(:not_found), do: gettext("Broadcast not found")

  def message(:nothing_to_resend), do: gettext("There are no failed deliveries to resend.")

  def message(%Ecto.Changeset{} = changeset) do
    gettext("Validation failed: %{errors}", errors: FormErrors.summary(changeset))
  end

  def message(reason) do
    gettext("Failed to send: %{reason}", reason: inspect(reason))
  end
end
