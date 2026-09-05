# frozen_string_literal: true

module SmartRouter
  class FallbackExecutor
    EXECUTION_SKIP_REASONS = {
      "rejected" => "provider_rejected",
      "expired" => "provider_expired"
    }.freeze

    def self.execute(context, tracker:)
      new.execute(context, tracker: tracker)
    end

    def execute(context, tracker:)
      eligible = Array(context.eligible_providers)
      external_eligible = eligible.reject { |provider| provider.payment_system == "spacepayments" }
      self_provider = context.providers.find do |provider|
        provider.payment_system == "spacepayments" && provider.status == "active"
      end

      if external_eligible.empty? && self_provider.nil?
        raise_no_provider!(context)
      end

      cascade = external_eligible.sort_by { |provider| [provider.priority, provider.payment_system] }
      cascade << self_provider if self_provider
      amount = context.operation.amount

      cascade.each do |provider|
        tracker.start(provider, amount)
        outcome = DecisionRecordBuilder.simulate_result(context.operation, provider)
        tracker.finish(provider, amount, outcome)

        case outcome
        when "approved"
          reason = selection_reason_for(provider, external_eligible)
          context.selected_provider = provider
          context.selection_reason = reason
          context.add_attempt(provider, "selected", reason)
          return context
        when "rejected", "expired"
          context.add_attempt(provider, "skipped", EXECUTION_SKIP_REASONS.fetch(outcome))
        end
      end

      raise_no_provider!(context)
    end

    private

    def selection_reason_for(provider, external_eligible)
      return "self_provider_fallback" if provider.payment_system == "spacepayments"

      external_eligible.one? ? "only_eligible_provider" : "first_eligible"
    end

    def raise_no_provider!(context)
      operation_id = context.operation&.operation_id
      message = if operation_id
                  "no eligible providers for #{operation_id}"
                else
                  "no eligible providers"
                end
      raise InputError.new(message)
    end
  end
end
