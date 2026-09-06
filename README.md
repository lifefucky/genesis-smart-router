# genesis-smart-router

`genesis-smart-router` — это референсная реализация explainable routing-движка для выплат на Ruby. Проект собирает все требования кейса из `docs/описание.md` в один сквозной пайплайн: от загрузки входных данных до формирования проверяемых артефактов `routing_decisions_test.json` и `routing_report_test.json`, с прозрачной историей принятия решений по каждой операции.

Основная цель репозитория — показать, **как должен выглядеть умный, объяснимый и проверяемый роутинг**: с разделением hard-constraints и soft-goals, быстрым batch runner CLI и детальной аналитикой качества маршрутизации.


## Краткий конспект умного роутинга

- Сначала жёсткий фильтр hard-constraints (статус, лимиты, банки, реквизиты и т.п.), который формирует допустимый пул провайдеров и фиксирует причины `skipped`.
- Затем скоринг soft-goals через стратегии `SmartRouter::Strategies::*` (traffic/volume share, conversion, commitments) и взвешенную сумму по `config/routing_policies.yml`.
- Кандидаты обходятся каскадом на общем `SmartRouter::StateTracker` с fallback на `spacepayments`, каждая попытка/отказ попадает в `attempts`.
- Один прогон очереди (`operations_queue*.json`) даёт batch-артефакты `routing_decisions_test.json` (пооперационные решения) и `routing_report_test.json` (агрегированная аналитика и рекомендации).

## Что уже реализовано

На текущий момент репозиторий покрывает все базовые ожидания кейса и большую часть архитектуры из `docs/_bmad-output/planning-artifacts/epics.md`:

- **Epic 1 - Baseline Explainable Routing**
  - Безопасная загрузка входов через `SmartRouter::RunInputs` (providers, queue, history).
  - Canonical hard-constraints filtering через `SmartRouter::HardConstraintsFilter` с причинами `amount_exceeds_limit`, `bank_not_in_list`, `daily_limit_exceeded`, и т.д.
  - Детерминированный базовый выбор кандидата (baseline policy).
  - Explainable decision record через `SmartRouter::DecisionRecordBuilder` c `operation_id`, `selected_provider`, `attempts`, `simulated_result`.
  - Атомарная запись `routing_decisions*.json` через `SmartRouter::RoutingDecisionsWriter`.

- **Epic 2 - Resilient Fallback and Stateful Execution**
  - Синхронный in-memory `SmartRouter::StateTracker` для `in_progress`, дневного оборота и реквизитов.
  - Fallback-каскад через `SmartRouter::FallbackExecutor`:
    - внешние провайдеры в порядке `[priority, payment_system]`;
    - `spacepayments` как special-case self-provider в хвосте каскада.
  - `attempts` фиксирует и hard-skip, и execution-fail причинно, с последним `selected`.

- **Epic 3 - Goal-Aware Smart Selection (MVP-реализация soft-goals)**
  - Отдельные стратегии soft-goals (`SmartRouter::Strategies::*`) с общим интерфейсом и нормализованным score:
    - `TrafficShare` — целевая доля по количеству заявок;
    - `VolumeShare` — целевая доля по объёму;
    - `ConversionRate` — учёт `conversion_24h`;
    - `FinancialCommitment` — финансовые обязательства и дневной оборот.
  - Комбинирование soft-goals через `SmartRouter::SoftGoalsScorer` и конфиг `config/routing_policies.yml` (веса и включение/отключение стратегий).
  - Разделение hard-constraints и soft-goals: сначала eligibility, потом скоринг допустимого пула.

- **Epic 4 - Routing Analytics and Tuning Feedback**
  - Формирование batch-аналитики через `SmartRouter::ReportBuilder`.
  - Генерация `routing_report_test.json` с:
    - фактическими долями по провайдерам и отклонений от целевых;
    - агрегированной статистикой причин skip/fallback;
    - projected daily utilization по дневным лимитам;
    - рекомендациями по тюнингу (traffic share, лимиты и т.п.).
  - Единый batch runner CLI `bin/genesis-smart-router`, который собирает оба артефакта для тестовой очереди.

