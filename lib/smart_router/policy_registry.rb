# frozen_string_literal: true

module SmartRouter
  StrategyPolicy = Data.define(:name, :enabled, :weight)

  class PolicyRegistry
    KNOWN_STRATEGY_KEYS = %w[
      traffic_share
      volume_share
      conversion_rate
      financial_commitment
    ].freeze

    attr_reader :path, :policies

    def self.load(path = DEFAULT_ROUTING_POLICIES_PATH)
      contents = SmartRouter.read_file(path)
      data =
        begin
          YAML.safe_load(contents, permitted_classes: [], aliases: false, filename: path)
        rescue Psych::Exception => e
          raise InputError.new("invalid YAML (#{e.message})", path: path)
        end

      unless data.is_a?(Hash)
        raise InputError.new("routing policies must be a mapping", path: path)
      end

      raw_strategies = data["strategies"]
      if raw_strategies.nil?
        raw_strategies = {}
      elsif !raw_strategies.is_a?(Hash)
        raise InputError.new("strategies must be a mapping", path: path)
      end

      policies = KNOWN_STRATEGY_KEYS.to_h do |name|
        [name, parse_entry(name, raw_strategies[name], path: path)]
      end

      new(path: path, policies: policies)
    end

    def initialize(path:, policies:)
      @path = path
      @policies = policies
    end

    def active_policies
      @policies.each_value.select { |policy| policy.enabled && policy.weight.positive? }
    end

    def self.parse_entry(name, entry, path:)
      return StrategyPolicy.new(name: name, enabled: false, weight: 0.0) if entry.nil?

      unless entry.is_a?(Hash)
        raise InputError.new("#{name} must be a mapping", path: path)
      end

      row = entry.transform_keys(&:to_s)

      if row.key?("enabled")
        enabled = row["enabled"]
        unless enabled == true || enabled == false
          raise InputError.new("#{name} enabled must be a boolean", path: path)
        end
      else
        enabled = false
      end

      if row.key?("weight")
        weight = row["weight"]
        unless SmartRouter.finite_number?(weight) && weight >= 0
          raise InputError.new("#{name} weight must be a finite number >= 0", path: path)
        end
      else
        weight = 0.0
      end

      StrategyPolicy.new(name: name, enabled: enabled, weight: weight)
    end
    private_class_method :parse_entry
  end
end
