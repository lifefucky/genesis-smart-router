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

    attr_reader :path, :policies, :current_version, :active_version

    @cache = {}

    def self.clear_cache!
      @cache = {}
    end

    def self.load(path = DEFAULT_ROUTING_POLICIES_PATH, policy_pack: nil)
      path = path.to_s
      cache_key = [path, policy_pack]

      cached = @cache[cache_key]
      return cached if cached

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

      # Determine if we have a versioned file or a flat file
      has_versions = data.key?("versions") || data.key?("current_version")

      if has_versions
        current_version = data["current_version"]
        versions = data["versions"]

        # Validate that versions is a hash
        if versions && !versions.is_a?(Hash)
          raise InputError.new("versions must be a mapping", path: path)
        end

        # Resolve active policy pack
        active_version = policy_pack ? policy_pack.to_s : current_version&.to_s

        if active_version.nil? || active_version.empty?
          raise InputError.new("no active policy pack specified or found", path: path)
        end

        version_data = versions ? versions[active_version] : nil
        if version_data.nil?
          raise InputError.new("policy pack '#{active_version}' not found", path: path)
        end

        unless version_data.is_a?(Hash)
          raise InputError.new("policy pack '#{active_version}' must be a mapping", path: path)
        end

        raw_strategies = version_data["strategies"]
      else
        # Legacy/flat YAML compatibility
        current_version = nil
        active_version = nil
        raw_strategies = data["strategies"]
      end

      if raw_strategies.nil?
        raw_strategies = {}
      elsif !raw_strategies.is_a?(Hash)
        raise InputError.new("strategies must be a mapping", path: path)
      end

      policies = KNOWN_STRATEGY_KEYS.to_h do |name|
        [name, parse_entry(name, raw_strategies[name], path: path)]
      end

      registry = new(
        path: path,
        policies: policies,
        current_version: current_version,
        active_version: active_version
      )
      @cache[cache_key] = registry
      registry
    end

    def initialize(path:, policies:, current_version: nil, active_version: nil)
      @path = path
      @policies = policies
      @current_version = current_version
      @active_version = active_version
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
