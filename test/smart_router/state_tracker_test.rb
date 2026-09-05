# frozen_string_literal: true

require "minitest/autorun"
require "smart_router"

class StateTrackerTest < Minitest::Test
  FIXTURES = File.expand_path("../fixtures/inputs", __dir__)

  def test_start_increments_in_progress_and_leaves_catalog_unchanged
    inputs = load_inputs
    catalog = inputs.providers.first
    catalog_before = snapshot(catalog)
    working = catalog.dup
    tracker = SmartRouter::StateTracker.new

    tracker.start(working, 50)

    assert_equal 5, working.in_progress_count
    assert_equal catalog_before.fetch(:in_progress_amount) + 50, working.in_progress_amount
    assert_equal catalog_before, snapshot(catalog)
  end

  def test_start_uses_matrix_deltas
    provider = build_provider(in_progress_count: 4, in_progress_amount: 100)

    SmartRouter::StateTracker.new.start(provider, 50)

    assert_equal 5, provider.in_progress_count
    assert_equal 150, provider.in_progress_amount
  end

  def test_rejected_restores_in_progress_without_permanent_changes
    assert_release_restores_in_progress("rejected")
  end

  def test_expired_restores_in_progress_without_permanent_changes
    assert_release_restores_in_progress("expired")
  end

  def test_approved_rolls_back_in_progress_and_accumulates_permanent_state
    provider = build_provider(
      in_progress_count: 4,
      in_progress_amount: 100,
      daily_approved_amount: 1000,
      available_requisites: 12
    )
    tracker = SmartRouter::StateTracker.new

    tracker.start(provider, 50)
    tracker.finish(provider, 50, "approved")

    assert_equal 4, provider.in_progress_count
    assert_equal 100, provider.in_progress_amount
    assert_equal 1050, provider.daily_approved_amount
    assert_equal 11, provider.available_requisites
  end

  def test_approved_leaves_non_numeric_requisites_unchanged
    provider = build_provider(daily_approved_amount: 1000, available_requisites: 12)
    provider.available_requisites = "n/a"
    tracker = SmartRouter::StateTracker.new

    tracker.start(provider, 50)
    tracker.finish(provider, 50, "approved")

    assert_equal 1050, provider.daily_approved_amount
    assert_equal "n/a", provider.available_requisites
  end

  def test_approved_does_not_decrement_zero_requisites_below_zero
    provider = build_provider(daily_approved_amount: 1000, available_requisites: 0)
    tracker = SmartRouter::StateTracker.new

    tracker.start(provider, 50)
    tracker.finish(provider, 50, "approved")

    assert_equal 1050, provider.daily_approved_amount
    assert_equal 0, provider.available_requisites
  end

  def test_unknown_finish_result_raises_and_leaves_snapshot_unchanged
    provider = build_provider(
      in_progress_count: 4,
      in_progress_amount: 100,
      daily_approved_amount: 1000,
      available_requisites: 12
    )
    tracker = SmartRouter::StateTracker.new
    tracker.start(provider, 50)
    before = snapshot(provider)

    error = assert_raises(ArgumentError) { tracker.finish(provider, 50, "skipped") }

    assert_match(/approved\|rejected\|expired/, error.message)
    assert_equal before, snapshot(provider)
  end

  def test_start_rejects_invalid_amount_and_leaves_snapshot_unchanged
    invalid_amounts.each do |amount|
      provider = build_provider(in_progress_count: 4, in_progress_amount: 100)
      before = snapshot(provider)

      assert_raises(ArgumentError) { SmartRouter::StateTracker.new.start(provider, amount) }
      assert_equal before, snapshot(provider), "start mutated snapshot for #{amount.inspect}"
    end
  end

  def test_finish_rejects_invalid_amount_and_leaves_in_progress_snapshot
    invalid_amounts.each do |amount|
      provider = build_provider(
        in_progress_count: 4,
        in_progress_amount: 100,
        daily_approved_amount: 1000,
        available_requisites: 12
      )
      tracker = SmartRouter::StateTracker.new
      tracker.start(provider, 50)
      after_start = snapshot(provider)

      assert_raises(ArgumentError) { tracker.finish(provider, amount, "approved") }
      assert_equal after_start, snapshot(provider), "finish mutated snapshot for #{amount.inspect}"
    end
  end

  def test_finish_without_start_raises_and_leaves_snapshot_unchanged
    provider = build_provider(
      in_progress_count: 4,
      in_progress_amount: 100,
      daily_approved_amount: 1000,
      available_requisites: 12
    )
    before = snapshot(provider)

    assert_raises(ArgumentError) do
      SmartRouter::StateTracker.new.finish(provider, 50, "approved")
    end

    assert_equal before, snapshot(provider)
  end

  def test_next_operation_hard_filter_sees_updated_working_set_not_catalog
    catalog = build_provider(
      payment_system: "vipay",
      daily_approved_amount: 1000,
      daily_amount_limit: 1049,
      available_requisites: 12,
      limit_amount_min: 1,
      in_progress_count: 4,
      in_progress_amount: 100
    )
    catalog_before = snapshot(catalog)
    working = catalog.dup
    tracker = SmartRouter::StateTracker.new
    tracker.start(working, 50)
    tracker.finish(working, 50, "approved")

    next_op = build_operation(operation_id: "op_next", amount: 50)
    context = SmartRouter::PipelineContext.for(next_op, providers: [working])
    SmartRouter::HardConstraintsFilter.filter(context)

    assert_equal 1050, working.daily_approved_amount
    assert_equal 11, working.available_requisites
    assert_empty context.eligible_providers
    assert_equal(
      [{ "provider" => "vipay", "decision" => "skipped", "reason" => "daily_limit_exceeded" }],
      context.attempts
    )
    assert_equal catalog_before, snapshot(catalog)
  end

  def test_next_operation_hard_filter_sees_requisite_depletion
    working = build_provider(
      payment_system: "vipay",
      available_requisites: 1,
      daily_approved_amount: 1000,
      daily_amount_limit: 10_000,
      limit_amount_min: 1
    )
    tracker = SmartRouter::StateTracker.new
    tracker.start(working, 50)
    tracker.finish(working, 50, "approved")

    context = SmartRouter::PipelineContext.for(
      build_operation(operation_id: "op_next", amount: 50),
      providers: [working]
    )
    SmartRouter::HardConstraintsFilter.filter(context)

    assert_equal 0, working.available_requisites
    assert_empty context.eligible_providers
    assert_equal(
      [{ "provider" => "vipay", "decision" => "skipped", "reason" => "no_requisites" }],
      context.attempts
    )
  end

  def test_dup_copies_current_tracked_metrics
    provider = build_provider(in_progress_count: 4, in_progress_amount: 100)
    SmartRouter::StateTracker.new.start(provider, 50)

    copy = provider.dup

    refute_same provider, copy
    assert_equal 5, copy.in_progress_count
    assert_equal 150, copy.in_progress_amount
    copy.in_progress_count = 99
    assert_equal 5, provider.in_progress_count
  end

  def test_mutations_do_not_touch_limits_priority_conversion_banks_or_margin
    provider = build_provider(
      priority: 2,
      conversion_24h: 0.42,
      banks: ["sberbank"],
      provider_margin_pct: 1.1,
      merchant_margin_pct: 1.8,
      in_progress_count_limit: 9,
      in_progress_amount_limit: 4000,
      daily_amount_limit: 8000,
      limit_amount_min: 10,
      limit_amount_max: 900
    )
    frozen = {
      priority: provider.priority,
      conversion_24h: provider.conversion_24h,
      banks: provider.banks.dup,
      provider_margin_pct: provider.provider_margin_pct,
      merchant_margin_pct: provider.merchant_margin_pct,
      in_progress_count_limit: provider.in_progress_count_limit,
      in_progress_amount_limit: provider.in_progress_amount_limit,
      daily_amount_limit: provider.daily_amount_limit,
      limit_amount_min: provider.limit_amount_min,
      limit_amount_max: provider.limit_amount_max
    }
    tracker = SmartRouter::StateTracker.new
    tracker.start(provider, 50)
    tracker.finish(provider, 50, "approved")

    assert_equal frozen[:priority], provider.priority
    assert_equal frozen[:conversion_24h], provider.conversion_24h
    assert_equal frozen[:banks], provider.banks
    assert_equal frozen[:provider_margin_pct], provider.provider_margin_pct
    assert_equal frozen[:merchant_margin_pct], provider.merchant_margin_pct
    assert_equal frozen[:in_progress_count_limit], provider.in_progress_count_limit
    assert_equal frozen[:in_progress_amount_limit], provider.in_progress_amount_limit
    assert_equal frozen[:daily_amount_limit], provider.daily_amount_limit
    assert_equal frozen[:limit_amount_min], provider.limit_amount_min
    assert_equal frozen[:limit_amount_max], provider.limit_amount_max
  end

  def test_start_matrix_does_not_mutate_loaded_catalog_objects
    inputs = load_inputs
    before = inputs.providers.map { |provider| snapshot(provider) }
    working = inputs.providers.map(&:dup)
    tracker = SmartRouter::StateTracker.new

    tracker.start(working.first, 50)
    tracker.finish(working.first, 50, "approved")

    assert_equal before, inputs.providers.map { |provider| snapshot(provider) }
  end

  private

  def assert_release_restores_in_progress(result)
    provider = build_provider(
      in_progress_count: 4,
      in_progress_amount: 100,
      daily_approved_amount: 1000,
      available_requisites: 12
    )
    before = snapshot(provider)
    tracker = SmartRouter::StateTracker.new

    tracker.start(provider, 50)
    tracker.finish(provider, 50, result)

    assert_equal before, snapshot(provider)
  end

  def invalid_amounts
    [nil, "50", Float::NAN, Float::INFINITY, -Float::INFINITY]
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
