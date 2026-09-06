# frozen_string_literal: true

require "minitest/autorun"
require "smart_router"

class ReportBuilderTest < Minitest::Test
  PERIOD = "2026-07-30"

  def build_provider(overrides = {})
    hash = {
      "payment_system" => "quickpay",
      "status" => "active",
      "priority" => 3,
      "traffic_percentage" => 25,
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

  def catalog
    [
      build_provider("payment_system" => "vipay", "traffic_percentage" => 40, "priority" => 1),
      build_provider("payment_system" => "payflow", "traffic_percentage" => 35, "priority" => 2),
      build_provider("payment_system" => "quickpay", "traffic_percentage" => 25, "priority" => 3)
    ]
  end

  def decision(operation_id, selected_provider, attempts: nil)
    {
      "operation_id" => operation_id,
      "selected_provider" => selected_provider,
      "attempts" => attempts || [
        {
          "provider" => selected_provider,
          "decision" => "selected",
          "reason" => "only_eligible_provider"
        }
      ],
      "simulated_result" => "approved",
      "latency_sec" => 1
    }
  end

  def report_for(records, providers = catalog, period: PERIOD)
    SmartRouter::ReportBuilder.build(records, providers, period: period)
  end

  def assert_distribution_row(row, count:, share_pct:, target_pct:)
    assert_equal count, row["count"]
    assert_in_delta share_pct, row["share_pct"]
    assert_in_delta target_pct, row["target_pct"]
    signed = share_pct - target_pct
    assert_in_delta signed, row["signed_deviation"]
    assert_in_delta signed.abs, row["absolute_deviation"]
  end

  def test_basic_distribution_without_skips
    records = [
      decision("op_1", "vipay"),
      decision("op_2", "vipay"),
      decision("op_3", "payflow"),
      decision("op_4", "payflow"),
      decision("op_5", "quickpay"),
      decision("op_6", "quickpay"),
      decision("op_7", "quickpay"),
      decision("op_8", "quickpay"),
      decision("op_9", "quickpay"),
      decision("op_10", "quickpay")
    ]

    report = report_for(records)

    assert_equal PERIOD, report["period"]
    assert_equal 10, report["total_operations"]
    assert_equal %w[vipay payflow quickpay], report["distribution"].keys
    assert_distribution_row(report["distribution"]["vipay"], count: 2, share_pct: 20.0, target_pct: 40.0)
    assert_distribution_row(report["distribution"]["payflow"], count: 2, share_pct: 20.0, target_pct: 35.0)
    assert_distribution_row(report["distribution"]["quickpay"], count: 6, share_pct: 60.0, target_pct: 25.0)
    assert_equal({}, report["skip_reasons"])
  end

  def test_aggregates_hard_and_execution_skip_reasons
    records = [
      decision(
        "op_1",
        "quickpay",
        attempts: [
          { "provider" => "vipay", "decision" => "skipped", "reason" => "amount_exceeds_limit" },
          { "provider" => "payflow", "decision" => "skipped", "reason" => "bank_not_in_list" },
          { "provider" => "quickpay", "decision" => "selected", "reason" => "first_eligible" }
        ]
      ),
      decision(
        "op_2",
        "vipay",
        attempts: [
          { "provider" => "payflow", "decision" => "skipped", "reason" => "provider_rejected" },
          { "provider" => "quickpay", "decision" => "skipped", "reason" => "provider_expired" },
          { "provider" => "vipay", "decision" => "selected", "reason" => "fallback" }
        ]
      ),
      decision(
        "op_3",
        "payflow",
        attempts: [
          { "provider" => "vipay", "decision" => "skipped", "reason" => "amount_exceeds_limit" },
          { "provider" => "payflow", "decision" => "selected", "reason" => "first_eligible" }
        ]
      )
    ]

    report = report_for(records)

    assert_equal 3, report["total_operations"]
    assert_distribution_row(report["distribution"]["vipay"], count: 1, share_pct: (100.0 / 3), target_pct: 40.0)
    assert_distribution_row(report["distribution"]["payflow"], count: 1, share_pct: (100.0 / 3), target_pct: 35.0)
    assert_distribution_row(report["distribution"]["quickpay"], count: 1, share_pct: (100.0 / 3), target_pct: 25.0)
    assert_equal(
      {
        "amount_exceeds_limit" => 2,
        "bank_not_in_list" => 1,
        "provider_expired" => 1,
        "provider_rejected" => 1
      },
      report["skip_reasons"]
    )
  end

  def test_unused_configured_provider_has_zero_count_and_share
    records = [
      decision("op_1", "vipay"),
      decision("op_2", "vipay"),
      decision("op_3", "payflow")
    ]

    report = report_for(records)

    assert_equal 3, report["total_operations"]
    assert_equal %w[vipay payflow quickpay], report["distribution"].keys
    assert_distribution_row(report["distribution"]["vipay"], count: 2, share_pct: (200.0 / 3), target_pct: 40.0)
    assert_distribution_row(report["distribution"]["payflow"], count: 1, share_pct: (100.0 / 3), target_pct: 35.0)
    assert_distribution_row(report["distribution"]["quickpay"], count: 0, share_pct: 0.0, target_pct: 25.0)
    assert_equal({}, report["skip_reasons"])
  end

  def test_empty_batch_is_deterministic_and_avoids_division_by_zero
    report = report_for([])

    assert_equal PERIOD, report["period"]
    assert_equal 0, report["total_operations"]
    assert_equal({}, report["distribution"])
    assert_equal({}, report["skip_reasons"])

    # Пустой batch не должен приводить к делению на ноль,
    # а результат должен быть детерминированным при повторном запуске.
    again = report_for([])
    assert_equal report, again
  end

  def test_does_not_copy_soft_goal_variances_into_skip_reasons
    records = [
      decision("op_1", "quickpay").merge(
        "soft_goal_variances" => [
          {
            "goal" => "traffic_share",
            "target_provider" => "vipay",
            "cause" => "target_provider_ineligible"
          }
        ]
      )
    ]

    report = report_for(records)

    assert_equal({}, report["skip_reasons"])
    refute_includes report["skip_reasons"].keys, "target_provider_ineligible"
  end

  def test_does_not_mutate_input_records
    records = [
      decision(
        "op_1",
        "vipay",
        attempts: [
          { "provider" => "payflow", "decision" => "skipped", "reason" => "bank_not_in_list" },
          { "provider" => "vipay", "decision" => "selected", "reason" => "fallback" }
        ]
      )
    ]
    snapshot = Marshal.load(Marshal.dump(records))

    report_for(records)

    assert_equal snapshot, records
  end

  def test_same_inputs_yield_identical_reports
    records = [
      decision(
        "op_1",
        "payflow",
        attempts: [
          { "provider" => "vipay", "decision" => "skipped", "reason" => "daily_limit_exceeded" },
          { "provider" => "quickpay", "decision" => "skipped", "reason" => "amount_exceeds_limit" },
          { "provider" => "payflow", "decision" => "selected", "reason" => "fallback" }
        ]
      ),
      decision("op_2", "vipay")
    ]

    first = report_for(records)
    second = report_for(records)

    assert_equal first, second
    assert_equal %w[amount_exceeds_limit daily_limit_exceeded], first["skip_reasons"].keys
  end
end
