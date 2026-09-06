# frozen_string_literal: true

module SmartRouter
  class PipelineContext
    attr_reader :operation, :providers, :attempts
    attr_accessor :eligible_providers, :selected_provider, :selection_reason, :policy_pack

    def self.for(operation, providers:, policy_pack: nil)
      ctx = new(
        operation: operation,
        providers: providers.map(&:dup),
        attempts: [],
        eligible_providers: []
      )
      ctx.policy_pack = policy_pack
      ctx
    end

    def initialize(operation:, providers:, attempts:, eligible_providers:,
                   selected_provider: nil, selection_reason: nil)
      @operation = operation
      @providers = providers
      @attempts = attempts
      @eligible_providers = eligible_providers
      @selected_provider = selected_provider
      @selection_reason = selection_reason
    end

    def add_attempt(provider, decision, reason)
      provider_name = provider.is_a?(Provider) ? provider.payment_system : provider.to_s
      @attempts << {
        "provider" => provider_name,
        "decision" => decision.to_s,
        "reason" => reason.to_s
      }
    end
  end
end
