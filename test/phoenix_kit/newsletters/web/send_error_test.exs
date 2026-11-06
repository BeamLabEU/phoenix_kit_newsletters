defmodule PhoenixKit.Newsletters.Web.SendErrorTest do
  @moduledoc """
  Pins the operator-facing rendering of `Broadcaster.send/1`'s refusals —
  the mapping both the editor's "Send now" and the details page's "Retry
  send" share, so neither can drift back to leaking a raw Elixir term.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Newsletters.Web.SendError

  test "an inactive CRM list names the status that blocked the send" do
    assert SendError.message({:crm_list_not_active, "archived"}) ==
             "Cannot send: the CRM list is archived, not active."
  end

  test "a status the send path refuses is rendered as a sentence" do
    assert SendError.message({:invalid_status, "sent"}) ==
             "Cannot send a broadcast with status Sent."
  end

  test "a translated sentence does not end in a raw status" do
    Gettext.with_locale(PhoenixKit.Newsletters.Gettext, "ru", fn ->
      refute SendError.message({:invalid_status, "sending"}) =~ "sending"
      refute SendError.message({:crm_list_not_active, "archived"}) =~ "archived"
    end)
  end

  test "an audience with nobody in it, and a body with nothing in it, are sentences too" do
    assert SendError.message(:no_recipients) =~ "Nobody in this audience"
    assert SendError.message(:blank_body) =~ "body"
  end

  test "a resend with nothing left to send says so" do
    assert SendError.message(:nothing_to_resend) == "There are no failed deliveries to resend."
  end

  test "an unmapped reason stays diagnosable rather than silently generic" do
    assert SendError.message({:some_future_reason, %{detail: 1}}) ==
             "Failed to send: {:some_future_reason, %{detail: 1}}"
  end
end
