defmodule PhoenixKit.Newsletters.Web.BroadcastEditorTest do
  @moduledoc """
  Direct callback-invocation unit tests for `BroadcastEditor` — no
  connected LiveView process needed (this package ships no real
  `PhoenixKitWeb.Endpoint`, so `Phoenix.LiveViewTest.live/2` isn't
  available here; see `config/test.exs`'s `:endpoint` comment). Uses
  `DataCase` because `handle_event("validate", ...)` always recomputes
  the CRM preflight (a real query) whenever `crm_list_uuid` is non-empty.
  """

  use PhoenixKitNewsletters.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Broadcast
  alias PhoenixKit.Newsletters.Paths
  alias PhoenixKit.Newsletters.Web.BroadcastEditor
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Roles
  alias PhoenixKitCRM.Lists
  alias PhoenixKitNewsletters.Test.Repo

  setup do
    Newsletters.enable_system()
    enable_crm()
    :ok
  end

  defp socket(assigns) do
    base = %{
      subject: "",
      source_type: "crm_list",
      crm_list_uuid: "",
      crm_lists: [],
      stranded_crm_list: nil,
      template_uuid: "",
      scheduled_at: "",
      markdown_content: "",
      templates: [],
      preview_locale: nil,
      preview_languages: [],
      preflight: nil,
      crm_list_archived?: false,
      broadcast: nil,
      saving: false,
      attachments: [],
      tz: "0",
      tz_label: "UTC+0",
      crm_available: true,
      can_send: true,
      phoenix_kit_current_scope: full_scope(),
      flash: %{},
      __changed__: %{}
    }

    %Phoenix.LiveView.Socket{assigns: Map.merge(base, assigns)}
  end

  defp role_with_reader do
    {:ok, role} = Roles.create_role(%{name: "ERole#{System.unique_integer([:positive])}"})

    {:ok, user} =
      %User{}
      |> User.guest_user_changeset(%{
        email: "reader-#{System.unique_integer([:positive])}@example.com"
      })
      |> Repo.insert()

    {:ok, _assignment} = Roles.assign_role(user, role.name)
    {role, user}
  end

  # What a schedule needs to reach the database.
  defp schedulable(attrs) do
    list_uuid = Ecto.UUID.generate()

    Map.merge(
      %{
        subject: "Hello",
        crm_list_uuid: list_uuid,
        crm_lists: [%{uuid: list_uuid}],
        markdown_content: "Body"
      },
      attrs
    )
  end

  test "switching from crm_list to user_group clears the stale crm_list_uuid" do
    socket = socket(%{source_type: "crm_list", crm_list_uuid: "some-crm-list-uuid"})

    {:noreply, updated} =
      BroadcastEditor.handle_event("validate", %{"source_type" => "user_group"}, socket)

    assert updated.assigns.source_type == "user_group"
    assert updated.assigns.crm_list_uuid == ""
  end

  # The button only checks `@subject == ""`, so spaces reach the changeset.
  test "Send now reports a rejected subject as a sentence, not as a changeset" do
    {:ok, role} = Roles.create_role(%{name: "ERole#{System.unique_integer([:positive])}"})

    socket =
      socket(%{source_type: "user_group", role_uuids: [role.uuid], available_roles: [role]})

    {:noreply, updated} =
      BroadcastEditor.handle_event(
        "submit",
        %{
          "action" => "send_now",
          "subject" => "   ",
          "source_type" => "user_group",
          "role_uuids" => [role.uuid],
          "editor_content" => "Body"
        },
        socket
      )

    assert updated.assigns.flash["error"] =~ "Subject: can't be blank"
    refute updated.assigns.flash["error"] =~ "Changeset"
  end

  test "picking a value without changing source_type doesn't clear anything" do
    picked_uuid = Ecto.UUID.generate()

    socket =
      socket(%{source_type: "crm_list", crm_list_uuid: "", crm_lists: [%{uuid: picked_uuid}]})

    {:noreply, updated} =
      BroadcastEditor.handle_event(
        "validate",
        %{"source_type" => "crm_list", "crm_list_uuid" => picked_uuid},
        socket
      )

    assert updated.assigns.crm_list_uuid == picked_uuid
  end

  describe "handle_event(\"schedule\", ...) — local time is interpreted in the viewer's timezone" do
    # Reaches save_broadcast/3 (a real Broadcast INSERT) — needs core V158's
    # attachments column; see test_helper.exs's :requires_v158 exclusion.
    @tag :requires_v158
    test "positive offset (UTC+3): local evening converts to UTC same day" do
      socket =
        socket(schedulable(%{scheduled_at: "2099-07-20T21:58", tz: "3"}))

      {:noreply, updated} = BroadcastEditor.handle_event("schedule", %{}, socket)

      assert updated.assigns.broadcast.status == "scheduled"
      assert updated.assigns.broadcast.scheduled_at == ~U[2099-07-20 18:58:00Z]
    end

    @tag :requires_v158
    test "negative offset (UTC-5): local late night rolls over to the next UTC day" do
      socket =
        socket(schedulable(%{scheduled_at: "2099-07-20T23:30", tz: "-5"}))

      {:noreply, updated} = BroadcastEditor.handle_event("schedule", %{}, socket)

      assert updated.assigns.broadcast.status == "scheduled"
      assert updated.assigns.broadcast.scheduled_at == ~U[2099-07-21 04:30:00Z]
    end

    @tag :requires_v158
    test "positive offset near midnight rolls back to the previous UTC day" do
      socket =
        socket(schedulable(%{scheduled_at: "2099-07-20T00:30", tz: "3"}))

      {:noreply, updated} = BroadcastEditor.handle_event("schedule", %{}, socket)

      assert updated.assigns.broadcast.status == "scheduled"
      assert updated.assigns.broadcast.scheduled_at == ~U[2099-07-19 21:30:00Z]
    end

    @tag :requires_v158
    test "zero offset (no personal/system timezone configured) preserves the old UTC-as-typed behavior" do
      socket =
        socket(schedulable(%{scheduled_at: "2099-07-20T21:58", tz: "0"}))

      {:noreply, updated} = BroadcastEditor.handle_event("schedule", %{}, socket)

      assert updated.assigns.broadcast.status == "scheduled"
      assert updated.assigns.broadcast.scheduled_at == ~U[2099-07-20 21:58:00Z]
    end

    test "an unparseable schedule value flashes an error instead of saving" do
      socket =
        socket(%{
          subject: "Hello",
          markdown_content: "Body",
          markdown_content: "Body",
          crm_list_uuid: Ecto.UUID.generate(),
          scheduled_at: "not-a-date",
          tz: "3"
        })

      {:noreply, updated} = BroadcastEditor.handle_event("schedule", %{}, socket)

      assert updated.assigns.broadcast == nil
      assert Phoenix.Flash.get(updated.assigns.flash, :error) =~ "valid schedule"
    end
  end

  describe "handle_params(:edit) — restores the schedule field in the viewer's local time" do
    @tag :requires_v158
    test "a UTC scheduled_at is displayed shifted into the viewer's timezone" do
      {:ok, broadcast} =
        Newsletters.create_broadcast(%{
          subject: "Hello",
          source_type: "crm_list",
          crm_list_uuid: Ecto.UUID.generate(),
          status: "draft",
          scheduled_at: ~U[2026-07-20 18:58:00Z]
        })

      socket =
        %Phoenix.LiveView.Socket{
          assigns: %{
            phoenix_kit_current_user: %{user_timezone: "3"},
            crm_lists: [],
            templates: [],
            preview_locale: nil,
            preview_languages: [],
            page_title: "",
            __changed__: %{}
          }
        }

      {:noreply, updated} =
        BroadcastEditor.handle_params(
          %{"id" => broadcast.uuid},
          "/admin/newsletters/broadcasts/#{broadcast.uuid}/edit",
          %{socket | assigns: Map.put(socket.assigns, :live_action, :edit)}
        )

      assert updated.assigns.scheduled_at == "2026-07-20T21:58"
    end
  end

  describe "attachments — a uuid that no longer resolves to a file" do
    # Storage.get_files/1 silently drops any uuid with no matching row —
    # load_attachment_files/1 must NOT let that silently shrink the chip
    # list (a deleted-from-Storage file becoming invisible, with no way to
    # specifically remove it): the missing uuid still appears, paired with
    # `nil` instead of a file.
    @tag :requires_v158
    test "shows up as a {uuid, nil} pair, not silently dropped" do
      missing_uuid = Ecto.UUID.generate()

      {:ok, broadcast} =
        Newsletters.create_broadcast(%{
          subject: "Hello",
          source_type: "crm_list",
          crm_list_uuid: Ecto.UUID.generate(),
          attachments: [missing_uuid]
        })

      socket =
        %Phoenix.LiveView.Socket{
          assigns: %{
            phoenix_kit_current_user: nil,
            crm_lists: [],
            templates: [],
            preview_locale: nil,
            preview_languages: [],
            page_title: "",
            __changed__: %{}
          }
        }

      {:noreply, updated} =
        BroadcastEditor.handle_params(
          %{"id" => broadcast.uuid},
          "/admin/newsletters/broadcasts/#{broadcast.uuid}/edit",
          %{socket | assigns: Map.put(socket.assigns, :live_action, :edit)}
        )

      assert updated.assigns.attachments == [missing_uuid]
      assert updated.assigns.attachment_files == [{missing_uuid, nil}]
    end
  end

  describe "schedule_preview/3" do
    test "shows the local time typed, its label, and the resolved UTC time" do
      preview = BroadcastEditor.schedule_preview("2026-07-20T21:58", "3", "UTC+3")

      assert preview == "Sends at 2026-07-20 21:58 (UTC+3) · 2026-07-20 18:58 UTC"
    end

    test "reflects a negative offset, including the day rollover in the UTC time" do
      preview = BroadcastEditor.schedule_preview("2026-07-20T23:30", "-5", "UTC-5")

      assert preview == "Sends at 2026-07-20 23:30 (UTC-5) · 2026-07-21 04:30 UTC"
    end

    test "is nil for an empty value" do
      assert BroadcastEditor.schedule_preview("", "3", "UTC+3") == nil
    end

    test "is nil for an unparseable value" do
      assert BroadcastEditor.schedule_preview("not-a-date", "3", "UTC+3") == nil
    end
  end

  describe "handle_params(:new) — resolves the viewer's timezone from the current user" do
    test "tz/tz_label come from phoenix_kit_current_user.user_timezone" do
      socket =
        %Phoenix.LiveView.Socket{
          assigns: %{
            phoenix_kit_current_user: %{user_timezone: "5"},
            crm_lists: [],
            templates: [],
            preview_locale: nil,
            preview_languages: [],
            template_uuid: "",
            page_title: "",
            live_action: :new,
            __changed__: %{}
          }
        }

      {:noreply, updated} =
        BroadcastEditor.handle_params(%{}, "/admin/newsletters/broadcasts/new", socket)

      assert updated.assigns.tz == "5"
      assert updated.assigns.tz_label == PhoenixKit.Settings.get_timezone_label("5")
    end
  end

  describe "submit routing — submitter buttons carry the full form" do
    # The regression this pins: Send now / Schedule used to be phx-click
    # buttons whose events carry NO form data, so the params-authoritative
    # role_uuids resolution wiped the selected roles to [] and every
    # user_group send failed changeset validation. As submit buttons the
    # full serialized form (role checkboxes included) reaches the handler.
    @tag :requires_v158
    test "submit with action=save_draft keeps role_uuids from the form params" do
      role_uuid = Ecto.UUID.generate()

      socket =
        socket(%{
          source_type: "user_group",
          role_uuids: [],
          subject: "wipe check",
          markdown_content: "hi",
          saving: false,
          broadcast: nil,
          tz: "0",
          available_roles: []
        })

      params = %{
        "action" => "save_draft",
        "subject" => "wipe check",
        "source_type" => "user_group",
        "role_uuids" => [role_uuid]
      }

      {:noreply, updated} = BroadcastEditor.handle_event("submit", params, socket)

      # save_broadcast runs and fails downstream (no template etc.) or
      # succeeds — either way the assigns must carry the submitted roles,
      # not a wiped [].
      assert updated.assigns.role_uuids == [role_uuid]
    end

    test "submit with an unknown/missing action falls back to save_draft" do
      socket =
        socket(%{
          source_type: "crm_list",
          crm_list_uuid: "",
          role_uuids: [],
          subject: "",
          markdown_content: "",
          saving: false,
          broadcast: nil,
          tz: "0",
          available_roles: []
        })

      assert {:noreply, _} = BroadcastEditor.handle_event("submit", %{}, socket)
    end
  end

  describe "stranded CRM selection — a pick that fell out of the picker's options" do
    test "a selection missing from the options is kept as the stranded list" do
      {:ok, ops} =
        Lists.create_list(%{
          name: "Suppliers #{System.unique_integer([:positive])}",
          subscribable: false
        })

      # @crm_lists holds only subscribable lists, so this selection is absent
      # from the options — it must survive as the disabled <option selected>,
      # or the next save silently resets crm_list_uuid to "".
      socket =
        socket(%{
          source_type: "crm_list",
          crm_lists: [],
          broadcast: %Broadcast{crm_list_uuid: ops.uuid}
        })

      {:noreply, updated} =
        BroadcastEditor.handle_event(
          "validate",
          %{"source_type" => "crm_list", "crm_list_uuid" => ops.uuid},
          socket
        )

      assert updated.assigns.stranded_crm_list.uuid == ops.uuid
      refute updated.assigns.crm_list_archived?
    end

    test "a selection present in the options is not stranded" do
      {:ok, sub} =
        Lists.create_list(%{
          name: "Mailing #{System.unique_integer([:positive])}",
          subscribable: true
        })

      socket = socket(%{source_type: "crm_list", crm_lists: [sub]})

      {:noreply, updated} =
        BroadcastEditor.handle_event(
          "validate",
          %{"source_type" => "crm_list", "crm_list_uuid" => sub.uuid},
          socket
        )

      assert updated.assigns.stranded_crm_list == nil
    end

    test "an archived selection is both stranded and flagged archived" do
      {:ok, list} =
        Lists.create_list(%{
          name: "Old campaign #{System.unique_integer([:positive])}",
          subscribable: true
        })

      {:ok, archived} = Lists.archive_list(list)

      socket =
        socket(%{
          source_type: "crm_list",
          crm_lists: [],
          broadcast: %Broadcast{crm_list_uuid: archived.uuid}
        })

      {:noreply, updated} =
        BroadcastEditor.handle_event(
          "validate",
          %{"source_type" => "crm_list", "crm_list_uuid" => archived.uuid},
          socket
        )

      assert updated.assigns.stranded_crm_list.uuid == archived.uuid
      assert updated.assigns.crm_list_archived?
    end

    test "a uuid that resolves to nothing strands nothing and is not archived" do
      socket = socket(%{source_type: "crm_list", crm_lists: []})

      {:noreply, updated} =
        BroadcastEditor.handle_event(
          "validate",
          %{"source_type" => "crm_list", "crm_list_uuid" => Ecto.UUID.generate()},
          socket
        )

      assert updated.assigns.stranded_crm_list == nil
      refute updated.assigns.crm_list_archived?
    end
  end

  describe "layouts in the editor" do
    alias PhoenixKit.Newsletters.Layouts

    defp create_layout(name, html, status \\ "active") do
      {:ok, layout} =
        Layouts.create_layout(%{"name" => name, "html_body" => html, "status" => status})

      layout
    end

    test "the preview renders the chosen layout in the chosen language" do
      layout =
        create_layout("welcome_layout", %{
          "en" => "<i>EN</i>{{{content}}}",
          "de" => "<i>DE</i>{{{content}}}"
        })

      socket =
        socket(%{
          templates: [layout],
          template_uuid: layout.uuid,
          markdown_content: "Hello **there**",
          preview_locale: "en",
          preview_languages: ["en", "de"]
        })

      {:noreply, updated} =
        BroadcastEditor.handle_event("validate", %{"preview_locale" => "de"}, socket)

      assert updated.assigns.preview_locale == "de"
      assert updated.assigns.preview_html =~ "<i>DE</i>"
      assert updated.assigns.preview_html =~ "<strong>there</strong>"
    end

    test "a preview language the picker does not offer is ignored" do
      socket = socket(%{preview_locale: "en", preview_languages: ["en", "de"]})

      {:noreply, updated} =
        BroadcastEditor.handle_event("validate", %{"preview_locale" => "xx-made-up"}, socket)

      assert updated.assigns.preview_locale == "en"
    end

    test "without a layout the preview is core's standard layout" do
      html = BroadcastEditor.render_preview("Hello", "", [], "en", "Subject")
      assert html =~ "<!DOCTYPE html>"
      assert html =~ "Hello"
    end

    test "shows the unsubscribe line a send would add" do
      assert BroadcastEditor.render_preview("Hello", "", [], "en", "Subject") =~
               ">Unsubscribe</a>"
    end

    test "shows no second line when the body has its own link" do
      markdown = "[Leave]({{unsubscribe_url}})"

      html = BroadcastEditor.render_preview(markdown, "", [], "en", "Subject")

      assert html =~ ">Leave</a>"
      refute html =~ ">Unsubscribe</a>"
    end

    test "an empty body previews as nothing, so the hint shows" do
      assert BroadcastEditor.render_preview("  ", "", [], "en", "Subject") == ""
    end

    test "shows the send profile's signature after the body, above the unsubscribe line" do
      html =
        BroadcastEditor.render_preview("Hello", "", [], "en", "Subject",
          signature: "<p>Best, Acme</p>"
        )

      assert html =~ ~r{<p>Hello</p>\s*<p>Best, Acme</p>.*>Unsubscribe</a>}s
    end

    test "the picker offers active layouts, plus the broadcast's own when archived" do
      active = create_layout("active_layout", %{"en" => "{{{content}}}"})
      archived = create_layout("old_layout", %{"en" => "{{{content}}}"}, "archived")

      {:ok, broadcast} =
        Newsletters.create_broadcast(%{
          subject: "Uses an archived layout",
          source_type: "user_group",
          source_params: %{"role_uuids" => [Ecto.UUID.generate()]},
          template_uuid: archived.uuid
        })

      socket =
        socket(%{phoenix_kit_current_user: nil, current_locale: nil, live_action: :edit})
        |> Map.update!(:assigns, &Map.merge(&1, %{preview_languages: [], attachment_files: []}))

      {:noreply, updated} =
        BroadcastEditor.handle_params(%{"id" => broadcast.uuid}, "/", socket)

      uuids = Enum.map(updated.assigns.templates, & &1.uuid)
      assert active.uuid in uuids
      assert archived.uuid in uuids
      assert updated.assigns.template_uuid == archived.uuid

      {:noreply, fresh} =
        BroadcastEditor.handle_params(%{}, "/", %{
          socket
          | assigns: %{socket.assigns | live_action: :new}
        })

      refute archived.uuid in Enum.map(fresh.assigns.templates, & &1.uuid)
    end

    test "a new broadcast starts with the default layout" do
      layout = create_layout("default_layout", %{"en" => "{{{content}}}"})
      :ok = Layouts.set_default_layout(layout)

      socket =
        socket(%{live_action: :new})
        |> Map.update!(:assigns, &Map.merge(&1, %{preview_languages: []}))

      {:noreply, updated} = BroadcastEditor.handle_params(%{}, "/", socket)
      assert updated.assigns.template_uuid == layout.uuid
    end
  end

  describe "only a draft is edited" do
    @describetag :requires_v158

    defp persisted(attrs \\ %{}) do
      base = %{
        subject: "Original",
        source_type: "crm_list",
        crm_list_uuid: Ecto.UUID.generate(),
        markdown_body: "Body"
      }

      {:ok, broadcast} = Newsletters.create_broadcast(Map.merge(base, attrs))
      broadcast
    end

    defp edit_socket do
      socket(%{
        phoenix_kit_current_user: %{user_timezone: "0"},
        live_action: :edit,
        page_title: ""
      })
    end

    defp open_for_edit(id) do
      BroadcastEditor.handle_params(%{"id" => id}, "/edit", edit_socket())
    end

    defp edited_params, do: %{"subject" => "EDITED", "source_type" => "crm_list"}

    for status <- ~w(scheduled sending sent cancelled failed) do
      test "a #{status} broadcast opens its details instead of the form" do
        broadcast = persisted(%{status: unquote(status)})

        assert {:noreply, updated} = open_for_edit(broadcast.uuid)

        assert updated.assigns.flash["error"] =~ "Only a draft"
        assert {:live, :redirect, %{to: to}} = updated.redirected
        assert to =~ broadcast.uuid
        assert updated.assigns.broadcast == nil
      end
    end

    test "a draft opens in the form" do
      broadcast = persisted()

      assert {:noreply, updated} = open_for_edit(broadcast.uuid)
      assert updated.assigns.broadcast.uuid == broadcast.uuid
      assert updated.redirected == nil
    end

    test "an id that is not a uuid is reported, not crashed on" do
      assert {:noreply, updated} = open_for_edit("garbage")
      assert updated.assigns.flash["error"] =~ "not found"
    end

    for status <- ~w(scheduled sending sent cancelled) do
      test "Save draft from a tab open since the broadcast became #{status} changes nothing" do
        stale = persisted()
        {:ok, _moved_on} = Newsletters.update_broadcast(stale, %{status: unquote(status)})

        assert {:noreply, updated} =
                 BroadcastEditor.handle_event(
                   "save_draft",
                   edited_params(),
                   socket(%{broadcast: stale, crm_list_uuid: stale.crm_list_uuid})
                 )

        assert updated.assigns.flash["error"] =~ "Only a draft"

        assert %Broadcast{subject: "Original", status: unquote(status)} =
                 Newsletters.get_broadcast!(stale.uuid)
      end

      test "Send now from a tab open since the broadcast became #{status} changes nothing" do
        stale = persisted()
        {:ok, _moved_on} = Newsletters.update_broadcast(stale, %{status: unquote(status)})

        assert {:noreply, _updated} =
                 BroadcastEditor.handle_event(
                   "send_now",
                   edited_params(),
                   socket(%{broadcast: stale, crm_list_uuid: stale.crm_list_uuid})
                 )

        assert %Broadcast{subject: "Original", status: unquote(status), sent_at: nil} =
                 Newsletters.get_broadcast!(stale.uuid)
      end
    end

    test "a save on a broadcast deleted since reports it" do
      stale = persisted()
      {:ok, _deleted} = Newsletters.delete_broadcast(stale)

      assert {:noreply, updated} =
               BroadcastEditor.handle_event(
                 "save_draft",
                 edited_params(),
                 socket(%{broadcast: stale, crm_list_uuid: stale.crm_list_uuid})
               )

      assert updated.assigns.flash["error"] =~ "not found"
    end
  end

  describe "a Send now that is refused" do
    @describetag :requires_v158

    test "keeps the one draft it saved, however many times it is clicked" do
      {:ok, list} = Lists.create_list(%{name: "Archived #{System.unique_integer([:positive])}"})
      {:ok, _list} = Lists.archive_list(list)

      subject = "Refused #{System.unique_integer([:positive])}"

      params = %{
        "subject" => subject,
        "source_type" => "crm_list",
        "crm_list_uuid" => list.uuid,
        "editor_content" => "Body"
      }

      socket =
        Enum.reduce(1..3, socket(%{crm_lists: [list]}), fn _click, socket ->
          {:noreply, saved} = BroadcastEditor.handle_event("send_now", params, socket)
          {:noreply, updated} = run_deferred_send(saved)
          assert updated.assigns.flash["error"] =~ "not active"
          refute updated.assigns.sending
          updated
        end)

      assert [%Broadcast{uuid: uuid, status: "draft"}] =
               Repo.all(from(b in Broadcast, where: b.subject == ^subject))

      assert socket.assigns.broadcast.uuid == uuid
    end
  end

  describe "the body comes from the form" do
    # A mouse paste, a drag and a reconnect press no key, so `editor_content` in
    # the form is the only place their text ever reaches the server.
    test "phx-change carries a body no key press reported" do
      {:noreply, updated} =
        BroadcastEditor.handle_event(
          "validate",
          %{"editor_content" => "Pasted **text**"},
          socket(%{subject: "Hello"})
        )

      assert updated.assigns.markdown_content == "Pasted **text**"
      assert updated.assigns.preview_html =~ "<strong>text</strong>"
    end

    test "Send now sends what is in the form, not what the last key press left" do
      start_supervised!({Oban, repo: Repo, testing: :manual, queues: [], plugins: false})
      {role, _user} = role_with_reader()

      {:noreply, saved} =
        BroadcastEditor.handle_event(
          "submit",
          %{
            "action" => "send_now",
            "subject" => "Pasted",
            "source_type" => "user_group",
            "role_uuids" => [role.uuid],
            "editor_content" => "From the form"
          },
          socket(%{
            source_type: "user_group",
            available_roles: [role],
            markdown_content: "Stale"
          })
        )

      run_deferred_send(saved)

      assert [%Broadcast{markdown_body: "From the form", status: "sending"}] =
               Repo.all(from(b in Broadcast, where: b.subject == "Pasted"))
    end

    test "a submit with no body field keeps the body already held" do
      {:noreply, updated} =
        BroadcastEditor.handle_event("validate", %{}, socket(%{markdown_content: "Held"}))

      assert updated.assigns.markdown_content == "Held"
    end

    for action <- ~w(send_now schedule) do
      test "#{action} refuses a blank body before anything is saved" do
        {role, _user} = role_with_reader()
        subject = "Blank #{System.unique_integer([:positive])}"

        {:noreply, updated} =
          BroadcastEditor.handle_event(
            "submit",
            %{
              "action" => unquote(action),
              "subject" => subject,
              "source_type" => "user_group",
              "role_uuids" => [role.uuid],
              "editor_content" => "   ",
              "scheduled_at" => "2099-01-01T10:00"
            },
            socket(%{source_type: "user_group", available_roles: [role]})
          )

        assert updated.assigns.flash["error"] == "Write the email body before sending."
        assert Repo.all(from(b in Broadcast, where: b.subject == ^subject)) == []
      end
    end

    test "a draft may be saved with no body yet" do
      subject = "Draft #{System.unique_integer([:positive])}"
      {role, _user} = role_with_reader()

      {:noreply, _updated} =
        BroadcastEditor.handle_event(
          "submit",
          %{
            "action" => "save_draft",
            "subject" => subject,
            "source_type" => "user_group",
            "role_uuids" => [role.uuid]
          },
          socket(%{source_type: "user_group", available_roles: [role]})
        )

      assert [%Broadcast{status: "draft"}] =
               Repo.all(from(b in Broadcast, where: b.subject == ^subject))
    end
  end

  describe "the schedule time" do
    test "a time already gone is refused, because the next tick would send it at once" do
      subject = "Late #{System.unique_integer([:positive])}"

      socket = socket(schedulable(%{subject: subject, scheduled_at: "2020-01-01T10:00"}))

      {:noreply, updated} = BroadcastEditor.handle_event("schedule", %{}, socket)

      assert updated.assigns.flash["error"] == "Please choose a time in the future"
      assert Repo.all(from(b in Broadcast, where: b.subject == ^subject)) == []
    end

    test "a draft keeps a time typed into it" do
      subject = "Later #{System.unique_integer([:positive])}"

      socket = socket(schedulable(%{subject: subject, scheduled_at: "2099-01-01T10:00"}))

      {:noreply, _updated} = BroadcastEditor.handle_event("save_draft", %{}, socket)

      assert [%Broadcast{status: "draft", scheduled_at: ~U[2099-01-01 10:00:00Z]}] =
               Repo.all(from(b in Broadcast, where: b.subject == ^subject))
    end

    test "a draft with nothing usable in the field keeps no time" do
      subject = "Undecided #{System.unique_integer([:positive])}"

      socket = socket(schedulable(%{subject: subject, scheduled_at: ""}))

      {:noreply, _updated} = BroadcastEditor.handle_event("save_draft", %{}, socket)

      assert [%Broadcast{status: "draft", scheduled_at: nil}] =
               Repo.all(from(b in Broadcast, where: b.subject == ^subject))
    end
  end

  describe "the preflight" do
    # Reads the whole audience, so it runs when the audience changes, not on every
    # keystroke in a form where every field reports.
    test "is not recomputed for a change that leaves the audience alone" do
      {role, _user} = role_with_reader()
      held = %{total: 99, sendable: 99, no_email: 0, unsendable: 0, stale_roles: 0}

      socket = socket(%{source_type: "user_group", role_uuids: [role.uuid], preflight: held})

      {:noreply, updated} =
        BroadcastEditor.handle_event(
          "validate",
          %{"subject" => "Typing", "source_type" => "user_group", "role_uuids" => [role.uuid]},
          socket
        )

      assert updated.assigns.preflight == held
    end

    test "is recomputed when the audience changes" do
      {role, _user} = role_with_reader()

      {:noreply, updated} =
        BroadcastEditor.handle_event(
          "validate",
          %{"source_type" => "user_group", "role_uuids" => [role.uuid]},
          socket(%{source_type: "user_group", role_uuids: []})
        )

      assert %{total: 1, sendable: 1} = updated.assigns.preflight
    end
  end

  describe "a crafted list uuid" do
    test "does not reach the assigns unless the picker offers it" do
      {:ok, segment} =
        Lists.create_list(%{
          name: "Suppliers #{System.unique_integer([:positive])}",
          subscribable: false
        })

      {:noreply, updated} =
        BroadcastEditor.handle_event(
          "validate",
          %{"source_type" => "crm_list", "crm_list_uuid" => segment.uuid},
          socket(%{source_type: "crm_list", crm_lists: []})
        )

      assert updated.assigns.crm_list_uuid == ""
    end
  end

  describe "a crafted role uuid" do
    test "never reaches the assigns, so it can't be saved or queried" do
      valid = Ecto.UUID.generate()

      {:noreply, updated} =
        BroadcastEditor.handle_event(
          "validate",
          %{"source_type" => "user_group", "role_uuids" => ["garbage", valid, %{"x" => "1"}]},
          socket(%{source_type: "user_group", available_roles: []})
        )

      assert updated.assigns.role_uuids == [valid]
    end
  end

  # Send now answers first and sends from a message to itself (see
  # BroadcastEditor.send_now/1); a hand-built socket has to be given it.
  defp run_deferred_send(socket) do
    assert_received {:send_now, %Broadcast{} = broadcast}
    BroadcastEditor.handle_info({:send_now, broadcast}, socket)
  end

  describe "Send now answers before it sends" do
    @describetag :requires_v158

    # A large audience can take longer to enqueue than the browser waits for an
    # answer, after which it reloads: on /new, an empty form beside a send still
    # going, and a second click mailed everyone again.
    test "on /new it saves the draft, moves to the draft's address and sends after" do
      start_supervised!({Oban, repo: Repo, testing: :manual, queues: [], plugins: false})
      {role, _user} = role_with_reader()
      subject = "Deferred #{System.unique_integer([:positive])}"

      {:noreply, saved} =
        BroadcastEditor.handle_event(
          "send_now",
          %{
            "subject" => subject,
            "source_type" => "user_group",
            "role_uuids" => [role.uuid],
            "editor_content" => "Body"
          },
          socket(%{source_type: "user_group", available_roles: [role], live_action: :new})
        )

      assert [%Broadcast{uuid: uuid, status: "draft"}] =
               Repo.all(from(b in Broadcast, where: b.subject == ^subject))

      assert saved.assigns.sending
      assert saved.assigns.broadcast.uuid == uuid
      assert {:live, :patch, %{to: to}} = saved.redirected
      assert to == Paths.broadcast_edit(uuid)

      # LiveView carries out the patch before the message arrives.
      {:noreply, sent} = run_deferred_send(%{saved | redirected: nil})

      assert %Broadcast{status: "sending"} = Newsletters.get_broadcast!(uuid)
      assert {:live, :redirect, %{to: details}} = sent.redirected
      assert details == Paths.broadcast_show(uuid)
    end

    test "records the author and drops a time the draft kept" do
      {role, user} = role_with_reader()
      subject = "Authored #{System.unique_integer([:positive])}"

      {:noreply, _saved} =
        BroadcastEditor.handle_event(
          "send_now",
          %{
            "subject" => subject,
            "source_type" => "user_group",
            "role_uuids" => [role.uuid],
            "editor_content" => "Body",
            "scheduled_at" => "2099-01-01T10:00"
          },
          socket(%{
            source_type: "user_group",
            available_roles: [role],
            phoenix_kit_current_user: user
          })
        )

      assert [%Broadcast{created_by_user_uuid: author, scheduled_at: nil}] =
               Repo.all(from(b in Broadcast, where: b.subject == ^subject))

      assert author == user.uuid
      assert_received {:send_now, _broadcast}
    end
  end

  describe "attachments in the form" do
    # Form recovery after a reconnect replays the form, and only the form.
    test "a form that carries the list restores it" do
      uuid = Ecto.UUID.generate()

      {:noreply, updated} =
        BroadcastEditor.handle_event(
          "validate",
          %{"attachments_sent" => "true", "attachments" => [uuid, uuid, "not-a-uuid"]},
          socket(%{attachments: []})
        )

      assert updated.assigns.attachments == [uuid]
      assert [{^uuid, nil}] = updated.assigns.attachment_files
    end

    test "an empty list in the form clears it, and no list leaves it alone" do
      uuid = Ecto.UUID.generate()

      {:noreply, cleared} =
        BroadcastEditor.handle_event(
          "validate",
          %{"attachments_sent" => "true"},
          socket(%{attachments: [uuid]})
        )

      assert cleared.assigns.attachments == []

      {:noreply, kept} =
        BroadcastEditor.handle_event("validate", %{}, socket(%{attachments: [uuid]}))

      assert kept.assigns.attachments == [uuid]
    end

    test "no more than a broadcast takes" do
      uuids = for _ <- 1..15, do: Ecto.UUID.generate()

      {:noreply, updated} =
        BroadcastEditor.handle_event(
          "validate",
          %{"attachments_sent" => "true", "attachments" => uuids},
          socket(%{attachments: []})
        )

      assert updated.assigns.attachments == Enum.take(uuids, Broadcast.max_attachments())
    end
  end
end
