defmodule PhoenixKit.Newsletters.Layouts do
  @moduledoc """
  Context for broadcast layouts (`PhoenixKit.Newsletters.Layout`): listing,
  lookup, create/update, archive/restore, and the site's default layout.

  The default layout is the `newsletters_default_template` setting — the
  key predates this table (it used to name an email template), and the
  rows carried over by migration V2 keep their uuids, so a value written
  before the move still points at the same layout. It is only a default for
  NEW broadcasts in the editor; a broadcast stores its own `template_uuid`.
  """

  import Ecto.Query

  alias PhoenixKit.Newsletters.Layout
  alias PhoenixKit.Settings

  @default_setting "newsletters_default_template"

  @doc "The settings key holding the default layout's uuid."
  @spec default_setting_key() :: String.t()
  def default_setting_key, do: @default_setting

  @doc """
  Layouts, by name.

  ## Options

    * `:status` — `"active"` or `"archived"`; all when omitted.
  """
  @spec list_layouts(keyword()) :: [Layout.t()]
  def list_layouts(opts \\ []) do
    Layout
    |> maybe_status(Keyword.get(opts, :status))
    |> order_by([l], asc: l.name)
    |> repo().all()
  end

  @doc "The layout with `uuid`, or `nil` (also for a malformed uuid)."
  @spec get_layout(term()) :: Layout.t() | nil
  def get_layout(uuid) when is_binary(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} -> repo().get(Layout, uuid)
      :error -> nil
    end
  end

  def get_layout(_uuid), do: nil

  @doc "A changeset for the layout form."
  @spec change_layout(Layout.t(), map()) :: Ecto.Changeset.t()
  def change_layout(%Layout{} = layout, attrs \\ %{}), do: Layout.changeset(layout, attrs)

  @doc "Creates a layout."
  @spec create_layout(map()) :: {:ok, Layout.t()} | {:error, Ecto.Changeset.t()}
  def create_layout(attrs) do
    %Layout{}
    |> Layout.changeset(attrs)
    |> repo().insert()
  end

  @doc "Updates a layout."
  @spec update_layout(Layout.t(), map()) :: {:ok, Layout.t()} | {:error, Ecto.Changeset.t()}
  def update_layout(%Layout{} = layout, attrs) do
    layout
    |> Layout.changeset(attrs)
    |> repo().update()
  end

  @doc """
  Archives a layout: it leaves the broadcast editor's picker, and stops
  being the default if it was. Broadcasts that already use it keep
  rendering with it.
  """
  @spec archive_layout(Layout.t()) :: {:ok, Layout.t()} | {:error, Ecto.Changeset.t()}
  def archive_layout(%Layout{} = layout) do
    with {:ok, layout} <- set_status(layout, "archived") do
      # The raw setting, not default_layout_uuid/0: that reads an archived
      # layout as "no default" already, and the setting would be left behind
      # to make the layout the default again on restore.
      if Settings.get_setting(@default_setting) == layout.uuid, do: set_default_layout(nil)
      {:ok, layout}
    end
  end

  @doc "Makes an archived layout active again."
  @spec restore_layout(Layout.t()) :: {:ok, Layout.t()} | {:error, Ecto.Changeset.t()}
  def restore_layout(%Layout{} = layout), do: set_status(layout, "active")

  @doc """
  The default layout's uuid, or `nil` when none is set or the setting
  names something that is not an active layout.
  """
  @spec default_layout_uuid() :: String.t() | nil
  def default_layout_uuid do
    case get_layout(Settings.get_setting(@default_setting)) do
      %Layout{status: "active", uuid: uuid} -> uuid
      _ -> nil
    end
  end

  @doc """
  Sets the default layout for new broadcasts; `nil` clears it. Only an
  active layout can be the default.
  """
  @spec set_default_layout(Layout.t() | String.t() | nil) :: :ok | {:error, :not_active | term()}
  def set_default_layout(nil) do
    write_default("")
  end

  def set_default_layout(%Layout{status: "active", uuid: uuid}), do: write_default(uuid)
  def set_default_layout(%Layout{}), do: {:error, :not_active}

  def set_default_layout(uuid) when is_binary(uuid) do
    case get_layout(uuid) do
      %Layout{} = layout -> set_default_layout(layout)
      nil -> {:error, :not_active}
    end
  end

  # ── internals ──────────────────────────────────────────────────────────

  defp write_default(value) do
    case Settings.update_setting_with_module(@default_setting, value, "newsletters") do
      {:ok, _setting} -> :ok
      {:error, _} = error -> error
    end
  end

  defp set_status(layout, status) do
    layout
    |> Ecto.Changeset.change(status: status)
    |> repo().update()
  end

  defp maybe_status(query, status) when is_binary(status) and status != "",
    do: where(query, [l], l.status == ^status)

  defp maybe_status(query, _status), do: query

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
