Оба ключевых тезиса перепроверил самостоятельно — подтверждаются:

- **core `pagination.ex:309-316`** (прочитал сам): `total_pages = max(total_pages, 1)` → `current_page |> max(1) |> min(total_pages)` → `start_page ≤ end_page` гарантированно; `//1` — избыточный, но задокументированный второй гарант. Фикс корректен.
- **crm `lists.ex:592-595`** (прочитал сам): `like = "%#{term}%"` **без** экранирования — и `list_members_live.ex:178` (этот батч) гонит туда user-ввод `:search`. Файл `lists.ex` в диапазоне коммитов не менялся (git log пуст), значит дефект предсуществующий — но он активируется фичей из этого же батча, а канонический `like_pattern/1` уже трижды скопирован по соседним контекстам.

Ниже — единый отчёт по трём репо.

---

# Внешнее ревью: батч «UI-канон + пагинация»

## Сводные вердикты

| Репо | Вердикт | Кратко |
|---|---|---|
| **core** `/app` | **SHIP-WITH-NOTES** | OOM-фикс корректен (✅ перепроверен), канон settings-страниц чист. Только косметика в `pagination_controls` и пробелы в тестах. |
| **phoenix_kit_newsletters** | **SHIP-WITH-NOTES** | Канон-миграция 4 страниц согласована; пагинации/Range в модуле нет (N/A). 2 пропущенных empty-state + несвежий gettext `.pot`. |
| **phoenix_kit_crm** | **SHIP-WITH-NOTES** | Канон последователен, контексты обратно-совместимы, новые ILIKE-пути экранированы, `?page=` устойчив. 1 реальный соседний дефект (pre-existing ILIKE в `lists.ex`). |

Класс OOM через неклампленный `Range` **полностью закрыт во всех трёх репо** — отдельных неклампленных `<.pagination>`/`pagination_controls`/ручных `..` из `?page=` не осталось (см. раздел «Свод по пропущенным местам»).

---

## 1. core `/app` — `98508433^..5162b973`

**Канон-комплаенс (98508433 + 1463c68e) — чисто.** `email_sending`/`send_profiles`/`send_profile_form`: `<.admin_page_header>` убран из тела, заголовок/субтитл через assigns; действия — в `<:toolbar_actions>`; Cancel в футере формы (`send_profile_form.html.heex:152-155`, возвращён 1463c68e) — обоснованно, т.к. `page_section` имеет `hidden sm:flex` и на мобиле Cancel = единственный путь назад. `admin.html.heex:18-19` прокидывает `page_section` обратно-совместимо (`nil` для LV, не задающих его).

Находки:
- **`components/core/pagination.ex:45-70` — MINOR — `pagination_controls/1` рендерит мусор при `total_pages ≤ 0`.** Внешнего гарда `total_pages > 1` (как у `pagination/1`) нет → при `page=5, total_pages=0` рисует «Prev» + кликабельную «1» для пустого списка. Не регрессия (раньше крашилось), но стоит `:if={@total_pages > 1}` на корневом `<div>`.
- **`test/.../pagination_test.exs:117-130` — MINOR — тест легитимизирует баг выше.** Кейс `page=9999999999, total=0` утверждает, что рендерится ссылка «1». Лучше `refute has_page_link?(result, 1)` + фикс.
- **`test/.../pagination_test.exs` — MINOR — пробелы в покрытии.** Не покрыты `current_page = 0` / отрицательный, мягкий overflow `current_page = total_pages ± 1`. Тесты честные (гоняют реальный `:for` через Range — это и упустило прошлое ревью), но граничных кейсов маловато.
- **`components/core/pagination.ex:304,309` — NOTE — комментарий vs код.** Коммент говорит «Clamping … into `[1, total_pages]`», по факту в `[1, max(total_pages, 1)]`. Не баг, формулировка чуть вводит в заблуждение.
- **`live/settings/integration_form.html.heex:5,17` — NOTE — вне скоупа.** Гибрид `page_title` + in-body `title={@page_title}` — канон применён точечно к Email Sending, не ко всем settings. В этом батче не блокирует.
- **✅ `mix.exs`/`CHANGELOG.md` — 0 строк diff** (соблюдено правило «не бампать версию/CHANGELOG»).

