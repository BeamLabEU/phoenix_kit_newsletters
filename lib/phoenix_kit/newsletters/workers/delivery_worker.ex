defmodule PhoenixKit.Newsletters.Workers.DeliveryWorker do
  @moduledoc """
  Oban worker for sending a single broadcast email to one recipient.

  ## Job Arguments

  - `delivery_uuid` - UUID of the Delivery record
  - `broadcast_uuid` - UUID of the Broadcast record

  ## Queue Configuration

  Add to your Oban config (concurrency controls rate limiting):

      config :my_app, Oban,
        queues: [newsletters_delivery: 10]

  The `newsletters_rate_limit` setting (default: 14 emails/sec) maps to queue concurrency.
  Parent app should read `Settings.get_setting("newsletters_rate_limit", "10")` and apply to Oban queue config.
  """

  use Oban.Worker,
    queue: :newsletters_delivery,
    max_attempts: 3,
    unique: [period: :infinity, keys: [:delivery_uuid], states: :incomplete]

  require Logger

  import Ecto.Query

  # Optional soft dependency — use module atom to avoid compile-time warnings
  @email_template_mod PhoenixKit.Modules.Emails.Template

  alias PhoenixKit.Email.ProviderOptions
  alias PhoenixKit.Email.SendProfile
  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Broadcast
  alias PhoenixKit.Newsletters.CRMSource
  alias PhoenixKit.Newsletters.Delivery
  alias PhoenixKit.Newsletters.PreferenceToken
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"delivery_uuid" => delivery_uuid, "broadcast_uuid" => broadcast_uuid},
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    with {:ok, delivery} <- get_delivery(delivery_uuid),
         {:ok, delivery} <- guard_unsent(delivery),
         {:ok, broadcast} <- get_broadcast(broadcast_uuid),
         {:ok, recipient} <- get_recipient(delivery),
         {unsubscribe_url, list_unsubscribe_url} = build_unsubscribe_url(recipient, broadcast),
         preferences_url = build_preferences_url(recipient, broadcast),
         {:ok, html_body, text_body} <-
           render_email(broadcast, recipient, unsubscribe_url, preferences_url),
         {:ok, result} <-
           send_email(
             broadcast,
             recipient,
             html_body,
             text_body,
             unsubscribe_url,
             list_unsubscribe_url
           ) do
      message_id = Map.get(result, :id)

      update_delivery_result(
        delivery,
        "sent",
        %{sent_at: UtilsDate.utc_now(), message_id: message_id},
        broadcast_uuid,
        :sent_count
      )

      :ok
    else
      # A retry (Oban's own, or a re-enqueue) landing on a delivery that
      # already succeeded — most plausibly the DB write for "sent" landed
      # but this same job was retried anyway (a crash/restart racing the
      # ack). Not a failure: skip re-sending rather than emailing the
      # recipient twice.
      {:error, {:already_sent, %Delivery{uuid: uuid}}} ->
        Logger.info(
          "DeliveryWorker: delivery #{uuid} already marked sent — skipping duplicate send"
        )

        :ok

      {:error, reason} ->
        if permanent_failure?(reason) do
          # Permanent conditions — a blocklisted recipient, or a profile whose
          # integration is gone/unusable. Retrying cannot help, and neither is
          # a delivery that bounced: counting them would re-inflate
          # bounced_count on every later broadcast for the very addresses the
          # blocklist already caught once, corrupting the deliverability
          # metric the blocklist exists to protect. Cancel instead of burning
          # all 3 Oban attempts.
          Logger.warning(
            "DeliveryWorker: permanent failure for #{delivery_uuid}: #{inspect(reason)}"
          )

          record_permanent_failure(delivery_uuid, broadcast_uuid, reason)
          {:cancel, inspect(reason)}
        else
          Logger.error("DeliveryWorker: Failed delivery #{delivery_uuid}: #{inspect(reason)}")
          handle_failure(delivery_uuid, broadcast_uuid, reason, attempt >= max_attempts)
          {:error, inspect(reason)}
        end
    end
  end

  # Idempotency guard: a delivery whose status is already "sent" must
  # never be re-sent, regardless of why perform/1 got invoked again.
  defp guard_unsent(%Delivery{status: "sent"} = delivery), do: {:error, {:already_sent, delivery}}
  defp guard_unsent(delivery), do: {:ok, delivery}

  @doc false
  # Blocklisted recipient, or the send profile's integration is deleted /
  # misconfigured. Neither improves on retry, and neither is a bounce.
  def permanent_failure?({:blocked, _reason}), do: true
  def permanent_failure?(:deleted), do: true
  def permanent_failure?(:not_configured), do: true
  def permanent_failure?(:unsupported_provider), do: true
  def permanent_failure?({:unsupported_provider, _}), do: true
  def permanent_failure?({:invalid_smtp_port, _}), do: true
  def permanent_failure?(_), do: false

  defp record_permanent_failure(delivery_uuid, broadcast_uuid, reason) do
    status = if match?({:blocked, _}, reason), do: "blocked", else: "failed"

    case get_delivery(delivery_uuid) do
      {:ok, delivery} ->
        # Deliberately passes no counter_field — neither :sent_count nor
        # :bounced_count is touched, so a blocklisted/misconfigured
        # recipient never re-inflates the bounce-rate metric. It still
        # goes through update_delivery_result/5 (not a bare status write)
        # so the broadcast-finalize check runs: a broadcast whose very
        # last delivery lands here must still be able to flip to "sent".
        update_delivery_result(delivery, status, %{error: inspect(reason)}, broadcast_uuid, nil)

      _ ->
        :ok
    end
  end

  defp get_delivery(uuid) do
    case repo().get(Delivery, uuid) do
      nil -> {:error, :delivery_not_found}
      delivery -> {:ok, delivery}
    end
  end

  defp get_broadcast(uuid) do
    {:ok, Newsletters.get_broadcast!(uuid)}
  rescue
    Ecto.NoResultsError -> {:error, :broadcast_not_found}
  end

  defp get_user(user_uuid) do
    case repo().get(PhoenixKit.Users.Auth.User, user_uuid) do
      nil -> {:error, :user_not_found}
      user -> {:ok, user}
    end
  end

  # The recipient is either a core User (newsletters-list broadcast — the
  # original path, unchanged) or a plain map standing in for one (crm_list
  # broadcast — no core User exists for most CRM contacts). Both shapes
  # answer `.email`/`.username`/`.uuid`, so render_email/2 and send_email/4
  # below don't need to know which kind they got.
  defp get_recipient(%Delivery{user_uuid: user_uuid})
       when is_binary(user_uuid) and user_uuid != "" do
    get_user(user_uuid)
  end

  defp get_recipient(%Delivery{recipient_email: email}) when is_binary(email) and email != "" do
    {:ok, %{uuid: nil, username: nil, email: email}}
  end

  defp get_recipient(%Delivery{}), do: {:error, :no_recipient}

  defp render_email(broadcast, recipient, unsubscribe_url, preferences_url) do
    variables = build_variables(recipient, unsubscribe_url, preferences_url)
    html = substitute_variables(broadcast.html_body || "", variables)
    text = substitute_variables(broadcast.text_body || "", variables)

    html = maybe_apply_template(html, broadcast)

    {:ok, html, text}
  end

  defp build_variables(recipient, unsubscribe_url, preferences_url) do
    %{
      "name" => recipient.username || recipient.email,
      "email" => recipient.email,
      "unsubscribe_url" => unsubscribe_url,
      "preferences_url" => preferences_url
    }
  end

  # newsletters-list recipient: the original user_uuid/list_uuid token,
  # unchanged — verified by the existing flavor in UnsubscribeController.
  # Same token backs both URLs, same reasoning as the crm_list clause
  # below: the interactive landing page for the email body link, and the
  # dedicated one-click endpoint for the List-Unsubscribe(-Post) headers.
  defp build_unsubscribe_url(%{uuid: uuid} = recipient, broadcast) when is_binary(uuid) do
    token = sign_unsubscribe_token(%{user_uuid: recipient.uuid, list_uuid: broadcast.list_uuid})
    {unsubscribe_page_url(token), one_click_unsubscribe_url(token)}
  end

  # crm_list recipient: no core User exists, so the token carries
  # contact_uuid/crm_list_uuid instead — resolved by looking the
  # delivery's snapshotted email back up in the CRM list (the same
  # lookup Broadcaster's resolver already relies on being unique per
  # list). No match (contact/list gone since send time) means no
  # personalized link rather than a broken one. Two URLs share the same
  # signed token: the interactive landing page (email body link, behind
  # the host's normal CSRF-protected :browser pipeline) and the
  # dedicated one-click endpoint (List-Unsubscribe headers, CSRF-exempt
  # by design — see Web.Routes) — they must differ because a mail
  # client's cold POST can never carry a CSRF token.
  defp build_unsubscribe_url(%{uuid: nil, email: email}, %{crm_list_uuid: crm_list_uuid})
       when is_binary(crm_list_uuid) do
    case CRMSource.get_member_by_email(crm_list_uuid, email) do
      %{contact_uuid: contact_uuid} ->
        token =
          sign_unsubscribe_token(%{contact_uuid: contact_uuid, crm_list_uuid: crm_list_uuid})

        {unsubscribe_page_url(token), one_click_unsubscribe_url(token)}

      nil ->
        {"", nil}
    end
  end

  defp build_unsubscribe_url(_recipient, _broadcast), do: {"", nil}

  defp sign_unsubscribe_token(token_data) do
    endpoint = PhoenixKit.Config.get(:endpoint, PhoenixKitWeb.Endpoint)
    Phoenix.Token.sign(endpoint, "unsubscribe", token_data)
  end

  defp unsubscribe_page_url(token), do: Routes.url("/newsletters/unsubscribe?token=#{token}")

  defp one_click_unsubscribe_url(token),
    do: Routes.url("/newsletters/unsubscribe/one-click?token=#{token}")

  # Preference-center link (spec §7) — only for crm_list recipients today.
  # Reuses the exact membership lookup build_unsubscribe_url/2's crm_list
  # clause already does, so the contact_uuid is the real, unambiguous
  # member of THIS list receiving THIS email (not a fresh directory-wide
  # email search, which could land on a different same-email contact under
  # the "always create new contact" import policy, §4.3).
  #
  # Deliberately does NOT extend to the legacy `%{uuid: uuid}` (newsletters
  # user-list) recipient shape — that would mean lazily creating a CRM
  # contact for every legacy-list recipient on every single send (a
  # write on the hot delivery path, for a system slated for removal once
  # §4.5's migration lands). That eager-linking case belongs with the
  # user_group/role recipient work (S4-C) and the list migration (S4-E),
  # not here — until then, a legacy-list recipient simply gets no
  # preferences link, same "no match, no broken link" precedent as
  # build_unsubscribe_url/2's own catch-all.
  defp build_preferences_url(%{uuid: nil, email: email}, %{crm_list_uuid: crm_list_uuid})
       when is_binary(email) and is_binary(crm_list_uuid) do
    case CRMSource.get_member_by_email(crm_list_uuid, email) do
      %{contact_uuid: contact_uuid} -> preferences_page_url(sign_preferences_token(contact_uuid))
      nil -> ""
    end
  end

  defp build_preferences_url(_recipient, _broadcast), do: ""

  defp sign_preferences_token(contact_uuid), do: PreferenceToken.sign(contact_uuid)

  defp preferences_page_url(token), do: Routes.url("/newsletters/preferences?token=#{token}")

  defp substitute_variables(content, variables) do
    Enum.reduce(variables, content, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", to_string(value))
    end)
  end

  defp maybe_apply_template(content, %{template_uuid: nil}), do: content

  defp maybe_apply_template(content, %{template_uuid: template_uuid}) do
    # Guard: Emails.Template is an optional dependency
    if Code.ensure_loaded?(PhoenixKit.Modules.Emails.Template) do
      apply_email_template(content, template_uuid)
    else
      content
    end
  end

  defp apply_email_template(content, template_uuid) do
    case repo().get(@email_template_mod, template_uuid) do
      nil ->
        content

      tmpl ->
        html = soft_call(@email_template_mod, :get_translation, [tmpl.html_body, "en"])
        String.replace(html, "{{content}}", content)
    end
  end

  defp send_email(
         broadcast,
         recipient,
         html_body,
         text_body,
         unsubscribe_url,
         list_unsubscribe_url
       ) do
    case resolve_send_profile(broadcast) do
      nil ->
        send_email_legacy(
          broadcast,
          recipient,
          html_body,
          text_body,
          unsubscribe_url,
          list_unsubscribe_url
        )

      profile ->
        deliver_profile_email(
          profile,
          broadcast,
          recipient,
          html_body,
          text_body,
          unsubscribe_url,
          list_unsubscribe_url
        )
    end
  end

  @doc false
  # Resolution order: the broadcast's own send_profile_uuid, falling back
  # to the service-wide default profile, falling back to nil (the legacy
  # single-Mailer path below). Not `defp` so it can be unit-tested
  # directly — mirrors core `PhoenixKit.Mailer.swoosh_config_for/1`'s
  # rationale (`@doc false` because it's an internal seam, not public API).
  def resolve_send_profile(%Broadcast{send_profile_uuid: uuid})
      when is_binary(uuid) and uuid != "" do
    case SendProfiles.get_send_profile(uuid) do
      %SendProfile{enabled: true} = profile ->
        profile

      # A disabled (or deleted) pinned profile must NOT send. `enabled` is an
      # operator kill-switch — e.g. the profile's from_email got blacklisted by
      # a provider and sending from it must stop NOW, without deleting the
      # profile. Fall through to the default profile, then to the legacy
      # mailer; never silently send from a sender the operator switched off.
      _disabled_or_missing ->
        SendProfiles.get_default_send_profile()
    end
  end

  def resolve_send_profile(%Broadcast{}) do
    SendProfiles.get_default_send_profile()
  end

  # No profile resolved — unchanged from the original single-Mailer
  # behavior, so existing user-list broadcasts keep sending identically.
  defp send_email_legacy(
         broadcast,
         recipient,
         html_body,
         text_body,
         _unsubscribe_url,
         list_unsubscribe_url
       ) do
    from_email = PhoenixKit.Settings.get_setting("from_email", "noreply@example.com")
    from_name = PhoenixKit.Settings.get_setting("from_name", "Newsletter")

    Swoosh.Email.new()
    |> Swoosh.Email.to(recipient.email)
    |> Swoosh.Email.from({from_name, from_email})
    |> Swoosh.Email.subject(broadcast.subject)
    |> Swoosh.Email.html_body(html_body)
    |> Swoosh.Email.text_body(text_body)
    |> maybe_put_list_unsubscribe_headers(broadcast, list_unsubscribe_url)
    |> PhoenixKit.Mailer.deliver_email()
  end

  defp deliver_profile_email(
         profile,
         broadcast,
         recipient,
         html_body,
         text_body,
         _unsubscribe_url,
         list_unsubscribe_url
       ) do
    profile
    |> build_profile_email(broadcast, recipient, html_body, text_body)
    |> maybe_put_list_unsubscribe_headers(broadcast, list_unsubscribe_url)
    |> PhoenixKit.Mailer.deliver_via_integration(profile.integration_uuid)
  end

  @doc false
  # RFC 8058 — for both broadcast flavors, whenever a personalized
  # one-click link actually resolved. `url` is the dedicated one-click
  # endpoint (Web.Routes' CSRF-exempt pipeline), NOT the interactive
  # landing-page URL used in the email body — a mail client's cold POST
  # can never carry a CSRF token, so it must target a different route.
  # Not `defp` so it can be unit-tested directly without needing a real
  # CRM-resolved url — same rationale as
  # `resolve_send_profile/1`/`build_profile_email/5` above.
  def maybe_put_list_unsubscribe_headers(email, %Broadcast{}, url)
      when is_binary(url) and url != "" do
    email
    |> Swoosh.Email.header("List-Unsubscribe", "<#{url}>")
    |> Swoosh.Email.header("List-Unsubscribe-Post", "List-Unsubscribe=One-Click")
  end

  def maybe_put_list_unsubscribe_headers(email, _broadcast, _url), do: email

  @doc false
  # Builds the Swoosh.Email for a profile-routed send: identity
  # (from name/email, falling back to the legacy settings), reply-to,
  # and the profile's signature appended to both bodies. Not `defp` so
  # it can be unit-tested directly without triggering real delivery —
  # same rationale as `resolve_send_profile/1` above. Actual delivery
  # via the resolved integration (SES/SMTP/Brevo) is exercised live in
  # D5 against real credentials: `deliver_via_integration/3` resolves a
  # real Swoosh adapter from the integration's stored provider, so
  # there's no Swoosh.Adapters.Test seam for that leg.
  def build_profile_email(profile, broadcast, recipient, html_body, text_body) do
    from_name = profile.from_name || PhoenixKit.Settings.get_setting("from_name", "Newsletter")

    from_email =
      profile.from_email || PhoenixKit.Settings.get_setting("from_email", "noreply@example.com")

    Swoosh.Email.new()
    |> Swoosh.Email.to(recipient.email)
    |> Swoosh.Email.from({from_name, from_email})
    |> Swoosh.Email.subject(broadcast.subject)
    |> Swoosh.Email.html_body(append_signature(html_body, profile.signature_html))
    |> Swoosh.Email.text_body(append_signature(text_body, profile.signature_text))
    |> maybe_reply_to(profile.reply_to)
    |> put_provider_options(profile)
  end

  # The profile's provider-specific settings (SES configuration set, Brevo
  # sender ID/tags) only reach the provider through the email's
  # provider_options — until this existed, `advanced` was written by the
  # form and then read by nobody.
  defp put_provider_options(email, profile) do
    profile.provider_kind
    |> ProviderOptions.to_provider_options(profile.advanced)
    |> Enum.reduce(email, fn {key, value}, acc ->
      Swoosh.Email.put_provider_option(acc, key, value)
    end)
  end

  defp maybe_reply_to(email, reply_to) when is_binary(reply_to) and reply_to != "" do
    Swoosh.Email.reply_to(email, reply_to)
  end

  defp maybe_reply_to(email, _reply_to), do: email

  defp append_signature(body, signature) when is_binary(signature) and signature != "" do
    (body || "") <> signature
  end

  defp append_signature(body, _signature), do: body

  @doc false
  # `terminal?` is `attempt >= max_attempts` from the current Oban.Job —
  # only counted as a bounce once Oban has genuinely given up. An
  # intermediate transient failure that a later retry recovers from was
  # never actually a lost delivery; counting it here would inflate
  # bounced_count with no way to correct it afterward (a later successful
  # retry only ever increments sent_count, never touches bounced_count).
  # Not `defp` so it can be unit-tested directly — same rationale as
  # `resolve_send_profile/1` above.
  def handle_failure(delivery_uuid, broadcast_uuid, reason, true) do
    case get_delivery(delivery_uuid) do
      {:ok, delivery} ->
        update_delivery_result(
          delivery,
          "failed",
          %{error: inspect(reason)},
          broadcast_uuid,
          :bounced_count
        )

      _ ->
        :ok
    end
  end

  # Still-retryable: Oban has already scheduled another attempt, so this
  # delivery isn't actually done. Records the error for admin visibility
  # but deliberately does NOT advance `status` away from "pending" — the
  # only status Delivery.non_terminal_broadcast_uuids_query/0 treats as
  # incomplete. Writing "failed" here (as a prior version of this
  # function did unconditionally) would let a single transient failure on
  # a broadcast's last outstanding delivery finalize it to "sent" —
  # dropping the "Cancel broadcast" button (gated on status == "sending")
  # — while a send attempt is still queued to run.
  def handle_failure(delivery_uuid, _broadcast_uuid, reason, false) do
    case get_delivery(delivery_uuid) do
      {:ok, delivery} ->
        Newsletters.update_delivery_status(delivery, delivery.status, %{error: inspect(reason)})

      _ ->
        :ok
    end

    :ok
  end

  @doc false
  # Commits a delivery-status transition, its paired broadcast-counter
  # increment, and the broadcast-finalize check in a single DB
  # transaction. Previously the status write and counter increment were
  # two independent repo calls: a crash between them (e.g. the BEAM going
  # down right after the status write lands but before the counter write)
  # permanently undercounts, since a retry's guard_unsent/1 sees the
  # delivery already in its target status and skips re-counting.
  # `counter_field` may be `nil` to skip the counter write (e.g. a
  # non-terminal failure, or a permanent failure that must not touch
  # :bounced_count — see record_permanent_failure/3) — the finalize check
  # always runs regardless, since a blocked/permanently-failed delivery is
  # still one fewer delivery standing between the broadcast and "sent".
  # Exposed (non-`defp`) for direct testing — same rationale as
  # resolve_send_profile/1 et al above.
  def update_delivery_result(delivery, status, attrs, broadcast_uuid, counter_field) do
    repo().transaction(fn ->
      case Newsletters.update_delivery_status(delivery, status, attrs) do
        {:ok, updated} ->
          maybe_bump_counter(broadcast_uuid, counter_field)
          maybe_finalize_broadcast(broadcast_uuid)
          updated

        {:error, changeset} ->
          repo().rollback(changeset)
      end
    end)
  end

  defp maybe_bump_counter(_broadcast_uuid, nil), do: :ok

  defp maybe_bump_counter(broadcast_uuid, counter_field) do
    # 0 rows is a real case (a broadcast_uuid that no longer resolves to a
    # row, e.g. deleted concurrently) — silently no-op rather than crash,
    # matching this write's behavior before finalize was split out of it.
    Broadcast
    |> where([b], b.uuid == ^broadcast_uuid)
    |> repo().update_all(inc: [{counter_field, 1}])

    :ok
  end

  # Every delivery has left Delivery's only non-terminal status (see
  # Delivery.non_terminal_broadcast_uuids_query/0) while the broadcast is
  # still "sending": flip to "sent" in one statement — no separate
  # exists?/count round trip to race against a concurrent transition. The
  # `status == "sending"` guard makes this race-safe when two workers
  # finish within the same window — both may see coverage satisfied after
  # their own transition, but only the one whose UPDATE commits first
  # actually matches the WHERE clause; the other's matches zero rows
  # (status is already "sent") and silently no-ops. Also backs
  # `Newsletters.repair_stuck_sending_broadcasts/0`'s sweep for
  # broadcasts that got stuck before this existed.
  defp maybe_finalize_broadcast(broadcast_uuid) do
    Broadcast
    |> where([b], b.uuid == ^broadcast_uuid and b.status == "sending")
    |> where([b], b.uuid not in subquery(Delivery.non_terminal_broadcast_uuids_query()))
    |> repo().update_all(set: [status: "sent"])

    :ok
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # Intentional apply/3 — calls optional soft-dependency modules to avoid compile-time warnings
  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp soft_call(mod, fun, args), do: apply(mod, fun, args)
end
