Прочитал план, все 8 коммитов (5 core + 3 emails), полный diff по `lib/` и `test/` в обоих репо, и окружающий неизменённый код: `integrations.ex` (`maybe_set_status/2`, `has_credentials?/1`, `validate_connection/2`, `record_validation/2`, `save_setup/3`, `add_connection/3`, `get_credentials/1`), `mailer.ex` (`deliver_email/2`, `deliver_with_runtime_config/3`), `encryption.ex` целиком, поведение `Email.Provider` + реализация `emails/Provider.ex`/`interceptor.ex`/`utils.ex`, `Config.get_parent_endpoint/0`, и исходник `Swoosh.Adapters.SMTP`. Ниже — разбор по фокусам.

---

## 1. Безопасность — C2b encryption-key fallback

**Предпосылка (план):** инсталлер никогда не ставит плоский `config :phoenix_kit, secret_key_base:`, поэтому в реальных host-приложениях `encryption_key/0` возвращал `nil` → секреты интеграций хранились открытым текстом. Это подтверждается кодом до изменения.

**Корректность fallback — ВЕРНО.**
- `secret_key_base/0` (`encryption.ex:162-167`) сначала пробует плоский ключ через `Config.get(:secret_key_base)`, и только при промахе уходит в `endpoint_secret_key_base/0`. **Предпосылление плоского ключа сохраняется** — оператор, сознательно его задавший, получает тот же ключ.
- `get_parent_endpoint/0` (`config.ex:424-443`) резолвит `[ParentWeb.Endpoint, Parent.Endpoint]` через `:parent_module` (его инсталлер ставит). `endpoint.config(:secret_key_base)` читается из конфига Endpoint, который есть у каждого Phoenix-приложения. Механизм корректен.
- **Обратная совместимость:** старые инсталлы БЕЗ плоского ключа хранили секреты открытым текстом (без `enc:v1:`). `decrypt_fields` → `maybe_decrypt_field` (`encryption.ex:111-119`) дешифрует ТОЛЬКО значения с префиксом `enc:v1:` — открытый текст возвращается как есть. Тест «leaves non-encrypted values as-is on decrypt» (`encryption_test.exs:78-88`) это доказывает. Значит: при апгрейде старые строки читаются, новые — шифруются, ничего не ломается. Инсталлы С плоским ключом — тот же ключ, та же расшифровка.

**Утечек в логах нет.** В `mailer.ex` вообще нет вызовов `Logger` (только `require Logger`). В `integrations.ex` Logger инспектирует только `reason`/`uuid` (`:1028`, `:1272`, `:1277`) — никогда не секрет/конфиг/токен. Путь `save_setup`/`validate`/`deliver` чист.

**`swoosh_config_for/1` (public, `@doc false`)** — error-ветки возвращают только `{:unsupported_provider, provider}` (без секретов). Success-ветка возвращает конфиг С секретами, но единственный вызывающий (`deliver_via_integration/3`) его не логирует. Публичность — минимальный риск (внешний вызывающий может залогировать), обоснование `@doc false` + комментарий принимаю.

**SHA-256 вместо PBKDF2** — допустимо: `secret_key_base` это 512-битный случайный секрет (`mix phx.gen.secret`), а не пароль, так что итерации PBKDF2 ничего не защищают. Документ поправлен верно.

🟡 **Но C2b расширяет поверхность silently — это надо задокументировать (improvement):** теперь ВСЕ секреты интеграций привязаны к `secret_key_base` Endpoint'а. Оператор, ротирующий секрет Endpoint'а (перезапуск `gen.secret`), **тихо сломает расшифровку всех интеграционных секретов** — `maybe_decrypt_field` при ошибке дешифровки оставляет `enc:v1:`-blob, и поле читается как мусор. Раньше (открытый текст) ротация была неактуальна. Это не блокер, но кейс реальный и нигде не описан. Действие: либо документировать caveat, либо добавить key-version-префикс/процедуру ротации. Дополнительно — `encryption_key/0 → nil` (нет ключа) сейчас тихо означает «хранить открытым текстом»; оправдано для библиотеки (не ронять host), но одно предупреждение в лог при записи чувствительного поля при `enabled?() == false` сняло бы ложное чувство безопасности.

