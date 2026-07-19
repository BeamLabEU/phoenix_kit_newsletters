I have everything I need. The compile check confirmed a critical PR-readiness signal: the newsletters repo (clean hex dep `phoenix_kit ~> 1.7` at `mix.exs:57`, no `pk_dep/3` override) calls `Mailer.deliver_via_integration/2` (`delivery_worker.ex:180`) which only exists on the core branch — it warns-then-fails under `--warnings-as-errors` against hex, but compiles clean in the Hydroforce path-dep setup. That's the hard ordering dependency, confirmed live.

All five "already-known" fixes verified correct in code: 465→`ssl:true` (`mailer.ex:338`), unparseable port rejected (`:317`), `:provider` injected into tracking opts (`:290`), `has_flat_credential_fields?/2` + numeric hardening (`integrations.ex:1233,1246`), endpoint `secret_key_base` fallback (`encryption.ex:176`).

---

# Финальное ревью — Phase 1 «Sending Foundation» (newsletters)

## 1. Соответствие плану/спеке

Фаза **доставляет заявленное**. Стейджи A–E реализованы: провайдеры `aws_ses`/`smtp`/`brevo_api` зарегистрированы (`providers.ex:554,600,659`); геттеры SES в emails резолвят креды из Integrations с legacy-fallback (`emails.ex` `aws_ses_credentials/0`); `migrate_legacy/0` переносит plaintext-настройки в шифрованное подключение (`emails.ex:920`); `Mailer.deliver_via_integration/3` строит per-call Swoosh-config и сохраняет Provider-seam (`mailer.ex:280`); V143 создаёт `send_profiles` + `broadcasts.send_profile_uuid` (`v143.ex`); SendProfile schema/context + admin «Send Settings» + profile-aware worker на месте. Blocklist (Stage E) авто-добавляется на hard-bounce (`sqs_processor.ex:480`) и enforcement работает на обеих путях доставки.

Без молчаливых пропусков и scope creep. Отложенное (контакты/импорт, rate-enforcement, rotation) явно задокументировано как более поздние фазы — корректно. `brevo_smtp` свёрнут в единый универсальный `smtp` (решение пользователя) — выполнено.

## 2. Correctness end-to-end

Путь трассируется чисто: `DeliveryWorker.perform` → `resolve_send_profile/1` (`delivery_worker.ex:153`) → `build_profile_email/5` (`:193`) → `Mailer.deliver_via_integration/3` → `check_recipient_allowed` → `Integrations.get_credentials` → `swoosh_config_for` → `intercept_before_send` → `Swoosh.Mailer.deliver` → `handle_after_send`. Проверены граничные сценарии:

- **Интеграция удалена:** `get_credentials/1` → `{:error, :deleted}` (`integrations.ex:283`) → worker помечает delivery `failed` + `bounced_count++`, Oban ретраит 3×. Громкая ошибка, приемлемо.
- **Provider_kind drift:** **невозможен структурно.** `save_setup/3` перезаписывает `"provider"` сохранённым значением (`integrations.ex:329`), `add_connection/3` штампует при рождении. Changeset `validate_provider_kind_matches_integration` (`send_profile.ex:80`) ловит рассинхрон на создании/редактировании — defense-in-depth, протестировано.
- **`advanced` с мусором:** инертен в Phase 1 (`swoosh_config_for` и `build_profile_email` его не читают), `cast(:map)` + `parse_advanced_json` (`send_profile_editor.ex:134`) невалидный JSON отвергает. OK.
- **Профиль disabled:** ⚠ см. находку #1 ниже — `enabled` игнорируется.

## 3. Security

- **Креды в покое:** AES-256-GCM, `password` добавлен в `@sensitive_fields` (`encryption.ex:27`). Fallback на endpoint `secret_key_base` работает (`:176`). ✅
- **В полёте:** `swoosh_config_for` помечен `@doc false` с предупреждением «never log/inspect». ✅ Но `deliver_via_integration/3` логирует `reason` через worker (`delivery_worker.ex:58` `inspect(reason)`) — для `:deleted`/`:blocked` это безопасно (не креды); для ошибок Swoosh — тоже OK. Креды в логи не текут.
- **Blocklist enforcement** — см. находку #2 (обход через cc/bcc).
- **SMTP TLS:** 465→`ssl:true`, остальное→`tls: :always` — корректно для submission-портов, но см. находку #4 (plaintext relays).

## 4. Data/migration safety (V143)

