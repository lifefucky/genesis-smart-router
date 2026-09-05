# frozen_string_literal: true

require "minitest/autorun"
require "smart_router"

class FallbackExecutorTest < Minitest::Test
  FIXTURES = File.expand_path("../fixtures/inputs", __dir__)

  def test_first_approved_selects_and_omits_untried_eligible
    first = build_provider(payment_system: "vipay", priority: 1, conversion_24h: 1.0)
    second = build_provider(payment_system: "payflow", priority: 2, conversion_24h: 1.0)
    catalog = [first, second]
    catalog_before = catalog.map { |provider| snapshot(provider) }
    context, tracker = context_with(catalog)
    working = context.providers

    result = SmartRouter::FallbackExecutor.execute(context, tracker: tracker)

    assert_same context, result
    assert_equal "vipay", context.selected_provider.payment_system
    assert_equal "first_eligible", context.selection_reason
    assert_equal(
      [{ "provider" => "vipay", "decision" => "selected", "reason" => "first_eligible" }],
      context.attempts
    )
    refute(context.attempts.any? { |attempt| attempt["provider"] == "payflow" })
    assert_equal catalog_before, catalog.map { |provider| snapshot(provider) }
    assert_in_progress_rolled_back(working.first, amount: 500)
    assert_equal 500, working.first.daily_approved_amount
    assert_equal 9, working.first.available_requisites
    assert_equal 0, working.last.daily_approved_amount
    assert_equal 10, working.last.available_requisites
  end

  def test_rejected_then_approved_writes_execution_skip_and_omits_third
    first = build_provider(payment_system: "vipay", priority: 1, conversion_24h: 0.0)
    second = build_provider(payment_system: "payflow", priority: 2, conversion_24h: 1.0)
    third = build_provider(payment_system: "quickpay", priority: 3, conversion_24h: 1.0)
    context, tracker = context_with(
      [third, second, first],
      operation: build_operation(operation_id: "op_test")
    )
    skipped = context.providers.find { |provider| provider.payment_system == "vipay" }
    chosen = context.providers.find { |provider| provider.payment_system == "payflow" }
    skipped_before = snapshot(skipped)

    SmartRouter::FallbackExecutor.execute(context, tracker: tracker)

    assert_equal "payflow", context.selected_provider.payment_system
    assert_equal "first_eligible", context.selection_reason
    assert_equal(
      [
        { "provider" => "vipay", "decision" => "skipped", "reason" => "provider_rejected" },
        { "provider" => "payflow", "decision" => "selected", "reason" => "first_eligible" }
      ],
      context.attempts
    )
    refute(context.attempts.any? { |attempt| attempt["provider"] == "quickpay" })
    assert_equal(
      "approved",
      SmartRouter::DecisionRecordBuilder.simulate_result(context.operation, context.selected_provider)
    )
    assert_skip_released_without_permanent_updates(skipped, before: skipped_before)
    assert_approved_permanent_updates(chosen, amount: 500)
  end

  def test_expired_skips_and_tries_next
    first = build_provider(payment_system: "vipay", priority: 1, conversion_24h: 1.0)
    second = build_provider(payment_system: "payflow", priority: 2, conversion_24h: 1.0)
    context, tracker = context_with(
      [second, first],
      operation: build_operation(operation_id: "op_test")
    )
    skipped = context.providers.find { |provider| provider.payment_system == "vipay" }
    chosen = context.providers.find { |provider| provider.payment_system == "payflow" }
    skipped_before = snapshot(skipped)
    simulate_singleton = class << SmartRouter::DecisionRecordBuilder
      self
    end
    outcomes = %w[expired approved]
    simulate_singleton.alias_method :__original_simulate_result, :simulate_result
    simulate_singleton.define_method(:simulate_result) do |*_args|
      outcomes.shift || raise("unexpected extra simulate_result call")
    end

    SmartRouter::FallbackExecutor.execute(context, tracker: tracker)

    assert_equal "payflow", context.selected_provider.payment_system
    assert_equal(
      [
        { "provider" => "vipay", "decision" => "skipped", "reason" => "provider_expired" },
        { "provider" => "payflow", "decision" => "selected", "reason" => "first_eligible" }
      ],
      context.attempts
    )
    assert_skip_released_without_permanent_updates(skipped, before: skipped_before)
    assert_approved_permanent_updates(chosen, amount: 500)
  ensure
    if simulate_singleton&.method_defined?(:__original_simulate_result)
      simulate_singleton.alias_method :simulate_result, :__original_simulate_result
      simulate_singleton.remove_method :__original_simulate_result
    end
  end

  def test_equal_priority_tries_ascending_payment_system
    beta = build_provider(payment_system: "beta", priority: 1, conversion_24h: 1.0)
    alpha = build_provider(payment_system: "alpha", priority: 1, conversion_24h: 1.0)
    context, tracker = context_with([beta, alpha])

    SmartRouter::FallbackExecutor.execute(context, tracker: tracker)

    assert_equal "alpha", context.selected_provider.payment_system
    assert_equal "first_eligible", context.selection_reason
    assert_equal(
      [{ "provider" => "alpha", "decision" => "selected", "reason" => "first_eligible" }],
      context.attempts
    )
    refute(context.attempts.any? { |attempt| attempt["provider"] == "beta" })
  end

  def test_all_failed_raises_input_error_without_selected
    first = build_provider(payment_system: "vipay", priority: 1, conversion_24h: 0.0)
    second = build_provider(payment_system: "payflow", priority: 2, conversion_24h: 0.0)
    context, tracker = context_with(
      [first, second],
      operation: build_operation(operation_id: "op_test")
    )
    working_before = context.providers.map { |provider| snapshot(provider) }

    error = assert_raises(SmartRouter::InputError) do
      SmartRouter::FallbackExecutor.execute(context, tracker: tracker)
    end

    assert_includes error.message, "no eligible providers"
    assert_includes error.message, "op_test"
    assert_nil context.selected_provider
    refute(context.attempts.any? { |attempt| attempt["decision"] == "selected" })
    assert_equal(
      [
        { "provider" => "vipay", "decision" => "skipped", "reason" => "provider_rejected" },
        { "provider" => "payflow", "decision" => "skipped", "reason" => "provider_rejected" }
      ],
      context.attempts
    )
    assert_equal working_before, context.providers.map { |provider| snapshot(provider) }
  end

  def test_hard_skip_stays_in_place_then_execution_skip_and_selected
    skipped = build_provider(payment_system: "blocked", priority: 9)
    first = build_provider(payment_system: "vipay", priority: 1, conversion_24h: 0.0)
    second = build_provider(payment_system: "payflow", priority: 2, conversion_24h: 1.0)
    context, tracker = context_with(
      [first, second, skipped],
      eligible: [first, second],
      operation: build_operation(operation_id: "op_test")
    )
    context.add_attempt(skipped, "skipped", "amount_exceeds_limit")

    SmartRouter::FallbackExecutor.execute(context, tracker: tracker)

    assert_equal(
      [
        { "provider" => "blocked", "decision" => "skipped", "reason" => "amount_exceeds_limit" },
        { "provider" => "vipay", "decision" => "skipped", "reason" => "provider_rejected" },
        { "provider" => "payflow", "decision" => "selected", "reason" => "first_eligible" }
      ],
      context.attempts
    )
    assert_equal 1, context.attempts.count { |attempt| attempt["reason"] == "amount_exceeds_limit" }
  end

  def test_next_operation_hard_filter_sees_working_set_not_catalog
    catalog = build_provider(
      payment_system: "vipay",
      conversion_24h: 1.0,
      daily_approved_amount: 1000,
      daily_amount_limit: 1050,
      available_requisites: 12,
      limit_amount_min: 1
    )
    catalog_before = snapshot(catalog)
    working = [catalog.dup]
    tracker = SmartRouter::StateTracker.new

    first_op = build_operation(operation_id: "op_first", amount: 50)
    first_ctx = SmartRouter::PipelineContext.for(first_op, providers: working)
    first_ctx.eligible_providers = first_ctx.providers
    SmartRouter::FallbackExecutor.execute(first_ctx, tracker: tracker)
    working = first_ctx.providers

    next_op = build_operation(operation_id: "op_next", amount: 50)
    next_ctx = SmartRouter::PipelineContext.for(next_op, providers: working)
    SmartRouter::HardConstraintsFilter.filter(next_ctx)

    assert_equal 1050, working.first.daily_approved_amount
    assert_equal 11, working.first.available_requisites
    assert_empty next_ctx.eligible_providers
    assert_equal(
      [{ "provider" => "vipay", "decision" => "skipped", "reason" => "daily_limit_exceeded" }],
      next_ctx.attempts
    )
    assert_equal catalog_before, snapshot(catalog)
  end

  def test_empty_eligible_raises_without_simulation_or_tracker
    provider = build_provider(payment_system: "vipay", conversion_24h: 1.0)
    before = snapshot(provider)
    context = SmartRouter::PipelineContext.for(build_operation, providers: [provider])
    context.eligible_providers = []
    tracker = SmartRouter::StateTracker.new

    error = assert_raises(SmartRouter::InputError) do
      SmartRouter::FallbackExecutor.execute(context, tracker: tracker)
    end

    assert_includes error.message, "no eligible providers"
    assert_nil context.selected_provider
    assert_empty context.attempts
    assert_equal before, snapshot(context.providers.first)
    assert_equal 0, context.providers.first.in_progress_count
  end

  def test_single_eligible_approved_uses_only_eligible_reason
    provider = build_provider(payment_system: "quickpay", priority: 3, conversion_24h: 1.0)
    context, tracker = context_with([provider])

    SmartRouter::FallbackExecutor.execute(context, tracker: tracker)

    assert_equal "only_eligible_provider", context.selection_reason
    assert_equal(
      [{ "provider" => "quickpay", "decision" => "selected", "reason" => "only_eligible_provider" }],
      context.attempts
    )
  end

  def test_does_not_call_baseline_selector
    first = build_provider(payment_system: "vipay", priority: 1, conversion_24h: 1.0)
    second = build_provider(payment_system: "payflow", priority: 2, conversion_24h: 1.0)
    context, tracker = context_with([first, second])
    called = false
    select_singleton = class << SmartRouter::BaselineSelector
      self
    end
    select_singleton.alias_method :__original_select, :select
    select_singleton.define_method(:select) do |*|
      called = true
      raise "BaselineSelector.select must not run during cascade"
    end

    SmartRouter::FallbackExecutor.execute(context, tracker: tracker)

    refute called
    assert_equal "vipay", context.selected_provider.payment_system
  ensure
    if select_singleton&.method_defined?(:__original_select)
      select_singleton.alias_method :select, :__original_select
      select_singleton.remove_method :__original_select
    end
  end

  def test_loaded_catalog_stays_clean_after_cascade
    inputs = load_inputs
    before = inputs.providers.map { |provider| snapshot(provider) }
    working = inputs.providers.map(&:dup)
    tracker = SmartRouter::StateTracker.new
    operation = inputs.operations.first
    context = SmartRouter::PipelineContext.for(operation, providers: working)
    SmartRouter::HardConstraintsFilter.filter(context)

    SmartRouter::FallbackExecutor.execute(context, tracker: tracker)

    assert_equal before, inputs.providers.map { |provider| snapshot(provider) }
    refute_empty context.attempts.select { |attempt| attempt["decision"] == "selected" }
  end

  def test_builder_simulated_result_matches_cascade_seed
    first = build_provider(payment_system: "vipay", priority: 1, conversion_24h: 0.0)
    second = build_provider(payment_system: "payflow", priority: 2, conversion_24h: 1.0)
    context, tracker = context_with(
      [first, second],
      operation: build_operation(operation_id: "op_test")
    )

    SmartRouter::FallbackExecutor.execute(context, tracker: tracker)
    record = SmartRouter::DecisionRecordBuilder.build(context)

    assert_equal "payflow", record["selected_provider"]
    assert_equal "approved", record["simulated_result"]
    assert_equal(
      SmartRouter::DecisionRecordBuilder.simulate_result(context.operation, context.selected_provider),
      record["simulated_result"]
    )
  end

  private

  def context_with(providers, operation: nil, eligible: nil)
    ctx = SmartRouter::PipelineContext.for(
      operation || build_operation,
      providers: providers
    )
    chosen = eligible || providers
    ctx.eligible_providers = chosen.map do |provider|
      ctx.providers.find { |row| row.payment_system == provider.payment_system }
    end
    [ctx, SmartRouter::StateTracker.new]
  end

  def assert_in_progress_rolled_back(provider, amount:)
    assert_equal 0, provider.in_progress_count
    assert_equal 0, provider.in_progress_amount
    assert_operator provider.daily_approved_amount, :>=, amount
  end

  def assert_skip_released_without_permanent_updates(provider, before:)
    assert_equal 0, provider.in_progress_count
    assert_equal 0, provider.in_progress_amount
    assert_equal before.fetch(:daily_approved_amount), provider.daily_approved_amount
    assert_equal before.fetch(:available_requisites), provider.available_requisites
  end

  def assert_approved_permanent_updates(provider, amount:)
    assert_equal 0, provider.in_progress_count
    assert_equal 0, provider.in_progress_amount
    assert_equal amount, provider.daily_approved_amount
    assert_equal 9, provider.available_requisites
  end

  def snapshot(provider)
    {
      in_progress_count: provider.in_progress_count,
      in_progress_amount: provider.in_progress_amount,
      daily_approved_amount: provider.daily_approved_amount,
      available_requisites: provider.available_requisites,
      priority: provider.priority,
      conversion_24h: provider.conversion_24h,
      banks: provider.banks.dup
    }
  end

  def build_provider(overrides = {})
    hash = {
      "payment_system" => "test_provider",
      "status" => "active",
      "priority" => 1,
      "traffic_percentage" => 50,
      "limit_amount_min" => 100,
      "limit_amount_max" => 1000,
      "daily_amount_limit" => 10_000,
      "daily_approved_amount" => 0,
      "in_progress_count_limit" => 5,
      "in_progress_count" => 0,
      "in_progress_amount_limit" => 5000,
      "in_progress_amount" => 0,
      "available_requisites" => 10,
      "conversion_24h" => 0.9,
      "avg_latency_sec" => 10,
      "banks" => [],
      "exclude_banks" => false,
      "provider_margin_pct" => 1.0,
      "merchant_margin_pct" => 1.5,
      "allow_negative_agreement" => false
    }.merge(overrides.transform_keys(&:to_s))

    SmartRouter::Provider.from_hash(hash, path: "test")
  end

  def build_operation(overrides = {})
    hash = {
      "operation_id" => "op_test",
      "created_at" => "2026-09-04T12:00:00+03:00",
      "amount" => 500,
      "bank" => "sberbank"
    }.merge(overrides.transform_keys(&:to_s))

    SmartRouter::Operation.from_hash(hash, path: "test")
  end

  def load_inputs
    SmartRouter::RunInputs.load(
      providers_path: File.join(FIXTURES, "providers.json"),
      queue_path: File.join(FIXTURES, "operations_queue.json"),
      history_path: File.join(FIXTURES, "operations_history.csv")
    )
  end
end