## Архитектура пайплайна

Высокоуровневый пайплайн роутинга выглядит так:

1. **Загрузка входов** — `SmartRouter::RunInputs.load`:
   - `config/providers.json` — каталог провайдеров;
   - `data/operations_queue*.json` — очередь операций;
   - `data/operations_history.csv` — история для метрик и soft-goals.
2. **Hard-constraints filtering** — `SmartRouter::HardConstraintsFilter`:
   - отвечает на вопрос *«можно ли вообще отправить эту заявку этому провайдеру?»*;
   - все причины исключения фиксируются в `attempts` (`decision: "skipped"` с canonical `reason`).
3. **Soft-goals scoring** — `SmartRouter::SoftGoalsScorer` + стратегии из `SmartRouter::Strategies::*`:
   - каждая стратегия считает свой score в диапазоне `0.0..1.0`;
   - итоговый score = взвешенная сумма по конфигу `config/routing_policies.yml`.
4. **Cascade + fallback execution** — `SmartRouter::FallbackExecutor` + `SmartRouter::StateTracker`:
   - обход кандидатов в порядке приоритета и итогового score;
   - симуляция результата (`approved` / `rejected` / `expired`);
   - при отказе — каскад на следующего кандидата; в конце — `spacepayments`.
5. **Decision record + output**:
   - `SmartRouter::DecisionRecordBuilder` собирает explainable запись;
   - `SmartRouter::RoutingDecisionsWriter` и `SmartRouter::RoutingReportWriter` пишут JSON-артефакты.

Детальный разбор требований и epic breakdown см. в [`docs/_bmad-output/planning-artifacts/epics.md`](docs/_bmad-output/planning-artifacts/epics.md).

## Требования к окружению

- **MRI Ruby >= 3.2.0** (проект опирается на возможности Ruby 3.2+ и не содержит шима для старых версий).
- Только стандартная библиотека Ruby: `json`, `csv`, `date`, `time`.

Версия Ruby зафиксирована и проверяется в трёх местах:

- `lib/smart_router.rb` поднимает `LoadError` на старом интерпретаторе;
- `Gemfile` содержит `ruby ">= 3.2.0"`;
- `.ruby-version` закрепляет локальную версию разработки.

Проверить текущую версию и прогнать тесты можно так (из корня репозитория):

```bash
ruby -v
ruby -Ilib:test -e "Dir['test/**/*_test.rb'].each { |f| require './' + f }"
ruby -Ilib:test test/smart_router/integration_decision_record_test.rb
```

- `ruby -v` — убеждаемся, что запущен Ruby `>= 3.2`.
- Вторая команда прогоняет весь текущий test suite.
- `integration_decision_record_test.rb` — лучший фактический end-to-end пример Epic 1–2.

## Быстрый старт: batch runner CLI

Основной способ прогнать роутинг — воспользоваться batch runner CLI:

```bash
bin/genesis-smart-router [QUEUE_PATH]
```

- **`QUEUE_PATH`** — путь до файла очереди операций; по умолчанию:
  - `data/operations_queue_test.json` относительно корня проекта.
- CLI автоматически использует:
  - `config/providers.json` как каталог провайдеров;
  - `data/operations_history.csv` как историю для метрик.

Успешный запуск:

- обрабатывает все операции очереди через полный пайплайн;
- записывает два файла **в корень проекта (PROJECT_ROOT)**, даже если вы запустили CLI из подкаталога:
  - `routing_decisions_test.json`;
  - `routing_report_test.json`.

Пример ожидаемого вывода:

```text
Успех: обработано 10 операций.
Файлы записаны:
  routing_decisions_test.json -> /path/to/repo/routing_decisions_test.json
  routing_report_test.json    -> /path/to/repo/routing_report_test.json
```

При ошибке входных данных (`SmartRouter::InputError`) CLI:

- печатает сообщение об ошибке с указанием проблемного файла;
- не создаёт и не перезаписывает `routing_decisions_test.json` / `routing_report_test.json`.

## Формат входных и выходных данных

Точные контракты форматов подробно описаны в [`docs/описание.md`](docs/описание.md). Вкратце:

