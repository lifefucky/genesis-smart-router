# frozen_string_literal: true

module SmartRouter
  ProviderScore = Data.define(:provider, :composite, :parts)

  # Soft scoring over an already-filtered eligible pool.
  # +state+ is read-only actual-share context, either nil, ShareState, or a Hash:
  #   {
  #     "traffic_shares" => { "<payment_system>" => 0.0..1.0, ... },
  #     "volume_shares"  => { "<payment_system>" => 0.0..1.0, ... },
  #     "path"           => optional InputError path (default "state")
  #   }
  # nil, missing maps, or all-zero shares mean no observed data (neutral 0.5).
  # Share maps are used as provided (already normalized); they are not re-weighted.
  class SoftGoalsScorer
    DEFAULT_STRATEGIES = {
      "traffic_share" => Strategies::TrafficShare.new,
      "volume_share" => Strategies::VolumeShare.new,
      "conversion_rate" => Strategies::ConversionRate.new,
      "financial_commitment" => Strategies::FinancialCommitment.new
    }.freeze

    def self.score(eligible_providers, operation:, state: nil,
                   policies_path: DEFAULT_ROUTING_POLICIES_PATH, strategies: {}, policy_pack: nil)
      new(policies_path: policies_path, strategies: strategies, policy_pack: policy_pack)
        .score(eligible_providers, operation: operation, state: state)
    end

    def initialize(policies_path: DEFAULT_ROUTING_POLICIES_PATH, strategies: {}, policy_pack: nil)
      @policies_path = policies_path
      @strategies = DEFAULT_STRATEGIES.merge(strategies.transform_keys(&:to_s))
      @policy_pack = policy_pack
    end

    def score(eligible_providers, operation:, state: nil)
      return [] if eligible_providers.nil? || eligible_providers.empty?

      registry = PolicyRegistry.load(@policies_path, policy_pack: @policy_pack)
      active = registry.active_policies
      resolved_state = ShareState.coerce(state)

      eligible_providers.map do |provider|
        parts = {}
        composite = 0.0

        active.each do |policy|
          strategy = @strategies[policy.name]
          if strategy.nil?
            raise InputError.new(
              "missing strategy implementation for #{policy.name}",
              path: @policies_path
            )
          end
          value = validate_score!(
            strategy.score(provider, operation, resolved_state),
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
