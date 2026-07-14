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

  alias PhoenixKit.Newsletters
  alias PhoenixKit.Newsletters.Broadcast
  alias PhoenixKit.Newsletters.Delivery
  alias PhoenixKit.Newsletters.ProviderOptions
  alias PhoenixKit.Newsletters.SendProfile
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"delivery_uuid" => delivery_uuid, "broadcast_uuid" => broadcast_uuid}
      }) do
    with {:ok, delivery} <- get_delivery(delivery_uuid),
         {:ok, broadcast} <- get_broadcast(broadcast_uuid),
         {:ok, user} <- get_user(delivery.user_uuid),
         {:ok, html_body, text_body} <- render_email(broadcast, user),
         {:ok, result} <- send_email(broadcast, user, html_body, text_body) do
      message_id = Map.get(result, :id)

      Newsletters.update_delivery_status(delivery, "sent", %{
        sent_at: UtilsDate.utc_now(),
        message_id: message_id
      })

      update_broadcast_counter(broadcast_uuid, :sent_count)

      :ok
    else
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
          handle_failure(delivery_uuid, broadcast_uuid, reason)
          {:error, inspect(reason)}
        end
    end
  end

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

  defp render_email(broadcast, user) do
    variables = build_variables(broadcast, user)
    html = substitute_variables(broadcast.html_body || "", variables)
    text = substitute_variables(broadcast.text_body || "", variables)

    html = maybe_apply_template(html, broadcast)

    {:ok, html, text}
  end

  defp build_variables(broadcast, user) do
    token_data = %{user_uuid: user.uuid, list_uuid: broadcast.list_uuid}

    endpoint = PhoenixKit.Config.get(:endpoint, PhoenixKitWeb.Endpoint)

    unsubscribe_token =
      Phoenix.Token.sign(endpoint, "unsubscribe", token_data)

    unsubscribe_url =
      Routes.url("/newsletters/unsubscribe?token=#{unsubscribe_token}")

    %{
      "name" => user.username || user.email,
      "email" => user.email,
      "unsubscribe_url" => unsubscribe_url
    }
  end

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

  defp send_email(broadcast, user, html_body, text_body) do
    case resolve_send_profile(broadcast) do
      nil -> send_email_legacy(broadcast, user, html_body, text_body)
      profile -> deliver_profile_email(profile, broadcast, user, html_body, text_body)
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
    case Newsletters.get_send_profile(uuid) do
      %SendProfile{enabled: true} = profile ->
        profile

      # A disabled (or deleted) pinned profile must NOT send. `enabled` is an
      # operator kill-switch — e.g. the profile's from_email got blacklisted by
      # a provider and sending from it must stop NOW, without deleting the
      # profile. Fall through to the default profile, then to the legacy
      # mailer; never silently send from a sender the operator switched off.
      _disabled_or_missing ->
        Newsletters.get_default_send_profile()
    end
  end

  def resolve_send_profile(%Broadcast{}) do
    Newsletters.get_default_send_profile()
  end

  # No profile resolved — unchanged from the original single-Mailer
  # behavior, so existing user-list broadcasts keep sending identically.
  defp send_email_legacy(broadcast, user, html_body, text_body) do
    from_email = PhoenixKit.Settings.get_setting("from_email", "noreply@example.com")
    from_name = PhoenixKit.Settings.get_setting("from_name", "Newsletter")

    Swoosh.Email.new()
    |> Swoosh.Email.to(user.email)
    |> Swoosh.Email.from({from_name, from_email})
    |> Swoosh.Email.subject(broadcast.subject)
    |> Swoosh.Email.html_body(html_body)
    |> Swoosh.Email.text_body(text_body)
    |> PhoenixKit.Mailer.deliver_email()
  end

  defp deliver_profile_email(profile, broadcast, user, html_body, text_body) do
    profile
    |> build_profile_email(broadcast, user, html_body, text_body)
    |> PhoenixKit.Mailer.deliver_via_integration(profile.integration_uuid)
  end

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
  def build_profile_email(profile, broadcast, user, html_body, text_body) do
    from_name = profile.from_name || PhoenixKit.Settings.get_setting("from_name", "Newsletter")

    from_email =
      profile.from_email || PhoenixKit.Settings.get_setting("from_email", "noreply@example.com")

    Swoosh.Email.new()
    |> Swoosh.Email.to(user.email)
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

  defp handle_failure(delivery_uuid, broadcast_uuid, reason) do
    case get_delivery(delivery_uuid) do
      {:ok, delivery} ->
        Newsletters.update_delivery_status(delivery, "failed", %{
          error: inspect(reason)
        })

        update_broadcast_counter(broadcast_uuid, :bounced_count)

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
