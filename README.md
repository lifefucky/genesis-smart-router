# genesis-smart-router

`genesis-smart-router` - это текущий baseline MVP для explainable routing выплат. На этой стадии проект уже умеет загрузить входные данные, отфильтровать недопустимых провайдеров по hard-constraints, провести fallback-каскад с синхронным in-memory состоянием и записать валидатор-совместимый `routing_decisions*.json` с понятным `attempts`.

Это важно понимать сразу: в репозитории пока нет единого CLI и нет отдельного batch runner entry point. Текущая версия проверяется либо тестами, либо ручной сборкой batch-прохода из уже существующих Ruby-классов.

## Что уже реализовано

- Безопасная загрузка входов через `SmartRouter::RunInputs`
- Hard-constraints filtering через `SmartRouter::HardConstraintsFilter`
- Синхронный in-memory трекер состояния через `SmartRouter::StateTracker`
- Fallback-каскад через `SmartRouter::FallbackExecutor` (внешние в порядке `[priority, payment_system]`, `spacepayments` — last-resort в хвосте)
- Explainable decision record через `SmartRouter::DecisionRecordBuilder`
- Атомарная запись JSON-массива решений через `SmartRouter::RoutingDecisionsWriter`

## Требования

- **MRI Ruby >= 3.2.0**
- Только стандартная библиотека Ruby: `json`, `csv`, `date`, `time`

Версия Ruby зафиксирована и проверяется в трёх местах:

- `lib/smart_router.rb` поднимает `LoadError` на старом интерпретаторе
- `Gemfile` содержит `ruby ">= 3.2.0"`
- `.ruby-version` закрепляет локальную версию разработки

## Как быстро проверить текущую версию

Из корня репозитория:

```bash
ruby -v
ruby -Ilib:test -e "Dir['test/**/*_test.rb'].each { |f| require './' + f }"
ruby -Ilib:test test/smart_router/integration_decision_record_test.rb
```

Что дают эти команды:

- `ruby -v` подтверждает, что вы действительно на Ruby `>= 3.2`
- `ruby -Ilib:test -e "Dir['test/**/*_test.rb'].each { |f| require './' + f }"` прогоняет текущий test suite
- `integration_decision_record_test.rb` показывает лучший фактический end-to-end пример Epic 1–2.3

## Как вручную собрать текущий routing run

На этой стадии запуск делается не через отдельную `bin/`-утилиту, а через уже существующие классы библиотеки. Команду ниже нужно запускать из корня репозитория, потому что `SmartRouter::RunInputs.load` использует стандартные относительные пути. Она:

- загружает `config/providers.json`, `data/operations_queue.json` и `data/operations_history.csv`
- для каждой операции вручную прогоняет Filter → FallbackExecutor → Build на общем `StateTracker` и working-set
- пишет итоговый JSON в `tmp/routing_decisions.json`

```bash
ruby -Ilib <<'RUBY'
require "smart_router"

inputs = SmartRouter::RunInputs.load
working = inputs.providers.map(&:dup)
tracker = SmartRouter::StateTracker.new

records = inputs.operations.map do |operation|
  context = SmartRouter::PipelineContext.for(operation, providers: working)
  SmartRouter::HardConstraintsFilter.filter(context)
  SmartRouter::FallbackExecutor.execute(context, tracker: tracker)
  working = context.providers
  SmartRouter::DecisionRecordBuilder.build(context)
end

SmartRouter::RoutingDecisionsWriter.write(records, path: "tmp/routing_decisions.json")
puts "Wrote #{records.size} decisions to tmp/routing_decisions.json"
RUBY
```

Что важно про этот run:

- `data/operations_history.csv` на этой стадии обязателен и валидируется как часть входного контракта; он нужен для следующих этапов stateful/analytic evolution
- при сломанных входах, пустом пуле без активного `spacepayments` или исчерпании каскада включая last-resort без `approved` прогон останавливается `InputError`
- heredoc сначала собирает весь массив `records` в памяти и только потом вызывает `SmartRouter::RoutingDecisionsWriter.write`; если на любой операции случится `InputError`, итоговый `tmp/routing_decisions.json` не будет записан
- текущий пример показывает именно ручную сборку batch-прохода, а не отдельный shipped CLI

Если нужен быстрый просмотр результата:

```bash
ruby -rjson -e 'puts JSON.pretty_generate(JSON.parse(File.read("tmp/routing_decisions.json")))'
```

Ниже - фактический record для `op_103` в full-catalog manual run на текущих project data:

```json
{
  "operation_id": "op_103",
  "selected_provider": "quickpay",
  "attempts": [
    { "provider": "vipay", "decision": "skipped", "reason": "amount_exceeds_limit" },
    { "provider": "payflow", "decision": "skipped", "reason": "amount_exceeds_limit" },
    { "provider": "quickpay", "decision": "selected", "reason": "only_eligible_provider" }
  ],
  "simulated_result": "approved",
  "latency_sec": 29
}
```

## Troubleshooting

Если manual run падает с `InputError`, чаще всего проблема в одном из этих мест:

- битый JSON в `config/providers.json` или `data/operations_queue.json`
- плохие CSV headers в `data/operations_history.csv`
- missing keys во входной операции или каталоге провайдеров
- non-numeric fields там, где ожидается число
- invalid timestamps, если `created_at` не проходит ISO 8601 parsing
- пустой eligible-пул после hard-filter и нет активного `spacepayments` в working-set — прогон останавливается тем же `InputError`
- каскад внешних и last-resort `spacepayments` исчерпан без `approved` — прогон останавливается тем же `InputError`

