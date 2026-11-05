defmodule PhoenixKit.Newsletters.Web.UnsubscribeHTML do
  @moduledoc false

  use PhoenixKitWeb, :html
  # After core's `use`: `gettext` reads the last backend named, and core's own
  # catalogs do not have these strings.
  use Gettext, backend: PhoenixKit.Newsletters.Gettext

  embed_templates("unsubscribe_html/*")
end
