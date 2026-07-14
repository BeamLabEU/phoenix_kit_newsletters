defmodule PhoenixKit.Newsletters.ProviderOptions do
  @moduledoc """
  Per-provider send settings — the "Advanced" half of a `SendProfile`.

  One source of truth for what each email provider actually accepts,
  shared by the Send Settings form (which renders `fields_for/1`) and by
  the delivery worker (which calls `to_provider_options/2` to turn a
  profile's `advanced` map into Swoosh provider options).

  Only options the underlying Swoosh adapter really reads are declared
  here. An option the adapter ignores is worse than a missing one: it
  looks configured and then silently does nothing — which is exactly what
  the old free-form "Advanced (JSON)" textarea did, since nothing ever
  read `advanced` at send time.

  `smtp` declares no options on purpose: `Swoosh.Adapters.SMTP` takes all
  its knobs (relay, port, TLS) from the connection itself and reads no
  per-email `provider_options` at all. Rendering fields for it would be
  the same lie in a new shape.

  ## Storage vs. wire format

  `advanced` is a JSONB column, so it round-trips with **string** keys.
  Swoosh, meanwhile, matches provider options on **atom** keys — and for
  SES tags it pattern-matches `%{name: name, value: value}` strictly, so
  a string-keyed tag map would raise inside the adapter. `cast/2` handles
  the storage side, `to_provider_options/2` the wire side. Atoms come
  from the `:option` field of a literal spec below, never from user
  input, so there is no dynamic atom creation.
  """

  use Gettext, backend: PhoenixKit.Newsletters.Gettext

  @type field :: %{
          key: String.t(),
          option: atom(),
          label: String.t(),
          type: :text | :number,
          cast: :string | :integer | :string_list | :name_value_list,
          placeholder: String.t(),
          help: String.t()
        }

  @doc """
  Returns the send settings a given provider supports, in display order.

  An unknown provider returns `[]` rather than raising: a profile whose
  integration was deleted, or one pointing at a provider some other module
  registered, must still render its common fields instead of 500ing.
  """
  @spec fields_for(String.t() | nil) :: [field()]
  def fields_for("aws_ses") do
    [
      %{
        key: "configuration_set_name",
        option: :configuration_set_name,
        label: gettext("Configuration set"),
        type: :text,
        cast: :string,
        placeholder: "my-configuration-set",
        help:
          gettext(
            "SES configuration set applied to every send from this profile — this is what routes bounce/complaint/open events and selects a dedicated IP pool."
          )
      },
      %{
        key: "tags",
        option: :tags,
        label: gettext("Message tags"),
        type: :text,
        cast: :name_value_list,
        placeholder: "campaign=newsletter, env=prod",
        help:
          gettext(
            "Comma-separated name=value pairs, attached to each message as SES message tags (visible in CloudWatch metrics)."
          )
      }
    ]
  end

  def fields_for("brevo_api") do
    [
      %{
        key: "sender_id",
        option: :sender_id,
        label: gettext("Sender ID"),
        type: :number,
        cast: :integer,
        placeholder: "12",
        help:
          gettext(
            "Numeric ID of a verified Brevo sender. Leave empty to send from the From address above."
          )
      },
      %{
        key: "tags",
        option: :tags,
        label: gettext("Tags"),
        type: :text,
        cast: :string_list,
        placeholder: "newsletter, ops",
        help:
          gettext(
            "Comma-separated tags attached to each message, for filtering in Brevo's statistics."
          )
      }
    ]
  end

  def fields_for(_provider_kind), do: []

  @doc """
  Normalizes raw form input into the map stored in `advanced`.

  Keeps only keys the provider declares, so flipping a profile from SES to
  Brevo can't leave an orphan `configuration_set_name` behind to be sent to
  an adapter that has no idea what it is. Blank values are dropped rather
  than stored as `""`, so an untouched field stores nothing at all.
  """
  @spec cast(String.t() | nil, map() | nil) :: map()
  def cast(provider_kind, raw) when is_map(raw) do
    provider_kind
    |> fields_for()
    |> Enum.reduce(%{}, fn field, acc ->
      case raw |> Map.get(field.key) |> cast_value(field.cast) do
        nil -> acc
        value -> Map.put(acc, field.key, value)
      end
    end)
  end

  def cast(_provider_kind, _raw), do: %{}

  @doc """
  Translates a profile's stored `advanced` map into Swoosh provider options.

  Returns a map keyed by the atoms Swoosh expects. Anything not declared by
  the provider is ignored — including leftovers written by the old raw-JSON
  textarea, which must never reach an adapter unvetted.
  """
  @spec to_provider_options(String.t() | nil, map() | nil) :: map()
  def to_provider_options(provider_kind, advanced) when is_map(advanced) do
    provider_kind
    |> fields_for()
    |> Enum.reduce(%{}, fn field, acc ->
      case Map.get(advanced, field.key) do
        nil -> acc
        value -> put_option(acc, field, value)
      end
    end)
  end

  def to_provider_options(_provider_kind, _advanced), do: %{}

  @doc """
  Renders a stored value back into the text the form input shows.

  The inverse of `cast_value/2` for the list types, so editing a profile
  shows `campaign=newsletter, env=prod` rather than a raw JSON array.
  """
  @spec to_input_value(field(), map() | nil) :: String.t()
  def to_input_value(field, advanced) when is_map(advanced) do
    advanced |> Map.get(field.key) |> format_value(field.cast)
  end

  def to_input_value(_field, _advanced), do: ""

  # --- Private ---

  defp put_option(acc, %{cast: :name_value_list, option: option}, value) do
    # Swoosh's SES adapter matches %{name: _, value: _} strictly — string
    # keys (which is how JSONB gives them back) would raise inside the
    # adapter, so rebuild with atom keys. Skip the option entirely if the
    # stored shape isn't what we wrote, rather than sending junk to AWS.
    tags =
      value
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"name" => name, "value" => v} -> [%{name: name, value: v}]
        %{name: name, value: v} -> [%{name: name, value: v}]
        _ -> []
      end)

    if tags == [], do: acc, else: Map.put(acc, option, tags)
  end

  defp put_option(acc, %{option: option}, value), do: Map.put(acc, option, value)

  defp cast_value(nil, _cast), do: nil

  defp cast_value(value, :string) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp cast_value(value, :integer) when is_binary(value) do
    case value |> String.trim() |> Integer.parse() do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp cast_value(value, :integer) when is_integer(value), do: value

  defp cast_value(value, :string_list) when is_binary(value) do
    value
    |> split_list()
    |> case do
      [] -> nil
      tags -> tags
    end
  end

  defp cast_value(value, :name_value_list) when is_binary(value) do
    value
    |> split_list()
    |> Enum.flat_map(&parse_name_value/1)
    |> case do
      [] -> nil
      tags -> tags
    end
  end

  # Already-normalized values (e.g. re-casting a loaded profile) pass through.
  defp cast_value(value, _cast) when is_list(value), do: if(value == [], do: nil, else: value)
  defp cast_value(_value, _cast), do: nil

  # A bare tag with no "=" is dropped rather than guessed at: SES requires both
  # a name and a value, and inventing one would silently tag every message with
  # something the operator never typed.
  defp parse_name_value(pair) do
    with [name, value] <- String.split(pair, "=", parts: 2),
         name = String.trim(name),
         value = String.trim(value),
         true <- name != "" and value != "" do
      [%{"name" => name, "value" => value}]
    else
      _ -> []
    end
  end

  defp split_list(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp format_value(nil, _cast), do: ""

  defp format_value(value, :name_value_list) when is_list(value) do
    Enum.map_join(value, ", ", fn
      %{"name" => name, "value" => v} -> "#{name}=#{v}"
      %{name: name, value: v} -> "#{name}=#{v}"
      other -> to_string(other)
    end)
  end

  defp format_value(value, :string_list) when is_list(value), do: Enum.join(value, ", ")
  defp format_value(value, _cast), do: to_string(value)
end
