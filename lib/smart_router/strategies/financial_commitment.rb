# frozen_string_literal: true

module SmartRouter
  module Strategies
    class FinancialCommitment < Base
      NEUTRAL = 0.5

      def score(provider, operation, state = nil)
        path = ShareState.coerce(state).path
        amount = operation.amount
        min = provider.limit_amount_min
        max = provider.limit_amount_max
        daily_limit = provider.daily_amount_limit
        daily_approved = provider.daily_approved_amount

        validate_limit_params!(min, max, daily_limit, daily_approved, path)
        return NEUTRAL if spacepayments?(provider)
        return NEUTRAL if min.nil? && max.nil?

        band_preference(min, max, amount, daily_limit, daily_approved)
      end

      private

      def spacepayments?(provider)
        provider.payment_system == "spacepayments"
      end

      def validate_limit_params!(min, max, daily_limit, daily_approved, path)
        {
          "limit_amount_min" => min,
          "limit_amount_max" => max,
          "daily_amount_limit" => daily_limit,
          "daily_approved_amount" => daily_approved
        }.each do |field, value|
          next if value.nil?
          unless SmartRouter.finite_number?(value)
            raise InputError.new("#{field} is not numeric", path: path)
          end
        end

        if !daily_limit.nil? && daily_limit.to_f.negative?
          raise InputError.new("daily_amount_limit must be >= 0", path: path)
        end

        if !min.nil? && !max.nil? && min.to_f > max.to_f
          raise InputError.new("limit_amount_min must be <= limit_amount_max", path: path)
        end
      end

      def safety_ratio(daily_limit, daily_approved)
        return 1.0 if daily_limit.nil?
        return 0.0 if daily_limit.zero?

        used = daily_approved.to_f / daily_limit.to_f
        remaining = 1.0 - used
        remaining.clamp(0.0, 1.0)
      end

      def band_preference(min, max, amount, daily_limit, daily_approved)
        return NEUTRAL if amount.nil?
        return NEUTRAL if min.nil? && max.nil?

        a = amount.to_f
        lower = min.nil? ? a : min.to_f
        upper = max.nil? ? a : max.to_f
        return NEUTRAL if lower == upper

        center = (lower + upper) / 2.0
        half_width = (upper - lower) / 2.0
        return NEUTRAL if half_width <= 0.0

        distance = (a - center).abs
        normalized = (half_width - distance) / half_width
        return NEUTRAL if normalized <= 0.0

        ratio = safety_ratio(daily_limit, daily_approved)
        boost = (normalized * ratio) / 2.0

        (NEUTRAL + boost).clamp(0.5, 1.0)
      end
    end
  end
end
