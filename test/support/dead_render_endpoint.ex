defmodule PhoenixKitNewsletters.Test.DeadRenderEndpoint do
  @moduledoc """
  The smallest endpoint that lets `Phoenix.ConnTest` drive a real request
  through `DeadRenderRouter`. Started by `test_helper.exs`; configured in
  `config/test.exs`. It never listens on a port (`server: false`).
  """

  use Phoenix.Endpoint, otp_app: :phoenix_kit_newsletters

  plug(Plug.Session,
    store: :cookie,
    key: "_newsletters_test_key",
    signing_salt: "newsletters_test_session"
  )

  plug(PhoenixKitNewsletters.Test.DeadRenderRouter)
end
