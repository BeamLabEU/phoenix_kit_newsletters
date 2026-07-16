I now have everything I need. Key confirmations: `<.select>` supports grouped options (via `options_for_select` tuple format), `section_header` is a core component (`FormSection`), `admin_page_header.back` is a dead no-op (so even the sibling `integration_form` has no real parentage affordance), and `<.confirm_modal>` / `<.empty_state>` / `<.table_row_menu>` / `<.table_default toggleable>` / `<.status_badge>` all exist. The mailer detection in item #3 already exists in core (`assign_transport_info`), and item #4's two defaults feed genuinely different code paths (`Mailer.deliver_email/2` vs newsletters delivery worker).

Вот полный инвентаризационный анализ.

---

# Инвентарь UI-компонентов: Email Sending interface

**Метод.** Прочитано: 5 целевых пар файлов + sibling-эталон (`integrations.*`, `integration_form.*`) + moduledoc/attrs ключевых core-компонентов (`admin_page_header`, `table_row_menu`, `table_default`, `badge`, `modal`/`confirm_modal`, `empty_state`, `integration_picker`, `button`, `select`, `form_section`), + трассировка потребителей обеих «default»-настроек через `mailer.ex` и newsletters. Всё ниже сверено с реальным кодом, а не с описаниями.

**Главное открытие, влияющее на пункт #2:** `admin_page_header` attr `back` — **депрекированный no-op** (`admin_page_header.ex:23-25`, в теле рендера его нет вообще). То есть `back=…` в `send_profiles`, `send_profile_form` **и даже в эталонном** `integration_form.html.heex:16` **не рисует ничего**. Видимой аффордансии подчинения сейчас нет нигде.

---

## (a) Пользовательские пункты — по приоритету

### Пункт #1 — Сырые action-кнопки в таблице Send Profiles → `table_row_menu`

**Файл:** `send_profiles.html.heex:88-118` (desktop) и `:159-183` (mobile-карточки, дубль)

**Сейчас:** три сырых кнопки на строку:
```heex
<button phx-click="make_default" … class="btn btn-xs btn-outline">…</button>      <!-- L90-98 -->
<.pk_link navigate="…/edit" class="btn btn-xs btn-outline">…</.pk_link>            <!-- L100-107 -->
<button phx-click="show_confirm" … class="btn btn-xs btn-outline btn-error">…</button> <!-- L108-117 -->
```

**Использовать вместо:** `<.table_row_menu>` (`components/core/table_row_menu.ex`). Именно его применяет эталон-sibling `integrations.html.heex:122-164`:
```heex
<.table_default_cell>
  <.table_row_menu id={"send-profile-menu-#{send_profile.uuid}"} mode="dropdown" label={gettext("Actions")}>
    <.table_row_menu_button :unless={send_profile.is_default}
      phx-click="make_default" phx-value-uuid={send_profile.uuid}
      icon="hero-star" label={gettext("Make default")} />
    <.table_row_menu_link
      navigate={"/admin/settings/email-sending/profiles/#{send_profile.uuid}/edit"}
      icon="hero-pencil" label={gettext("Edit")} />
    <.table_row_menu_divider />
    <.table_row_menu_button
      phx-click="show_confirm" phx-value-action="delete" phx-value-uuid={send_profile.uuid}
      icon="hero-trash" label={gettext("Delete")} variant="error"
      data-confirm={gettext("This send profile will be permanently deleted.")} />
  </.table_row_menu>
</.table_default_cell>
```
Ключевые attrs: `id` (required), `label`, `mode` (`"dropdown"`/`"inline"`/`"auto"`). Дочерние: `table_row_menu_link` (`navigate`/`href`/`icon`/`label`/`variant`), `table_row_menu_button` (`phx-click` + `phx-value-*` через `@rest`, `icon`/`label`/`variant`, поддерживает `data-confirm`), `table_row_menu_divider`.

**Бонус от этого перехода:** `data-confirm` на кнопке Delete позволяет убрать **весь** ручной modal-state-машина (`send_profiles.ex:24-28` assigns `show_confirm_modal/confirm_action/confirm_target/confirm_title/confirm_message` + handlers `:52-83`) — браузерный confirm-dialog заменяет LV-roundtrip. Если всё же нужен красивый modal, есть `<.confirm_modal>` (см. ниже, nice-to-have).