*Примечание:* ещё две собственные `pagination_range/2` (`media_selector_modal.ex:629-645`, `users/media_selector.ex:371-387`) — другой алгоритм на `cond` с фиксированным окном, OOM-пути нет. Pre-existing долг (3 копии), не этого батча.

---

## 2. phoenix_kit_newsletters — `f3a1977^..146ed83`

**Канон-миграция broadcasts/lists/list_members (+ editors/details) — согласована.** `table_default` с `:toolbar_title`/`:toolbar_actions`, заголовков в теле нет, вложенные страницы задают `page_section`+`page_section_path` (крошка), inline `← Parent` удалены, Cancel в футере форм восстановлен (146ed83), `empty_state variant="featured"` для top-level списков. `<h2>Deliveries</h2>` в `broadcast_details` — легитимная section-heading rich-detail (исключение канона №4).

Находки:
- **`web/list_members.html.heex:82-93` — MINOR — пропущена миграция empty-state.** Self-rolled «No members found» вместо `<.empty_state variant="compact" …>`. Коммит `7da68e6` перевёл только `broadcasts`/`lists`, `list_members` проскочил.
- **`web/broadcast_details.html.heex:130-133` — MINOR — то же.** Self-rolled `<div …>No deliveries yet</div>` под deliveries-таблицей → `<.empty_state variant="compact" …>`.
- **`priv/gettext/default.pot` (+ `en/et/ru/LC_MESSAGES/default.po`) — MINOR — не выполнен `gettext.extract`.** Отсутствуют новые строки этого батча: `Create first broadcast` (`broadcasts.html.heex:18`), `View` (`broadcasts.html.heex:82`). Ровно случай, когда `--merge` навесит `#, fuzzy` и английский «провалится» в исходник (см. памятку про de-fuzzy). `Create first list` при этом в `.pot` есть — неконсистентность явная.
- **`test/phoenix_kit/newsletters/web/` — NOTE — нет LiveView-тестов** под канон-изменения (`page_section` assigns, ветки `empty_state`). Минимальные тесты заблокировали бы регрессии находок 1-2.

**Свод по пропущенным местам:** в `lib/phoenix_kit/newsletters` нет ни `<.pagination>`, ни `pagination_controls`, ни `pagination_range`, ни ручных `Range` из `?page=`. Единственная «пагинация» — `apply_pagination/2` (`newsletters.ex:470-474`, Ecto `limit`/`offset`), к OOM отношения не имеет. **N/A.**

---

## 3. phoenix_kit_crm — `cc7c126^..dfb41a5`

**Канон по модулю — последователен.** Топ-листинги (`contacts_live`, `companies_live`, `lists_live`) — нулевая header-разметка в теле, фильтры/кнопки/счётчики в toolbar-слотах (`refute html =~ "<h1"` в тестах). Вложенные страницы задают `page_section`/`page_section_path`. Show-страницы осознанно держат rich in-body хедер (исключение №4). Тест-харнесс `test/support/test_layouts.ex:52-56` корректен.

**Контексты (fef46a8):**
- ✅ **Обратная совместимость** — `:search/:limit/:offset` опциональны (`Keyword.get` + nil-паттерны), существующие вызовы без изменений.
- ✅ **ILIKE-экранирование в НОВЫХ путях** — `like_pattern/1` корректно экранирует `\ % _` перед обёрткой в `%…%`, значение через bind `^like` (SQL-инъекции нет). Применено в `contacts.ex:204-212`, `companies.ex:150-158`, `party_roles.ex:276-284`.
- ✅ **N+1 нет** — count отдельным запросом; `company_memberships: :company` одним preload; `PartyRoles.active_roles_map/3` — один запрос на страницу.
- ✅ **`Integer.parse` (532b748)** — `nil`/`""`/`"abc"`/`"-1"`/`"0"`/`"1.5"` все → 1, крашев нет.
- ✅ **Клампинг (dfb41a5)** — contacts/companies `COUNT+clamp`; list_members peek+retry. Двухуровневая защита (LV + core `<.pagination>`).

