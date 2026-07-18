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

  # Optional soft dependency — use module atom to avoid compile-time warnings
  @email_template_mod PhoenixKit.Modules.Emails.Template

  alias PhoenixKit.Email.ProviderOptions
  alias PhoenixKit.Email.SendProfile
  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Broadcast
  alias PhoenixKit.Newsletters.CRMSource
  alias PhoenixKit.Newsletters.Delivery
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
         {:ok, html_body, text_body} <- render_email(broadcast, recipient, unsubscribe_url),
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

      Newsletters.update_delivery_status(delivery, "sent", %{
        sent_at: UtilsDate.utc_now(),
        message_id: message_id
      })

      update_broadcast_counter(broadcast_uuid, :sent_count)

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

          record_permanent_failure(delivery_uuid, reason)
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

  defp record_permanent_failure(delivery_uuid, reason) do
    status = if match?({:blocked, _}, reason), do: "blocked", else: "failed"

    case get_delivery(delivery_uuid) do
      {:ok, delivery} ->
        # Deliberately does NOT touch :bounced_count.
        Newsletters.update_delivery_status(delivery, status, %{error: inspect(reason)})

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

  defp render_email(broadcast, recipient, unsubscribe_url) do
    variables = build_variables(recipient, unsubscribe_url)
    html = substitute_variables(broadcast.html_body || "", variables)
    text = substitute_variables(broadcast.text_body || "", variables)

    html = maybe_apply_template(html, broadcast)

    {:ok, html, text}
  end

  defp build_variables(recipient, unsubscribe_url) do
    %{
      "name" => recipient.username || recipient.email,
      "email" => recipient.email,
      "unsubscribe_url" => unsubscribe_url
    }
  end

  # newsletters-list recipient: the original user_uuid/list_uuid token,
  # unchanged — verified by the existing flavor in UnsubscribeController.
  # No List-Unsubscribe headers on this path (maybe_put_list_unsubscribe_headers/3
  # only fires for crm_list broadcasts), so the second element is unused.
  defp build_unsubscribe_url(%{uuid: uuid} = recipient, broadcast) when is_binary(uuid) do
    token = sign_unsubscribe_token(%{user_uuid: recipient.uuid, list_uuid: broadcast.list_uuid})
    {unsubscribe_page_url(token), nil}
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
  # RFC 8058 — only for crm_list-sourced broadcasts (newsletters_list
  # broadcasts keep their prior behavior exactly, no new headers) and
  # only when a personalized link actually resolved. `url` is the
  # dedicated one-click endpoint (Web.Routes' CSRF-exempt pipeline), NOT
  # the interactive landing-page URL used in the email body — a mail
  # client's cold POST can never carry a CSRF token, so it must target a
  # different route. Not `defp` so it can be unit-tested directly
  # without needing a real CRM-resolved url — same rationale as
  # `resolve_send_profile/1`/`build_profile_email/5` above.
  def maybe_put_list_unsubscribe_headers(email, %Broadcast{source_type: "crm_list"}, url)
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
  def handle_failure(delivery_uuid, broadcast_uuid, reason, terminal?) do
    case get_delivery(delivery_uuid) do
      {:ok, delivery} ->
        Newsletters.update_delivery_status(delivery, "failed", %{
          error: inspect(reason)
        })

        if terminal?, do: update_broadcast_counter(broadcast_uuid, :bounced_count)

      _ ->
        :ok
    end
  end

  defp update_broadcast_counter(broadcast_uuid, field) do
    import Ecto.Query

    PhoenixKit.Newsletters.Broadcast
    |> where([b], b.uuid == ^broadcast_uuid)
    |> repo().update_all(inc: [{field, 1}])
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # Intentional apply/3 — calls optional soft-dependency modules to avoid compile-time warnings
  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp soft_call(mod, fun, args), do: apply(mod, fun, args)
end
