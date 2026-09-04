# frozen_string_literal: true

module SmartRouter
  class HardConstraintsFilter
    def self.filter(context)
      new.filter(context)
    end

    def filter(context)
      context.eligible_providers = []

      context.providers.each do |provider|
        # 1. Status check: status == "active"
        # If not active, completely ignore (do not add to eligible_providers, do not add to attempts)
        next unless provider.status == "active"

        # spacepayments bypasses ALL hard filters (always eligible)
        if provider.payment_system == "spacepayments"
          context.eligible_providers << provider
          next
        end

        # 2. Traffic percentage check: traffic_percentage.to_f > 0
        # Providers with zero traffic, except spacepayments, are excluded with reason "amount_below_minimum"
        if provider.traffic_percentage.to_f <= 0
          context.add_attempt(provider, "skipped", "amount_below_minimum")
          next
        end

        # 3. Minimum amount check: limit_amount_min
        # if set and amount < limit_amount_min -> "amount_below_minimum"
        if provider.limit_amount_min && context.operation.amount < provider.limit_amount_min
          context.add_attempt(provider, "skipped", "amount_below_minimum")
          next
        end

        # 4. Maximum amount check: limit_amount_max
        # if set and amount > limit_amount_max -> "amount_exceeds_limit"
        if provider.limit_amount_max && context.operation.amount > provider.limit_amount_max
          context.add_attempt(provider, "skipped", "amount_exceeds_limit")
          next
        end

        # 5. Daily limit: daily_approved_amount + amount > daily_amount_limit -> "daily_limit_exceeded"
        if provider.daily_amount_limit && (provider.daily_approved_amount + context.operation.amount) > provider.daily_amount_limit
          context.add_attempt(provider, "skipped", "daily_limit_exceeded")
          next
        end

        # 6. In progress count limit: in_progress_count >= in_progress_count_limit -> "in_progress_count_exceeded"
        if provider.in_progress_count_limit && provider.in_progress_count >= provider.in_progress_count_limit
          context.add_attempt(provider, "skipped", "in_progress_count_exceeded")
          next
        end

        # 7. In progress amount limit: in_progress_amount + amount > in_progress_amount_limit -> "in_progress_amount_exceeded"
        if provider.in_progress_amount_limit && (provider.in_progress_amount + context.operation.amount) > provider.in_progress_amount_limit
          context.add_attempt(provider, "skipped", "in_progress_amount_exceeded")
          next
        end

        # 8. Requisites presence: available_requisites == 0 -> "no_requisites"
        if provider.available_requisites == 0
          context.add_attempt(provider, "skipped", "no_requisites")
          next
        end

        # 9. Margin check: provider_margin_pct > merchant_margin_pct (if allow_negative_agreement is false) -> "negative_margin"
        if !provider.allow_negative_agreement && provider.provider_margin_pct > provider.merchant_margin_pct
          context.add_attempt(provider, "skipped", "negative_margin")
          next
        end

        # 10. Bank filter: if banks is not empty, check application bank with respect to exclude_banks -> "bank_not_in_list"
        if !provider.banks.empty?
          bank = context.operation.bank
          is_included = provider.banks.include?(bank)
          if provider.exclude_banks
            if is_included
              context.add_attempt(provider, "skipped", "bank_not_in_list")
              next
            end
          else
            if !is_included
              context.add_attempt(provider, "skipped", "bank_not_in_list")
              next
            end
          end
        end

        # If all checks pass, provider is eligible
        context.eligible_providers << provider
      end

      context
    end
  end
end
