defmodule PhoenixKit.Newsletters.Web.StatusLabel do
  @moduledoc """
  A broadcast's status as an operator reads it, for every page and message that
  shows one. A status with no label here stays as it is.
  """

  use Gettext, backend: PhoenixKit.Newsletters.Gettext

  @spec broadcast(String.t()) :: String.t()
  def broadcast("draft"), do: gettext("Draft")
  def broadcast("scheduled"), do: gettext("Scheduled")
  def broadcast("sending"), do: gettext("Sending")
  def broadcast("sent"), do: gettext("Sent")
  def broadcast("cancelled"), do: gettext("Cancelled")
  def broadcast("failed"), do: gettext("Failed")
  def broadcast(other), do: other
end
