# frozen_string_literal: true

require "minitest/autorun"
require "smart_router"

class DecisionRecordBuilderTest < Minitest::Test
  def build_provider(overrides = {})
    hash = {
      "payment_system" => "quickpay",
      "status" => "active",
      "priority" => 3,
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

  def selected_context(provider: nil, operation: nil, extra_attempts: [])
    chosen = provider || build_provider
    ctx = SmartRouter::PipelineContext.for(
      operation || build_operation,
      providers: [chosen]
    )
    extra_attempts.each do |attempt|
      ctx.add_attempt(attempt.fetch("provider"), attempt.fetch("decision"), attempt.fetch("reason"))
    end
    ctx.eligible_providers = [chosen]
    ctx.selected_provider = chosen
    ctx.selection_reason = extra_attempts.any? ? "first_eligible" : "only_eligible_provider"
    ctx.add_attempt(chosen, "selected", ctx.selection_reason)
    ctx
  end

  def test_happy_path_returns_five_required_string_keys
    context = selected_context
    record = SmartRouter::DecisionRecordBuilder.build(context)

    assert_equal %w[operation_id selected_provider attempts simulated_result latency_sec],
                 record.keys
    assert_equal "op_test", record["operation_id"]
    assert_equal "quickpay", record["selected_provider"]
    assert_kind_of Array, record["attempts"]
    assert_includes %w[approved rejected expired], record["simulated_result"]
    assert_instance_of Integer, record["latency_sec"]
    assert_operator record["latency_sec"], :>=, 1
  end

  def test_preserves_skip_attempts_without_duplicating_or_reordering
    skip_attempt = {
      "provider" => "vipay",
      "decision" => "skipped",
      "reason" => "bank_not_in_list"
    }
    context = selected_context(
      provider: build_provider(payment_system: "payflow", priority: 2),
      extra_attempts: [skip_attempt]
    )

    record = SmartRouter::DecisionRecordBuilder.build(context)

    assert_equal 2, record["attempts"].length
    assert_equal skip_attempt, record["attempts"].first
    assert_equal(
      { "provider" => "payflow", "decision" => "selected", "reason" => "first_eligible" },
      record["attempts"].last
    )
    assert_equal 1, record["attempts"].count { |attempt| attempt["decision"] == "selected" }
    refute_same context.attempts, record["attempts"]
    refute_same context.attempts.first, record["attempts"].first
  end

  def test_nil_selected_provider_raises_input_error
    context = SmartRouter::PipelineContext.for(build_operation, providers: [build_provider])

    error = assert_raises(SmartRouter::InputError) do
      SmartRouter::DecisionRecordBuilder.build(context)
    end
    assert_includes error.message, "selected provider"
  end

  def test_simulation_is_deterministic_across_repeated_builds
    provider = build_provider(conversion_24h: 0.5, avg_latency_sec: 38)
    context = selected_context(provider: provider)

    first = SmartRouter::DecisionRecordBuilder.build(context)
    second = SmartRouter::DecisionRecordBuilder.build(context)

    assert_equal first["simulated_result"], second["simulated_result"]
    assert_equal first["latency_sec"], second["latency_sec"]
    assert_includes %w[approved rejected expired], first["simulated_result"]
  end

  def test_simulation_matches_spec_seeded_formula
    operation = build_operation(operation_id: "op_golden")
    provider = build_provider(payment_system: "quickpay", conversion_24h: 0.5)
    context = selected_context(provider: provider, operation: operation)

    record = SmartRouter::DecisionRecordBuilder.build(context)
    shared = SmartRouter::DecisionRecordBuilder.simulate_result(operation, provider)

    assert_equal expected_simulated_result("op_golden", "quickpay", 0.5),
                 record["simulated_result"]
    assert_equal record["simulated_result"], shared
  end

  def test_zero_conversion_is_rejected_or_expired_and_stable
    provider = build_provider(conversion_24h: 0.0, avg_latency_sec: 12)
    context = selected_context(provider: provider)

    results = 3.times.map { SmartRouter::DecisionRecordBuilder.build(context)["simulated_result"] }

    assert_equal 1, results.uniq.length
    assert_includes %w[rejected expired], results.first
  end

  def test_full_conversion_is_approved
    provider = build_provider(conversion_24h: 1.0)
    context = selected_context(provider: provider)

    record = SmartRouter::DecisionRecordBuilder.build(context)

    assert_equal "approved", record["simulated_result"]
  end

  def test_latency_sec_maps_avg_latency_to_positive_integer
    assert_equal 38, build_and_latency(avg_latency_sec: 38)
    assert_equal 10, build_and_latency(avg_latency_sec: 10.9)
    assert_equal 1, build_and_latency(avg_latency_sec: 0)
    assert_equal 1, build_and_latency(avg_latency_sec: 0.4)
  end

  def test_does_not_rerun_baseline_selection
    vipay = build_provider(payment_system: "vipay", priority: 1)
    payflow = build_provider(payment_system: "payflow", priority: 2)
    context = SmartRouter::PipelineContext.for(
      build_operation,
      providers: [vipay, payflow]
    )
    context.eligible_providers = [vipay, payflow]
    context.selected_provider = payflow
    context.selection_reason = "first_eligible"
    context.add_attempt(payflow, "selected", "first_eligible")

    record = SmartRouter::DecisionRecordBuilder.build(context)

    assert_equal "payflow", record["selected_provider"]
    assert_equal "payflow", context.selected_provider.payment_system
    assert_equal 1, record["attempts"].length
  end

  private

  def build_and_latency(avg_latency_sec:)
    context = selected_context(provider: build_provider(avg_latency_sec: avg_latency_sec))
    SmartRouter::DecisionRecordBuilder.build(context)["latency_sec"]
  end

  def expected_simulated_result(operation_id, payment_system, conversion_24h)
    seed = "#{operation_id}:#{payment_system}".each_byte.reduce(0) { |acc, byte| acc * 31 + byte }
    rng = Random.new(seed)
    if rng.rand < conversion_24h
      "approved"
    else
      rng.rand < 0.5 ? "rejected" : "expired"
    end
  end
end
