# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "fileutils"
require "tmpdir"
require "rbconfig"

class BatchRunnerCliTest < Minitest::Test
  PROJECT_ROOT = File.expand_path("../..", __dir__)

  def test_cli_writes_decisions_and_report_to_root
    Dir.mktmpdir do |dir|
      copy_minimal_project(dir)

      output = nil
      status = nil

      Dir.chdir(dir) do
        cmd = [RbConfig.ruby, "-Ilib", "bin/genesis-smart-router"]
        output = IO.popen(cmd, err: [:child, :out], &:read)
        status = $?
      end

      assert status&.success?, "CLI failed with status #{status}: #{output}"

      decisions_path = File.join(dir, "routing_decisions_test.json")
      report_path = File.join(dir, "routing_report_test.json")

      assert File.exist?(decisions_path), "routing_decisions_test.json was not created"
      assert File.exist?(report_path), "routing_report_test.json was not created"

      decisions = JSON.parse(File.read(decisions_path))
      report = JSON.parse(File.read(report_path))

      assert_kind_of Array, decisions
      refute_empty decisions

      assert_kind_of Hash, report
      assert_equal "batch_run", report["period"]
    end
  end

  private

  def copy_minimal_project(target_root)
    FileUtils.mkdir_p(File.join(target_root, "config"))
    FileUtils.mkdir_p(File.join(target_root, "data"))
    FileUtils.mkdir_p(File.join(target_root, "bin"))
    FileUtils.mkdir_p(File.join(target_root, "lib"))

    FileUtils.cp(
      File.join(PROJECT_ROOT, "config/providers.json"),
      File.join(target_root, "config/providers.json")
    )
    FileUtils.cp(
      File.join(PROJECT_ROOT, "config/routing_policies.yml"),
      File.join(target_root, "config/routing_policies.yml")
    )
    FileUtils.cp(
      File.join(PROJECT_ROOT, "data/operations_queue_test.json"),
      File.join(target_root, "data/operations_queue_test.json")
    )
    FileUtils.cp(
      File.join(PROJECT_ROOT, "data/operations_history.csv"),
      File.join(target_root, "data/operations_history.csv")
    )

    FileUtils.cp_r(
      File.join(PROJECT_ROOT, "lib", "."),
      File.join(target_root, "lib")
    )
    FileUtils.cp(
      File.join(PROJECT_ROOT, "bin/genesis-smart-router"),
      File.join(target_root, "bin/genesis-smart-router")
    )
  end
end
