# Dialyzer warnings to ignore (matched by dialyxir).
[
  # Gettext.Backend expands into code that constructs %Expo.PluralForms{}
  # literals inline; that struct is @opaque in Expo, so dialyzer flags the
  # generated call to Gettext.Plural.plural/2 as a call_without_opaque
  # mismatch. Known upstream false positive (gettext >= 0.26) — the plural
  # forms work correctly. Mirrors the same ignore in phoenix_kit_ecommerce /
  # phoenix_kit_staff / phoenix_kit_billing / phoenix_kit_catalogue /
  # phoenix_kit_projects / phoenix_kit_publishing.
  {"lib/phoenix_kit/newsletters/gettext.ex", :call_without_opaque}
]
