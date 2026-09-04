# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "smart_router"

class RoutingDecisionsWriterTest < Minitest::Test
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

  def sample_record
    provider = build_provider
    context = SmartRouter::PipelineContext.for(build_operation, providers: [provider])
    context.eligible_providers = [provider]
    context.selected_provider = provider
    context.selection_reason = "only_eligible_provider"
    context.add_attempt(provider, "selected", "only_eligible_provider")
    SmartRouter::DecisionRecordBuilder.build(context)
  end

  def test_writes_json_array_to_tmp_routing_decisions
    Dir.mktmpdir do |dir|
      path = File.join(dir, "tmp", "routing_decisions.json")
      records = [sample_record]

      SmartRouter::RoutingDecisionsWriter.write(records, path: path)

      parsed = JSON.parse(File.read(path))
      assert_kind_of Array, parsed
      assert_equal 1, parsed.length
      assert_equal %w[operation_id selected_provider attempts simulated_result latency_sec],
                   parsed.first.keys
      assert_equal "op_test", parsed.first["operation_id"]
      assert_equal "quickpay", parsed.first["selected_provider"]
      assert_kind_of Array, parsed.first["attempts"]
      assert_includes %w[approved rejected expired], parsed.first["simulated_result"]
      assert_instance_of Integer, parsed.first["latency_sec"]
    end
  end

  def test_single_record_is_still_written_as_json_array
    Dir.mktmpdir do |dir|
      path = File.join(dir, "routing_decisions.json")

      SmartRouter::RoutingDecisionsWriter.write(sample_record, path: path)

      parsed = JSON.parse(File.read(path))
      assert_kind_of Array, parsed
      assert_equal 1, parsed.length
      assert_equal "op_test", parsed.first["operation_id"]
    end
  end

  def test_writes_multiple_records_in_given_order
    Dir.mktmpdir do |dir|
      path = File.join(dir, "tmp", "out", "routing_decisions.json")
      first = sample_record
      second = sample_record.merge("operation_id" => "op_other")

      SmartRouter::RoutingDecisionsWriter.write([first, second], path: path)

      parsed = JSON.parse(File.read(path))
      assert_equal %w[op_test op_other], parsed.map { |row| row["operation_id"] }
    end
  end

  def test_nil_records_raise_and_do_not_create_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "routing_decisions.json")

      error = assert_raises(SmartRouter::InputError) do
        SmartRouter::RoutingDecisionsWriter.write(nil, path: path)
      end
      assert_includes error.message, "records required"
      refute File.exist?(path)
    end
  end

  def test_does_not_create_file_when_builder_raises
    Dir.mktmpdir do |dir|
      path = File.join(dir, "tmp", "routing_decisions.json")
      context = SmartRouter::PipelineContext.for(build_operation, providers: [build_provider])

      assert_raises(SmartRouter::InputError) do
        record = SmartRouter::DecisionRecordBuilder.build(context)
        SmartRouter::RoutingDecisionsWriter.write([record], path: path)
      end

      refute File.exist?(path)
      refute File.exist?(File.join(dir, "tmp"))
    end
  end

  def test_does_not_overwrite_file_when_builder_raises
    Dir.mktmpdir do |dir|
      path = File.join(dir, "routing_decisions.json")
      File.write(path, "SENTINEL")
      context = SmartRouter::PipelineContext.for(build_operation, providers: [build_provider])

      assert_raises(SmartRouter::InputError) do
        record = SmartRouter::DecisionRecordBuilder.build(context)
        SmartRouter::RoutingDecisionsWriter.write([record], path: path)
      end

      assert_equal "SENTINEL", File.read(path)
    end
  end

  def test_does_not_create_file_when_serialization_fails
    Dir.mktmpdir do |dir|
      path = File.join(dir, "routing_decisions.json")

      assert_raises(JSON::GeneratorError) do
        SmartRouter::RoutingDecisionsWriter.write([Float::NAN], path: path)
      end

      refute File.exist?(path)
    end
  end

  def test_does_not_overwrite_file_when_serialization_fails
    Dir.mktmpdir do |dir|
      path = File.join(dir, "routing_decisions.json")
      File.write(path, "SENTINEL")

      assert_raises(JSON::GeneratorError) do
        SmartRouter::RoutingDecisionsWriter.write([Float::NAN], path: path)
      end

      assert_equal "SENTINEL", File.read(path)
    end
  end

  def test_does_not_leave_partial_tmp_file_on_write_failure
    Dir.mktmpdir do |dir|
      path = File.join(dir, "routing_decisions.json")
      writer = SmartRouter::RoutingDecisionsWriter.new

      File.stub(:write, ->(*) { raise Errno::ENOSPC, "disk full" }) do
        assert_raises(Errno::ENOSPC) do
          writer.write([sample_record], path: path)
        end
      end

      refute File.exist?(path)
      leftover = Dir.glob(File.join(dir, ".routing_decisions.json.*.tmp"))
      assert_empty leftover
    end
  end

  def test_does_not_overwrite_or_leave_tmp_when_rename_fails
    Dir.mktmpdir do |dir|
      path = File.join(dir, "routing_decisions.json")
      File.write(path, "SENTINEL")
      writer = SmartRouter::RoutingDecisionsWriter.new

      File.stub(:rename, ->(*) { raise Errno::EXDEV, "cross-device" }) do
        assert_raises(Errno::EXDEV) do
          writer.write([sample_record], path: path)
        end
      end

      assert_equal "SENTINEL", File.read(path)
      leftover = Dir.glob(File.join(dir, ".routing_decisions.json.*.tmp"))
      assert_empty leftover
    end
  end
end
