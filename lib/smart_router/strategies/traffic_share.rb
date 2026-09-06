# frozen_string_literal: true

module SmartRouter
  module Strategies
    class TrafficShare < Base
      def score(provider, _operation, state = nil)
        resolved = ShareState.coerce(state)
        ShareDeficit.score_share(
          target_pct: provider.traffic_percentage,
          shares: resolved.traffic_shares,
          payment_system: provider.payment_system,
          field: "traffic_percentage",
          path: resolved.path
        )
      end
    end
  end
end
