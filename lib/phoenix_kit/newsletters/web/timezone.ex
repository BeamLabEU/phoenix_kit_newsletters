defmodule PhoenixKit.Newsletters.Web.Timezone do
  @moduledoc """
  Shared timezone-offset resolution and display formatting for the
  newsletters admin LiveViews — used by the broadcast composer's schedule
  field (`BroadcastEditor`) and the broadcasts list/details pages, so the
  resolution logic lives in one place instead of being reimplemented per
  LiveView.
  """

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: DateUtils

  @doc """
  The viewer's timezone offset — user profile → system setting → "0" (UTC),
  via core's `PhoenixKit.Utils.Date.get_user_timezone/1`.

  Deliberately profile-first: unlike core's Maintenance module (a single
  site-wide event window, resolved from the system `time_zone` setting
  only), these are personal actions by the admin viewing/scheduling, so
  their own profile timezone — if they've set one — takes precedence.

  Also note: this is a fixed numeric offset, not a real tz database — a
  time saved or displayed before a DST transition will read differently
  in local wall-clock terms after the transition, in zones that observe
  DST.
  """
  def user_tz_offset(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{} = user -> DateUtils.get_user_timezone(user)
      _ -> Settings.get_setting_cached("time_zone", "0")
    end
  rescue
    _ -> "0"
  end

  @doc """
  Displays a stored UTC datetime shifted into the given timezone offset.
  Storage stays UTC — this is display-only, via
  `PhoenixKit.Utils.Date.shift_to_offset/2`. Returns `"-"` for `nil`.
  """
  def format_datetime(nil, _tz_offset), do: "-"

  def format_datetime(dt, tz_offset) do
    dt
    |> DateUtils.shift_to_offset(tz_offset)
    |> Calendar.strftime("%Y-%m-%d %H:%M")
  end
end
