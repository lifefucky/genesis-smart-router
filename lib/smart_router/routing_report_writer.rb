# frozen_string_literal: true

require "json"
require "fileutils"

module SmartRouter
  class RoutingReportWriter
    def self.write(report, path:)
      new.write(report, path: path)
    end

    def write(report, path:)
      raise InputError.new("routing report required") if report.nil?
      unless report.is_a?(Hash)
        raise InputError.new("routing report must be an object")
      end

      payload = JSON.pretty_generate(report)
      write_atomically(path, payload)
      path
    end

    private

    def write_atomically(path, payload)
      tmp_path = nil
      dir = File.dirname(path)
      FileUtils.mkdir_p(dir) unless dir == "."

      tmp_path = File.join(
        dir,
        ".#{File.basename(path)}.#{Process.pid}.#{Thread.current.object_id}.tmp"
      )
      File.write(tmp_path, payload)
      File.rename(tmp_path, path)
    ensure
      File.delete(tmp_path) if tmp_path && File.exist?(tmp_path)
    end
  end
end