---

### Пункт #2 — Нет подчинения Send Profiles → Email Sending (`back` — мёртвый)

**Файлы:** `send_profiles.html.heex:9-13`, `send_profile_form.html.heex:9-17`

**Сейчас:** оба передают `back={Routes.path(…)}` в `<.admin_page_header>`. Но `back` — no-op (`admin_page_header.ex:23-25`), стрелки/хлебной крошки **не появляется**. Sibling `integration_form.html.heex:15-19` делает так же — и тоже ничего не показывает; пользователь ошибочно считает, что там parentage есть.

**Рекомендация (два варианта):**

1. **Library gap (предпочтительно, см. секцию ниже):** восстановить в `admin_page_header` рабочий `back` (рендер `<.pk_link navigate={@back} class="btn btn-ghost btn-sm"><.icon name="hero-arrow-left"/></.pk_link>` над заголовком) ИЛИ добавить новый attr `breadcrumb={[...]}` / компонент `<.breadcrumb>`. Тогда три страницы (send_profiles, send_profile_form, integration_form) получат аффордансию одним исправлением.
2. **Без правки core (быстро):** положить явную ссылку «← Email Sending» в `:actions`-слот `admin_page_header` (слот существует и рендерится справа — `admin_page_header.ex:87-92`):
   ```heex
   <.admin_page_header title={gettext("Send Profiles")} subtitle={…}>
     <:actions>
       <.pk_link navigate="/admin/settings/email-sending" class="btn btn-ghost btn-sm">
         <.icon name="hero-arrow-left" class="w-4 h-4" /> {gettext("Email Sending")}
       </.pk_link>
     </:actions>
   </.admin_page_header>
   ```
   Минус: `back`-attr при этом нужно удалить из вызовов (сейчас он бесполезный балласт, вводящий в заблуждение).

**Library gap:** `admin_page_header` лишён аффордансии parentage после депрекации `back`, замены нет. Кандидат — новый core-компонент `<.breadcrumb items={[…]}>` или рабочий `back`/`back_label`.

---

### Пункт #3 — Transport-панель: detect-and-display статуса mailer

**Файл:** `email_sending.html.heex:67-78`

**Состояние дел (важно):** **детект уже есть** — `email_sending.ex:150-163` (`assign_transport_info/1`) через `Mailer.get_mailer()` → `Config.get(mailer, [])` / `Config.get_parent_app_config(mailer, [])` → `Keyword.get(config, :adapter)`, и assigns `:mailer_module`, `:mailer_built_in?`, `:mailer_adapter`. Источник детекта — корректный, ровно та же форма, что и в модуле emails (`Utils.mailer_adapter_status/0`, `amazon_ses_sqs.ex:51`). То есть «предложить источник детекта» — он уже выбран правильно.

**Проблема — только отображение.** Сейчас это прода как обычный абзац:
```heex
<p class="text-sm">
  <%= if @mailer_built_in? do %> Static mailer: built-in … <% else %> …parent app mailer (%{module})<% end %>
  <span :if={@mailer_adapter} class="text-base-content/50">(adapter: …)</span>
</p>
``
Нет различения **«сконфигурирован / не сконфугурирован»**, нет статуса, нет подсказки что делать, если adapter = `nil`.

**Рекомендация:** взять за эталон сам sibling — `amazon_ses_sqs.html.heex:1-50` — который уже решает ровно эту задачу для SES: `<div class="alert alert-info|warning|success">` + `<span class="badge badge-success|badge-warning">Configured/Not Configured</span>` + `<code>config :app, Module</code>` + действие. Применить к transport-панели:
```heex
<div class={["alert", transport_alert_class(@mailer_adapter)]}>
  <.icon name="hero-server-stack" class="w-5 h-5 shrink-0" />
  <div>
    <h3 class="font-bold flex items-center gap-2">
      {transport_title(@mailer_built_in?, @mailer_module)}
      <span class={["badge badge-sm", if(@mailer_adapter, do: "badge-success", else: "badge-warning")]}>
        {if @mailer_adapter, do: gettext("Configured"), else: gettext("Not configured")}
      </span>
    </h3>
    <p class="text-sm mt-1">adapter: {inspect(@mailer_adapter)} …</p>
  </div>
