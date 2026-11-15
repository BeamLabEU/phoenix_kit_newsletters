defmodule PhoenixKitNewsletters.Test.Users do
  @moduledoc """
  Accounts for role audiences. A role broadcast mails only confirmed accounts
  (`UserGroupSource`'s moduledoc), so a member a test means to reach must be one.
  """

  alias PhoenixKit.Users.Auth.User

  @doc "`User.guest_user_changeset/2` with the address already confirmed."
  @spec confirmed_guest_changeset(User.t(), map()) :: Ecto.Changeset.t()
  def confirmed_guest_changeset(%User{} = user, attrs) do
    user
    |> User.guest_user_changeset(attrs)
    |> Ecto.Changeset.put_change(:confirmed_at, DateTime.truncate(DateTime.utc_now(), :second))
  end
end
