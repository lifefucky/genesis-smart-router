# frozen_string_literal: true

module SmartRouter
  class StateTracker
    FINISH_RESULTS = %w[approved rejected expired].freeze

    def initialize
      @outstanding_starts = Hash.new(0)
    end

    def start(provider, amount)
      require_finite_amount!(amount)

      provider.in_progress_count += 1
      provider.in_progress_amount += amount
      @outstanding_starts[provider.object_id] += 1
      provider
    end

    def finish(provider, amount, result)
      require_finite_amount!(amount)

      outcome = result.to_s
      unless FINISH_RESULTS.include?(outcome) && @outstanding_starts[provider.object_id].positive?
        raise ArgumentError, "finish requires a prior start and result approved|rejected|expired"
      end

      provider.in_progress_count -= 1
      provider.in_progress_amount -= amount

      if outcome == "approved"
        provider.daily_approved_amount += amount
        requisites = provider.available_requisites
        if SmartRouter.finite_number?(requisites)
          provider.available_requisites = [requisites - 1, 0].max
        end
      end

      @outstanding_starts[provider.object_id] -= 1
      provider
    end

    private

    def require_finite_amount!(amount)
      return if SmartRouter.finite_number?(amount)

      raise ArgumentError, "amount must be a finite number"
    end
  end
end
