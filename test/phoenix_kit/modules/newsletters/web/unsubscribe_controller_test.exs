defmodule PhoenixKit.Newsletters.Web.UnsubscribeControllerTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Newsletters.Web.UnsubscribeController

  describe "module structure" do
    test "UnsubscribeController module is loadable" do
      assert Code.ensure_loaded?(UnsubscribeController)
    end

    test "exports unsubscribe/2" do
      assert function_exported?(UnsubscribeController, :unsubscribe, 2)
    end

    test "exports process_unsubscribe/2" do
      assert function_exported?(UnsubscribeController, :process_unsubscribe, 2)
    end
  end

  describe "token verification" do
    # Use a string key base to avoid requiring a running Phoenix Endpoint in tests
    @secret_key_base String.duplicate("test_secret_key_base_for_unit_tests_only_", 2)

    test "Phoenix.Token.verify rejects invalid tokens" do
      result =
        Phoenix.Token.verify(
          @secret_key_base,
          "unsubscribe",
          "invalid_token_string",
          max_age: 604_800
        )

      assert {:error, _reason} = result
    end

    test "Phoenix.Token.verify rejects tampered tokens" do
      result =
        Phoenix.Token.verify(
          @secret_key_base,
          "unsubscribe",
          "SFMyNTY.tampered.signature",
          max_age: 604_800
        )

      assert {:error, _reason} = result
    end

    test "Phoenix.Token.verify rejects empty token" do
      result =
        Phoenix.Token.verify(
          @secret_key_base,
          "unsubscribe",
          "",
          max_age: 604_800
        )

      assert {:error, _reason} = result
    end

    test "valid signed token verifies successfully" do
      token = Phoenix.Token.sign(@secret_key_base, "unsubscribe", %{user: "uuid", list: "uuid"})

      assert {:ok, %{user: "uuid", list: "uuid"}} =
               Phoenix.Token.verify(@secret_key_base, "unsubscribe", token, max_age: 604_800)
    end

    test "token signed with different salt is rejected" do
      token = Phoenix.Token.sign(@secret_key_base, "other_salt", "payload")

      assert {:error, :invalid} =
               Phoenix.Token.verify(@secret_key_base, "unsubscribe", token, max_age: 604_800)
    end
  end
end
