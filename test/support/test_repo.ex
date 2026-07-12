defmodule PhoenixKitNewsletters.Test.Repo do
  use Ecto.Repo,
    otp_app: :phoenix_kit_newsletters,
    adapter: Ecto.Adapters.Postgres
end
