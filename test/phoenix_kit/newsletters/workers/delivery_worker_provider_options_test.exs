defmodule PhoenixKit.Newsletters.Workers.DeliveryWorkerProviderOptionsTest do
  @moduledoc """
  Proves a send profile's provider-specific settings actually reach the email.

  Kept separate from `DeliveryWorkerTest` (which is DataCase-backed, and so
  excluded from runs without a database) because this is the leg that used to
  be silently missing: `advanced` was written by the form and read by nobody.
  `build_profile_email/5` is pure as long as the profile sets its own from
  name/address — no Settings lookup, hence no DB — so these guarantees hold in
  every run.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Newsletters.Broadcast
  alias PhoenixKit.Newsletters.SendProfile
  alias PhoenixKit.Newsletters.Workers.DeliveryWorker
  alias PhoenixKit.Users.Auth.User

  defp profile(attrs) do
    struct!(
      %SendProfile{
        name: "Test profile",
        from_name: "Acme",
        from_email: "news@example.com"
      },
      attrs
    )
  end

  defp build(profile) do
    DeliveryWorker.build_profile_email(
      profile,
      %Broadcast{subject: "Hello"},
      %User{email: "subscriber@example.com"},
      "<p>Body</p>",
      "Body"
    )
  end

  describe "build_profile_email/5 provider options" do
    test "an SES profile carries its configuration set to the adapter" do
      # The configuration set is how SES routes bounce/complaint/open events
      # and picks a dedicated IP pool. Before this, it was unreachable: the
      # form stored it and the send path never looked.
      email =
        profile(%{
          provider_kind: "aws_ses",
          advanced: %{"configuration_set_name" => "my-set"}
        })
        |> build()

      assert email.provider_options == %{configuration_set_name: "my-set"}
    end

    test "SES message tags reach the adapter with the atom keys it matches on" do
      email =
        profile(%{
          provider_kind: "aws_ses",
          advanced: %{
            "configuration_set_name" => "my-set",
            "tags" => [%{"name" => "campaign", "value" => "newsletter"}]
          }
        })
        |> build()

      assert email.provider_options == %{
               configuration_set_name: "my-set",
               tags: [%{name: "campaign", value: "newsletter"}]
             }
    end

    test "a Brevo profile carries its sender ID and tags" do
      email =
        profile(%{
          provider_kind: "brevo_api",
          advanced: %{"sender_id" => 12, "tags" => ["newsletter", "ops"]}
        })
        |> build()

      assert email.provider_options == %{sender_id: 12, tags: ["newsletter", "ops"]}
    end

    test "an SMTP profile sets no provider options" do
      email = profile(%{provider_kind: "smtp", advanced: %{}}) |> build()

      assert email.provider_options == %{}
    end

    test "a profile with nothing configured sets no provider options" do
      email = profile(%{provider_kind: "aws_ses", advanced: %{}}) |> build()

      assert email.provider_options == %{}
    end

    test "unrecognized leftovers in `advanced` are never forwarded to an adapter" do
      # Profiles written by the old free-form JSON textarea can hold anything.
      email =
        profile(%{
          provider_kind: "aws_ses",
          advanced: %{"totally_made_up" => "x"}
        })
        |> build()

      assert email.provider_options == %{}
    end

    test "the identity and signature behavior is unchanged" do
      # Guard against the provider-options plumbing disturbing what already worked.
      email =
        profile(%{
          provider_kind: "smtp",
          reply_to: "support@example.com",
          signature_html: "<p>Bye</p>",
          signature_text: "Bye",
          advanced: %{}
        })
        |> build()

      assert email.from == {"Acme", "news@example.com"}
      assert email.to == [{"", "subscriber@example.com"}]
      assert email.subject == "Hello"
      assert email.reply_to == {"", "support@example.com"}
      assert email.html_body == "<p>Body</p><p>Bye</p>"
      assert email.text_body == "BodyBye"
    end
  end
end
