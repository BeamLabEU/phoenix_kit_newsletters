defmodule PhoenixKit.Newsletters.ProviderOptionsTest do
  @moduledoc """
  Tests for per-provider send settings — the "Advanced" half of a send profile.

  These are pure (no DB), so the guarantees below hold in every run: chiefly
  that what we hand Swoosh matches the shape its adapters pattern-match on.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Newsletters.ProviderOptions

  describe "fields_for/1" do
    test "SES declares a configuration set and message tags" do
      keys = "aws_ses" |> ProviderOptions.fields_for() |> Enum.map(& &1.key)
      assert keys == ["configuration_set_name", "tags"]
    end

    test "Brevo declares a sender ID and tags" do
      keys = "brevo_api" |> ProviderOptions.fields_for() |> Enum.map(& &1.key)
      assert keys == ["sender_id", "tags"]
    end

    test "SMTP declares none — Swoosh's SMTP adapter reads no provider options" do
      assert ProviderOptions.fields_for("smtp") == []
    end

    test "an unknown provider returns [] rather than raising" do
      # A profile whose integration was deleted, or one pointing at a provider
      # registered by another module, must still render its common fields.
      assert ProviderOptions.fields_for("who_knows") == []
      assert ProviderOptions.fields_for(nil) == []
    end
  end

  describe "cast/2" do
    test "keeps only keys the provider declares" do
      # An SES-only key must not survive on a Brevo profile: it would otherwise
      # sit in JSONB waiting to be handed to an adapter that never asked for it.
      assert ProviderOptions.cast("brevo_api", %{
               "configuration_set_name" => "my-set",
               "sender_id" => "12"
             }) == %{"sender_id" => 12}
    end

    test "drops blanks instead of storing empty strings" do
      assert ProviderOptions.cast("aws_ses", %{"configuration_set_name" => "  "}) == %{}
    end

    test "parses an integer field, and drops it when it isn't one" do
      assert ProviderOptions.cast("brevo_api", %{"sender_id" => "12"}) == %{"sender_id" => 12}
      assert ProviderOptions.cast("brevo_api", %{"sender_id" => "twelve"}) == %{}
    end

    test "splits Brevo tags on commas" do
      assert ProviderOptions.cast("brevo_api", %{"tags" => "newsletter, ops"}) ==
               %{"tags" => ["newsletter", "ops"]}
    end

    test "parses SES tags as name=value pairs" do
      assert ProviderOptions.cast("aws_ses", %{"tags" => "campaign=newsletter, env=prod"}) ==
               %{
                 "tags" => [
                   %{"name" => "campaign", "value" => "newsletter"},
                   %{"name" => "env", "value" => "prod"}
                 ]
               }
    end

    test "drops a bare SES tag with no value rather than inventing one" do
      # SES requires both a name and a value. Guessing one would silently tag
      # every message with something the operator never typed.
      assert ProviderOptions.cast("aws_ses", %{"tags" => "campaign"}) == %{}
    end

    test "SMTP stores nothing at all" do
      assert ProviderOptions.cast("smtp", %{"configuration_set_name" => "my-set"}) == %{}
    end

    test "switching a profile's provider prunes the previous provider's settings" do
      # This is what stops a repointed profile from carrying a stale SES
      # configuration set into an SMTP send.
      ses = ProviderOptions.cast("aws_ses", %{"configuration_set_name" => "my-set"})
      assert ses == %{"configuration_set_name" => "my-set"}
      assert ProviderOptions.cast("smtp", ses) == %{}
    end
  end

  describe "to_provider_options/2" do
    test "SES tags come back with ATOM keys, as Swoosh's adapter matches on" do
      # Swoosh.Adapters.AmazonSES pattern-matches %{name: name, value: value}
      # strictly. JSONB round-trips string keys, so without the rebuild this
      # raises a FunctionClauseError *inside the adapter*, mid-send.
      advanced = %{
        "configuration_set_name" => "my-set",
        "tags" => [%{"name" => "campaign", "value" => "newsletter"}]
      }

      assert ProviderOptions.to_provider_options("aws_ses", advanced) == %{
               configuration_set_name: "my-set",
               tags: [%{name: "campaign", value: "newsletter"}]
             }
    end

    test "Brevo options come back keyed by the atoms the adapter reads" do
      advanced = %{"sender_id" => 12, "tags" => ["newsletter"]}

      assert ProviderOptions.to_provider_options("brevo_api", advanced) == %{
               sender_id: 12,
               tags: ["newsletter"]
             }
    end

    test "SMTP yields no options even if the column holds something" do
      assert ProviderOptions.to_provider_options("smtp", %{"configuration_set_name" => "x"}) ==
               %{}
    end

    test "leftovers from the old free-form JSON textarea never reach an adapter" do
      # Profiles created before this module existed could hold arbitrary keys,
      # since the old UI accepted any JSON object. They must be ignored, not
      # forwarded to Swoosh.
      advanced = %{"anything_at_all" => "x", "configuration_set_name" => "my-set"}

      assert ProviderOptions.to_provider_options("aws_ses", advanced) == %{
               configuration_set_name: "my-set"
             }
    end

    test "an empty or nil advanced map yields no options" do
      assert ProviderOptions.to_provider_options("aws_ses", %{}) == %{}
      assert ProviderOptions.to_provider_options("aws_ses", nil) == %{}
    end

    test "a malformed tag list is skipped rather than sent as junk" do
      assert ProviderOptions.to_provider_options("aws_ses", %{"tags" => ["not-a-pair"]}) == %{}
    end
  end

  describe "to_input_value/2" do
    test "renders stored lists back into the text the form input shows" do
      [_config_set, tags_field] = ProviderOptions.fields_for("aws_ses")

      advanced = %{
        "tags" => [
          %{"name" => "campaign", "value" => "newsletter"},
          %{"name" => "env", "value" => "prod"}
        ]
      }

      assert ProviderOptions.to_input_value(tags_field, advanced) ==
               "campaign=newsletter, env=prod"
    end

    test "round-trips through cast/2 unchanged" do
      [_sender_id, tags_field] = ProviderOptions.fields_for("brevo_api")

      advanced = ProviderOptions.cast("brevo_api", %{"tags" => "newsletter, ops"})
      rendered = ProviderOptions.to_input_value(tags_field, advanced)

      assert rendered == "newsletter, ops"
      assert ProviderOptions.cast("brevo_api", %{"tags" => rendered}) == advanced
    end

    test "an unset field renders as an empty string, not \"nil\"" do
      [config_set | _] = ProviderOptions.fields_for("aws_ses")

      assert ProviderOptions.to_input_value(config_set, %{}) == ""
      assert ProviderOptions.to_input_value(config_set, nil) == ""
    end
  end
end
