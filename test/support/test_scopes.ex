defmodule PhoenixKitNewsletters.TestScopes do
  @moduledoc """
  Real `PhoenixKit.Users.Auth.Scope` structs for the admin LiveView tests.

  The pages check `newsletters.send`, `newsletters.audiences` and the CRM
  module's `crm` key through `Scope.can?/2`, which also asks whether the
  module behind each key is on — so a test that wants CRM lists calls
  `enable_crm/0` (the newsletters tests already call `enable_system/0`).
  """

  alias PhoenixKit.Users.Auth.Scope

  @all ~w(newsletters newsletters.send newsletters.audiences crm)

  @doc "A scope holding every key the admin pages check."
  def full_scope(user \\ nil), do: scope_with(@all, user)

  @doc "A scope holding exactly `permissions`."
  def scope_with(permissions, user \\ nil) do
    %Scope{
      user: user,
      authenticated?: true,
      cached_roles: [],
      cached_permissions: MapSet.new(permissions)
    }
  end

  @doc "Turns the CRM module on, so `Scope.can?(scope, \"crm\")` can hold."
  def enable_crm do
    {:ok, _} = PhoenixKit.Settings.update_boolean_setting("crm_enabled", true)
    :ok
  end
end
