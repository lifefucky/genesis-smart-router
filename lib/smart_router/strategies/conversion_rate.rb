# frozen_string_literal: true

module SmartRouter
  module Strategies
    class ConversionRate < Base
      SCORE = 0.5

      def score(_provider, _operation, _state = nil)
        SCORE
      end
    end
  end
end
