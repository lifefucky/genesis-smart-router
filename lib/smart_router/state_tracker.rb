# frozen_string_literal: true

module SmartRouter
  class StateTracker
    FINISH_RESULTS = %w[approved rejected expired].freeze

    def initialize
      @open_deltas = {}
    end

    def start(provider, amount)
      require_tracked_amount!(amount)
      if @open_deltas.key?(provider.object_id)
        raise ArgumentError, "start requires no open delta for this provider"
      end

      write_metrics(
        provider,
        in_progress_count: provider.in_progress_count + 1,
        in_progress_amount: provider.in_progress_amount + amount,
        daily_approved_amount: provider.daily_approved_amount,
        available_requisites: provider.available_requisites
      )
      @open_deltas[provider.object_id] = amount
      provider
    end

    def finish(provider, amount, result)
      require_tracked_amount!(amount)

      outcome = result.to_s
      open_amount = @open_deltas[provider.object_id]
      unless FINISH_RESULTS.include?(outcome) && !open_amount.nil? && open_amount == amount
        raise ArgumentError, "finish requires a prior start with matching amount and result approved|rejected|expired"
      end

      daily = provider.daily_approved_amount
      requisites = provider.available_requisites
      if outcome == "approved"
        daily += amount
        if SmartRouter.finite_number?(requisites)
          requisites = [requisites - 1, 0].max
        end
      end

      write_metrics(
        provider,
        in_progress_count: provider.in_progress_count - 1,
        in_progress_amount: provider.in_progress_amount - amount,
        daily_approved_amount: daily,
        available_requisites: requisites
      )
      @open_deltas.delete(provider.object_id)
      provider
    end

    private

    def require_tracked_amount!(amount)
      return if (amount.is_a?(Integer) || amount.is_a?(Float)) && amount.finite? && amount.positive?

      raise ArgumentError, "amount must be a finite Integer or Float greater than 0"
    end

    def write_metrics(provider, in_progress_count:, in_progress_amount:,
                      daily_approved_amount:, available_requisites:)
      provider.send(
        :write_tracked_metrics,
        in_progress_count,
        in_progress_amount,
        daily_approved_amount,
        available_requisites
      )
    end
  end
end
