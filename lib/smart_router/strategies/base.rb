# frozen_string_literal: true

module SmartRouter
  module Strategies
    class Base
      def score(_provider, _operation, _state = nil)
        raise NotImplementedError, "#{self.class}#score must be implemented"
      end
    end
  end
end
