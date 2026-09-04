# frozen_string_literal: true

module SmartRouter
  class BaselineSelector
    def self.select(context)
      new.select(context)
    end

    def select(context)
      eligible = Array(context.eligible_providers)
      if eligible.empty?
        operation_id = context.operation&.operation_id
        message = if operation_id
                    "no eligible providers for #{operation_id}"
                  else
                    "no eligible providers"
                  end
        raise InputError.new(message)
      end

      chosen = eligible.min_by { |provider| [provider.priority, provider.payment_system] }
      reason = eligible.one? ? "only_eligible_provider" : "first_eligible"

      context.selected_provider = chosen
      context.selection_reason = reason
      context.add_attempt(chosen, "selected", reason)
      context
    end
  end
end