Находки:
- **`lib/phoenix_kit_crm/lists.ex:592-595` — MAJOR (pre-existing, но активируется этим батчем) — неэкранированный ILIKE в `maybe_search_members/2`.** ✅ *Перепроверено мной:* `like = "%#{term}%"` без экранирования; `list_members_live.ex:178` гонит сюда user-ввод `:search` (search-бокс этого батча). Поиск `50%` / `_` работает как wildcards. Сам `lists.ex` в диапазоне коммитов не менялся → формально out-of-scope, но это ровно тот класс дефекта, что проверяется, и фикса тривиален (4-я копия `like_pattern/1`). **Самый приоритетный follow-up.**
- **`web/contact_show_live.ex:250-252` (+ симметрично `company_show_live.ex`) — MINOR — двойной way-back.** После `a5ff5ef` show-страницы имеют и chrome-крошку (`page_section`), и инлайн `← Contacts`. Автор так задумал (фиксирует в сообщении коммита), но эталон `user_details` использует один `<.admin_page_header back=…>`. Можно ужать.
- **`web/contacts_live.ex:219-227` (+ `companies_live.ex:211-219`) — MINOR — неконсистентность URL-билдеров.** Внутренний `contacts_path/2` дропает `page=1`/`filter=active`, а core `<.pagination>` через `build_page_url/3` всегда кладёт `page` → клик на «1» даёт `?page=1&filter=supplier` вместо чистого `?filter=supplier`. Рабочее, менее аккуратное.
- **`test/.../contacts_test.exs:162-170` — NOTE — wildcard-escape протестирован только для старого `search_contacts/3` (picker).** Для новых `list_contacts/1`/`list_companies/1` — только косвенно (хелпер идентичен). Прямой `Contacts.list_contacts(search: "%")` был бы уместен.
- **`test/.../contacts_live_test.exs:99-107` — NOTE — `?page=0` отдельно не протестирован.** Математика `max(n, 1)` покрывает, но в edge-список `["abc","","1.5","1abc","-1e5"]` стоит добавить `"0"` (вероятный fat-finger).

**Свод по пропущенным местам:** `<.pagination>` — только `contacts_live.ex:219`, `companies_live.ex:211` (оба клампят до fetch + core-гард). `events_component.ex:34-42` — своя пагинация с guard `n >= 1` и `disabled` на границах (OOM-пути нет). Неклампленных `Range` нет.

---

## Сквозные замечания (второе мнение)

1. **`like_pattern/1` размножен 3×, `lists.ex` будет 4-й копия.** Реальная возможность вынести в общий helper контекста (DRY + одна точка правки для escaping-политики). NOTE, не блокирует.
2. **Поведенческий разрыв list_members (peek+retry) vs contacts/companies (COUNT+clamp)** — оба подхода осознанны и прокомментированы. Принять можно, но peek-схема принципиально **не знает реального `total_pages`** (только `has_more?`) → пользователь, ходящий между типами списков, видит то «page X of Y», то бесконечный Next. Унификация или хотя бы единый UX — на будущий PR. MINOR.
3. **`pagination_range/2`: `//1` избыточен** (после `total_pages = max(.,1)` total ≥ 1 всегда, так что start ≤ end гарантирован и без шага). Harmless и задокументирован как второй гарант — оставлять. NOTE.
4. **Стандарт edge-тестов пагинации неравномерен:** core — сильный, crm — средний, newsletters — отсутствует. На будущее — единый набор (`page 0`, `page ≫ total`, `total = 0`, `search с %/_`).

## Что НЕ считается находкой (известный долг)
- 42 падения полного core-сьюта (multi_session/sitemap/integrations_probe) — апстримные фикстуры с 1.7.184, до точки ветвления.
- Standalone-компиляция newsletters ломана из-за hex-версии core без SendProfile — проверять через hydroforce path-deps.

---

**Итог:** все три репо — **SHIP-WITH-NOTES**. Блокирующих MAJOR в затронутом коде нет; единственный MAJOR (`lists.ex` ILIKE) предсуществующий, но его стоит взять первым follow-up — батч сам начинает им пользоваться через search-бокс list_members. Хочешь — могу сразу сформировать короткий список «quick follow-up PR'ов» (4-я копия `like_pattern/1` в `lists.ex` + вынос хелпера; `pagination_controls` guard + тест; 2 missed empty-state в newsletters; свежий `gettext.extract`), без правок в этом ревью.
