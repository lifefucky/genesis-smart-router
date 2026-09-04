# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "smart_router"

class IntegrationDecisionRecordTest < Minitest::Test
  FIXTURES = File.expand_path("../fixtures/inputs", __dir__)
  PROJECT_ROOT = File.expand_path("../..", __dir__)

  def test_op_101_multi_eligible_emits_complete_decision_record
    inputs = load_fixture_inputs
    operation = inputs.operations.find { |row| row.operation_id == "op_101" }
    context = SmartRouter::PipelineContext.for(operation, providers: inputs.providers)
    SmartRouter::HardConstraintsFilter.filter(context)
    SmartRouter::BaselineSelector.select(context)

    record = SmartRouter::DecisionRecordBuilder.build(context)

    assert_equal "op_101", record["operation_id"]
    assert_equal "vipay", record["selected_provider"]
    assert_equal "first_eligible", context.selection_reason
    selected = record["attempts"].select { |attempt| attempt["decision"] == "selected" }
    assert_equal 1, selected.length
    assert_equal "vipay", selected.first["provider"]
    assert_includes %w[approved rejected expired], record["simulated_result"]
    assert_equal [context.selected_provider.avg_latency_sec.to_i, 1].max, record["latency_sec"]

    Dir.mktmpdir do |dir|
      path = File.join(dir, "tmp", "routing_decisions.json")
      SmartRouter::RoutingDecisionsWriter.write([record], path: path)
      parsed = JSON.parse(File.read(path))
      assert_equal [record], parsed
    end
  end

  def test_op_103_only_eligible_preserves_hard_skip_attempts
    inputs = load_project_inputs
    providers = inputs.providers.reject { |provider| provider.payment_system == "spacepayments" }
    operation = inputs.operations.find { |row| row.operation_id == "op_103" }
    context = SmartRouter::PipelineContext.for(operation, providers: providers)
    SmartRouter::HardConstraintsFilter.filter(context)
    SmartRouter::BaselineSelector.select(context)

    record = SmartRouter::DecisionRecordBuilder.build(context)

    assert_equal "op_103", record["operation_id"]
    assert_equal "quickpay", record["selected_provider"]
    assert_equal "only_eligible_provider", context.selection_reason
    assert_equal(
      [
        { "provider" => "vipay", "decision" => "skipped", "reason" => "amount_exceeds_limit" },
        { "provider" => "payflow", "decision" => "skipped", "reason" => "amount_exceeds_limit" },
        { "provider" => "quickpay", "decision" => "selected", "reason" => "only_eligible_provider" }
      ],
      record["attempts"]
    )
    selected = record["attempts"].select { |attempt| attempt["decision"] == "selected" }
    assert_equal 1, selected.length
    assert_includes %w[approved rejected expired], record["simulated_result"]
    assert_instance_of Integer, record["latency_sec"]
    assert_operator record["latency_sec"], :>=, 1
  end

  def test_repeated_pipeline_builds_are_deterministic
    inputs = load_fixture_inputs
    operation = inputs.operations.find { |row| row.operation_id == "op_101" }

    records = 2.times.map do
      context = SmartRouter::PipelineContext.for(operation, providers: inputs.providers)
      SmartRouter::HardConstraintsFilter.filter(context)
      SmartRouter::BaselineSelector.select(context)
      SmartRouter::DecisionRecordBuilder.build(context)
    end

    assert_equal records.first["simulated_result"], records.last["simulated_result"]
    assert_equal records.first["latency_sec"], records.last["latency_sec"]
    assert_equal records.first["selected_provider"], records.last["selected_provider"]
    assert_equal records.first["attempts"], records.last["attempts"]
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
