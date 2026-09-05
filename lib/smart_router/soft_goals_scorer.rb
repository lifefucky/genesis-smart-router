# frozen_string_literal: true

module SmartRouter
  ProviderScore = Data.define(:provider, :composite, :parts)

  class SoftGoalsScorer
    DEFAULT_STRATEGIES = {
      "traffic_share" => Strategies::TrafficShare.new,
      "volume_share" => Strategies::VolumeShare.new,
      "conversion_rate" => Strategies::ConversionRate.new,
      "financial_commitment" => Strategies::FinancialCommitment.new
    }.freeze

    def self.score(eligible_providers, operation:, state: nil,
                   policies_path: DEFAULT_ROUTING_POLICIES_PATH, strategies: {})
      new(policies_path: policies_path, strategies: strategies)
        .score(eligible_providers, operation: operation, state: state)
    end

    def initialize(policies_path: DEFAULT_ROUTING_POLICIES_PATH, strategies: {})
      @policies_path = policies_path
      @strategies = DEFAULT_STRATEGIES.merge(strategies.transform_keys(&:to_s))
    end

    def score(eligible_providers, operation:, state: nil)
      return [] if eligible_providers.nil? || eligible_providers.empty?

      registry = PolicyRegistry.load(@policies_path)
      active = registry.active_policies

      eligible_providers.map do |provider|
        parts = {}
        composite = 0.0

        active.each do |policy|
          strategy = @strategies.fetch(policy.name)
          value = validate_score!(
            strategy.score(provider, operation, state),
            policy.name,
            path: @policies_path
          )
          parts[policy.name] = value
          composite += policy.weight * value
        end

        ProviderScore.new(provider: provider, composite: composite, parts: parts)
      end
    end

    private

    def validate_score!(value, name, path:)
      unless SmartRouter.finite_number?(value) && value >= 0.0 && value <= 1.0
        raise InputError.new("#{name} score must be a finite number in [0.0, 1.0]", path: path)
      end

      value.to_f
    end
  end
end
