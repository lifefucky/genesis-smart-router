# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "smart_router"

class RoutingReportWriterTest < Minitest::Test
  def sample_report
    {
      "period" => "2026-07-30",
      "total_operations" => 10,
      "distribution" => {
        "vipay" => {
          "count" => 2,
          "share_pct" => 20.0,
          "target_pct" => 40.0,
          "signed_deviation" => -20.0,
          "absolute_deviation" => 20.0
        }
      },
      "skip_reasons" => {
        "amount_exceeds_limit" => 3
      }
    }
  end

  def test_writes_single_json_object_not_array
    Dir.mktmpdir do |dir|
      path = File.join(dir, "routing_report.json")

      SmartRouter::RoutingReportWriter.write(sample_report, path: path)

      parsed = JSON.parse(File.read(path))
      assert_kind_of Hash, parsed
      refute_kind_of Array, parsed
      assert_equal "2026-07-30", parsed["period"]
      assert_equal 10, parsed["total_operations"]
      assert_kind_of Hash, parsed["distribution"]
      assert_kind_of Hash, parsed["skip_reasons"]
      assert_equal 2, parsed["distribution"]["vipay"]["count"]
      assert_equal 3, parsed["skip_reasons"]["amount_exceeds_limit"]
    end
  end

  def test_serializes_empty_report_builder_output
    Dir.mktmpdir do |dir|
      path = File.join(dir, "routing_report.json")
      report = SmartRouter::ReportBuilder.build([], [], period: "2026-07-30")

      SmartRouter::RoutingReportWriter.write(report, path: path)

      parsed = JSON.parse(File.read(path))
      assert_kind_of Hash, parsed
      refute_kind_of Array, parsed
      assert_equal "2026-07-30", parsed["period"]
      assert_equal 0, parsed["total_operations"]
      assert_equal({}, parsed["distribution"])
      assert_equal({}, parsed["skip_reasons"])
    end
  end

  def test_empty_report_serializes_without_wrapping
    Dir.mktmpdir do |dir|
      path = File.join(dir, "routing_report.json")
      report = {
        "period" => "2026-07-30",
        "total_operations" => 0,
        "distribution" => {},
        "skip_reasons" => {}
      }

      SmartRouter::RoutingReportWriter.write(report, path: path)

      parsed = JSON.parse(File.read(path))
      assert_kind_of Hash, parsed
      refute_kind_of Array, parsed
      assert_equal 0, parsed["total_operations"]
      assert_equal({}, parsed["distribution"])
      assert_equal({}, parsed["skip_reasons"])
    end
  end

  def test_writes_via_tmp_file_then_rename
    Dir.mktmpdir do |dir|
      path = File.join(dir, "tmp", "routing_report.json")
      writes = []
      renames = []
      original_write = File.method(:write)
      original_rename = File.method(:rename)

      File.stub(:write, ->(tmp_path, payload) {
        writes << tmp_path
        original_write.call(tmp_path, payload)
      }) do
        File.stub(:rename, ->(tmp_path, dest) {
          renames << [tmp_path, dest]
          original_rename.call(tmp_path, dest)
        }) do
          SmartRouter::RoutingReportWriter.write(sample_report, path: path)
        end
      end

      assert_equal 1, writes.length
      tmp_path = writes.first
      assert_equal File.dirname(path), File.dirname(tmp_path)
      assert_match(/\A\.routing_report\.json\.\d+\.\d+\.tmp\z/, File.basename(tmp_path))
      assert_equal [[tmp_path, path]], renames
      refute File.exist?(tmp_path)
      parsed = JSON.parse(File.read(path))
      assert_kind_of Hash, parsed
    end
  end

  def test_does_not_touch_existing_decisions_file
    Dir.mktmpdir do |dir|
      decisions = File.join(dir, "routing_decisions.json")
      File.write(decisions, "SENTINEL")
      path = File.join(dir, "routing_report.json")

      SmartRouter::RoutingReportWriter.write(sample_report, path: path)

      assert_equal "SENTINEL", File.read(decisions)
      assert File.exist?(path)
    end
  end

  def test_nil_report_raises_and_does_not_create_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "routing_report.json")

      error = assert_raises(SmartRouter::InputError) do
        SmartRouter::RoutingReportWriter.write(nil, path: path)
      end
      assert_includes error.message, "routing report required"
      refute File.exist?(path)
    end
  end

  def test_array_report_raises_and_does_not_create_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "routing_report.json")

      error = assert_raises(SmartRouter::InputError) do
        SmartRouter::RoutingReportWriter.write([sample_report], path: path)
      end
      assert_includes error.message, "must be an object"
      refute File.exist?(path)
    end
  end

  def test_does_not_create_file_when_serialization_fails
    Dir.mktmpdir do |dir|
      path = File.join(dir, "routing_report.json")

      assert_raises(JSON::GeneratorError) do
        SmartRouter::RoutingReportWriter.write({ "bad" => Float::NAN }, path: path)
      end

      refute File.exist?(path)
    end
  end

  def test_does_not_overwrite_file_when_serialization_fails
    Dir.mktmpdir do |dir|
      path = File.join(dir, "routing_report.json")
      File.write(path, "SENTINEL")

      assert_raises(JSON::GeneratorError) do
        SmartRouter::RoutingReportWriter.write({ "bad" => Float::NAN }, path: path)
      end

      assert_equal "SENTINEL", File.read(path)
    end
  end

  def test_does_not_leave_partial_tmp_file_on_write_failure
    Dir.mktmpdir do |dir|
      path = File.join(dir, "routing_report.json")
      writer = SmartRouter::RoutingReportWriter.new

      File.stub(:write, ->(*) { raise Errno::ENOSPC, "disk full" }) do
        assert_raises(Errno::ENOSPC) do
          writer.write(sample_report, path: path)
        end
      end

      refute File.exist?(path)
      leftover = Dir.glob(File.join(dir, ".routing_report.json.*.tmp"))
      assert_empty leftover
    end
  end

  def test_does_not_overwrite_or_leave_tmp_when_rename_fails
    Dir.mktmpdir do |dir|
      path = File.join(dir, "routing_report.json")
      File.write(path, "SENTINEL")
      writer = SmartRouter::RoutingReportWriter.new

      File.stub(:rename, ->(*) { raise Errno::EXDEV, "cross-device" }) do
        assert_raises(Errno::EXDEV) do
          writer.write(sample_report, path: path)
        end
      end

      assert_equal "SENTINEL", File.read(path)
      leftover = Dir.glob(File.join(dir, ".routing_report.json.*.tmp"))
      assert_empty leftover
    end
  end
end
