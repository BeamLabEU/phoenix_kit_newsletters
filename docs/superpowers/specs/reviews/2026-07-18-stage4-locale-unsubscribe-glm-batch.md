Сбор данных завершён. Отчёт составляю самостоятельно (а не повторным запуском `reviewer`-агента) — ценность второго мнения именно в независимом чтении кода + проверке живой БД, а Sonnet-ревью уже дало PASS ×3. Методология: полный diff-аудит 3 репозиториев + верификация на живых БД Decor/Hydroforce через Tidewave.

---

# Code Review — batch «list locale + broadcasts→CRM lists + unsubscribe»

## 1. core `/app` — ветка `feature/email-send-profiles-core`

Проверил целостность V152-секций (up/down, prefix-safety, аменд-семантику) и сверил с живыми БД.

### NOTE-1 — Аменд `locale` (a6248e4e) и already-stamped БД
`lib/phoenix_kit/migrations/postgres/v152.ex:238` — `locale VARCHAR(10)` добавлен в `CREATE TABLE phoenix_kit_crm_lists` amend-in-place. Любая БД, на которую V152 **уже** наложен (до аменда), колонку `locale` не получит → CRM-запросы к `phoenix_kit_crm_lists.locale` упадут с `column does not exist`.
**Верифицировано на живых БД:** Decor — stamp `151` (V152 ещё не наложен, получит amended-версию ✓); Hydroforce — stamp `152`, `crm_lists_has_locale=1` ✓. Конфликта нигде нет. Операционный гатча остаётся для любого иного already-stamped окружения — но «unreleased, amend in place» документировано, так что NOTE.

### NOTE-2 — `down/1` сознательно не восстанавливает NOT NULL
`v152.ex` down-секция `down_broadcast_crm_source` дропает только новые колонки, оставляя `list_uuid`/`user_uuid` nullable. Асимметрично, но честно задокументировано в moduledoc: повторное наложение NOT NULL сломало бы documented rollback-and-reapply на данных с NULL. Пере-apply идемпотентен (`DROP NOT NULL` + `ADD COLUMN IF NOT EXISTS`). Принимается.

### NOTE-3 — Дублирующий `ensure_extension!("citext")`
`v152.ex` `up_broadcast_crm_source` снова вызывает `Helpers.ensure_extension!("citext")`, хотя V151 его уже гарантирует. Избыточно, но идемпотентно — безвредно.

### Позитив (prefix-safety)
Новая секция корректна: bare index-имя на `CREATE INDEX` (`v152.ex:336`), квалифицированное на `DROP INDEX` (`:359`); секции в `up`/`down` идут в правильном обратном порядке; `crm_list_uuid` без FK — осознанный soft-ref по образцу `send_profile_uuid`. Newsletters-таблицы создаются core-миграцией V79, так что `ALTER TABLE` в V152 не падает на orphan-table. V152Test покрывает все новые колонки/индекс. `admin_tabs.ex` (Send Profiles subtab) тривиален и покрыт тестом.

**Вердикт core: SHIP-WITH-NOTES.** Чистая миграционная работа, все замечания документированы/намерены. Блокирующих проблем нет.

---

## 2. `phoenix_kit_crm` — ветка `feature/crm-contact-lists`

### NOTE-1 — `locale_apply_preview` — три COUNT-запроса вместо одной FILTER-агрегации
`lib/phoenix_kit_crm/lists.ex` `locale_apply_preview/1` делает три отдельных запроса (total/missing_locale/different_locale) по одной базовой выборке. Click-time-операция над списками в «low thousands» — не горячо, но один запрос с `filter(count(...), ...)` (как сделано в newsletters `CRMSource.preflight`) убрал бы 2 round-trip. Minor.

