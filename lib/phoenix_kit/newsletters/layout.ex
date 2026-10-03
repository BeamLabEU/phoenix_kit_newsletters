defmodule PhoenixKit.Newsletters.Layout do
  @moduledoc """
  An operator-authored wrapper ("layout") a broadcast is sent inside.

  One row per layout; every text field is a map keyed by language
  (`%{"en" => …, "de" => …}`), the same shape the database email templates
  used — rows carried over from `phoenix_kit_email_templates` by
  `PhoenixKitNewsletters.Migrations` V2 keep their uuid and their maps
  unchanged.

    * `html_body` — the HTML document around the broadcast. The body goes
      where `{{{content}}}` is (the older `{{content}}` still works); see
      `PhoenixKit.Newsletters.Render` for the other placeholders.
    * `subject` — optional. A non-blank value is a pattern for the email's
      subject and must contain `{{subject}}` (the broadcast's own subject);
      left blank, the broadcast's subject is sent unchanged.
    * `text_body` — kept with the row for the record; the text part of a
      broadcast is sent without a wrapper.
    * `display_name` — what the editor shows; `name` is the stable slug.

  `status` is `"active"` (offered in the broadcast editor) or `"archived"`.
  Archiving never breaks a broadcast that already points at the layout: a
  send renders whatever the broadcast references.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  use Gettext, backend: PhoenixKit.Newsletters.Gettext
  import Ecto.Changeset

  alias PhoenixKit.Settings
  alias PhoenixKit.Templates.Substitution

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @valid_statuses ["active", "archived"]
  @translatable [:display_name, :subject, :html_body, :text_body]

  # `phoenix_kit_newsletters_layouts` `character varying` widths,
  # interpolated into `PhoenixKitNewsletters.Migrations`' V2 DDL — the
  # single source for both. `name` is the width of the email-templates
  # column the migrated rows come from.
  @column_widths %{name: 255, status: 20}

  @name_format ~r/\A[a-z][a-z0-9_]*\z/

  @type t :: %__MODULE__{}

  schema "phoenix_kit_newsletters_layouts" do
    field(:name, :string)
    field(:display_name, :map, default: %{})
    field(:subject, :map, default: %{})
    field(:html_body, :map, default: %{})
    field(:text_body, :map, default: %{})
    field(:status, :string, default: "active")
    field(:metadata, :map, default: %{})
    field(:created_by_user_uuid, UUIDv7)

    timestamps(type: :utc_datetime)
  end

  @doc "The `character varying` widths the migration chain builds the table with."
  @spec column_widths() :: %{name: pos_integer(), status: pos_integer()}
  def column_widths, do: @column_widths

  @doc "Statuses a layout can have."
  @spec valid_statuses() :: [String.t()]
  def valid_statuses, do: @valid_statuses

  @doc """
  Changeset for creating and editing a layout.

  Every translatable field must be a map of language => string. At least
  one language must have an HTML body. An HTML translation must place the
  body (`{{{content}}}` or `{{content}}`) — a wrapper without it would send
  the wrapper alone — and a non-blank subject translation must contain
  `{{subject}}`. Both rules check only the translations this change adds
  or alters: a row carried over from the email-templates table keeps its
  other languages as they were, and stays editable.

  A carried-over SYSTEM email (`metadata["email_is_system"]`) is archived
  for good: it cannot be made active again.

  Error messages are `gettext_noop` msgids of this package's backend;
  translate them with `PhoenixKit.Newsletters.Gettext` when shown.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(layout, attrs) do
    layout
    |> cast(attrs, [
      :name,
      :display_name,
      :subject,
      :html_body,
      :text_body,
      :status,
      :metadata,
      :created_by_user_uuid
    ])
    |> update_change(:display_name, &compact/1)
    |> update_change(:subject, &compact/1)
    |> update_change(:html_body, &compact/1)
    |> update_change(:text_body, &compact/1)
    |> validate_required([:name, :status])
    |> validate_length(:name, max: @column_widths.name)
    |> validate_format(:name, @name_format,
      message:
        gettext_noop(
          "must start with a letter and contain only lowercase letters, numbers, and underscores"
        )
    )
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_translation_maps()
    |> validate_html_body()
    |> validate_subject()
    |> validate_system_stays_archived()
    |> unique_constraint(:name, name: :idx_newsletters_layouts_name)
  end

  @doc """
  Whether the layout is a SYSTEM email carried over from the email-templates
  table because a broadcast or the default setting still pointed at it.
  Such a layout stays archived: it keeps rendering for those broadcasts,
  and is never offered again.
  """
  @spec system_email?(t()) :: boolean()
  def system_email?(%__MODULE__{metadata: %{"email_is_system" => true}}), do: true
  def system_email?(_layout), do: false

  @doc "Whether `html` places the broadcast body (`{{{content}}}` or `{{content}}`)."
  @spec places_content?(String.t() | nil) :: boolean()
  def places_content?(html) when is_binary(html),
    do: "content" in Substitution.variables(html)

  def places_content?(_html), do: false

  @doc """
  The value of a language map for `locale`, or `nil` when the map has no
  usable value.

  Fallback order: the exact language (`"de-AT"`), its base language
  (`"de"`), another dialect of that base (`"de-CH"`), the site's content
  language (and its base), then any language present (alphabetically, so
  the choice is stable). Blank strings count as missing.
  """
  @spec translation(map() | nil, String.t() | nil, String.t() | nil | :site) ::
          String.t() | nil
  def translation(map, locale, site_default \\ :site) do
    case translation_key(map, locale, site_default) do
      nil -> nil
      key -> Map.fetch!(map, key)
    end
  end

  @doc """
  The language `translation/3` picks from `map` for `locale` — the key, not
  the value — or `nil`. Lets a caller read a second map in the SAME language
  (a layout's subject in the language its HTML was picked in).
  """
  @spec translation_key(map() | nil, String.t() | nil, String.t() | nil | :site) ::
          String.t() | nil
  def translation_key(map, locale, site_default \\ :site)

  def translation_key(map, locale, site_default) when is_map(map) do
    present = for {k, v} <- map, is_binary(k), present?(v), do: k

    if present == [] do
      nil
    else
      site = if site_default == :site, do: site_language(), else: site_default
      pick = fn keys -> Enum.find(keys, &(&1 in present)) end

      pick.(candidates(locale)) || dialect_match(present, locale) ||
        pick.(candidates(site)) || dialect_match(present, site) ||
        present |> Enum.sort() |> List.first()
    end
  end

  def translation_key(_map, _locale, _site_default), do: nil

  @doc """
  The display name for `locale` (same fallback as `translation/3`), or the
  slug when the layout has none.
  """
  @spec display_name(t(), String.t() | nil) :: String.t()
  def display_name(%__MODULE__{} = layout, locale) do
    translation(layout.display_name, locale) || layout.name
  end

  @doc "Languages the layout has an HTML body in, sorted."
  @spec languages(t()) :: [String.t()]
  def languages(%__MODULE__{html_body: html}) when is_map(html) do
    html |> Enum.filter(fn {_k, v} -> present?(v) end) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
  end

  def languages(_layout), do: []

  # ── internals ──────────────────────────────────────────────────────────

  # Exact (as written, and with `_` spelled `-`), then the base language.
  defp candidates(locale) when is_binary(locale) and locale != "" do
    base = locale |> String.split(["-", "_"]) |> hd()
    Enum.uniq([locale, String.replace(locale, "_", "-"), base])
  end

  defp candidates(_locale), do: []

  defp dialect_match(present, locale) when is_binary(locale) and locale != "" do
    base = locale |> String.split(["-", "_"]) |> hd()

    present
    |> Enum.sort()
    |> Enum.find(fn key -> key |> String.split(["-", "_"]) |> hd() == base end)
  end

  defp dialect_match(_present, _locale), do: nil

  defp site_language do
    case Settings.get_content_language() do
      language when is_binary(language) and language != "" -> language
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  # Blank translations are dropped on the way in, so "this language has a
  # subject" always means a non-blank one.
  defp compact(map) when is_map(map) do
    for {k, v} <- map, present?(v), into: %{}, do: {to_string(k), v}
  end

  defp compact(other), do: other

  defp validate_translation_maps(changeset) do
    Enum.reduce(
      @translatable,
      changeset,
      &validate_change(&2, &1, fn field, value ->
        if translation_map?(value),
          do: [],
          else: [{field, gettext_noop("must map each language to text")}]
      end)
    )
  end

  defp translation_map?(value) when is_map(value),
    do: Enum.all?(value, fn {k, v} -> is_binary(k) and is_binary(v) end)

  defp translation_map?(_value), do: false

  # The languages of `field` this change adds or alters — the only ones the
  # content rules below check, so an untouched carried-over translation
  # never blocks an edit of another one.
  defp changed_languages(changeset, field) do
    case fetch_change(changeset, field) do
      {:ok, new} when is_map(new) ->
        old = Map.get(changeset.data, field) || %{}

        new
        |> Enum.reject(fn {lang, value} -> Map.get(old, lang) == value end)
        |> Enum.map(&elem(&1, 0))

      _ ->
        []
    end
  end

  defp validate_html_body(changeset) do
    html = get_field(changeset, :html_body) || %{}

    cond do
      not is_map(html) ->
        changeset

      html == %{} ->
        add_error(changeset, :html_body, gettext_noop("can't be blank"))

      language =
          changeset
          |> changed_languages(:html_body)
          |> Enum.sort()
          |> Enum.find(&(not places_content?(html[&1]))) ->
        add_error(
          changeset,
          :html_body,
          gettext_noop("must place the broadcast with {{{content}}} (missing in %{language})"),
          language: language
        )

      true ->
        changeset
    end
  end

  defp validate_subject(changeset) do
    subject = get_field(changeset, :subject) || %{}

    missing =
      if is_map(subject) do
        changeset
        |> changed_languages(:subject)
        |> Enum.sort()
        |> Enum.find(&(not subject_pattern?(subject[&1])))
      end

    if missing,
      do:
        add_error(
          changeset,
          :subject,
          gettext_noop("must contain {{subject}} (missing in %{language})"),
          language: missing
        ),
      else: changeset
  end

  defp validate_system_stays_archived(changeset) do
    if system_email?(changeset.data) and get_field(changeset, :status) != "archived",
      do:
        add_error(
          changeset,
          :status,
          gettext_noop("a carried-over system email stays archived")
        ),
      else: changeset
  end

  @doc """
  Whether a subject translation can stand as a pattern: it places
  `{{subject}}`, the broadcast's own subject.
  """
  @spec subject_pattern?(String.t() | nil) :: boolean()
  def subject_pattern?(subject) when is_binary(subject),
    do: "subject" in Substitution.variables(subject)

  def subject_pattern?(_subject), do: false
end