## Как устроен текущий pipeline Epic 1–2.3

### 1. `RunInputs`

`SmartRouter::RunInputs.load` собирает стартовое состояние прогона из трёх файлов:

- `config/providers.json`
- `data/operations_queue.json`
- `data/operations_history.csv`

Текущий контракт входов такой:

- `config/providers.json` - JSON-объект с массивом `"providers"`; актуальный полный schema-template берите прямо из этого файла
- `data/operations_queue.json` - JSON-массив операций; для custom queue обязательны `operation_id`, `created_at`, `amount`, `bank`
- `created_at` должен быть ISO 8601 timestamp, а `amount` - numeric JSON value
- `data/operations_history.csv` - CSV с обязательными заголовками `operation_id`, `created_at`, `amount`, `bank`, `payment_system`, `status`, `latency_sec`

Если файл отсутствует, сломан или не проходит базовую валидацию, прогон останавливается явной ошибкой. Частичный результат при этом не должен выглядеть как успешный run.

### 2. `HardConstraintsFilter`

`SmartRouter::HardConstraintsFilter` отвечает на вопрос: можно ли вообще отправить конкретную операцию конкретному провайдеру. На этом шаге из пула выбывают провайдеры, которые не проходят по статусу, лимитам суммы, дневному лимиту, `in_progress` ограничениям, банковому фильтру, марже или наличию реквизитов.

Две важные детали текущей реализации:

- провайдеры со статусом, отличным от `active`, исключаются молча и не попадают в `attempts`
- `spacepayments` проходит как special-case: hard filter bypass'ит обычные ограничения и оставляет его eligible; last-resort append делает уже `FallbackExecutor`
- bank filter работает коротко так: `banks` + `exclude_banks=false` - это whitelist, а `exclude_banks=true` - blacklist по перечисленному списку

Для каждого hard-skip в `attempts` остаётся каноническая причина вроде:

- `amount_below_minimum`
- `amount_exceeds_limit`
- `daily_limit_exceeded`
- `in_progress_count_exceeded`
- `in_progress_amount_exceeded`
- `bank_not_in_list`
- `no_requisites`
- `negative_margin`

### 3. `FallbackExecutor` и `StateTracker`

Прогон не вызывает `BaselineSelector.select`. `SmartRouter::FallbackExecutor` сначала берёт внешних из `eligible_providers` в порядке `[priority, payment_system]`. Активный `spacepayments` из working-set дописывается в хвост каскада только если внешних нет или все их попытки провалились. Каждая попытка: `StateTracker#start` → симуляция → `#finish`. Сид общий с `DecisionRecordBuilder`: `operation_id:payment_system` и `conversion_24h`.

- `approved` у внешнего - `selected` с `only_eligible_provider` или `first_eligible`; `spacepayments` в `attempts` не попадает
- `approved` у `spacepayments` - `selected` с `self_provider_fallback`
- `rejected` / `expired` - в `attempts` пишется `skipped` с `provider_rejected` / `provider_expired`, кандидат выбывает из этой заявки, сразу следующий
- hard-skip фильтра не переставляются и не дублируются
- нет активного `spacepayments` при пустых внешних, либо никто не `approved` - `InputError`, без `selected`

`PipelineContext.for` копирует список провайдеров. Очередь несёт working-set: `working = inputs.providers.map(&:dup)`, после операции `working = context.providers`. Каталог `RunInputs.providers` не мутируется. Один `StateTracker` на весь прогон.

`BaselineSelector` остаётся в библиотеке для той же сортировки, но в batch-прогоне не используется.

### 4. `DecisionRecordBuilder` и `RoutingDecisionsWriter`

`SmartRouter::DecisionRecordBuilder` собирает финальную explainable-запись решения:

- `operation_id`
- `selected_provider`
- `attempts`
- `simulated_result`
- `latency_sec`

На этой стадии:

- `attempts` содержит hard-skips, execution-skips каскада и ровно один финальный `selected`
- eligible-провайдеры, которых не пробовали, в `attempts` не попадают
- `simulated_result` - исход выбранного провайдера; формула та же, что у каскада
- `latency_sec` берётся из `avg_latency_sec` через integer truncation (`to_i`) и не опускается ниже `1`

Затем `SmartRouter::RoutingDecisionsWriter` сохраняет итог как JSON-массив без частично записанного файла.

## Текущее ограничение стадии

Важно не путать shipped baseline и следующие этапы развития:

- пока нет единой CLI-команды для полного batch run
- пока нет soft-scoring по traffic share, volume share, conversion или commitments
- пока нет `routing_report_test.json` и отдельной аналитической подсистемы

Иными словами, текущий README описывает честный способ проверить уже существующие Epic 1 и Epic 2, а не обещаемый future-state.

## Что будет дальше

Epic 1–2 уже в shipped-стадии. Дальше:

- **Epic 2 - Resilient Fallback and Stateful Execution.** Каскад, stateful updates и last-resort `spacepayments` уже в прогоне.
- **Epic 3 - Goal-Aware Smart Selection.** Добавит soft-goals и более умный выбор среди допустимых провайдеров: traffic share, volume share, conversion, amount bands и другие policy-driven факторы.
- **Epic 4 - Routing Analytics and Tuning Feedback.** Добавит итоговую аналитику качества роутинга, `routing_report_test.json` и рекомендации для следующего прогона.