</div>
```
Распознавание «configured?» = `@mailer_adapter != nil` (либо более строгая проверка через наличие секретов в config, как `Emails.aws_configured?/0` — `amazon_ses_sqs.ex:53`). Для статуса есть core `<.status_badge>` (`badge.ex:221`), но он не знает статусов «configured/not configured» — см. library gap.

**Library gap:** нет core-компонента для статуса «конфигурация обнаружена/отсутствует» (callout/config-status). И `alert alert-*`, и badge сейчас рисуются сырыми — причём `integration_status_badge/1` **скопирован вручную в двух местах** (`email_sending.ex:213-217` и `integrations.ex` через `integrations.html.heex:107`). Кандидаты нового core: `<.config_status_badge adapter=…/>` и/или вынести `integration_status_badge/1` в `badge.ex` (он не покрывает `connected/configured/disconnected` — `status_badge` в `badge.ex:233-255` знает только `active/inactive/…`).

---

### Пункт #4 — Две «default»-настройки: различить на обеих страницах

Трассировка потребителей (через `mailer.ex:202-266` и newsletters `delivery_worker.ex`):

| | Default **Send Integration** | Default **Send Profile** (звезда) |
|---|---|---|
| Где | `email_sending.html.heex:124-146` | `send_profiles.html.heex:88-98` (+форма) |
| Setting/поле | `default_email_integration_uuid` | `send_profiles.is_default` (partial-unique индекс) |
| Кто читает | `Mailer.deliver_email/2` (`mailer.ex:202-207`) — **весь** транзакционный mail: auth, уведомления, модули | newsletters `delivery_worker.ex` → `SendProfiles.default/0` — только **массовые рассылки** |
| Скоуп | transport-уровень (через какую *connection* идёт core-mail) | campaign-уровень (sender identity + rate-limits + provider opts для broadcast) |
| Fallback | static app-config mailer (та самая transport-панель из #3) | нет профиля → рассылка не идёт |

Это **разные** скоупы — источники не пересекаются, поэтому проблема исключительно в подаче.

**Сейчас — что сбивает:** обе страницы называют это «default» без пояснений и **не ссылаются друг на друга**. На `email_sending.html.heex:172-179` Send Profiles — это просто ссылка «Manage», без связи с default-профилем. На `send_profiles.html.heex` нет ни слова про default-integration.

**Рекомендации (надо сделать на ОБОИХ страницах):**

На **Email Sending → Default Send Integration** (`email_sending.html.heex:124-146`):
- Переименовать секцию/подзаголовок, чтобы убрать слово-омоним: «**Default Transactional Integration**» с подзаголовком-различием: «Routes all core mail — authentication, notifications — through this connection. Newsletter broadcasts use Send Profiles instead.»
- Заменить сырой `<select>` (L131-144) на `<.select>` (`select.ex`, raw-mode через `name`/`value`/`options`).
- Добавить cross-link в подзаголовке через `<:subtitle>` (он slot, поддерживает `<.pk_link>` — см. `form_section.ex:30-40`):
  ```heex
  <:subtitle>
    {gettext("For newsletter broadcasts, see")}
    <.pk_link navigate="/admin/settings/email-sending/profiles" class="link link-primary">
      {gettext("Send Profiles")}
    </.pk_link>.
  </:subtitle>
  ```

На **Send Profiles** (`send_profiles.html.heex:49-65` + action): переименовать «Default» в **«Default Newsletter Profile»** (`badge-info` L60, L137 → текст бейджа), help-text в `<.admin_page_header subtitle=…>` (L12): «Service-wide default profile used by newsletter broadcasts. Transactional mail (auth, notifications) is routed by the Default Integration on the Email Sending page.» + ссылка обратно.

**Library gap:** нет стандартного help-text/cross-link-паттерна именно для таких связанных настроек — но `<:subtitle>` slot у `form_section`/`admin_page_header` полностью покрывает потребность, нового компонента не требуется.

---

## (b) Консистентность с sibling-страницами

### B1 — `table_default`: send_profiles дублирует responsive-card-машинерию вручную
**Файл:** `send_profiles.html.heex:39-188`
Сейчас bare `<.table_default variant="zebra" size="sm">` (L42) **без** `toggleable`/`items`/`card_fields`, плюс полностью отдельная hand-rolled mobile-card-разметка (L127-188). Эталон `integrations.html.heex:14-211` использует богатую форму: `<.table_default toggleable items={@connections} card_title={…} card_fields={…}>` со слотами `<:toolbar_actions>`, `<:card_actions>`, `<:card_header>`.
**Использовать:** `toggleable: true`, `items: @send_profiles`, `card_title`, `card_fields`, `<:card_actions :let={p}>` (сюда тот же `<.table_row_menu>`, что и в строках — `integrations.html.heex:169-210` дублирует меню в обоих слотах, это рабочий паттерн). Это убирает ~60 строк ручной mobile-разметки и даёт клиентский toggle table↔card бесплатно.

### B2 — Status-badges сырые, хотя есть `<.status_badge>`/`<.enabled_badge>`
**Файлы:** `send_profiles.html.heex:60,64,82-84,137,141-143,151`; `email_sending.html.heex:108-109`
Сейчас `<span class="badge badge-sm badge-success">…</span>`. Core: `<.enabled_badge enabled={p.enabled}>` (`badge.ex:188`, даёт Active/Disabled), `<.status_badge status="…">` (`badge.ex:221`). «Default»-бейдж — кастомный, тут `<.status_badge>` не подойдёт (нет такого статуса), оставить ручной с улучшенным текстом из #4.

### B3 — Hand-rolled confirm-modal → `<.confirm_modal>` или удалить
**Файл:** `send_profiles.html.heex:26-37` (+ state-boilerplate `send_profiles.ex:24-28,52-83`)
Сейчас `<div class="modal modal-open"><div class="modal-box">…`. Core `<.confirm_modal>` (`modal.ex:267`) — целевой компонент: `show`, `on_confirm`, `on_cancel`, `title`, `title_icon`, `messages=[{:warning, "…"}]`, `danger: true`, `confirm_text`. Либо (проще) — убрать modal целиком в пользу `data-confirm` на кнопке (см. #1).

### B4 — Hand-rolled empty-state → `<.empty_state variant="featured">`
**Файл:** `send_profiles.html.heex:189-204`
Core `<.empty_state variant="featured" icon="hero-paper-airplane" title=… description=…>` (`empty_state.ex:72`) с CTA в `inner_block`. Эталон `integrations.html.heex:215-225` тоже рисует вручную — там та же возможность для улучшения.

### B5 — Сырые `<input>`/`<label>` в Sender Identity / Test Send
**Файл:** `email_sending.html.heex:27-58, 154-168`
`<label class="label">…<input class="input input-bordered">`. Core-canonical (см. CLAUDE.md, `user_form.html.heex`): `<.input field={…} type="email" label="Email" />`. Здесь формы — не Ecto-changeset, а `phx-submit` с raw-`name`, поэтому raw-режим `<.input name="from_name" value={@from_name} label={gettext("From name")} type="text" />` (`input.ex` поддерживает raw `name`/`value`). Убирает дублирование `<label>`+`<input>` и даёт `phx-feedback-for`.

### B6 — Кнопки: `<.button>`/`<.pk_link_button>` против сырых
**Файлы:** много (`email_sending.html.heex:56,166,176`; `send_profiles.html.heex:17,100,169,198`; `send_profile_form.html.heex:180,183`).
Core `<.button>` (`button.ex`) — **всегда** `btn-primary`, без `variant`, без loading — поэтому весь проект обходится сырыми `<button class="btn btn-outline …">`. `<.pk_link_button navigate variant="primary">` (`pk_link.ex`) — есть и полезен для link-кнопок (CLAUDE.md подтверждает). Рекомендация: link-кнопки (`send_profiles.html.heex:17,100,169,198`, `email_sending.html.heex:176`) → `<.pk_link_button>`; submit-кнопки оставить raw (это кодбейз-паттерн, не регрессия конкретно этих файлов). **Library gap:** `<.button>` не поддерживает `variant`/`loading`/`icon` — отсюда повсемостный raw-HTML; кандидат на расширение.

### B7 — `send_profile_form` card-обёртка → `<.form_section>`
**Файл:** `send_profile_form.html.heex:20-21`
`<div class="card bg-base-100 shadow-sm"><div class="card-body">` — ровно то, что оборачивает `<.form_section>` (`form_section.ex:63-77`). Остальная settings-страница (`email_sending`) использует `<.form_section>` последовательно — форма профиля выпадает из паттерна.

### B8 — `fieldset`+`label`+`<.input>` избыточен
**Файл:** `send_profile_form.html.heex:24-101`
`<fieldset class="fieldset"><label class="label" for={@form[:name].id}>Name</label><.input field={@form[:name]} type="text" …></fieldset>` — но `<.input>` сам рендерит label через `label=` attr. Сейчас передаётся label-less `<.input>` + ручной `<label>` → не-канон. Схлопнуть в `<.input field={@form[:name]} label={gettext("Name")} type="text" …/>` (как в эталоне `user_form.html.heex`).

### B9 — Сырой `<select>` с optgroup → `<.select>`
**Файл:** `send_profile_form.html.heex:40-55`
Raw `<select>` с `<optgroup>` по провайдерам. `<.select>` (`select.ex`) поддерживает grouped-options: `options_for_select/2` принимает кортежи `{"Group", [{val,label},…]}`. Замена:
```heex
<.select field={@form[:integration_uuid]}
  prompt={gettext("Select an integration…")}
  options={Enum.map(@connections_by_provider, fn {p, conns} ->
    {provider_label(p), Enum.map(conns, &{&1.uuid, &1.name})}
  end)} />
