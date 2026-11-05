defmodule PhoenixKit.Newsletters.Web.FormErrorsTest do
  use ExUnit.Case, async: false

  alias PhoenixKit.Newsletters.Broadcast
  alias PhoenixKit.Newsletters.Web.FormErrors

  defp changeset(attrs), do: Broadcast.changeset(%Broadcast{}, attrs)

  defp in_locale(locale, fun) do
    previous = Gettext.get_locale()
    Gettext.put_locale(locale)

    try do
      fun.()
    after
      Gettext.put_locale(previous)
    end
  end

  test "names the field the way the form does, and fills in the count" do
    too_long = String.duplicate("a", 999)
    summary = %{subject: too_long, source_type: "crm_list"} |> changeset() |> FormErrors.summary()

    assert summary =~ "Subject: should be at most 998 character(s)"
    refute summary =~ "%{count}"
  end

  test "says which field in the reader's language, for each locale" do
    errors = %{source_type: "user_group"} |> changeset()

    english = in_locale("en", fn -> FormErrors.summary(errors) end)
    russian = in_locale("ru", fn -> FormErrors.summary(errors) end)

    assert english =~ "Subject: can't be blank"
    assert english =~ "Roles: select at least one role"
    refute russian =~ "can't be blank"
    refute russian =~ "select at least one role"
  end

  test "every Ecto message it lists has a translation in every locale" do
    for locale <- ~w(et ru), message <- FormErrors.ecto_messages() do
      translated =
        in_locale(locale, fn -> FormErrors.translate({message, count: 3}) end)

      refute translated == String.replace(message, "%{count}", "3"),
             "#{inspect(message)} has no #{locale} translation"
    end
  end

  test "a message outside the catalogue comes back with its bindings filled" do
    assert FormErrors.translate({"needs %{count} more", count: 2}) == "needs 2 more"
  end
end
