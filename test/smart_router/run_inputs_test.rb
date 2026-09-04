# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "fileutils"
require "tmpdir"
require "smart_router"

class RunInputsTest < Minitest::Test
  FIXTURES = File.expand_path("../fixtures/inputs", __dir__)
  PROJECT_ROOT = File.expand_path("../..", __dir__)
  DECISIONS_FILES = %w[routing_decisions.json routing_decisions_test.json].freeze

  def test_runtime_requires_ruby_3_2_or_newer
    assert Gem::Requirement.new(">= #{SmartRouter::REQUIRED_RUBY_VERSION}")
      .satisfied_by?(Gem::Version.new(RUBY_VERSION)),
           "expected Ruby #{SmartRouter::REQUIRED_RUBY_VERSION}+, running #{RUBY_VERSION}"
  end

  def test_load_valid_inputs_returns_providers_and_operations
    inputs = load_inputs

    refute_empty inputs.providers
    refute_empty inputs.operations
    assert_equal "op_101", inputs.operations.first.operation_id
    assert_kind_of Time, inputs.operations.first.created_at
    assert_kind_of Numeric, inputs.operations.first.amount

    first_history = inputs.history.first
    assert_kind_of SmartRouter::HistoryRecord, first_history
    assert_kind_of Data, first_history
    assert_kind_of Data, inputs.operations.first
    assert_equal "op_001", first_history.operation_id
    assert_kind_of Time, first_history.created_at
    assert_kind_of Numeric, first_history.amount
    assert_equal 12_000, first_history.amount
    assert_equal 76, first_history.latency_sec
    assert_equal "alfa", first_history.bank
    assert_equal "vipay", first_history.payment_system
    assert_equal "approved", first_history.status

    vipay = inputs.providers.find { |provider| provider.payment_system == "vipay" }
    refute_nil vipay
    assert_equal "active", vipay.status
    assert_equal 1, vipay.priority
    assert_equal 1000, vipay.limit_amount_min
    assert_equal 100_000, vipay.limit_amount_max
    assert_equal 5_000_000, vipay.daily_amount_limit
    assert_equal 3_200_000, vipay.daily_approved_amount
    assert_equal 10, vipay.in_progress_count_limit
    assert_equal 4, vipay.in_progress_count
    assert_equal 1_000_000, vipay.in_progress_amount_limit
    assert_equal 380_000, vipay.in_progress_amount
    assert_equal 12, vipay.available_requisites
    assert_equal ["sberbank", "tinkoff", "vtb"], vipay.banks
    assert_equal false, vipay.exclude_banks
    assert_equal 1.2, vipay.provider_margin_pct
    assert_equal 1.5, vipay.merchant_margin_pct

    spacepayments = inputs.providers.find { |provider| provider.payment_system == "spacepayments" }
    refute_nil spacepayments
    assert_nil spacepayments.limit_amount_min
    assert_nil spacepayments.limit_amount_max
    assert_nil spacepayments.daily_amount_limit
    assert_nil spacepayments.in_progress_count_limit
    assert_nil spacepayments.in_progress_amount_limit
  end

  def test_load_empty_queue_succeeds_with_zero_operations
    inputs = load_inputs(queue_path: File.join(FIXTURES, "operations_queue_empty.json"))

    refute_empty inputs.providers
    assert_equal 0, inputs.operations.length
    refute_empty inputs.history
  end

  def test_missing_providers_raises_input_error_without_decisions_json
    with_untouched_decisions do |dir|
      path = File.join(dir, "missing_providers.json")
      error = assert_raises(SmartRouter::InputError) do
        load_inputs(providers_path: path)
      end
      assert_equal path, error.path
      assert_includes error.message, path
    end
  end

  def test_missing_queue_raises_input_error_without_decisions_json
    with_untouched_decisions do |dir|
      path = File.join(dir, "missing_queue.json")
      error = assert_raises(SmartRouter::InputError) do
        load_inputs(queue_path: path)
      end
      assert_equal path, error.path
      assert_includes error.message, path
    end
  end

  def test_missing_history_raises_input_error_without_decisions_json
    with_untouched_decisions do |dir|
      path = File.join(dir, "missing_history.csv")
      error = assert_raises(SmartRouter::InputError) do
        load_inputs(history_path: path)
      end
      assert_equal path, error.path
      assert_includes error.message, path
    end
  end

  def test_invalid_providers_json_raises_input_error_without_decisions_json
    with_untouched_decisions do |dir|
      path = File.join(dir, "providers.json")
      File.write(path, "{not json")
      error = assert_raises(SmartRouter::InputError) do
        load_inputs(providers_path: path)
      end
      assert_equal path, error.path
      assert_includes error.message, path
    end
  end

  def test_invalid_queue_json_raises_input_error_without_decisions_json
    with_untouched_decisions do |dir|
      path = File.join(dir, "queue.json")
      File.write(path, "[1,")
      error = assert_raises(SmartRouter::InputError) do
        load_inputs(queue_path: path)
      end
      assert_equal path, error.path
      assert_includes error.message, path
    end
  end

  def test_csv_missing_headers_raises_input_error_without_decisions_json
    with_untouched_decisions do |dir|
      path = File.join(dir, "history.csv")
      File.write(path, "op_001,2026-07-29T08:00:00+03:00,12000,alfa,vipay,approved,76\n")
      error = assert_raises(SmartRouter::InputError) do
        load_inputs(history_path: path)
      end
      assert_equal path, error.path
      assert_includes error.message, path
    end
  end

  def test_malformed_csv_raises_input_error_without_decisions_json
    with_untouched_decisions do |dir|
      path = File.join(dir, "history.csv")
      File.write(
        path,
        "operation_id,created_at,amount,bank,payment_system,status,latency_sec\n" \
        "\"op_001,broken\n"
      )
      error = assert_raises(SmartRouter::InputError) do
        load_inputs(history_path: path)
      end
      assert_equal path, error.path
      assert_includes error.message, path
    end
  end

  def test_provider_missing_payment_system_raises_input_error_without_decisions_json
    with_untouched_decisions do |dir|
      catalog = JSON.parse(File.read(File.join(FIXTURES, "providers.json")))
      catalog["providers"].first.delete("payment_system")
      path = File.join(dir, "providers.json")
      File.write(path, JSON.generate(catalog))
      error = assert_raises(SmartRouter::InputError) do
        load_inputs(providers_path: path)
      end
      assert_equal path, error.path
      assert_includes error.message, path
    end
  end

  def test_operation_missing_operation_id_raises_input_error_without_decisions_json
    with_untouched_decisions do |dir|
      path = File.join(dir, "queue.json")
      File.write(
        path,
        JSON.generate(
          [{ "created_at" => "2026-07-30T09:05:00+03:00", "amount" => 15000, "bank" => "sberbank" }]
        )
      )
      error = assert_raises(SmartRouter::InputError) do
        load_inputs(queue_path: path)
      end
      assert_equal path, error.path
      assert_includes error.message, path
    end
  end

  def test_operation_missing_amount_raises_input_error_without_decisions_json
    with_untouched_decisions do |dir|
      path = File.join(dir, "queue.json")
      File.write(
        path,
        JSON.generate(
          [{ "operation_id" => "op_101", "created_at" => "2026-07-30T09:05:00+03:00", "bank" => "sberbank" }]
        )
      )
      error = assert_raises(SmartRouter::InputError) do
        load_inputs(queue_path: path)
      end
      assert_equal path, error.path
      assert_includes error.message, path
    end
  end

  def test_amount_not_numeric_raises_input_error_without_decisions_json
    with_untouched_decisions do |dir|
      path = File.join(dir, "queue.json")
      File.write(
        path,
        JSON.generate(
          [{
            "operation_id" => "op_101",
            "created_at" => "2026-07-30T09:05:00+03:00",
            "amount" => "15000",
            "bank" => "sberbank"
          }]
        )
      )
      error = assert_raises(SmartRouter::InputError) do
        load_inputs(queue_path: path)
      end
      assert_equal path, error.path
      assert_includes error.message, path
    end
  end

  def test_empty_providers_catalog_raises_input_error_without_decisions_json
    with_untouched_decisions do |dir|
      path = File.join(dir, "providers.json")
      File.write(path, JSON.generate("providers" => []))
      error = assert_raises(SmartRouter::InputError) do
        load_inputs(providers_path: path)
      end
      assert_equal path, error.path
      assert_includes error.message, path
    end
  end

  def test_invalid_created_at_raises_input_error_without_decisions_json
    with_untouched_decisions do |dir|
      path = File.join(dir, "queue.json")
      File.write(
        path,
        JSON.generate(
          [{
            "operation_id" => "op_101",
            "created_at" => "not-an-iso8601-timestamp",
            "amount" => 15000,
            "bank" => "sberbank"
          }]
        )
      )
      error = assert_raises(SmartRouter::InputError) do
        load_inputs(queue_path: path)
      end
      assert_equal path, error.path
      assert_includes error.message, path
    end
  end

  def test_history_amount_not_numeric_raises_input_error_without_decisions_json
    with_untouched_decisions do |dir|
      path = File.join(dir, "history.csv")
      File.write(
        path,
        "operation_id,created_at,amount,bank,payment_system,status,latency_sec\n" \
        "op_001,2026-07-29T08:00:00+03:00,not-a-number,alfa,vipay,approved,76\n"
      )
      error = assert_raises(SmartRouter::InputError) do
        load_inputs(history_path: path)
      end
      assert_equal path, error.path
      assert_includes error.message, path
    end
  end

  def test_non_finite_operation_amount_raises_input_error_without_decisions_json
    with_untouched_decisions do |dir|
      path = File.join(dir, "queue.json")
      File.write(
        path,
        '[{"operation_id":"op_101","created_at":"2026-07-30T09:05:00+03:00","amount":1e309,"bank":"sberbank"}]'
      )
      error = assert_raises(SmartRouter::InputError) do
        load_inputs(queue_path: path)
      end
      assert_equal path, error.path
      assert_includes error.message, path
    end
  end

  def test_provider_string_limit_amount_max_raises_input_error_without_decisions_json
    with_untouched_decisions do |dir|
      path = write_mutated_providers(dir) do |catalog|
        catalog["providers"].first["limit_amount_max"] = "100000"
      end
      error = assert_raises(SmartRouter::InputError) do
        load_inputs(providers_path: path)
      end
      assert_equal path, error.path
      assert_includes error.message, path
    end
  end

  def test_provider_null_banks_raises_input_error_without_decisions_json
    with_untouched_decisions do |dir|
      path = write_mutated_providers(dir) do |catalog|
        catalog["providers"].first["banks"] = nil
      end
      error = assert_raises(SmartRouter::InputError) do
        load_inputs(providers_path: path)
      end
      assert_equal path, error.path
      assert_includes error.message, path
    end
  end

  def test_provider_non_array_banks_raises_input_error_without_decisions_json
    with_untouched_decisions do |dir|
      path = write_mutated_providers(dir) do |catalog|
        catalog["providers"].first["banks"] = "sberbank"
      end
      error = assert_raises(SmartRouter::InputError) do
        load_inputs(providers_path: path)
      end
      assert_equal path, error.path
      assert_includes error.message, path
    end
  end

  def test_history_csv_strips_padded_headers
    Dir.mktmpdir do |dir|
      path = File.join(dir, "history.csv")
      File.write(
        path,
        " operation_id , created_at , amount , bank , payment_system , status , latency_sec \n" \
        "op_001,2026-07-29T08:00:00+03:00,12000,alfa,vipay,approved,76\n"
      )
      inputs = load_inputs(history_path: path)
      assert_equal 1, inputs.history.length
      assert_equal "op_001", inputs.history.first.operation_id
      assert_equal 12_000, inputs.history.first.amount
    end
  end

  def test_input_error_does_not_create_decisions_json
    with_isolated_cwd do |dir|
      missing = File.join(dir, "missing_providers.json")
      assert_raises(SmartRouter::InputError) { load_inputs(providers_path: missing) }
      DECISIONS_FILES.each do |name|
        refute File.exist?(File.join(dir, name)), "#{name} was created"
      end
    end
  end

  def test_input_error_does_not_overwrite_existing_decisions_json
    with_isolated_cwd do |dir|
      DECISIONS_FILES.each { |name| File.write(File.join(dir, name), "SENTINEL") }
      missing = File.join(dir, "missing_providers.json")
      assert_raises(SmartRouter::InputError) { load_inputs(providers_path: missing) }
      DECISIONS_FILES.each do |name|
        assert_equal "SENTINEL", File.read(File.join(dir, name)), "#{name} was overwritten"
      end
    end
  end

  def test_pipeline_context_copies_snapshots_and_starts_empty_traces
    inputs = load_inputs
    original_banks = inputs.providers.first.banks.dup

    ctx = SmartRouter::PipelineContext.for(inputs.operations.first, providers: inputs.providers)

    assert_equal "op_101", ctx.operation.operation_id
    assert_equal [], ctx.attempts
    assert_equal [], ctx.eligible_providers
    refute_empty ctx.providers
    refute_same inputs.providers.first, ctx.providers.first
    refute_same inputs.providers.first.banks, ctx.providers.first.banks

    ctx.providers.first.banks << "mutated-bank"
    assert_equal original_banks, inputs.providers.first.banks
  end

  def test_default_paths_load_from_project_root
    Dir.chdir(PROJECT_ROOT) do
      inputs = SmartRouter::RunInputs.load
      refute_empty inputs.providers
      refute_empty inputs.operations
      refute_empty inputs.history
      assert_equal "op_101", inputs.operations.first.operation_id
    end
  end

  def test_routing_config_load_returns_providers
    providers = SmartRouter::RoutingConfig.load(File.join(FIXTURES, "providers.json"))
    assert_kind_of Array, providers
    assert_kind_of SmartRouter::Provider, providers.first
    refute_empty providers
  end

  private

  def load_inputs(**overrides)
    SmartRouter::RunInputs.load(
      providers_path: overrides.fetch(:providers_path, File.join(FIXTURES, "providers.json")),
      queue_path: overrides.fetch(:queue_path, File.join(FIXTURES, "operations_queue.json")),
      history_path: overrides.fetch(:history_path, File.join(FIXTURES, "operations_history.csv"))
    )
  end

  def write_mutated_providers(dir)
    catalog = JSON.parse(File.read(File.join(FIXTURES, "providers.json")))
    yield catalog
    path = File.join(dir, "providers.json")
    File.write(path, JSON.generate(catalog))
    path
  end

  def with_isolated_cwd
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) { yield dir }
    end
  end

  def with_untouched_decisions
    with_isolated_cwd do |dir|
      DECISIONS_FILES.each { |name| File.write(File.join(dir, name), "SENTINEL") }
      yield dir
      DECISIONS_FILES.each do |name|
        path = File.join(dir, name)
        assert File.exist?(path), "#{name} was deleted"
        assert_equal "SENTINEL", File.read(path), "#{name} was overwritten"
      end
    end
  end
end