- **Входы**:
  - `config/providers.json` — JSON-объект с массивом `"providers"` и полями вроде
    `traffic_percentage`, `limit_amount_min/max`, `daily_amount_limit`,
    `in_progress_*`, `conversion_24h`, `provider_margin_pct`, `merchant_margin_pct` и др.;
  - `data/operations_history.csv` — CSV с историческими операциями (`operation_id`,
    `created_at`, `amount`, `bank`, `payment_system`, `status`, `latency_sec`);
  - `data/operations_queue_test.json` — дефолтная тестовая очередь для CLI и примеров;
  - `data/operations_queue.json` — пример пользовательской очереди для manual-run (кастомный путь).

- **Выходы**:
  - `routing_decisions_test.json` — массив решений:
    - `operation_id`, `selected_provider`, `attempts[]`, `simulated_result`, `latency_sec`;
  - `routing_report_test.json` — аналитика по пройденному батчу:
    - фактическое распределение по провайдерам (++ отклонения от таргетов);
    - распределение причин skip/fallback;
    - projected daily utilization и рекомендации.

Оба файла строго совместимы с автопроверкой (`validate.rb` и аналогами) из постановки задачи.

## Конфигурация soft-goals

Поведение soft-goals (traffic/volume share, conversion, commitments) настраивается через:

- `config/routing_policies.yml`:

```yaml
strategies:
  traffic_share:      { enabled: true, weight: 0.25 }
  volume_share:       { enabled: true, weight: 0.25 }
  conversion_rate:    { enabled: true, weight: 0.25 }
  financial_commitment: { enabled: true, weight: 0.25 }
```

- `SmartRouter::PolicyRegistry` и `SmartRouter::RoutingConfig` инкапсулируют доступ к этим настройкам в коде.

Это позволяет:

- включать/выключать отдельные стратегии без изменения ядра пайплайна;
- изменять веса soft-goals под разные сценарии;
- расширять набор стратегий за счёт новых классов в `SmartRouter::Strategies::*`.

## Ручной low-level прогон (heredoc)

Помимо CLI, можно собрать batch-прогон вручную через уже существующие классы библиотеки. Команду ниже нужно запускать из корня репозитория. Она:

- загружает `config/providers.json`, `operations_queue.json` (из корня) и `data/operations_history.csv`;
- для каждой операции вручную прогоняет Filter → FallbackExecutor → Build на общем `StateTracker` и working-set;
- пишет итоговый JSON в `tmp/routing_decisions.json`.

Manual-run из Ruby-heredoc ниже остаётся low-level runbook'ом для разработчиков: CLI — основной путь, heredoc — детализированный пример пайплайна для отладки и экспериментов.

```bash
ruby -Ilib <<'RUBY'
require "smart_router"

inputs = SmartRouter::RunInputs.load(queue_path: "operations_queue.json")
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

Особенности этого прогона:

- `data/operations_history.csv` на этой стадии обязателен и валидируется как часть входного контракта;
- при сломанных входах или пустом пуле без активного `spacepayments` — прогон останавливается `SmartRouter::InputError`;
- heredoc сначала собирает весь массив `records` в памяти и только потом пишет файл; если на любой операции случится `InputError`, итоговый `tmp/routing_decisions.json` не будет записан.

Для быстрого просмотра результата:

```bash
ruby -rjson -e 'puts JSON.pretty_generate(JSON.parse(File.read("tmp/routing_decisions.json")))'
```

## Troubleshooting

Если manual run или CLI падают с `SmartRouter::InputError`, чаще всего проблема в одном из этих мест:

- битый JSON в `config/providers.json` или `data/operations_queue*.json`;
- плохие CSV headers в `data/operations_history.csv`;
- missing keys во входной операции или каталоге провайдеров;
- non-numeric fields там, где ожидается число;
- invalid timestamps, если `created_at` не проходит ISO 8601 parsing;
- пустой eligible-пул после hard-filter и нет активного `spacepayments` в working-set.

## Лицензия

Проект распространяется на условиях лицензии, указанной в файле [`LICENSE`](LICENSE).

