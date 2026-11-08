defmodule PhoenixKit.Newsletters.Web.StatusLabel do
  @moduledoc """
  A broadcast's status as an operator reads it, for every page and message that
  shows one, and the badge colour it is shown in. A status with no label here
  stays as it is.
  """

  use Gettext, backend: PhoenixKit.Newsletters.Gettext

  @spec broadcast(String.t()) :: String.t()
  def broadcast("draft"), do: gettext("Draft")
  def broadcast("scheduled"), do: gettext("Scheduled")
  def broadcast("sending"), do: gettext("Sending")
  # A context of its own: a broadcast is sent (ru "Отправлен") where a delivery,
  # and the counters, say sent of a message (ru "Отправлено").
  def broadcast("sent"), do: pgettext("broadcast status", "Sent")
  def broadcast("cancelled"), do: gettext("Cancelled")
  def broadcast("failed"), do: gettext("Failed")
  def broadcast(other), do: other

  @doc "The daisyUI badge modifier a broadcast's status is shown with, on every page."
  @spec broadcast_badge_class(String.t()) :: String.t()
  def broadcast_badge_class("scheduled"), do: "badge-info"
  def broadcast_badge_class("sending"), do: "badge-warning"
  def broadcast_badge_class("sent"), do: "badge-success"
  def broadcast_badge_class(status) when status in ["cancelled", "failed"], do: "badge-error"
  def broadcast_badge_class(_draft_or_other), do: "badge-ghost"
end