### NOTE-2 — `:all` перезаписывает locale у контактов, общих с другими списками
`lists.ex` `apply_locale_to_members/3` — locale живёт на контакте, не на membership; «последний список выигрывает». Явно задокументировано («That's expected, not a bug»). Может удивить админа, но by-design.

### NOTE-3 — Третья копия `@locale_format`-регулярки
`lib/phoenix_kit_crm/schemas/contact_list.ex:21` — локальная копия `~r/^[a-z]{2,3}(-[A-Za-z]{2,4})?$/` (уже есть в core `User` и `CRM.Contact`). Риск дрейфа. Оправдано комментарием «don't reach into sibling schema», но копий становится три.

### NOTE-4 — Гонка preview→apply (приемлемо)
Preview — снапшот на момент `open_locale_modal`; `apply_locale_to_members` ре-запрашивает at apply-time. Счётчик в модалке может расходиться с фактом, если члены меняются между. Для preview допустимо; e9b06ae-фикс (счётчик по выбранному режиму) корректен.

### Позитив
`String.to_existing_atom(socket.assigns.locale_mode)` безопасен — handler `set_locale_mode` гардуирует `mode in ~w(missing_only all)`; bulk-update скоупирован на `status == "subscribed"`; Activity.log следует устоявшемуся 2-arity CRM-паттерну (строки 234/346/736/749); кнопка Apply disabled при `affected_count == 0`.

**Вердикт CRM: SHIP-WITH-NOTES.** Добротно, хорошо задокументировано. Блокирующих проблем нет.

---

## 3. `phoenix_kit_newsletters` — ветка `feature/newsletters-sending-foundation`

### 🔴 MAJOR-1 — One-click эндпоинт мутирует на GET → silent unsubscribe link-сканерами
`lib/phoenix_kit/newsletters/web/unsubscribe_controller.ex:129` `one_click_unsubscribe/2` не имеет проверки метода — `CRMSource.remove_from_list(contact, list)` (`:134`) выполняется **и на GET, и на POST**. При этом RFC 8058 требует наличия `List-Unsubscribe:`-хедера, а он указывает на **тот же** one-click URL (`delivery_worker.ex:351-355`, `url = list_unsubscribe_url = one_click_unsubscribe_url(token)`).

Следствие: корпоративный AV / link-сканер / anti-spam, который GET'ит URL из `List-Unsubscribe`-хедера (а такие есть), молча отпишет получателя. Это **ровно тот footgun, который fd7354a починил** для интерактивного `/newsletters/unsubscribe` (commit-msg: «corporate link-scanners routinely GET every link»). Для человека, GETнувшего one-click в браузере, — ещё и редирект домой без подтверждения уже после мутации.

Усугубляет: в `test/.../unsubscribe_controller_test.exs:74-78` комментарий заявляет *«a crm_list token's GET never mutates … confirmed»* — но (а) фраза «follow-up POST scope=list» описывает **интерактивный** эндпоинт, не one-click; (б) сами one-click-тесты **не написаны** («verified live rather than here»). Регрессия никем не поймана.

**Фикс (1 строка):** мутировать только при `conn.method == "POST"`, на GET — рендерить лендинг или 200 без действия. Рекомендую починить до merge — дёшево и противоречит собственному принципу проекта.

### 🟠 MAJOR-2 (verify) — Oban-ретраи: double-send + inflation `bounced_count`
`delivery_worker.ex:42` `perform` + `:410` `handle_failure` + `:424` `update_broadcast_counter`. На транзиентной неудаче: `handle_failure` ставит `status="failed"`, `bounced_count += 1`, возвращает `{:error, ...}` → Oban ретраит. Если попытка 2 успешна → `status="sent"`, `sent_count += 1`, но `bounced_count` **не декрементируется** → метрика bounced_count пере-считывает каждую «транзиентный провал → успех»-доставку.
Отдельно: если попытка 1 **фактически** доставила письмо, но процесс упал до `update_delivery_status("sent")`, попытка 2 шлёт повторно → дубль письма. `unique: [keys: [:delivery_uuid], ...]` (`delivery_worker.ex:18`) защищает от дублей **джобов**, но не от повторного **выполнения** того же джоба. Применимо к обоим source_type (CRM наследует). Требует идемпотентного сендинга (check `delivery.status` перед отправкой).

### 🟡 MINOR-3 — Двойной вызов `sendable_recipients` при CRM-рассылке
`broadcaster.ex:157` (`count_recipients`) и `:173` (`enqueue_all_recipients`) каждый зовёт `CRMSource.sendable_recipients/1` → дедуп-запрос + `Enum.uniq_by` дважды за send. Объём «low thousands», но один запрос с переиспользованием убрал бы дубль.

### 🟡 MINOR-4 — `validate_recipient/1` декоративен на прод-пути
`delivery.ex` `validate_recipient` требует «user_uuid ИЛИ recipient_email», но `Broadcaster.process_batch` вставляет через `repo.insert_all` (мимо changeset). Member newsletters-списка с nil `user_uuid` даст both-nil delivery (поймается позже как `{:error, :no_recipient}` в `get_recipient`, но «at least one» реально не энфорсится при insert).

### NOTE-5 — RFC 8058 только для CRM; flavor-A без List-Unsubscribe
`delivery_worker.ex:175` — newsletters_list-рассылка возвращает `{url, nil}`, и `maybe_put_list_unsubscribe_headers` для неё no-op. Одно-клик-отписка на стороне провайдера есть только у CRM-получателей. Намеренно (коммент.), но продуктовая непоследовательность.

### NOTE-6 — `CRMSource.remove_from_list/opt_out` без `available?`-гарда
`crm_source.ex` — `remove_from_list/2`, `opt_out/1` зовут `soft_call` напрямую, без `Code.ensure_loaded?`-гарда, как у остальных функций. Практически безопасно (crmlist-broadcast требует установленного CRM), но непоследовательно.

### Позитив (security)
- **CSRF-скоуп чист:** exemption только для `/newsletters/unsubscribe/one-click` (pipeline `:phoenix_kit_newsletters_one_click` = `:accepts ["html"]` без session/CSRF); интерактивный `/newsletters/unsubscribe` за `:browser`. `routes.ex`.
- **XSS:** `{@crm_list.name}` в HEEx авто-эскейпится; сырых интерполяций/`raw` нет.
- **Open redirect:** все редиректы на `Routes.path("/")`.
- **Токены:** Phoenix.Token, соль `"unsubscribe"`, `max_age: 604_800` (7 дней); два флейвора различаются ключами claim, без confusion-вектора (подделка без `secret_key_base` невозможна).
- **Bounce/CRM-доставки (user_uuid=nil):** проверил — блок-лист в `Mailer.check_blocklisted/1` (`mailer.ex:392-407`) ключируется по **email-адресу**, не по user_uuid → заблокированный CRM-адрес корректно ловится pre-send как `{:blocked, _}` → `permanent_failure?` → `status="blocked"` без touched `bounced_count`. Гэпа нет.

**Вердикт newsletters: SHIP-WITH-NOTES** — при условии, что **MAJOR-1 (one-click GET-mutation) починят до merge** (one-line fix, противоречит принципу проекта и комментариям тестов). Остальное — MINOR/NOTE, можно rolling-follow-up. Если принципиально оставить GET-mutation как one-click-fallback — задокументировать намеренно и добавить тест, закрывающий регрессию.

---

## Сводная таблица вердиктов

| Репо | Вердикт | Блокирующее |
|------|---------|-------------|
| **core** `/app` | **SHIP-WITH-NOTES** | нет (все NOTE документированы) |
| **phoenix_kit_crm** | **SHIP-WITH-NOTES** | нет |
| **phoenix_kit_newsletters** | **SHIP-WITH-NOTES** (с условием) | MAJOR-1 one-click GET-mutation — рекомендую фикс до merge |

**Что оба ревью (Sonnet + мой), скорее всего, различает:** MAJOR-1 — Sonnet-ревью проходило до/вокруг fd7354a, где фокус был на интерактивном GET; one-click эндпоинт остался в тени, а комментарий теста маскирует пробел. Это самая ценная независимая находка пачки.
