# frozen_string_literal: true

module SmartRouter
  class PipelineContext
    attr_reader :operation, :providers, :attempts, :eligible_providers

    def self.for(operation, providers:)
      new(
        operation: operation,
        providers: providers.map(&:dup),
        attempts: [],
        eligible_providers: []
      )
    end

    def initialize(operation:, providers:, attempts:, eligible_providers:)
      @operation = operation
      @providers = providers
      @attempts = attempts
      @eligible_providers = eligible_providers
    end
  end
end
