defmodule PhoenixKit.Newsletters.Web.Timezone do
  @moduledoc """
  Shared timezone resolution and display formatting for the
  newsletters admin LiveViews — used by the broadcast composer's schedule
  field (`BroadcastEditor`), the broadcasts list/details pages and the
  verification page, so every time on them is resolved and written the same
  way.
  """

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: DateUtils

  @doc """
  Human-readable label for a timezone value — core's own
  (`PhoenixKit.Settings.get_timezone_label/1`): "(UTC+02:00) Europe/Warsaw"
  for an IANA id, "UTC+03:00" for a legacy offset.

  This used to look the value up in a private copy of the old picker list,
  which labelled a legacy "2" with cities that are only on UTC+2 for half
  the year and had nothing to say about an IANA id at all.
  """
  @spec tz_label(String.t() | nil) :: String.t()
  def tz_label(tz), do: Settings.get_timezone_label(tz)

  @doc """
  The viewer's timezone value — user profile → system setting → "0" (UTC),
  core's `PhoenixKit.Utils.Date.get_user_timezone/1` rule. An IANA id such as
  `Europe/Warsaw`, or a legacy fixed offset such as `"2"` on a row written
  before core 2.13.9; never a number, so pass it straight to core's
  per-instant helpers (`shift_to_offset/2`, `parse_datetime_local/2`,
  `format_datetime_local/2`), which follow daylight saving on the date
  shown.

  Deliberately profile-first: unlike core's Maintenance module (a single
  site-wide event window, resolved from the system `time_zone` setting
  only), these are personal actions by the admin viewing/scheduling, so
  their own profile timezone — if they've set one — takes precedence.
  """
  @spec viewer_tz(Phoenix.LiveView.Socket.t()) :: String.t()
  def viewer_tz(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      # `Map.get/2` rather than core's resolver: the page's user may be a
      # partial map without the column, and a blank value is "not set".
      %{} = user ->
        case Map.get(user, :user_timezone) do
          tz when is_binary(tz) and tz != "" -> tz
          _ -> Settings.get_setting_cached("time_zone", "0")
        end

      _ ->
        Settings.get_setting_cached("time_zone", "0")
    end
  end

  @doc """
  Displays a stored UTC datetime in the given timezone, in the site's own date
  and time formats: Settings' `date_format` (or the viewer's country format, as
  core resolves it) and `time_format`, as core's admin pages show them. With the
  defaults, `Y-m-d` and `H:i`, that reads `2026-07-20 21:58`.

  Storage stays UTC — this is display-only, via
  `PhoenixKit.Utils.Date.shift_to_offset/2`, which resolves the zone for the
  instant shown. Returns `"-"` for `nil`.
  """
  @spec format_datetime(DateTime.t() | nil, String.t()) :: String.t()
  def format_datetime(nil, _tz), do: "-"

  def format_datetime(dt, tz) do
    local = DateUtils.shift_to_offset(dt, tz)

    date_format =
      DateUtils.viewer_date_format(Settings.get_setting_cached("date_format", "Y-m-d"))

    time_format = Settings.get_setting_cached("time_format", "H:i")

    DateUtils.format_date(DateTime.to_date(local), date_format) <>
      " " <> DateUtils.format_time(DateTime.to_time(local), time_format)
  end
end
