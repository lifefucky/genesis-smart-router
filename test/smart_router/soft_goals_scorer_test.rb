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
    vipay = build_neutral_soft_provider(payment_system: "vipay")
    payflow = build_neutral_soft_provider(payment_system: "payflow")

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
    vipay = build_neutral_soft_provider(payment_system: "vipay")

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
    assert_in_delta 0.5, parts["traffic_share"]
    assert_in_delta 0.5, parts["volume_share"]
    assert_in_delta 0.5, parts["financial_commitment"]
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

    state = {
      "traffic_shares" => { "vipay" => 0.20, "payflow" => 0.80 },
      "volume_shares" => { "vipay" => 0.20, "payflow" => 0.80 }
    }
    state_before = Marshal.load(Marshal.dump(state))

    scores = SmartRouter::SoftGoalsScorer.score(
      context.eligible_providers,
      operation: operation,
      state: state,
      policies_path: POLICIES_FIXTURE
    )

    refute_empty scores
    assert_equal attempts_before, context.attempts
    assert_equal eligible_before, context.eligible_providers
    assert_nil selected_before
    assert_nil context.selected_provider
    assert_equal vipay_traffic, vipay.traffic_percentage
    assert_equal payflow_traffic, payflow.traffic_percentage
    assert_equal state_before, state
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

  def test_default_policies_path_loads_shipped_config
    vipay = build_neutral_soft_provider(payment_system: "vipay")
    payflow = build_neutral_soft_provider(payment_system: "payflow")
    root = File.expand_path("../..", __dir__)

    scores = Dir.chdir(root) do
      SmartRouter::SoftGoalsScorer.score([vipay, payflow], operation: build_operation)
    end

    assert_equal 2, scores.length
    scores.each do |row|
      assert_in_delta 0.5, row.composite
      assert_equal(
        %w[traffic_share volume_share conversion_rate financial_commitment],
        row.parts.keys
      )
      assert_in_delta 0.5, row.parts["traffic_share"]
      assert_in_delta 0.5, row.parts["volume_share"]
      assert_in_delta 0.5, row.parts["conversion_rate"]
      assert_in_delta 0.5, row.parts["financial_commitment"]
    end
  end

  def test_shipped_policies_match_fixture
    root = File.expand_path("../..", __dir__)
    shipped = YAML.safe_load(
      File.read(File.join(root, SmartRouter::DEFAULT_ROUTING_POLICIES_PATH)),
      permitted_classes: [],
      aliases: false
    )
    fixture = YAML.safe_load(
      File.read(POLICIES_FIXTURE),
      permitted_classes: [],
      aliases: false
    )
    assert_equal shipped, fixture
  end

  def test_missing_strategy_implementation_raises_input_error
    vipay = build_provider(payment_system: "vipay")

    error = nil
    with_policies(
      "strategies" => {
        "traffic_share" => { "enabled" => true, "weight" => 1.0 }
      }
    ) do |path|
      error = assert_raises(SmartRouter::InputError) do
        score_pool(
          [vipay],
          policies_path: path,
          strategies: { "traffic_share" => nil }
        )
      end
      assert_equal path, error.path
      assert_includes error.message, path
      assert_includes error.message, "traffic_share"
    end
  end

  def test_traffic_deficit_boosts_and_surplus_penalizes
    vipay = build_provider(payment_system: "vipay", traffic_percentage: 40)
    payflow = build_provider(payment_system: "payflow", traffic_percentage: 35)
    state = {
      "traffic_shares" => { "vipay" => 0.20, "payflow" => 0.80 }
    }

    scores = score_pool([vipay, payflow], policies_path: POLICIES_FIXTURE, state: state)
    by_name = scores.to_h { |row| [row.provider.payment_system, row] }

    assert_operator by_name["vipay"].parts["traffic_share"], :>=, 0.7
    assert_operator by_name["payflow"].parts["traffic_share"], :<=, 0.3
    assert_in_delta 0.5, by_name["vipay"].parts["volume_share"]
    assert_in_delta 0.5, by_name["payflow"].parts["volume_share"]
    assert_operator by_name["vipay"].composite, :>, by_name["payflow"].composite
  end

  def test_volume_deficit_boosts_and_surplus_penalizes
    vipay = build_provider(
      payment_system: "vipay",
      traffic_percentage: 40,
      volume_share_pct: 40
    )
    payflow = build_provider(
      payment_system: "payflow",
      traffic_percentage: 35,
      volume_share_pct: 35
    )
    state = {
      "volume_shares" => { "vipay" => 0.10, "payflow" => 0.90 }
    }

    scores = score_pool([vipay, payflow], policies_path: POLICIES_FIXTURE, state: state)
    by_name = scores.to_h { |row| [row.provider.payment_system, row] }

    assert_operator by_name["vipay"].parts["volume_share"], :>, 0.5
    assert_operator by_name["payflow"].parts["volume_share"], :<, 0.5
    assert_in_delta 0.5, by_name["vipay"].parts["traffic_share"]
    assert_in_delta 0.5, by_name["payflow"].parts["traffic_share"]
    assert_operator by_name["vipay"].composite, :>, by_name["payflow"].composite
  end

  def test_near_target_stays_near_neutral
    vipay = build_provider(
      payment_system: "vipay",
      traffic_percentage: 40,
      volume_share_pct: 40
    )
    payflow = build_provider(
      payment_system: "payflow",
      traffic_percentage: 40,
      volume_share_pct: 40
    )
    state = {
      "traffic_shares" => { "vipay" => 0.38, "payflow" => 0.42 },
      "volume_shares" => { "vipay" => 0.42, "payflow" => 0.38 }
    }

    scores = score_pool([vipay, payflow], policies_path: POLICIES_FIXTURE, state: state)
    scores.each do |row|
      assert_in_delta 0.5, row.parts["traffic_share"], 0.05
      assert_in_delta 0.5, row.parts["volume_share"], 0.05
      assert_operator row.parts["traffic_share"], :>=, 0.45
      assert_operator row.parts["traffic_share"], :<=, 0.55
      assert_operator row.parts["volume_share"], :>=, 0.45
      assert_operator row.parts["volume_share"], :<=, 0.55
    end
  end

  def test_missing_or_zero_actual_shares_are_neutral
    vipay = build_neutral_soft_provider(
      payment_system: "vipay",
      traffic_percentage: 40,
      volume_share_pct: 40
    )
    payflow = build_neutral_soft_provider(
      payment_system: "payflow",
      traffic_percentage: 35,
      volume_share_pct: 35
    )

    [
      nil,
      {},
      { "traffic_shares" => {}, "volume_shares" => {} },
      { "traffic_shares" => { "vipay" => 0.0, "payflow" => 0.0 },
        "volume_shares" => { "vipay" => 0.0, "payflow" => 0.0 } }
    ].each do |state|
      scores = score_pool([vipay, payflow], policies_path: POLICIES_FIXTURE, state: state)
      scores.each do |row|
        assert_in_delta 0.5, row.parts["traffic_share"]
        assert_in_delta 0.5, row.parts["volume_share"]
        assert_in_delta 0.5, row.composite
      end
    end
  end

  def test_invalid_traffic_target_raises_input_error
    vipay = build_provider(payment_system: "vipay", traffic_percentage: 150)
    path = File.join(FIXTURES, "providers.json")
    state = {
      "traffic_shares" => { "vipay" => 0.20 },
      "path" => path
    }

    error = assert_raises(SmartRouter::InputError) do
      score_pool([vipay], policies_path: POLICIES_FIXTURE, state: state)
    end
    assert_equal path, error.path
    assert_includes error.message, path
    assert_includes error.message, "traffic_percentage"
  end

  def test_invalid_volume_target_raises_input_error
    vipay = build_provider(
      payment_system: "vipay",
      volume_share_pct: -5
    )
    path = File.join(FIXTURES, "providers.json")
    state = {
      "volume_shares" => { "vipay" => 0.20 },
      "path" => path
    }

    error = assert_raises(SmartRouter::InputError) do
      score_pool([vipay], policies_path: POLICIES_FIXTURE, state: state)
    end
    assert_equal path, error.path
    assert_includes error.message, path
    assert_includes error.message, "volume_share_pct"
  end

  def test_invalid_actual_share_raises_input_error_without_partial_result
    vipay = build_provider(payment_system: "vipay", traffic_percentage: 40)
    payflow = build_provider(payment_system: "payflow", traffic_percentage: 35)
    path = File.join(FIXTURES, "providers.json")
    state = {
      "traffic_shares" => { "vipay" => 0.20, "payflow" => 1.5 },
      "path" => path
    }

    error = assert_raises(SmartRouter::InputError) do
      score_pool([vipay, payflow], policies_path: POLICIES_FIXTURE, state: state)
    end
    assert_equal path, error.path
    assert_includes error.message, path
    assert_includes error.message, "traffic_shares"
  end

  def test_conversion_rate_boosts_higher_conversion_provider
    vipay = build_provider(payment_system: "vipay", conversion_24h: 0.70)
    payflow = build_provider(payment_system: "payflow", conversion_24h: 0.95)

    scores = with_policies(
      "strategies" => {
        "conversion_rate" => { "enabled" => true, "weight" => 1.0 }
      }
    ) do |path|
      score_pool([vipay, payflow], policies_path: path)
    end

    by_name = scores.to_h { |row| [row.provider.payment_system, row] }
    assert_operator by_name["payflow"].parts["conversion_rate"], :>, by_name["vipay"].parts["conversion_rate"]
    assert_in_delta by_name["payflow"].parts["conversion_rate"], 0.95
    assert_in_delta by_name["vipay"].parts["conversion_rate"], 0.70
    assert_operator by_name["payflow"].composite, :>, by_name["vipay"].composite
  end

  def test_conversion_rate_accepts_zero_and_one
    zero = build_provider(payment_system: "vipay", conversion_24h: 0.0)
    full = build_provider(payment_system: "payflow", conversion_24h: 1.0)

    scores = with_conversion_only do |policies_path|
      score_pool([zero, full], policies_path: policies_path)
    end

    by_name = scores.to_h { |row| [row.provider.payment_system, row] }
    assert_in_delta 0.0, by_name["vipay"].parts["conversion_rate"]
    assert_in_delta 1.0, by_name["payflow"].parts["conversion_rate"]
  end

  def test_nil_conversion_returns_neutral
    vipay = build_unchecked_provider(payment_system: "vipay", conversion_24h: nil)

    scores = with_conversion_only do |policies_path|
      score_pool([vipay], policies_path: policies_path, state: catalog_state)
    end

    assert_in_delta 0.5, scores.first.parts["conversion_rate"]
    assert_in_delta 0.5, scores.first.composite
  end

  def test_invalid_conversion_value_raises_input_error
    vipay = build_provider(payment_system: "vipay", conversion_24h: 1.5)
    path = File.join(FIXTURES, "providers.json")

    error = nil
    with_conversion_only do |policies_path|
      error = assert_raises(SmartRouter::InputError) do
        score_pool([vipay], policies_path: policies_path, state: catalog_state(path))
      end
      assert_equal path, error.path
      assert_includes error.message, path
      assert_includes error.message, "conversion_24h"
    end
    refute_nil error
  end

  def test_non_finite_or_negative_conversion_raises_without_partial_result
    valid = build_provider(payment_system: "vipay", conversion_24h: 0.90)
    path = File.join(FIXTURES, "providers.json")

    [Float::NAN, Float::INFINITY, -Float::INFINITY, -0.1].each do |invalid|
      broken = build_unchecked_provider(payment_system: "payflow", conversion_24h: invalid)
      error = nil
      with_conversion_only do |policies_path|
        error = assert_raises(SmartRouter::InputError) do
          score_pool(
            [valid, broken],
            policies_path: policies_path,
            state: catalog_state(path)
          )
        end
      end
      assert_equal path, error.path
      assert_includes error.message, path
      assert_includes error.message, "conversion_24h"
    end
  end

  def test_amount_band_prefers_center_of_range
    vipay = build_provider(
      payment_system: "vipay",
      limit_amount_min: 1_000,
      limit_amount_max: 100_000,
      daily_amount_limit: 5_000_000,
      daily_approved_amount: 1_000_000
    )
    payflow = build_provider(
      payment_system: "payflow",
      limit_amount_min: 500,
      limit_amount_max: 50_000,
      daily_amount_limit: 5_000_000,
      daily_approved_amount: 1_000_000
    )
    operation = build_operation(amount: 90_000)

    scores = with_policies(
      "strategies" => {
        "financial_commitment" => { "enabled" => true, "weight" => 1.0 }
      }
    ) do |path|
      SmartRouter::SoftGoalsScorer.score(
        [vipay, payflow],
        operation: operation,
        policies_path: path
      )
    end

    by_name = scores.to_h { |row| [row.provider.payment_system, row] }
    assert_operator by_name["vipay"].parts["financial_commitment"], :>, 0.5
    assert_in_delta 0.5, by_name["payflow"].parts["financial_commitment"]
    assert_operator by_name["vipay"].composite, :>, by_name["payflow"].composite
  end

  def test_overlapping_bands_stay_at_least_neutral
    vipay = build_provider(
      payment_system: "vipay",
      limit_amount_min: 1_000,
      limit_amount_max: 100_000,
      daily_amount_limit: 5_000_000,
      daily_approved_amount: 0
    )
    payflow = build_provider(
      payment_system: "payflow",
      limit_amount_min: 1_000,
      limit_amount_max: 200_000,
      daily_amount_limit: 5_000_000,
      daily_approved_amount: 0
    )
    operation = build_operation(amount: 50_000)

    scores = with_financial_only do |path|
      SmartRouter::SoftGoalsScorer.score(
        [vipay, payflow],
        operation: operation,
        policies_path: path
      )
    end

    by_name = scores.to_h { |row| [row.provider.payment_system, row] }
    assert_operator by_name["vipay"].parts["financial_commitment"], :>, 0.5
    assert_operator by_name["payflow"].parts["financial_commitment"], :>, 0.5
    assert_operator(
      by_name["vipay"].parts["financial_commitment"],
      :>,
      by_name["payflow"].parts["financial_commitment"]
    )
  end

  def test_more_daily_headroom_raises_financial_commitment
    closer = build_provider(
      payment_system: "vipay",
      limit_amount_min: 1_000,
      limit_amount_max: 100_000,
      daily_amount_limit: 1_000_000,
      daily_approved_amount: 100_000
    )
    tighter = build_provider(
      payment_system: "payflow",
      limit_amount_min: 1_000,
      limit_amount_max: 100_000,
      daily_amount_limit: 1_000_000,
      daily_approved_amount: 900_000
    )
    operation = build_operation(amount: 50_500)

    scores = with_financial_only do |path|
      SmartRouter::SoftGoalsScorer.score(
        [closer, tighter],
        operation: operation,
        policies_path: path
      )
    end

    by_name = scores.to_h { |row| [row.provider.payment_system, row] }
    assert_operator(
      by_name["vipay"].parts["financial_commitment"],
      :>,
      by_name["payflow"].parts["financial_commitment"]
    )
  end

  def test_spacepayments_financial_commitment_is_exactly_neutral
    space = build_provider(
      payment_system: "spacepayments",
      limit_amount_min: 1_000,
      limit_amount_max: 100_000,
      daily_amount_limit: 5_000_000,
      daily_approved_amount: 0
    )
    operation = build_operation(amount: 50_500)

    scores = with_financial_only do |path|
      SmartRouter::SoftGoalsScorer.score(
        [space],
        operation: operation,
        policies_path: path
      )
    end

    assert_in_delta 0.5, scores.first.parts["financial_commitment"]
  end

  def test_missing_amount_band_signal_is_neutral
    vipay = build_provider(
      payment_system: "vipay",
      limit_amount_min: nil,
      limit_amount_max: nil,
      daily_amount_limit: 5_000_000,
      daily_approved_amount: 0
    )

    scores = with_financial_only do |path|
      score_pool([vipay], policies_path: path)
    end

    assert_in_delta 0.5, scores.first.parts["financial_commitment"]
  end

  def test_zero_min_bound_is_kept_and_zero_daily_limit_has_no_headroom
    with_zero_min = build_provider(
      payment_system: "vipay",
      limit_amount_min: 0,
      limit_amount_max: 100_000,
      daily_amount_limit: 1_000_000,
      daily_approved_amount: 0
    )
    zero_daily = build_provider(
      payment_system: "payflow",
      limit_amount_min: 1_000,
      limit_amount_max: 100_000,
      daily_amount_limit: 0,
      daily_approved_amount: 0
    )
    operation = build_operation(amount: 50_000)

    scores = with_financial_only do |path|
      SmartRouter::SoftGoalsScorer.score(
        [with_zero_min, zero_daily],
        operation: operation,
        policies_path: path
      )
    end

    by_name = scores.to_h { |row| [row.provider.payment_system, row] }
    assert_operator by_name["vipay"].parts["financial_commitment"], :>, 0.5
    assert_in_delta 0.5, by_name["payflow"].parts["financial_commitment"]
  end

  def test_daily_limit_nil_does_not_force_neutral_when_band_exists
    vipay = build_provider(
      payment_system: "vipay",
      limit_amount_min: 1_000,
      limit_amount_max: 100_000,
      daily_amount_limit: nil,
      daily_approved_amount: 0
    )
    operation = build_operation(amount: 50_500)

    scores = with_financial_only do |path|
      SmartRouter::SoftGoalsScorer.score(
        [vipay],
        operation: operation,
        policies_path: path
      )
    end

    assert_operator scores.first.parts["financial_commitment"], :>, 0.5
  end

  def test_amount_on_band_boundary_and_outside_sweet_zone_is_neutral
    vipay = build_provider(
      payment_system: "vipay",
      limit_amount_min: 1_000,
      limit_amount_max: 100_000,
      daily_amount_limit: 5_000_000,
      daily_approved_amount: 0
    )

    [1_000, 100_000, 500, 150_000].each do |amount|
      scores = with_financial_only do |path|
        SmartRouter::SoftGoalsScorer.score(
          [vipay],
          operation: build_operation(amount: amount),
          policies_path: path
        )
      end
      assert_in_delta 0.5, scores.first.parts["financial_commitment"],
                      0.0, "amount=#{amount} should stay neutral"
    end
  end

  def test_invalid_limit_params_raise_input_error_with_catalog_path
    path = File.join(FIXTURES, "providers.json")
    cases = [
      [
        { limit_amount_min: Float::NAN, limit_amount_max: 100_000 },
        "limit_amount_min"
      ],
      [
        { limit_amount_min: 1_000, limit_amount_max: Float::INFINITY },
        "limit_amount_max"
      ],
      [
        { daily_amount_limit: -1 },
        "daily_amount_limit"
      ],
      [
        { limit_amount_min: 100_000, limit_amount_max: 1_000 },
        "limit_amount_min"
      ],
      [
        {
          payment_system: "spacepayments",
          limit_amount_min: Float::NAN,
          limit_amount_max: 100_000
        },
        "limit_amount_min"
      ]
    ]

    cases.each do |overrides, expected_field|
      broken = build_unchecked_provider(
        { payment_system: "vipay" }.merge(overrides)
      )
      error = nil
      with_financial_only do |policies_path|
        error = assert_raises(SmartRouter::InputError) do
          score_pool(
            [broken],
            policies_path: policies_path,
            state: catalog_state(path)
          )
        end
      end
      assert_equal path, error.path
      assert_includes error.message, path
      assert_includes error.message, expected_field
    end
  end

  def test_false_share_map_raises_input_error
    vipay = build_provider(payment_system: "vipay", traffic_percentage: 40)
    path = File.join(FIXTURES, "providers.json")
    state = { "traffic_shares" => false, "path" => path }

    error = assert_raises(SmartRouter::InputError) do
      score_pool([vipay], policies_path: POLICIES_FIXTURE, state: state)
    end
    assert_equal path, error.path
    assert_includes error.message, "traffic_shares"
  end

  def test_blank_share_key_raises_input_error
    vipay = build_provider(payment_system: "vipay", traffic_percentage: 40)
    path = File.join(FIXTURES, "providers.json")
    state = { "traffic_shares" => { "" => 1.0 }, "path" => path }

    error = assert_raises(SmartRouter::InputError) do
      score_pool([vipay], policies_path: POLICIES_FIXTURE, state: state)
    end
    assert_equal path, error.path
    assert_includes error.message, "payment_system"
  end

  def test_duplicate_share_keys_raise_input_error
    vipay = build_provider(payment_system: "vipay", traffic_percentage: 40)
    path = File.join(FIXTURES, "providers.json")
    state = {
      "traffic_shares" => { "vipay" => 0.2, :vipay => 0.8 },
      "path" => path
    }

    error = assert_raises(SmartRouter::InputError) do
      score_pool([vipay], policies_path: POLICIES_FIXTURE, state: state)
    end
    assert_equal path, error.path
    assert_includes error.message, "duplicate"
  end

  def test_non_finite_actual_share_raises_input_error
    vipay = build_provider(payment_system: "vipay", traffic_percentage: 40)
    path = File.join(FIXTURES, "providers.json")

    [Float::NAN, Float::INFINITY, -Float::INFINITY].each do |invalid|
      state = {
        "volume_shares" => { "vipay" => invalid },
        "path" => path
      }
      error = assert_raises(SmartRouter::InputError) do
        score_pool([vipay], policies_path: POLICIES_FIXTURE, state: state)
      end
      assert_equal path, error.path
      assert_includes error.message, path
    end
  end

  def test_invalid_volume_share_pct_type_raises_on_load
    error = assert_raises(SmartRouter::InputError) do
      build_provider(volume_share_pct: "forty")
    end
    assert_equal "test", error.path
    assert_includes error.message, "volume_share_pct"
  end

  def test_missing_volume_share_pct_is_optional_and_neutral
    vipay = build_provider(payment_system: "vipay", traffic_percentage: 40)
    assert_nil vipay.volume_share_pct

    score = SmartRouter::Strategies::VolumeShare.new.score(
      vipay,
      build_operation,
      { "volume_shares" => { "vipay" => 0.10 } }
    )
    assert_in_delta 0.5, score
  end

  def test_spacepayments_without_volume_goal_stays_neutral
    space = build_provider(payment_system: "spacepayments", traffic_percentage: 0)
    vipay = build_provider(payment_system: "vipay", traffic_percentage: 40)
    assert_nil space.volume_share_pct

    scores = score_pool(
      [vipay, space],
      policies_path: POLICIES_FIXTURE,
      state: {
        "traffic_shares" => { "vipay" => 0.20, "spacepayments" => 0.80 }
      }
    )
    by_name = scores.to_h { |row| [row.provider.payment_system, row] }

    assert_in_delta 0.5, by_name["spacepayments"].parts["traffic_share"]
    assert_in_delta 0.5, by_name["spacepayments"].parts["volume_share"]
    assert_operator by_name["vipay"].parts["traffic_share"], :>, 0.5
  end

  def test_fixture_providers_expose_volume_share_pct
    catalog = SmartRouter::RoutingConfig.load(File.join(FIXTURES, "providers.json"))
    by_name = catalog.to_h { |provider| [provider.payment_system, provider] }

    assert_equal 40, by_name["vipay"].volume_share_pct
    assert_equal 35, by_name["payflow"].volume_share_pct
    assert_equal 25, by_name["quickpay"].volume_share_pct
    assert_nil by_name["spacepayments"].volume_share_pct
  end

  def test_share_scores_are_deterministic_and_clipped
    vipay = build_provider(
      payment_system: "vipay",
      traffic_percentage: 90,
      volume_share_pct: 10
    )
    state = {
      "traffic_shares" => { "vipay" => 0.0, "payflow" => 1.0 },
      "volume_shares" => { "vipay" => 1.0 }
    }

    first = score_pool([vipay], policies_path: POLICIES_FIXTURE, state: state).first
    second = score_pool([vipay], policies_path: POLICIES_FIXTURE, state: state).first

    assert_in_delta first.parts["traffic_share"], second.parts["traffic_share"]
    assert_in_delta first.parts["volume_share"], second.parts["volume_share"]
    assert_in_delta 1.0, first.parts["traffic_share"]
    assert_in_delta 0.0, first.parts["volume_share"]
  end

  private

  def score_pool(eligible, policies_path:, strategies: {}, state: nil)
    SmartRouter::SoftGoalsScorer.score(
      eligible,
      operation: build_operation,
      policies_path: policies_path,
      strategies: strategies,
      state: state
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

  def catalog_state(path = File.join(FIXTURES, "providers.json"))
    { "path" => path }
  end

  def with_conversion_only(&block)
    with_policies(
      "strategies" => {
        "conversion_rate" => { "enabled" => true, "weight" => 1.0 }
      },
      &block
    )
  end

  def with_financial_only(&block)
    with_policies(
      "strategies" => {
        "financial_commitment" => { "enabled" => true, "weight" => 1.0 }
      },
      &block
    )
  end

  def provider_attrs(overrides = {})
    {
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
  end

  def build_provider(overrides = {})
    SmartRouter::Provider.from_hash(provider_attrs(overrides), path: "test")
  end

  def build_unchecked_provider(overrides = {})
    SmartRouter::Provider.new(provider_attrs(overrides))
  end

  def build_neutral_soft_provider(overrides = {})
    build_provider(
      {
        conversion_24h: 0.5,
        limit_amount_min: nil,
        limit_amount_max: nil
      }.merge(overrides)
    )
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

  public

  def test_versioned_policy_registry_loading
    Dir.mktmpdir do |dir|
      yaml_path = File.join(dir, "versioned_policies.yml")
      yaml_content = <<~YAML
        current_version: pack_b
        versions:
          pack_a:
            strategies:
              traffic_share: { enabled: true, weight: 0.1 }
              volume_share: { enabled: false, weight: 0.0 }
          pack_b:
            strategies:
              traffic_share: { enabled: true, weight: 0.5 }
              volume_share: { enabled: true, weight: 0.5 }
      YAML
      File.write(yaml_path, yaml_content)

      # 1. By default, loads current_version (pack_b)
      registry = SmartRouter::PolicyRegistry.load(yaml_path)
      assert_equal "pack_b", registry.active_version
      assert_equal "pack_b", registry.current_version
      assert registry.policies["traffic_share"].enabled
      assert_in_delta 0.5, registry.policies["traffic_share"].weight
      assert registry.policies["volume_share"].enabled

      # 2. Explicit pack loading override (pack_a)
      registry_a = SmartRouter::PolicyRegistry.load(yaml_path, policy_pack: :pack_a)
      assert_equal "pack_a", registry_a.active_version
      assert registry_a.policies["traffic_share"].enabled
      assert_in_delta 0.1, registry_a.policies["traffic_share"].weight
      refute registry_a.policies["volume_share"].enabled

      # 3. Missing pack name raises InputError
      assert_raises(SmartRouter::InputError) do
        SmartRouter::PolicyRegistry.load(yaml_path, policy_pack: "non_existent")
      end
    end
  end

  def test_versioned_policy_registry_invalid_structures
    Dir.mktmpdir do |dir|
      yaml_path = File.join(dir, "invalid_versions.yml")
      
      # versions is not a mapping
      File.write(yaml_path, "current_version: v1\nversions: 123")
      assert_raises(SmartRouter::InputError) do
        SmartRouter::PolicyRegistry.load(yaml_path)
      end

      # pack data is not a mapping
      File.write(yaml_path, "current_version: v1\nversions:\n  v1: 456")
      assert_raises(SmartRouter::InputError) do
        SmartRouter::PolicyRegistry.load(yaml_path)
      end
    end
  end
end
