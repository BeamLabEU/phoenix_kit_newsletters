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

  # A local copy of `Settings.get_setting_options/0`'s "time_zone" list —
  # core has no cheaper dedicated accessor for it, and get_setting_options/0
  # bundles it with every *other* setting's options, including
  # `Roles.list_roles/0` for "new_user_default_role" (a DB query, per call,
  # just to label a timezone offset). Keep in sync with core's list; a
  # follow-up may add a cheaper core accessor.
  @time_zone_options [
    {"UTC-12 (Baker Island)", "-12"},
    {"UTC-11 (Pago Pago, Niue)", "-11"},
    {"UTC-10 (Honolulu, Tahiti)", "-10"},
    {"UTC-9 (Anchorage, Juneau)", "-9"},
    {"UTC-8 (Los Angeles, Vancouver, Seattle)", "-8"},
    {"UTC-7 (Denver, Phoenix, Calgary)", "-7"},
    {"UTC-6 (Chicago, Mexico City, Guatemala)", "-6"},
    {"UTC-5 (New York, Toronto, Bogotá, Lima)", "-5"},
    {"UTC-4 (Halifax, Caracas, Santiago)", "-4"},
    {"UTC-3 (Buenos Aires, São Paulo, Montevideo)", "-3"},
    {"UTC-2 (South Georgia)", "-2"},
    {"UTC-1 (Azores, Cape Verde)", "-1"},
    {"UTC+0 (London, Dublin, Lisbon, Accra)", "0"},
    {"UTC+1 (Paris, Berlin, Rome, Madrid, Lagos)", "1"},
    {"UTC+2 (Kyiv, Athens, Helsinki, Cairo, Johannesburg)", "2"},
    {"UTC+3 (Istanbul, Riyadh, Nairobi, Baghdad, Moscow)", "3"},
    {"UTC+4 (Dubai, Baku, Tbilisi)", "4"},
    {"UTC+5 (Karachi, Tashkent, Yekaterinburg)", "5"},
    {"UTC+5:30 (Mumbai, Delhi, Kolkata, Colombo)", "5.5"},
    {"UTC+6 (Dhaka, Almaty, Bishkek)", "6"},
    {"UTC+7 (Bangkok, Jakarta, Ho Chi Minh City)", "7"},
    {"UTC+8 (Beijing, Singapore, Hong Kong, Perth)", "8"},
    {"UTC+9 (Tokyo, Seoul, Pyongyang)", "9"},
    {"UTC+9:30 (Adelaide, Darwin)", "9.5"},
    {"UTC+10 (Sydney, Melbourne, Brisbane)", "10"},
    {"UTC+11 (Honiara, Noumea)", "11"},
    {"UTC+12 (Auckland, Fiji, Wellington)", "12"},
    {"UTC+13 (Nuku'alofa, Apia)", "13"},
    {"UTC+14 (Kiritimati)", "14"}
  ]

  @doc """
  Human-readable label for a timezone offset (e.g.
  `"UTC+3 (Istanbul, Riyadh, Nairobi, Baghdad, Moscow)"`), via core's
  `PhoenixKit.Settings.get_timezone_label/2` — but against the local
  `@time_zone_options` list instead of the full, DB-querying
  `Settings.get_setting_options/0`.
  """
  def tz_label(tz_offset) do
    Settings.get_timezone_label(tz_offset, %{"time_zone" => @time_zone_options})
  end

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