```

### B10 — `email_tracking` number-with-unit → нет core-компонента
**Файл:** `email_tracking.html.heex:41-60, 69-103, 118-137`
`<div class="input-group"><input …><span class="bg-base-200 px-4 py-3">%</span></div>`. `<.input>` суффикс-юнит не умеет. **Library gap:** кандидат `<.input_group>`/`field_with_suffix`. Пока оставить raw (идиоматический daisyUI), но пометить.

### B11 — `amazon_ses_sqs`: захардкоженные цвета (нарушение правила «semantic only»)
**Файл:** `amazon_ses_sqs.html.heex:519-529`
```heex
<div class="p-4 bg-blue-50 border border-blue-200 rounded-md">
  <h4 class="font-semibold text-blue-900 …">
  <ul class="text-sm text-blue-800 …">
```
Палитра Tailwind `blue-*` напрямую — нарушает правило проекта (memory: «semantic classes only, never hardcode colors»). Заменить на `<div class="alert alert-info">` (как `L209` в `email_tracking`).

### B12 — `amazon_ses_sqs`: сырой `<select>` для SES-credentials-source
**Файл:** `amazon_ses_sqs.html.heex:61-74`
Raw `<select>` (как в #B9) → `<.select name="uuid" value={@selected_aws_integration_uuid} options=… phx-change=…>`.

### B13 — Raw `<div class="collapse collapse-arrow">` для setup/advanced-гидов
**Файлы:** `amazon_ses_sqs.html.heex:99-224, 309-412, 415-531`; `integration_form.html.heex:391-429` (там `<details>`)
В core есть `accordion.ex` — кандидат, но collapse-arrow — идиоматичный daisyUI и `accordion.ex` может иметь другую API/семантику. **Низкий приоритет** — проверить `accordion.ex` moduledoc; если подходит — унифицировать, иначе оставить.

### B14 — В «Default Send Integration» / SES-picker — `<.integration_picker>`?
Для #4 и `amazon_ses_sqs.ex:61` выбор connection-а сейчас селектом. Есть core `<.integration_picker>` (`integration_picker.ex`) — карточный single/multi-select с поиском и статус-бейджами. Для 1–3 соединений overkill (селект компактнее), но при росте числа соединений — кандидат. Сейчас `<.select>` достаточен; `integration_picker` отмечаю как опциональный апгрейд.

---

## (c) Nice-to-have

- **C1** `send_profiles.ex:24-28,52-83` — весь confirm-modal-state-boilerplate удаляется при переходе на `data-confirm` (B3/#1). Чисто, минус ~40 строк.
- **C2** `email_sending.ex:213-217` — `integration_status_badge/1` дублируется; вынести в `badge.ex` (расширив `status_badge` статусами `connected/configured/disconnected` или отдельной функцией `integration_status_badge/1`).
- **C3** `<.aws_credentials_verify>` (`amazon_ses_sqs.html.heex:227`) — хороший пример специализированного core-компонента; по аналогии можно сделать `<.mailer_status_panel>` для #3.
- **C4** Кнопки с loading everywhere (`email_tracking.html.heex:88,142,195`; `amazon_ses_sqs.html.heex:553,569`) — ручной `class={["btn …", if(@x, do: "loading")]}`; решится расширением `<.button>` (B6).

---

## Library gaps — кандидаты новых core-компонентов

1. **`<.breadcrumb>` / рабочий `back` в `admin_page_header`** (пункт #2, blocker). Самый приоритетный gap — сейчас нет способа выразить parentage ни на одной settings-подстранице.
2. **`integration_status_badge/1` в `badge.ex`** (#3, B2, C2) — сейчас copy-pasted в ≥2 LiveView.
3. **`<.config_status_badge>` / `<.callout>` (alert-обёртка)** (#3) — для detect-and-display статуса mailer/adapter; сейчас raw `alert`+`badge` в каждой панели.
4. **`<.button>` с `variant`/`loading`/`icon`** (B6, C4) — регрессия по всему кодбейзу, не только email.
5. **`<.input_group>` (number + unit)** (B10) — `%`, `days`, `ms`, `messages` в email-tracking/SES.

---

## Приоритизированный action-list

**Blocker (пункт #2 + #1):**
1. Восстановить parentage: либо починить `back`/добавить `<.breadcrumb>` в core (`admin_page_header`), либо положить явный «← Email Sending» в `:actions` на обеих страницах `send_profiles`/`send_profile_form` (и заодно убрать мёртвый `back=`).
2. `send_profiles.html.heex:88-118` → `<.table_row_menu>` (+ `data-confirm` → удалить modal-boilerplate в `.ex`).

**Высокий (пункты #3, #4 + B1):**
3. `email_sending.html.heex:67-78` → status-тreatment (alert + configured/not-configured badge) по образцу `amazon_ses_sqs.html.heex:1-50`.
4. #4: переименовать оба «default» + cross-link через `<:subtitle>` на обеих страницах; `<.select>` вместо raw.
5. B1: `send_profiles` table → `<.table_default toggleable items card_fields :card_actions>`, удалить ручной mobile-блок.

**Средний (consistency):**
6. B5/B8/B9: raw `<input>`/`<label>`/`<select>` в `email_sending` и `send_profile_form` → `<.input label=…>` / `<.select options=grouped>`.
7. B3/B4: `<.confirm_modal>` (или удаление) и `<.empty_state variant="featured">`.
8. B11: убрать hardcoded `blue-*` в `amazon_ses_sqs.html.heex:519-529` → `alert alert-info`.
9. B2: `<.enabled_badge>`/`<.status_badge>` в `send_profiles`.

**Низкий (nice-to-have / library work):**
10. B6/C4 — расширение `<.button>` (variant/loading); C2 — `integration_status_badge` в core; B10 — `<.input_group>`; B13 — проверить `accordion.ex` против raw `collapse`.

Вердикт по существующим компонентам: **почти все необходимые core-компоненты существуют** (`table_row_menu`, `table_default toggleable`, `modal`/`confirm_modal`, `empty_state`, `badge`, `select`, `input`, `checkbox`, `textarea`, `form_section`, `section_header`, `pk_link`/`pk_link_button`). Реальные library-gap'ы — только `breadcrumb`/рабочий `back` (#2, blocker), `integration_status_badge`/`config_status_badge` (#3), и расширение `<.button>` (B6). Остальное — работа по миграции сырой разметки в уже готовые компоненты.
