# frozen_string_literal: true

module SmartRouter
  module Strategies
    class VolumeShare < Base
      def score(provider, _operation, state = nil)
        resolved = ShareState.coerce(state)
        ShareDeficit.score_share(
          target_pct: provider.volume_share_pct,
          shares: resolved.volume_shares,
          payment_system: provider.payment_system,
          field: "volume_share_pct",
          path: resolved.path
        )
      end
    end
  end
end