---

## 2. Корректность gate-генерализации (`has_flat_credential_fields?/2`)

Реализация (`integrations.ex:1233-1239`):
```elixir
defp has_flat_credential_fields?(%{auth_type: :credentials, setup_fields: fields}, data) do
  fields |> Enum.filter(& &1.required) |> Enum.all?(fn %{key: key} -> present?(data[key]) end)
end
defp has_flat_credential_fields?(_provider, _data), do: false
```

- Гейдится ТОЛЬКО по `required: true` полям — корректно. Пустые строки отсекаются `present?/1`. ✓
- Для `brevo_api` (`:api_key`) эта функция не вызывается — там своя ветка `:api_key -> present?(data["api_key"])`. Корректно.
- Трассировка полного пути для smtp: `add_connection` (status `"disconnected"`) → `save_setup` → `maybe_set_status` для `:credentials` теперь `has_custom_creds?(data) or has_flat_credential_fields?(...)` → status `"configured"` → `validate_connection` (pre-check `has_credentials?/1` проходит по статусу `"configured"`) → `do_validate/2` catch-all → `:ok` (`:958`) → `record_validation(:ok)` → status `"connected"` (`validation_fields(:ok) == {"connected","ok"}`, `:1034`). Для `brevo_api` — `:api_key` clause без `validation` URL → `:ok`. Для `aws_ses` (`:key_secret`) — catch-all `:ok`. Тесты (`providers_test.exs:62-150`) доказывают end-to-end `get_credentials == {:ok, _}` для всех трёх, причём smtp — с двумя независимыми именованными соединениями. **Путь работает.**

🟡 **Два латентных дефекта (low):**
1. **Int-порт ловушка.** `present?/1` — только `is_binary(val) and val != ""`, но `port` имеет тип `:number`. Сегодня форма шлёт строки → работает. Но `parse_smtp_port/1` в `mailer.ex` осознанно обрабатывает и integer — намёк, что порт может прийти числом из какого-то пути. Если хоть раз запишется `port: 587` (числом), `present?(587) == false` → `has_creds == false` → status `"disconnected"` → `get_credentials` падает → отправка молча ломается. Несоответствие между гейтом и доставкой.
2. **Zero-required-fields footgun:** `Enum.all?([], _) == true`, т.е. гипотетический `:credentials`-провайдер без required-полей всегда считался бы «имеющим кредитеншиалы». Сейчас такого нет, но это мина.

---

## 3. Mailer seam

`deliver_via_integration/3` (`mailer.ex:255-264`) добросовестно повторяет seam из `deliver_email/2` (`:173-201`): `intercept_before_send` ДО, `handle_after_send` ПОСЛЕ, тот же `opts`, тот же `tracked_email` в обе точки. Тест `MailerTest` (`mailer_test.exs:157-192`) доказывает, что оба хука стреляют и Brevo-запрос уходит с правильным `Api-Key`. **Корреляция `X-PhoenixKit-Log-Id` сохраняется:** `handle_after_send` (`emails/provider.ex:16-33`) читает хедер из того же `tracked_email`, который ушёл в доставку. Ничего не теряется.

