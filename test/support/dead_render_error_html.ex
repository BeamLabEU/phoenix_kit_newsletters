defmodule PhoenixKitNewsletters.Test.DeadRenderErrorHTML do
  @moduledoc """
  Error pages for the test endpoint. Phoenix renders the 500 page before it
  re-raises a request's exception, so without a module that can render one
  a failing request shows "no 500 template" instead of the real error.
  """

  def render(template, _assigns), do: template
end
