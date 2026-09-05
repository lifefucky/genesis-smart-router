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
    context, _working = run_cascade(operation, inputs.providers)

    record = SmartRouter::DecisionRecordBuilder.build(context)

    assert_equal "op_101", record["operation_id"]
    assert_equal "vipay", record["selected_provider"]
    assert_equal "first_eligible", context.selection_reason
    selected = record["attempts"].select { |attempt| attempt["decision"] == "selected" }
    assert_equal 1, selected.length
    assert_equal "vipay", selected.first["provider"]
    assert_equal "approved", record["simulated_result"]
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
    context, _working = run_cascade(operation, providers)

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
      context, _working = run_cascade(operation, inputs.providers)
      SmartRouter::DecisionRecordBuilder.build(context)
    end

    assert_equal records.first["simulated_result"], records.last["simulated_result"]
    assert_equal records.first["latency_sec"], records.last["latency_sec"]
    assert_equal records.first["selected_provider"], records.last["selected_provider"]
    assert_equal records.first["attempts"], records.last["attempts"]
  end

  def test_queue_carries_working_set_and_leaves_catalog_clean
    inputs = load_fixture_inputs
    catalog_before = inputs.providers.map { |provider| provider_snapshot(provider) }
    working = inputs.providers.map(&:dup)
    tracker = SmartRouter::StateTracker.new
    first = inputs.operations.find { |row| row.operation_id == "op_101" }
    second = inputs.operations.find { |row| row.operation_id == "op_102" }

    first_ctx = SmartRouter::PipelineContext.for(first, providers: working)
    SmartRouter::HardConstraintsFilter.filter(first_ctx)
    SmartRouter::FallbackExecutor.execute(first_ctx, tracker: tracker)
    working = first_ctx.providers

    second_ctx = SmartRouter::PipelineContext.for(second, providers: working)
    SmartRouter::HardConstraintsFilter.filter(second_ctx)
    SmartRouter::FallbackExecutor.execute(second_ctx, tracker: tracker)
    working = second_ctx.providers

    catalog_by_name = inputs.providers.to_h { |provider| [provider.payment_system, provider] }
    moved = working.any? do |provider|
      catalog = catalog_by_name.fetch(provider.payment_system)
      provider.daily_approved_amount != catalog.daily_approved_amount ||
        provider.available_requisites != catalog.available_requisites
    end
    assert moved, "working-set metrics should move relative to the catalog"
    working.each do |provider|
      catalog = catalog_by_name.fetch(provider.payment_system)
      assert_equal catalog.in_progress_count, provider.in_progress_count
      assert_equal catalog.in_progress_amount, provider.in_progress_amount
    end
    assert_equal catalog_before, inputs.providers.map { |provider| provider_snapshot(provider) }
    refute_nil second_ctx.selected_provider
  end

  private

  def run_cascade(operation, providers, tracker: SmartRouter::StateTracker.new)
    working = providers.map(&:dup)
    context = SmartRouter::PipelineContext.for(operation, providers: working)
    SmartRouter::HardConstraintsFilter.filter(context)
    SmartRouter::FallbackExecutor.execute(context, tracker: tracker)
    working = context.providers
    [context, working]
  end

  def provider_snapshot(provider)
    {
      daily_approved_amount: provider.daily_approved_amount,
      available_requisites: provider.available_requisites,
      in_progress_count: provider.in_progress_count,
      in_progress_amount: provider.in_progress_amount
    }
  end

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
