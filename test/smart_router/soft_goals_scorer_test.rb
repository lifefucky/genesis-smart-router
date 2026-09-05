# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
require "tmpdir"
require "smart_router"

class SoftGoalsScorerTest < Minitest::Test
  FIXTURES = File.expand_path("../fixtures/inputs", __dir__)
  POLICIES_FIXTURE = File.join(FIXTURES, "routing_policies.yml")

  STRATEGY_CLASSES = [
    SmartRouter::Strategies::TrafficShare,
    SmartRouter::Strategies::VolumeShare,
    SmartRouter::Strategies::ConversionRate,
    SmartRouter::Strategies::FinancialCommitment
  ].freeze

  def test_four_strategies_share_score_interface
    provider = build_provider(payment_system: "vipay")
    operation = build_operation

    STRATEGY_CLASSES.each do |klass|
      score = klass.new.score(provider, operation, nil)
      assert_kind_of Float, score
      assert score.finite?, "#{klass} score must be finite"
      assert_operator score, :>=, 0.0
      assert_operator score, :<=, 1.0
    end
  end

  def test_equal_weights_composite_is_half_and_parts_has_four_keys
    vipay = build_provider(payment_system: "vipay")
    payflow = build_provider(payment_system: "payflow")

    scores = score_pool([vipay, payflow], policies_path: POLICIES_FIXTURE)

    assert_equal 2, scores.length
    scores.each do |row|
      assert_kind_of SmartRouter::ProviderScore, row
      assert_in_delta 0.5, row.composite
      assert_equal(
        %w[traffic_share volume_share conversion_rate financial_commitment],
        row.parts.keys
      )
      row.parts.each_value { |value| assert_in_delta 0.5, value }
    end
  end

  def test_single_active_strategy_uses_injected_scores
    vipay = build_provider(payment_system: "vipay")
    payflow = build_provider(payment_system: "payflow")
    stub = per_provider_strategy("vipay" => 1.0, "payflow" => 0.0)

    scores = with_policies(
      "strategies" => {
        "traffic_share" => { "enabled" => true, "weight" => 1.0 }
      }
    ) do |path|
      score_pool(
        [vipay, payflow],
        policies_path: path,
        strategies: { "traffic_share" => stub }
      )
    end

    by_name = scores.to_h { |row| [row.provider.payment_system, row] }
    assert_in_delta 1.0, by_name["vipay"].composite
    assert_in_delta 0.0, by_name["payflow"].composite
    assert_equal ["traffic_share"], by_name["vipay"].parts.keys
    assert_equal ["traffic_share"], by_name["payflow"].parts.keys
    assert_in_delta 1.0, by_name["vipay"].parts["traffic_share"]
    assert_in_delta 0.0, by_name["payflow"].parts["traffic_share"]
  end

  def test_disabled_strategy_omitted_from_parts_and_composite
    vipay = build_provider(payment_system: "vipay")

    scores = with_policies(
      "strategies" => {
        "traffic_share" => { "enabled" => true, "weight" => 0.25 },
        "volume_share" => { "enabled" => true, "weight" => 0.25 },
        "conversion_rate" => { "enabled" => false, "weight" => 0.25 },
        "financial_commitment" => { "enabled" => true, "weight" => 0.25 }
      }
    ) do |path|
      score_pool([vipay], policies_path: path)
    end

    parts = scores.first.parts
    refute parts.key?("conversion_rate")
    assert_equal %w[traffic_share volume_share financial_commitment], parts.keys
    assert_in_delta 0.375, scores.first.composite
  end

  def test_all_strategies_disabled_yields_zero_composite
    vipay = build_provider(payment_system: "vipay")
    payflow = build_provider(payment_system: "payflow")

    scores = with_policies(
      "strategies" => {
        "traffic_share" => { "enabled" => false, "weight" => 0.25 },
        "volume_share" => { "enabled" => false, "weight" => 0.25 },
        "conversion_rate" => { "enabled" => false, "weight" => 0.25 },
        "financial_commitment" => { "enabled" => false, "weight" => 0.25 }
      }
    ) do |path|
      score_pool([vipay, payflow], policies_path: path)
    end

    scores.each do |row|
      assert_in_delta 0.0, row.composite
      assert_empty row.parts
    end
  end

  def test_all_zero_weights_yields_zero_composite
    vipay = build_provider(payment_system: "vipay")

    scores = with_policies(
      "strategies" => {
        "traffic_share" => { "enabled" => true, "weight" => 0.0 },
        "volume_share" => { "enabled" => true, "weight" => 0.0 },
        "conversion_rate" => { "enabled" => true, "weight" => 0.0 },
        "financial_commitment" => { "enabled" => true, "weight" => 0.0 }
      }
    ) do |path|
      score_pool([vipay], policies_path: path)
    end

    assert_in_delta 0.0, scores.first.composite
    assert_empty scores.first.parts
  end

  def test_empty_strategies_block_yields_zero_composite
    vipay = build_provider(payment_system: "vipay")
    payflow = build_provider(payment_system: "payflow")

    scores = with_policies("strategies" => {}) do |path|
      score_pool([vipay, payflow], policies_path: path)
    end

    scores.each do |row|
      assert_in_delta 0.0, row.composite
      assert_empty row.parts
    end
  end

  def test_score_above_one_raises_input_error
    assert_invalid_score_raises(1.5)
  end

  def test_score_below_zero_raises_input_error
    assert_invalid_score_raises(-0.1)
  end

  def test_nan_score_raises_input_error
    assert_invalid_score_raises(Float::NAN)
  end

  def test_infinite_score_raises_input_error
    assert_invalid_score_raises(Float::INFINITY)
  end

  def test_missing_policies_file_raises_input_error
    Dir.mktmpdir do |dir|
      path = File.join(dir, "missing_routing_policies.yml")
      error = assert_raises(SmartRouter::InputError) do
        score_pool([build_provider], policies_path: path)
      end
      assert_equal path, error.path
      assert_includes error.message, path
    end
  end

  def test_non_hash_policies_yaml_raises_input_error
    Dir.mktmpdir do |dir|
      path = File.join(dir, "routing_policies.yml")
      File.write(path, "- not a mapping\n")
      error = assert_raises(SmartRouter::InputError) do
        score_pool([build_provider], policies_path: path)
      end
      assert_equal path, error.path
      assert_includes error.message, path
    end
  end

  def test_negative_weight_raises_input_error
    error = nil
    with_policies(
      "strategies" => {
        "traffic_share" => { "enabled" => true, "weight" => -0.1 }
      }
    ) do |path|
      error = assert_raises(SmartRouter::InputError) do
        score_pool([build_provider], policies_path: path)
      end
      assert_equal path, error.path
      assert_includes error.message, path
    end
  end

  def test_broken_yaml_raises_input_error
    Dir.mktmpdir do |dir|
      path = File.join(dir, "routing_policies.yml")
      File.write(path, "strategies: [\n")
      error = assert_raises(SmartRouter::InputError) do
        score_pool([build_provider], policies_path: path)
      end
      assert_equal path, error.path
      assert_includes error.message, path
    end
  end

  def test_alias_yaml_raises_input_error
    Dir.mktmpdir do |dir|
      path = File.join(dir, "routing_policies.yml")
      File.write(
        path,
        <<~YAML
          strategies:
            traffic_share: &share
              enabled: true
              weight: 0.25
            volume_share: *share
        YAML
      )
      error = assert_raises(SmartRouter::InputError) do
        score_pool([build_provider], policies_path: path)
      end
      assert_equal path, error.path
      assert_includes error.message, path
    end
  end

  def test_empty_eligible_returns_empty_array
    scores = score_pool([], policies_path: POLICIES_FIXTURE)
    assert_equal [], scores
  end

  def test_does_not_mutate_context_or_providers
    vipay = build_provider(payment_system: "vipay", traffic_percentage: 40)
    payflow = build_provider(payment_system: "payflow", traffic_percentage: 30)
    operation = build_operation
    context = SmartRouter::PipelineContext.for(operation, providers: [vipay, payflow])
    context.eligible_providers = context.providers.dup
    context.add_attempt(vipay, "skipped", "amount_below_minimum")
    attempts_before = context.attempts.map(&:dup)
    eligible_before = context.eligible_providers.dup
    selected_before = context.selected_provider
    vipay_traffic = vipay.traffic_percentage
    payflow_traffic = payflow.traffic_percentage

    scores = SmartRouter::SoftGoalsScorer.score(
      context.eligible_providers,
      operation: operation,
      policies_path: POLICIES_FIXTURE
    )

    refute_empty scores
    assert_equal attempts_before, context.attempts
    assert_equal eligible_before, context.eligible_providers
    assert_nil selected_before
    assert_nil context.selected_provider
    assert_equal vipay_traffic, vipay.traffic_percentage
    assert_equal payflow_traffic, payflow.traffic_percentage
    refute_respond_to vipay, :composite=
  end

  def test_unknown_strategy_keys_are_ignored
    vipay = build_provider(payment_system: "vipay")

    scores = with_policies(
      "strategies" => {
        "traffic_share" => { "enabled" => true, "weight" => 1.0 },
        "mystery_goal" => { "enabled" => true, "weight" => 9.0 }
      }
    ) do |path|
      score_pool([vipay], policies_path: path)
    end

    assert_equal ["traffic_share"], scores.first.parts.keys
    refute scores.first.parts.key?("mystery_goal")
    assert_in_delta 0.5, scores.first.composite
  end

  def test_composite_does_not_renormalize_weights
    vipay = build_provider(payment_system: "vipay")

    scores = with_policies(
      "strategies" => {
        "traffic_share" => { "enabled" => true, "weight" => 1.0 },
        "volume_share" => { "enabled" => true, "weight" => 1.0 }
      }
    ) do |path|
      score_pool([vipay], policies_path: path)
    end

    assert_in_delta 1.0, scores.first.composite
  end

  private

  def score_pool(eligible, policies_path:, strategies: {})
    SmartRouter::SoftGoalsScorer.score(
      eligible,
      operation: build_operation,
      policies_path: policies_path,
      strategies: strategies
    )
  end

  def assert_invalid_score_raises(raw_score)
    stub = constant_strategy(raw_score)
    with_policies(
      "strategies" => {
        "traffic_share" => { "enabled" => true, "weight" => 1.0 }
      }
    ) do |path|
      error = assert_raises(SmartRouter::InputError) do
        score_pool(
          [build_provider],
          policies_path: path,
          strategies: { "traffic_share" => stub }
        )
      end
      assert_equal path, error.path
      assert_includes error.message, path
    end
  end

  def with_policies(hash)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "routing_policies.yml")
      File.write(path, YAML.dump(hash))
      yield path
    end
  end

  def constant_strategy(value)
    strategy = Object.new
    strategy.define_singleton_method(:score) { |_provider, _operation, _state| value }
    strategy
  end

  def per_provider_strategy(scores)
    strategy = Object.new
    strategy.define_singleton_method(:score) do |provider, _operation, _state|
      scores.fetch(provider.payment_system, 0.0)
    end
    strategy
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
end
