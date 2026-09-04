# frozen_string_literal: true

require "minitest/autorun"
require "smart_router"

class BaselineSelectorTest < Minitest::Test
  FIXTURES = File.expand_path("../fixtures/inputs", __dir__)
  PROJECT_ROOT = File.expand_path("../..", __dir__)

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

  def context_with(providers, operation: nil, eligible: nil)
    ctx = SmartRouter::PipelineContext.for(
      operation || build_operation,
      providers: providers
    )
    ctx.eligible_providers = eligible || providers
    ctx
  end

  def test_single_eligible_provider_is_selected_with_only_eligible_reason
    quickpay = build_provider(payment_system: "quickpay", priority: 3)
    context = context_with([quickpay])

    result = SmartRouter::BaselineSelector.select(context)

    assert_same context, result
    assert_equal "quickpay", context.selected_provider.payment_system
    assert_equal "only_eligible_provider", context.selection_reason
    assert_equal 1, context.attempts.length
    assert_equal(
      { "provider" => "quickpay", "decision" => "selected", "reason" => "only_eligible_provider" },
      context.attempts.last
    )
  end

  def test_multiple_eligible_providers_select_lowest_priority_as_first_eligible
    vipay = build_provider(payment_system: "vipay", priority: 1)
    payflow = build_provider(payment_system: "payflow", priority: 2)
    quickpay = build_provider(payment_system: "quickpay", priority: 3)
    context = context_with([quickpay, payflow, vipay])

    SmartRouter::BaselineSelector.select(context)

    assert_equal "vipay", context.selected_provider.payment_system
    assert_equal "first_eligible", context.selection_reason
    assert_equal 1, context.attempts.length
    assert_equal(
      { "provider" => "vipay", "decision" => "selected", "reason" => "first_eligible" },
      context.attempts.last
    )
  end

  def test_equal_priority_breaks_ties_by_payment_system
    beta = build_provider(payment_system: "beta", priority: 1)
    alpha = build_provider(payment_system: "alpha", priority: 1)
    context = context_with([beta, alpha])

    SmartRouter::BaselineSelector.select(context)

    assert_equal "alpha", context.selected_provider.payment_system
    assert_equal "first_eligible", context.selection_reason
  end

  def test_preserves_existing_skip_attempts_and_appends_one_selected
    vipay = build_provider(payment_system: "vipay", priority: 1)
    payflow = build_provider(payment_system: "payflow", priority: 2)
    context = context_with([vipay, payflow], eligible: [vipay, payflow])
    context.add_attempt("vipay_skip_source", "skipped", "bank_not_in_list")

    SmartRouter::BaselineSelector.select(context)

    assert_equal 2, context.attempts.length
    assert_equal(
      { "provider" => "vipay_skip_source", "decision" => "skipped", "reason" => "bank_not_in_list" },
      context.attempts.first
    )
    assert_equal(
      { "provider" => "vipay", "decision" => "selected", "reason" => "first_eligible" },
      context.attempts.last
    )
    refute(context.attempts.any? { |attempt| attempt["provider"] == "payflow" })
  end

  def test_empty_eligible_pool_raises_input_error
    provider = build_provider(payment_system: "vipay")
    context = context_with([provider], eligible: [])

    error = assert_raises(SmartRouter::InputError) do
      SmartRouter::BaselineSelector.select(context)
    end
    assert_includes error.message, "no eligible providers"
    assert_includes error.message, "op_test"
    assert_nil context.selected_provider
    assert_empty context.attempts
  end

  def test_fixture_op_101_selects_vipay_as_first_eligible
    inputs = load_fixture_inputs
    operation = inputs.operations.find { |row| row.operation_id == "op_101" }
    context = SmartRouter::PipelineContext.for(operation, providers: inputs.providers)
    SmartRouter::HardConstraintsFilter.filter(context)
    SmartRouter::BaselineSelector.select(context)

    assert_equal "vipay", context.selected_provider.payment_system
    assert_equal "first_eligible", context.selection_reason
    selected = context.attempts.select { |attempt| attempt["decision"] == "selected" }
    assert_equal 1, selected.length
    assert_equal "vipay", selected.first["provider"]
  end

  def test_fixture_op_103_selects_quickpay_as_only_external_eligible
    inputs = load_project_inputs
    providers = inputs.providers.reject { |provider| provider.payment_system == "spacepayments" }
    operation = inputs.operations.find { |row| row.operation_id == "op_103" }
    context = SmartRouter::PipelineContext.for(operation, providers: providers)
    SmartRouter::HardConstraintsFilter.filter(context)
    SmartRouter::BaselineSelector.select(context)

    assert_equal ["quickpay"], context.eligible_providers.map(&:payment_system)
    assert_equal "quickpay", context.selected_provider.payment_system
    assert_equal "only_eligible_provider", context.selection_reason
  end

  private

  def load_fixture_inputs
    SmartRouter::RunInputs.load(
      providers_path: File.join(FIXTURES, "providers.json"),
      queue_path: File.join(FIXTURES, "operations_queue.json"),
      history_path: File.join(FIXTURES, "operations_history.csv")
    )
  end

  def load_project_inputs
    SmartRouter::RunInputs.load(
      providers_path: File.join(PROJECT_ROOT, "config/providers.json"),
      queue_path: File.join(PROJECT_ROOT, "data/operations_queue.json"),
      history_path: File.join(PROJECT_ROOT, "data/operations_history.csv")
    )
  end
end
