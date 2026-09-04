# frozen_string_literal: true

require "json"
require "csv"
require "time"

module SmartRouter
  REQUIRED_RUBY_VERSION = "3.2.0"

  unless Gem::Requirement.new(">= #{REQUIRED_RUBY_VERSION}")
      .satisfied_by?(Gem::Version.new(RUBY_VERSION))
    raise LoadError,
          "SmartRouter requires Ruby #{REQUIRED_RUBY_VERSION}+ (running #{RUBY_VERSION})"
  end

  DEFAULT_PROVIDERS_PATH = "config/providers.json"
  DEFAULT_QUEUE_PATH = "data/operations_queue.json"
  DEFAULT_HISTORY_PATH = "data/operations_history.csv"

  class InputError < StandardError
    attr_reader :path

    def initialize(message, path: nil)
      @path = path
      super(path ? "#{message}: #{path}" : message)
    end
  end

  def self.finite_number?(value)
    value.is_a?(Numeric) && value.finite?
  end

  def self.read_file(path)
    File.read(path)
  rescue SystemCallError, EncodingError => e
    raise InputError.new(e.message, path: path)
  end

  def self.read_json(path)
    JSON.parse(read_file(path))
  rescue JSON::ParserError, EncodingError => e
    raise InputError.new("invalid JSON (#{e.message})", path: path)
  end
end

require_relative "smart_router/provider"
require_relative "smart_router/operation"
require_relative "smart_router/routing_config"
require_relative "smart_router/run_inputs"
require_relative "smart_router/pipeline_context"
require_relative "smart_router/hard_constraints_filter"
require_relative "smart_router/baseline_selector"
