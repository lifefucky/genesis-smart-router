# frozen_string_literal: true

require "json"
require "fileutils"

module SmartRouter
  class RoutingDecisionsWriter
    def self.write(records, path:)
      new.write(records, path: path)
    end

    def write(records, path:)
      raise InputError.new("routing decisions records required") if records.nil?

      list = records.is_a?(Array) ? records : [records]
      payload = JSON.pretty_generate(list)
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
