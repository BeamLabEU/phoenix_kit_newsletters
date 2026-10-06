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

  An edit of `html_body` must also leave at least one language that places
  the body.

  `metadata` and `created_by_user_uuid` are never cast: the migration and
  `PhoenixKit.Newsletters.Layouts.create_layout/2` set them. So a
  carried-over SYSTEM email (`metadata["email_is_system"]`) is archived for
  good: it cannot be made active again, and no attrs can drop the flag.

  Error messages are `gettext_noop` msgids of this package's backend;
  translate them with `PhoenixKit.Newsletters.Gettext` when shown.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(layout, attrs) do
    layout
    |> cast(attrs, [:name, :display_name, :subject, :html_body, :text_body, :status])
    |> update_change(:display_name, &compact/1)
    |> update_change(:subject, &compact/1)
    |> update_change(:html_body, &compact/1)
    |> update_change(:text_body, &compact/1)
    |> validate_required([:name, :status])
    |> validate_length(:name, max: @column_widths.name)
    |> validate_format(:name, @name_format,
      message:
        gettext_noop(
          "must use only lowercase Latin letters, numbers and underscores, and start with a letter (for example monthly_news)"
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

  @typedoc """
  One tab of the layout editor. `language` is what the tab is called and the
  id it is switched by (a site language, or a stored key the site no longer
  offers); `locale` is the language its preview renders in; `keys` maps each
  field to the key of that field's language map the tab reads and writes
  (`nil`: that key is another tab's, so the tab has no value there and writes
  none); `site?` is false for a stored key no site language claims;
  `residue?` is true for a subject stored under a key no HTML is stored
  under, which a send never reads.
  """
  @type language_tab :: %{
          language: String.t(),
          locale: String.t(),
          keys: %{optional(String.t()) => String.t() | nil},
          site?: boolean(),
          residue?: boolean()
        }

  @own_fields ["display_name", "text_body"]

  @doc """
  The editor's tabs: one per site language, in the site's order, then one per
  stored key no site language accounts for (sorted).

  `translations` maps each field to its language map (`%{"html_body" =>
  %{"en" => …}, …}`). The editor writes each field where a send will read it:

    * **HTML** — the key `translation_key/3` finds for the tab's language:
      exact, then base, then another dialect of the same base; a language
      with none starts a key named by the tab's code. A site that spells its
      languages with a dialect (`en-US`) over a layout that stores base keys
      (`en`) is one tab and one translation, not two.
    * **Subject** — the HTML's key. `Render.subject/4` reads the subject
      pattern in the language the HTML was picked in, so a subject stored
      under any other key is never used.
    * **Display name** and **text** — a send reads the display name by its
      own `translation_key/3` match (the text is kept for reference and never
      read), so these are matched per field the same way; a language with no
      match of its own uses the tab's HTML key, so new translations stay under
      one key per language.

  A key belongs to at most one tab in a field. Exact matches are settled first,
  then base matches, then dialect matches, each in the site's order, so an
  earlier tab never takes the key a later tab spells exactly. With the site's
  `en-GB` and `en-US` and only `en` stored, `en` is `en-GB`'s and `en-US`
  starts a key of its own, so saving on both tabs leaves `en` and `en-US` in
  the map. `en_US` and `en-US` are one site language. Blank values are not
  stored translations.

  A stored key no site language accounts for is a tab of its own, called by
  the key, with `site?: false`; in a field where another tab already owns that
  key the tab has no key (`nil`). A subject under a key that no HTML is under
  (the old editor saved one under `en-US` over HTML under `en`) is shown on a
  `residue?: true` tab, named `"<key> (subject)"` when the key is a site
  language, so it can be read, copied to the right tab or cleared, and is
  never silently dropped; that tab has no HTML key.
  """
  @spec language_tabs([String.t()], %{optional(String.t()) => map() | nil}) :: [language_tab()]
  def language_tabs(site_languages, translations) when is_map(translations) do
    site =
      site_languages
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq_by(&String.replace(&1, "_", "-"))

    stored =
      Map.new(["html_body", "subject" | @own_fields], &{&1, present_keys(translations[&1])})

    {html_claimed, _} = claim_keys(site, stored["html_body"])
    site_html = Map.new(site, &{&1, Map.get(html_claimed, &1, &1)})
    html_keys = Map.values(site_html)

    own =
      Map.new(@own_fields, fn field ->
        {claimed, _} = claim_keys(site, stored[field])
        taken = Map.values(claimed)

        keys =
          Map.new(site, fn lang ->
            {lang, claimed[lang] || if(site_html[lang] in taken, do: nil, else: site_html[lang])}
          end)

        {field, keys}
      end)

    site_tabs =
      for lang <- site do
        keys =
          %{"html_body" => site_html[lang], "subject" => site_html[lang]}
          |> Map.merge(Map.new(@own_fields, &{&1, own[&1][lang]}))

        %{language: lang, locale: lang, keys: keys, site?: true, residue?: false}
      end

    html_extra = stored["html_body"] -- Map.values(html_claimed)
    own_extra = Enum.flat_map(@own_fields, &(stored[&1] -- Map.values(own[&1])))
    with_html = Enum.uniq(html_extra ++ own_extra)
    residue = stored["subject"] -- (html_keys ++ with_html)

    extra_tabs =
      Enum.map(Enum.sort(with_html), &extra_tab(&1, site, own, html_keys, false)) ++
        Enum.map(Enum.sort(residue), &extra_tab(&1, site, own, html_keys, true))

    site_tabs ++ Enum.sort_by(extra_tabs, &{&1.residue?, &1.locale})
  end

  # A tab for a stored key no site language accounts for. It owns the key in
  # every field where no site tab does.
  defp extra_tab(key, site, own, html_keys, residue?) do
    html = if residue? or key in html_keys, do: nil, else: key

    keys =
      Map.new(@own_fields, fn field ->
        {field, if(key in Map.values(own[field]), do: nil, else: key)}
      end)
      |> Map.merge(%{"html_body" => html, "subject" => if(residue?, do: key, else: html)})

    language = if residue? and key in site, do: "#{key} (subject)", else: key

    %{language: language, locale: key, keys: keys, site?: false, residue?: residue?}
  end

  # Which stored key each site language reads in one field, in passes, so a
  # key never has two owners.
  defp claim_keys(site, stored) do
    steps = [
      fn lang, free -> Enum.find(exact_candidates(lang), &(&1 in free)) end,
      fn lang, free -> Enum.find(base_candidates(lang), &(&1 in free)) end,
      fn lang, free -> dialect_match(free, lang) end
    ]

    {claimed, _free} =
      Enum.reduce(steps, {%{}, stored}, fn step, acc ->
        Enum.reduce(site, acc, &claim_key(&1, &2, step))
      end)

    {claimed, stored}
  end

  defp present_keys(map) when is_map(map),
    do: for({k, v} <- map, is_binary(k), present?(v), do: k) |> Enum.uniq() |> Enum.sort()

  defp present_keys(_map), do: []

  # One site language claims the stored key `step` finds for it among the
  # keys still free, unless an earlier step already gave it one.
  defp claim_key(lang, {claimed, free} = state, step) do
    with false <- Map.has_key?(claimed, lang),
         key when is_binary(key) <- step.(lang, free) do
      {Map.put(claimed, lang, key), List.delete(free, key)}
    else
      _ -> state
    end
  end

  @doc """
  A name the operator can accept for a layout called `text`: lowercase ASCII
  letters and digits, with spaces and `-` as `_`; `nil` when nothing usable
  is left (a name in another script). Always a valid name when not `nil`.
  """
  @spec suggest_name(String.t() | nil) :: String.t() | nil
  def suggest_name(text) when is_binary(text) do
    slug =
      text
      |> String.downcase()
      |> String.replace(~r/[\s-]+/u, "_")
      |> String.replace(~r/[^a-z0-9_]/, "")
      |> String.replace(~r/_+/, "_")
      |> String.trim("_")

    cond do
      slug == "" -> nil
      slug =~ ~r/\A[a-z]/ -> String.slice(slug, 0, @column_widths.name)
      true -> String.slice("layout_" <> slug, 0, @column_widths.name)
    end
  end

  def suggest_name(_text), do: nil

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
  defp candidates(locale), do: exact_candidates(locale) ++ base_candidates(locale)

  defp exact_candidates(locale) when is_binary(locale) and locale != "",
    do: Enum.uniq([locale, String.replace(locale, "_", "-")])

  defp exact_candidates(_locale), do: []

  defp base_candidates(locale) when is_binary(locale) and locale != "" do
    base = locale |> String.split(["-", "_"]) |> hd()
    if base in exact_candidates(locale), do: [], else: [base]
  end

  defp base_candidates(_locale), do: []

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
  # subject" always means a non-blank one. Keep malformed values so the
  # translation-map validation rejects them instead of deleting data.
  defp compact(map) when is_map(map) do
    for {k, v} <- map,
        not (is_binary(v) and String.trim(v) == ""),
        into: %{},
        do: {to_string(k), v}
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

      # An edit that leaves no language placing the body (deleting the only
      # one that did) would turn every send into the standard layout.
      changed?(changeset, :html_body) and
          not Enum.any?(html, fn {_l, v} -> places_content?(v) end) ->
        add_error(
          changeset,
          :html_body,
          gettext_noop("at least one language must place the broadcast with {{{content}}}")
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
