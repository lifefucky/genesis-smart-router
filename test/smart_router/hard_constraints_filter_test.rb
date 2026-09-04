# frozen_string_literal: true

require "minitest/autorun"
require "smart_router"

class HardConstraintsFilterTest < Minitest::Test
  def build_provider(overrides = {})
    hash = {
      "payment_system" => "test_provider",
      "status" => "active",
      "priority" => 1,
      "traffic_percentage" => 50,
      "limit_amount_min" => 100,
      "limit_amount_max" => 1000,
      "daily_amount_limit" => 10000,
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

  def test_all_eligible_providers
    provider = build_provider(payment_system: "vipay")
    operation = build_operation(amount: 500, bank: "sberbank")
    context = SmartRouter::PipelineContext.for(operation, providers: [provider])

    SmartRouter::HardConstraintsFilter.filter(context)

    assert_equal 1, context.eligible_providers.length
    assert_equal "vipay", context.eligible_providers.first.payment_system
    assert_empty context.attempts
  end

  def test_inactive_provider_ignored
    provider = build_provider(payment_system: "vipay", status: "inactive")
    operation = build_operation(amount: 500)
    context = SmartRouter::PipelineContext.for(operation, providers: [provider])

    SmartRouter::HardConstraintsFilter.filter(context)

    assert_empty context.eligible_providers
    assert_empty context.attempts
  end

  def test_spacepayments_always_eligible
    provider = build_provider(
      payment_system: "spacepayments",
      traffic_percentage: 0,
      limit_amount_min: 1000,
      available_requisites: 0,
      provider_margin_pct: 2.0,
      merchant_margin_pct: 1.0,
      banks: ["tinkoff"],
      exclude_banks: false
    )
    operation = build_operation(amount: 500, bank: "sberbank")
    context = SmartRouter::PipelineContext.for(operation, providers: [provider])

    SmartRouter::HardConstraintsFilter.filter(context)

    assert_equal 1, context.eligible_providers.length
    assert_equal "spacepayments", context.eligible_providers.first.payment_system
    assert_empty context.attempts
  end

  def test_traffic_percentage_zero_excluded
    provider = build_provider(payment_system: "vipay", traffic_percentage: 0)
    operation = build_operation(amount: 500)
    context = SmartRouter::PipelineContext.for(operation, providers: [provider])

    SmartRouter::HardConstraintsFilter.filter(context)

    assert_empty context.eligible_providers
    assert_equal 1, context.attempts.length
    assert_equal(
      { "provider" => "vipay", "decision" => "skipped", "reason" => "amount_below_minimum" },
      context.attempts.first
    )
  end

  def test_limit_amount_min_excluded
    provider = build_provider(payment_system: "vipay", limit_amount_min: 1000)
    operation = build_operation(amount: 500)
    context = SmartRouter::PipelineContext.for(operation, providers: [provider])

    SmartRouter::HardConstraintsFilter.filter(context)

    assert_empty context.eligible_providers
    assert_equal 1, context.attempts.length
    assert_equal(
      { "provider" => "vipay", "decision" => "skipped", "reason" => "amount_below_minimum" },
      context.attempts.first
    )
  end

  def test_limit_amount_max_excluded
    provider = build_provider(payment_system: "vipay", limit_amount_max: 400)
    operation = build_operation(amount: 500)
    context = SmartRouter::PipelineContext.for(operation, providers: [provider])

    SmartRouter::HardConstraintsFilter.filter(context)

    assert_empty context.eligible_providers
    assert_equal 1, context.attempts.length
    assert_equal(
      { "provider" => "vipay", "decision" => "skipped", "reason" => "amount_exceeds_limit" },
      context.attempts.first
    )
  end

  def test_daily_limit_exceeded
    provider = build_provider(
      payment_system: "vipay",
      daily_amount_limit: 1000,
      daily_approved_amount: 600
    )
    operation = build_operation(amount: 500)
    context = SmartRouter::PipelineContext.for(operation, providers: [provider])

    SmartRouter::HardConstraintsFilter.filter(context)

    assert_empty context.eligible_providers
    assert_equal 1, context.attempts.length
    assert_equal(
      { "provider" => "vipay", "decision" => "skipped", "reason" => "daily_limit_exceeded" },
      context.attempts.first
    )
  end

  def test_in_progress_count_exceeded
    provider = build_provider(
      payment_system: "vipay",
      in_progress_count_limit: 5,
      in_progress_count: 5
    )
    operation = build_operation(amount: 500)
    context = SmartRouter::PipelineContext.for(operation, providers: [provider])

    SmartRouter::HardConstraintsFilter.filter(context)

    assert_empty context.eligible_providers
    assert_equal 1, context.attempts.length
    assert_equal(
      { "provider" => "vipay", "decision" => "skipped", "reason" => "in_progress_count_exceeded" },
      context.attempts.first
    )
  end

  def test_in_progress_amount_exceeded
    provider = build_provider(
      payment_system: "vipay",
      in_progress_amount_limit: 1000,
      in_progress_amount: 600
    )
    operation = build_operation(amount: 500)
    context = SmartRouter::PipelineContext.for(operation, providers: [provider])

    SmartRouter::HardConstraintsFilter.filter(context)

    assert_empty context.eligible_providers
    assert_equal 1, context.attempts.length
    assert_equal(
      { "provider" => "vipay", "decision" => "skipped", "reason" => "in_progress_amount_exceeded" },
      context.attempts.first
    )
  end

  def test_no_requisites
    provider = build_provider(payment_system: "vipay", available_requisites: 0)
    operation = build_operation(amount: 500)
    context = SmartRouter::PipelineContext.for(operation, providers: [provider])

    SmartRouter::HardConstraintsFilter.filter(context)

    assert_empty context.eligible_providers
    assert_equal 1, context.attempts.length
    assert_equal(
      { "provider" => "vipay", "decision" => "skipped", "reason" => "no_requisites" },
      context.attempts.first
    )
  end

  def test_negative_margin
    provider = build_provider(
      payment_system: "vipay",
      provider_margin_pct: 1.6,
      merchant_margin_pct: 1.5,
      allow_negative_agreement: false
    )
    operation = build_operation(amount: 500)
    context = SmartRouter::PipelineContext.for(operation, providers: [provider])

    SmartRouter::HardConstraintsFilter.filter(context)

    assert_empty context.eligible_providers
    assert_equal 1, context.attempts.length
    assert_equal(
      { "provider" => "vipay", "decision" => "skipped", "reason" => "negative_margin" },
      context.attempts.first
    )
  end

  def test_negative_margin_allowed
    provider = build_provider(
      payment_system: "vipay",
      provider_margin_pct: 1.6,
      merchant_margin_pct: 1.5,
      allow_negative_agreement: true
    )
    operation = build_operation(amount: 500)
    context = SmartRouter::PipelineContext.for(operation, providers: [provider])

    SmartRouter::HardConstraintsFilter.filter(context)

    assert_equal 1, context.eligible_providers.length
    assert_empty context.attempts
  end

  def test_bank_not_in_list_whitelist
    provider = build_provider(
      payment_system: "vipay",
      banks: ["tinkoff", "vtb"],
      exclude_banks: false
    )
    operation = build_operation(amount: 500, bank: "sberbank")
    context = SmartRouter::PipelineContext.for(operation, providers: [provider])

    SmartRouter::HardConstraintsFilter.filter(context)

    assert_empty context.eligible_providers
    assert_equal 1, context.attempts.length
    assert_equal(
      { "provider" => "vipay", "decision" => "skipped", "reason" => "bank_not_in_list" },
      context.attempts.first
    )
  end

  def test_bank_in_list_whitelist
    provider = build_provider(
      payment_system: "vipay",
      banks: ["sberbank", "vtb"],
      exclude_banks: false
    )
    operation = build_operation(amount: 500, bank: "sberbank")
    context = SmartRouter::PipelineContext.for(operation, providers: [provider])

    SmartRouter::HardConstraintsFilter.filter(context)

    assert_equal 1, context.eligible_providers.length
    assert_empty context.attempts
  end

  def test_bank_not_in_list_blacklist
    provider = build_provider(
      payment_system: "vipay",
      banks: ["sberbank"],
      exclude_banks: true
    )
    operation = build_operation(amount: 500, bank: "sberbank")
    context = SmartRouter::PipelineContext.for(operation, providers: [provider])

    SmartRouter::HardConstraintsFilter.filter(context)

    assert_empty context.eligible_providers
    assert_equal 1, context.attempts.length
    assert_equal(
      { "provider" => "vipay", "decision" => "skipped", "reason" => "bank_not_in_list" },
      context.attempts.first
    )
  end

  def test_bank_in_list_blacklist
    provider = build_provider(
      payment_system: "vipay",
      banks: ["tinkoff"],
      exclude_banks: true
    )
    operation = build_operation(amount: 500, bank: "sberbank")
    context = SmartRouter::PipelineContext.for(operation, providers: [provider])

    SmartRouter::HardConstraintsFilter.filter(context)

    assert_equal 1, context.eligible_providers.length
    assert_empty context.attempts
  end

  def test_multiple_providers_mixed
    p1 = build_provider(payment_system: "vipay", status: "active")
    p2 = build_provider(payment_system: "payflow", status: "inactive")
    p3 = build_provider(
      payment_system: "spacepayments",
      traffic_percentage: 0,
      limit_amount_min: 1000,
      available_requisites: 0
    )
    p4 = build_provider(payment_system: "quickpay", available_requisites: 0)
    p5 = build_provider(payment_system: "fastpay", banks: ["tinkoff"], exclude_banks: false)

    operation = build_operation(amount: 500, bank: "sberbank")
    context = SmartRouter::PipelineContext.for(operation, providers: [p1, p2, p3, p4, p5])

    SmartRouter::HardConstraintsFilter.filter(context)

    # Eligible: vipay, spacepayments
    assert_equal 2, context.eligible_providers.length
    assert_equal "vipay", context.eligible_providers[0].payment_system
    assert_equal "spacepayments", context.eligible_providers[1].payment_system

    # Attempts: quickpay, fastpay (payflow is inactive so ignored entirely)
    assert_equal 2, context.attempts.length
    assert_equal(
      { "provider" => "quickpay", "decision" => "skipped", "reason" => "no_requisites" },
      context.attempts[0]
    )
    assert_equal(
      { "provider" => "fastpay", "decision" => "skipped", "reason" => "bank_not_in_list" },
      context.attempts[1]
    )
  end

  def test_regular_provider_with_nil_limits_is_eligible
    provider = build_provider(
      payment_system: "vipay",
      limit_amount_min: nil,
      limit_amount_max: nil,
      daily_amount_limit: nil,
      in_progress_count_limit: nil,
      in_progress_amount_limit: nil
    )
    operation = build_operation(amount: 500)
    context = SmartRouter::PipelineContext.for(operation, providers: [provider])

    SmartRouter::HardConstraintsFilter.filter(context)

    assert_equal 1, context.eligible_providers.length
    assert_equal "vipay", context.eligible_providers.first.payment_system
    assert_empty context.attempts
  end

  def test_non_active_suspended_provider_ignored
    provider = build_provider(payment_system: "vipay", status: "suspended")
    operation = build_operation(amount: 500)
    context = SmartRouter::PipelineContext.for(operation, providers: [provider])

    SmartRouter::HardConstraintsFilter.filter(context)

    assert_empty context.eligible_providers
    assert_empty context.attempts
  end

  def test_filter_returns_identical_context_object
    provider = build_provider(payment_system: "vipay")
    operation = build_operation(amount: 500)
    context = SmartRouter::PipelineContext.for(operation, providers: [provider])

    result = SmartRouter::HardConstraintsFilter.filter(context)

    assert_same context, result
  end
end