Идемпотентен (`IF NOT EXISTS` везде), prefix-aware, TIMESTAMPTZ, partial unique index корректен, `down` сбрасывает comment на `'142'`. `broadcasts.send_profile_uuid` nullable без default → существующие строки получают NULL → legacy-путь. Тест V143 (`v143_test.exs`) пинит columns/types/index-def/«second default rejected» через raw SQL. Backward-compat для user-list broadcasts без профиля доказан тестом (`delivery_worker_test.exs:169` «sends identically to pre-Stage-D»). ✅ Единственное: `down` не тестируется (ограничение Ecto.Migrator-runner, как у других V-тестов) — низкий риск.

## 5. Blocklist (Stage E)

Hard bounces — единственное, что авто-блоклистит (Transient — нет, `sqs_processor.ex:480`, протестировано). Enforcement в Mailer, не в interceptor — правильно (у interceptor нет abort-канала). Но: **обход через cc/bcc** (нахождение #2) и **ретраи заблокированных** (нахождение #3). Performance: одна DB-проверка на получателя — для 100k-рассылки это заметно, но блоклист-таблица индексирована по email; приемлемо для Phase 1, оптимизация (batch-lookup) — на будущее.

## 6. Test quality

Тесты **содержательные, не кодифицируют поведение**: `mailer_test.exs` упражняет реальный `Swoosh.Adapters.Brevo` через `FakeBrevoApiClient` + проверяет tracking-seam и инъекцию `:provider`; `v143_test` пинит схему и partial-unique; `send_profile_test` покрывает provider_kind-mismatch и missing-integration; `sqs_processor_test` доказывает что orphan-bounce тоже блоклистит. Решение юнит-тестировать profile-leg worker'а без E2E **приемлемо** — `deliver_via_integration/3` покрыт E2E в core, а worker покрывает resolution + build_email; непротестирован только one-liner-связка `deliver_profile_email → deliver_via_integration`. Заметные пробелы: нет теста «default-профиль существует → broadcast без профиля уходит через него» (поведенческий сдвиг) и нет проверки disabled-профиля.

---

## (a) Приоритизированные находки

**🟠 IMPROVEMENT-HIGH — `enabled` декоративен.** `get_send_profile/1` (`newsletters.ex`) и `get_default_send_profile/0` не фильтруют по `enabled`; `resolve_send_profile/1` (`delivery_worker.ex:153`) его не проверяет. При этом UI показывает бейдж Enabled/Disabled (`send_profiles.html.heex:77`) и чекбокс (`send_profile_editor.html.heex:112`). Оператор, отключающий сломанный профиль, ожидает остановки отправки — её нет. Либо реализовать (skip disabled в resolution с fall-through к default/legacy), либо спрятать тоггл и задокументировать как «stored, enforced in Phase 5» (по аналогии с rate-полями).

**🟠 BUG-MEDIUM — Blocklist обходится через cc/bcc.** `check_recipient_allowed/1` (`mailer.ex:373`) читает только `%Swoosh.Email{to: recipients}`. Для newsletters (только `to`) неактуально, но Mailer — общий (auth-mail, emails), а suppression-list с дырой — compliance-риск. Фикс: добавить `cc`/`bcc` в проверку.

**🟠 EFFICIENCY-MEDIUM — Заблокированные отправки ретраятся 3× и инкрементируют `bounced_count`.** `deliver_via_integration` → `{:error, {:blocked, _}}` → worker else-branch (`delivery_worker.ex:57`) возвращает `{:error, inspect(reason)}` → Oban ретраит до `max_attempts: 3`; `handle_failure` (`:220`) ставит `failed` + `bounced_count++`. Для suppressed-получателя ретраи бессмысленны, а `bounced_count` искажён. Стоит возвращать `{:cancel, :blocked}` и/или статус `suppressed` вместо `failed`.

**🟡 IMPROVEMENT-MEDIUM (component-architect) — Editor не использует канонические форм-примитивы.** `send_profile_editor.html.heex` использует сырые `<textarea>` (`:128, :141, :154`) и сырой `<input type="checkbox">` (`:112`) вместо `<.textarea>`/`<.checkbox>` из `PhoenixKitWeb.Components.Core`, что прямо предписано CLAUDE.md. Это и консистентность, и потеря `phx-feedback` error-wiring. Сырой `<select>` (`:41`) оправдан optgroup'ами, но без EEx-комментария. Список (`send_profiles.html.heex`) — чистый: `<.table_default>`, EEx-комментарии `<%!-- --%>`, семантические daisyUI-классы.

**🟡 IMPROVEMENT-MEDIUM — «Test Connection» лжёт для всех трёх новых провайдеров.** `aws_ses`/`brevo_api`/`smtp` не имеют `validation`-map (`providers.ex:554,659,600`), а `do_validate` для `:key_secret` и для `:api_key` без validation возвращает `:ok` (`integrations.ex:958,953`). В сочетании с `record_validation(:ok)` статус становится `connected` без реальной проверки. Админ с неверными кредами видит «ок», отправка падает. Есть валидирующие эндпоинты (SES `GetSendQuota`, Brevo `GET /v3/account`).

**🟡 IMPROVEMENT-MEDIUM — SMTP `tls: :always` блокирует plaintext/local relays.** `mailer.ex:338` — для всех не-465 портов mandatory STARTTLS. Верно для 587, но ломает локальный dev (MailHog:1025) и plaintext-smarthost:25. transport-override из `advanced` не подключён (Phase 5). Задокументировать или добавить opt-in plaintext.

**🟢 IMPROVEMENT-LOW — Doc-drift после второго blocklist-коммита.** `deliver_email/2` doc (`mailer.ex:188`) и `deliver_via_integration/3` doc (`:271`) упоминают «send-rate limits», хотя `57b183ac` переключил на `check_blocklist/1` (намеренно — чтобы не троттлить app-wide mail). Поправить докстринги.

**🟢 SECURITY-LOW (документационное) — `migrate_legacy/0` оставляет plaintext-креды.** `emails.ex:920` копирует в Integrations, но не очищает `aws_secret_access_key`. План B5 относит blanking к ручному шагу после верификации — операционно верно, но в коде/доке `migrate_legacy` этого не сказано. PR-описание должно явно требовать: после проверки SES-via-Integrations — зачистить legacy-настройки.

**🟢 OPERATIONAL-LOW — Ротация `secret_key_base` молча ломает все креды.** `encryption.ex:12` предупреждает, но `decrypt` при ошибке возвращает ciphertext (`:118`), который уйдёт как «секрет» в адаптер. До этого Phase 1 не сделал это хуже — но теперь ВСЕ email-креды живут под этим ключом, так что ротация = тишина в отказе отправки. Стоит отдельной операционной заметки.

## (b) MUST-FIX BEFORE PR

**Кодовых блокеров нет** — ни одного correctness-бага, генерирующего неверный результат; фаза live-verified, тесты зелёные (core/emails компилируются чисто под `--warnings-as-errors`).

Обязательные **процессные/документационные** пункты перед открытием/мёрджем:

1. **Порядок мёрджа + hex-публикация (критично).** Newsletters **жёстко** зависит от core на уровне компиляции: `delivery_worker.ex:180` вызывает `Mailer.deliver_via_integration/2`, которого нет в hex-версии `phoenix_kit ~> 1.7` (`mix.exs:57`). Подтверждено: `mix compile --warnings-as-errors` в newsletters против hex — **FAIL** с warning'ом; против `/app` (Hydroforce path-dep) — чисто. Порядок: **core → publish hex → emails → newsletters**. Newsletters-PR нельзя влить, пока core с `deliver_via_integration/3` + V143 не на hex. Дополнительно: у newsletters **нет** `pk_dep/3`-override (в отличие от других модулей Max), т.е. его CI не сможет гоняться против локального core — только против hex.
2. **Задокументировать `enabled`-решение** в PR-описании (реализовать или явно «deferred to Phase 5») — чтобы не-функциональный тоггл не стал сюрпризом.
3. **Задокументировать ручной blanking legacy-кредов** после `migrate_legacy` (B5).

## (c) Verdict: **Ship-with-changes**

Фаза цельная, соответствует плану/спеке, live-проверена, тесты сильные, ужеизвестные фиксы корректны, security-контур (креды/шифрование/TLS/seam) выстроен грамотно. Кодовых must-fix нет. Перед мёрджем желательно закрыть «HI/medium»-находки (`enabled`, cc/bcc-обход, ретраи blocked, сырые form-примитивы в editor) — либо исправить, либо явно отнести к Phase 5 с пометкой в UI/доке. PR-порядок (core→emails→newsletters, с hex-публикацией core как гейтом) — обязательное условие, без него newsletters не компилируется в своём CI.