🔴 **BUG — HIGH: порт 465 (implicit TLS) сломан.** `mailer.ex:283-296`:
```elixir
tls: if(port == 465, do: :always, else: :if_available)
```
Для 465 ставится `tls: :always`, **но не `ssl: true`**. А `Swoosh.Adapters.SMTP` (исходник подтверждает): moduledoc явно — implicit TLS (465/SMTPS) это **`ssl: true` + `tls: :always`**; STARTTLS — «omit ssl or set to false». gen_smtp различает `:ssl` (TLS с начала соединения = implicit) и `:tls` (поведение STARTTLS поверх plaintext). Без `ssl: true` gen_smtp начинает plaintext-рукопожатие на 465, где сервер сразу шлёт TLS ServerHello → соединение падает. **465 объявлен (`if port == 465`), но не работает.** 587 (`:if_available`) — корректен. Тест (`mailer_test.exs:106-118`) ловлю не поддевает — он ассертит только `config[:tls]`, никогда `config[:ssl]` и не коннектится. Фикс: `ssl: port == 465, tls: if(port == 465, do: :always, else: :if_available)`.

🟠 **GAP — MEDIUM (влияет на Stage D): provider-attribution.** `deliver_via_integration/3` **не инжектит `provider:` в opts** перехватчика. Значит `Interceptor.detect_provider/2` (`interceptor.ex:136-161`) проваливается до `detect_provider_from_config/0` (`utils.ex:60-71`), который читает **статический mailer-адаптер host-приложения**, а не адаптер интеграции. Симптом: SMTP/Brevo-отправка через интеграцию на host, где mailer = SES, залогируется как `provider: "aws_ses"` (неверно) + на каждый такой send `maybe_extract_provider_data` для `"aws_ses"` не находит AWS MessageId → варнинг «No provider data extracted» (`interceptor.ex:352`) на каждой отправке. Для SES-через-интеграцию на SES-host всё корректно (recovery-путь и прямая ветка работают). Фикс — либо `deliver_via_integration` делает `[{:provider, creds["provider"]} | opts]` перед `intercept_before_send`, либо Stage D DeliveryWorker обязан передать `provider:` явно.

---

## 4. Emails SES-рефакторинг

