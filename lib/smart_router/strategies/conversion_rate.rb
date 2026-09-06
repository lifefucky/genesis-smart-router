# frozen_string_literal: true

module SmartRouter
  module Strategies
    class ConversionRate < Base
      NEUTRAL = 0.5

      def score(provider, _operation, state = nil)
        value = provider.conversion_24h
        return NEUTRAL if value.nil?

        path = ShareState.coerce(state).path

        unless SmartRouter.finite_number?(value)
          raise InputError.new("conversion_24h is not numeric", path: path)
        end

        score = value.to_f
        if score.negative? || score > 1.0
          raise InputError.new("conversion_24h must be between 0.0 and 1.0", path: path)
        end

        score
      end
    end
  end
end
