defmodule PhoenixKit.Newsletters.Web.TimezoneTest do
  @moduledoc """
  Unit tests for the shared timezone-resolution/display helper used by
  BroadcastEditor, Broadcasts, and BroadcastDetails.
  """

  use PhoenixKitNewsletters.DataCase, async: false

  alias PhoenixKit.Newsletters.Web.BroadcastEditor
  alias PhoenixKit.Newsletters.Web.Timezone
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.User

  defp socket_with_user(user_assign) do
    %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}}, user_assign)}
  end

  describe "viewer_tz/1 — resolves the viewer's timezone (profile-first)" do
    test "uses the profile timezone when the viewer has set one" do
      # A legacy offset, still on any account written before core moved the
      # picker to IANA ids — both the profile dropdown (core's
      # Settings.timezone_options/0) and the "use browser timezone" one-click
      # button store an identifier now, so cover that one too.
      user = %User{user_timezone: "3"}

      assert Timezone.viewer_tz(socket_with_user(%{phoenix_kit_current_user: user})) == "3"

      user = %User{user_timezone: "Europe/Warsaw"}

      assert Timezone.viewer_tz(socket_with_user(%{phoenix_kit_current_user: user})) ==
               "Europe/Warsaw"
    end

    test "falls back to the system time_zone setting when the profile timezone is unset" do
      Settings.update_setting("time_zone", "-5")
      user = %User{user_timezone: nil}

      assert Timezone.viewer_tz(socket_with_user(%{phoenix_kit_current_user: user})) == "-5"
    end

    test "falls back to the system time_zone setting when there's no viewer at all" do
      Settings.update_setting("time_zone", "-5")

      assert Timezone.viewer_tz(socket_with_user(%{})) == "-5"
    end

    test "a user without the column, or with a blank value, is the site setting — not UTC" do
      # A partial map (a test scope, a degraded embed) has no :user_timezone
      # field; a blank value is "not set". Both used to raise inside core's
      # resolver and be rescued to UTC, silently ignoring the site's zone.
      site = Settings.get_setting_cached("time_zone", "0")

      assert Timezone.viewer_tz(socket_with_user(%{phoenix_kit_current_user: %{}})) == site

      assert Timezone.viewer_tz(
               socket_with_user(%{phoenix_kit_current_user: %{user_timezone: ""}})
             ) == site
    end
  end

  describe "format_datetime/2" do
    test "returns \"-\" for nil" do
      assert Timezone.format_datetime(nil, "3") == "-"
    end

    test "shifts a UTC datetime forward for a positive offset" do
      assert Timezone.format_datetime(~U[2026-07-20 18:58:00Z], "3") == "2026-07-20 21:58"
    end

    test "shifts a UTC datetime backward for a negative offset, including a day rollback" do
      assert Timezone.format_datetime(~U[2026-07-20 02:00:00Z], "-5") == "2026-07-19 21:00"
    end

    # As core's admin pages write times: a site set to day-first dates and a
    # 12-hour clock sees them so here too.
    test "follows the site's date and time formats" do
      Settings.update_setting("date_format", "d.m.Y")
      Settings.update_setting("time_format", "h:i A")

      assert Timezone.format_datetime(~U[2026-07-20 18:58:00Z], "3") == "20.07.2026 09:58 PM"

      assert BroadcastEditor.schedule_preview(
               "2026-07-20T21:58",
               "3",
               "UTC+03:00"
             ) == "Sends at 20.07.2026 09:58 PM (UTC+03:00) · 20.07.2026 06:58 PM UTC"
    end
  end

  describe "tz_label/1" do
    test "is core's label, for an IANA id and for a legacy offset alike" do
      assert Timezone.tz_label("Europe/Warsaw") == Settings.get_timezone_label("Europe/Warsaw")
      assert Timezone.tz_label("Europe/Warsaw") =~ "Europe/Warsaw"
      assert Timezone.tz_label("3") == Settings.get_timezone_label("3")
      assert Timezone.tz_label("3") =~ "UTC+03"
    end
  end

  describe "format_datetime/2 with an IANA zone" do
    test "follows daylight saving on the date shown" do
      assert Timezone.format_datetime(~U[2026-01-15 08:00:00Z], "Europe/Tallinn") ==
               "2026-01-15 10:00"

      assert Timezone.format_datetime(~U[2026-07-15 08:00:00Z], "Europe/Tallinn") ==
               "2026-07-15 11:00"
    end
  end
end
