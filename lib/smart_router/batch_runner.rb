# frozen_string_literal: true

module SmartRouter
  class BatchRunner
    Result = Data.define(:decisions, :providers)

    def self.run(queue_path:, providers_path:, history_path:)
      new(
        providers_path: providers_path,
        queue_path: queue_path,
        history_path: history_path
      ).run
    end

    def initialize(providers_path:, queue_path:, history_path:)
      @providers_path = providers_path
      @queue_path = queue_path
      @history_path = history_path
    end

    def run
      inputs = RunInputs.load(
        providers_path: @providers_path,
        queue_path: @queue_path,
        history_path: @history_path
      )

      working_providers = inputs.providers.map(&:dup)
      tracker = StateTracker.new

      decisions = inputs.operations.map do |operation|
        context = PipelineContext.for(operation, providers: working_providers)
        HardConstraintsFilter.filter(context)
        FallbackExecutor.execute(context, tracker: tracker)
        working_providers = context.providers
        DecisionRecordBuilder.build(context, state: nil)
      end

      Result.new(decisions: decisions, providers: working_providers)
    end
  end
end

