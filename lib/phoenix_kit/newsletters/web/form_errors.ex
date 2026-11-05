defmodule PhoenixKit.Newsletters.Web.FormErrors do
  @moduledoc """
  Turns a changeset's errors into sentences for the admin forms, in the reader's
  language.

  Messages are msgids of this package's backend. Ecto writes its own in English,
  so the ones these forms can produce are listed here for the extractor to find;
  any other comes back as written, with its bindings filled in.
  """

  use Gettext, backend: PhoenixKit.Newsletters.Gettext

  @ecto_messages [
    gettext_noop("can't be blank"),
    gettext_noop("is invalid"),
    gettext_noop("does not exist"),
    gettext_noop("should be at least %{count} character(s)"),
    gettext_noop("should be at most %{count} character(s)"),
    gettext_noop("should have at most %{count} item(s)")
  ]

  @doc "Ecto's own messages this module carries translations for."
  @spec ecto_messages() :: [String.t()]
  def ecto_messages, do: @ecto_messages

  @doc "One `Field: message` sentence per error."
  @spec messages(Ecto.Changeset.t()) :: [String.t()]
  def messages(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&translate/1)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, &"#{label(field)}: #{&1}")
    end)
  end

  @doc "Every error as one line, for a flash."
  @spec summary(Ecto.Changeset.t()) :: String.t()
  def summary(%Ecto.Changeset{} = changeset), do: changeset |> messages() |> Enum.join(", ")

  @doc "Translates one `{message, opts}` error and fills in its bindings."
  @spec translate({String.t(), keyword()}) :: String.t()
  def translate({message, opts}) do
    bindings = for {key, value} <- opts, scalar?(value), into: %{}, do: {key, value}
    Gettext.dgettext(PhoenixKit.Newsletters.Gettext, "default", message, bindings)
  end

  defp scalar?(value), do: is_binary(value) or is_number(value) or is_atom(value)

  defp label(:name), do: gettext("Name")
  defp label(:display_name), do: gettext("Display name")
  defp label(:subject), do: gettext("Subject")
  defp label(:html_body), do: gettext("HTML")
  defp label(:text_body), do: gettext("Text")
  defp label(:crm_list_uuid), do: gettext("CRM list")
  defp label(:source_params), do: gettext("Roles")
  defp label(:attachments), do: gettext("Attachments")
  defp label(:template_uuid), do: gettext("Template")
  defp label(other), do: to_string(other)
end
