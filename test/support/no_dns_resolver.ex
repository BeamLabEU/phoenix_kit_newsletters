if Code.ensure_loaded?(PhoenixKit.Modules.Emails.Verification.Resolver) do
  defmodule PhoenixKitNewsletters.Test.NoDnsResolver do
    @moduledoc """
    A `Verification.Resolver` that never touches the network, wired in by
    `config/test.exs` so a real-engine test cannot reach live DNS. Every domain
    has one mail host, except those whose name starts with `nomx`, which do not
    exist.
    """

    @behaviour PhoenixKit.Modules.Emails.Verification.Resolver

    @impl true
    def lookup_mx("nomx" <> _, _timeout), do: {:error, :nxdomain}
    def lookup_mx(domain, _timeout), do: {:ok, [%{host: "mx." <> domain, pref: 10}]}

    @impl true
    def lookup_addresses(_domain, _timeout), do: {:error, :nxdomain}
  end
end