- **Legacy fallback корректен:** `get_aws_*` = `Map.get(aws_ses_credentials(), key) || legacy_*()`. Без выбранной интеграции `aws_ses_credentials/0` → `%{}` → legacy. ✓
- **`aws_configured?/0`** (`emails.ex:2186`) логику не изменил (`!= ""`), читает через рефакторённые геттеры → true при наличии интеграционных кредов. Регрессии нет. (Старый nil-vs-`""` quirk сохранён as-is.)
- **`migrate_legacy/0`** корректен и покрыт (`migrate_legacy_test.exs`): шифрует secret (`assert raw["secret_key"] |> String.starts_with?("enc:v1:")`), idempotent, no-op без legacy, регион по умолчанию `us-east-1`. `validate → record_validation` (а не `validate_connection/2` с actor-аргументом) — корректно, статус доходит до `"connected"`.
- **`delete_setting` vs empty-string:** LiveView-обработчик `select_aws_integration` при `uuid == ""` делает `delete_setting` (changeset Setting'а режектит пустые значения) — обосновано. Геттеры и `migrate_legacy` проверяют `in [nil, ""]` consistently. ✓
- 🟡 **Low:** после живого «blanking» legacy-plaintext (B5), если integration-строка будет удалена, `migrate_legacy` уже не отработает (legacy пуст) → отправка сломается без fallback. Это документированный паттерн «loud failure», но стоит упомянуть в PR.

---

## 5. Backward-compat & blast radius

- `Encryption.enabled?() == true` в тестах теперь везде — но `encryption_test.exs` ветвится по `enabled?/0` (оба случая), а `migrate_legacy_test` ассертит `enc:v1:` (т.е. ожидает включённое шифрование). Регрессионный риск тестового набора — низкий.
- **Gate-изменение не имеет blast radius для существующих провайдеров:** новый ор через `or` в `has_credentials?/1` и `maybe_set_status/2` может только ДОБАВИТЬ `true`-ность для `:credentials`-провайдеров; для всех остальных `has_flat_credential_fields?/2` возвращает `false` (guard `auth_type: :credentials`). Существующие `oauth2/api_key/key_secret/bot_token`-ветки не тронуты. ✓
- **Universal-smtp / brevo_api vs detection-map (`utils.ex:34-43`):** в карте есть `AmazonSES→"aws_ses"`, `SMTP→"smtp"`, **нет `Brevo`** → Brevo-API send детектится как `"unknown"`. Это совпадает с заявленным в плане defer'ом Brevo-трекинга до Phase 7 (finding #8). Не поломка, но подтверждено — к Brevo не будет open/click-классификации.

---

## 6. Блокеры/ограничения для Stage D

- **SendProfile → `integration_uuid` → `deliver_via_integration/3` — интерфейс совпадает.** `provider_kind` на SendProfile нужен только для changeset-consistency-check (D2 `validate_provider_kind_matches_integration`), доставка его не требует (адаптер выводится из `creds["provider"]`). Два источника истины согласованы в changeset. ✓
- **Provider-attribution gap (#3) — это Stage D interface concern:** DeliveryWorker — основной вызывающий; без инжекта `provider:` отправки атрибутируются неверно. **Зафиксировать сейчас.**
- **465 (#из п.3):** если Stage D поддержит SMTP-профили на 465 — сломается в проде. Если только 587 — нейтрально.
- `swoosh_config_for/1` — чистая точка расширения: новый провайдер = новый clause. Architectural blocker'а нет.

---

## (a) Топ-5 проблем (по убыванию серьёзности)

1. 🔴 **BUG — HIGH** — `mailer.ex:283-296`: SMTP порт 465 без `ssl: true` → implicit TLS не работает. Фикс: `ssl: port == 465`.
2. 🟠 **IMPROVEMENT — MEDIUM** — `mailer.ex:255-264`: `deliver_via_integration/3` не передаёт `provider:` в `intercept_before_send` → неверная атрибуция лога и warning-шум для SMTP/Brevo на SES-host; прямо влияет на Stage D DeliveryWorker. Фикс: `[{:provider, creds["provider"]} | opts]`.
3. 🟡 **IMPROVEMENT — MEDIUM/LOW** — `encryption.ex:162-179`: C2b привязал секреты к `secret_key_base` Endpoint'а — ротация секрета тихо инвалидирует все интеграционные креды (раньше N/A). Документировать caveat / добавить процедуру ротации; опц. warn-log при silent-disable.
4. 🟡 **IMPROVEMENT — LOW** — `integrations.ex:1233-1239`: гейт `present?/1` бинарный vs `:number`-порт (int-port ловушка) + `Enum.all?([]) == true` для гипотетического credentials-провайдера без required-полей.
5. 🟡 **NITPICK — LOW** — `encryption.ex:174` широкое `rescue _ -> nil` маскирует реальные ошибки под «no key → plaintext»; `swoosh_config_for/1` публично возвращает конфиг с секретами (оправдано `@doc false`, но `defp` + тест через доставку был бы строже).

## (b) SAFE TO BUILD STAGE D ON THIS? — **Да**, с must-fix-first:
1. Инжектить `provider:` в `deliver_via_integration` (или передавать из DeliveryWorker) — иначе атрибуция/трекинг Stage D-отправок некорректны.
2. Починить 465 `ssl: true` — если Stage D допускает SMTP-профили на 465.

Оба фикса локальные (по несколько строк), архитектурных изменений не требуют. SendProfile→integration_uuid→`deliver_via_integration` интерфейсно чист.

## (c) Вердикт: **Sound-with-changes**

Фундамент (провайдеры, шифрование с безопасным fallback'ом, gate-генерализация, seam-репликация, migrate_legacy, тесты) — корректен и хорошо покрыт. Один конкретный runtime-баг (465/`ssl`), один interface-документируемый gap для Stage D (provider-attribution), и пара латентных низких рисков. После двух must-fix правок Stage D строится на надёжной основе.
