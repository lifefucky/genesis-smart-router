# frozen_string_literal: true

module SmartRouter
  class DecisionRecordBuilder
    HARD_SKIP_REASONS = %w[
      amount_exceeds_limit
      amount_below_minimum
      bank_not_in_list
      daily_limit_exceeded
      in_progress_count_exceeded
      in_progress_amount_exceeded
      no_requisites
      negative_margin
    ].freeze

    SOFT_GOAL_VARIANCE_CAUSES = %w[
      target_provider_ineligible
      higher_priority_goal_conflict
      target_provider_execution_failed
    ].freeze

    def self.build(context, state: nil)
      new.build(context, state: state)
    end

    def build(context, state: nil)
      operation = context.operation
      provider = context.selected_provider
      if operation.nil? || provider.nil?
        raise InputError.new("decision record requires a selected provider")
      end

      record = {
        "operation_id" => operation.operation_id,
        "selected_provider" => provider.payment_system,
        "attempts" => copy_attempts(context.attempts),
        "simulated_result" => self.class.simulate_result(operation, provider),
        "latency_sec" => latency_sec(provider)
      }

      variances = build_soft_goal_variances(context, state: state)
      record["soft_goal_variances"] = variances unless variances.empty?

      record
    end

    def self.simulate_result(operation, provider)
      seed = "#{operation.operation_id}:#{provider.payment_system}"
            .each_byte.reduce(0) { |acc, byte| acc * 31 + byte }
      rng = Random.new(seed)
      if rng.rand < provider.conversion_24h
        "approved"
      else
        rng.rand < 0.5 ? "rejected" : "expired"
      end
    end

    private

    def build_soft_goal_variances(context, state: nil)
      operation = context.operation
      selected = context.selected_provider
      return [] if operation.nil? || selected.nil?

      providers = Array(context.providers)
      return [] if providers.empty?

      eligible = Array(context.eligible_providers)
      eligible_names = eligible.map { |provider| provider.payment_system.to_s }.uniq

      attempts = Array(context.attempts).map { |row| row.to_h.transform_keys(&:to_s) }

      execution_failed = {}
      attempts.each do |row|
        next unless row["decision"] == "skipped"
        reason = row["reason"].to_s
        next unless %w[provider_rejected provider_expired].include?(reason)

        name = row["provider"].to_s
        next if name.empty?

        execution_failed[name] = true
      end

      policy_pack = context.respond_to?(:policy_pack) ? context.policy_pack : nil
      registry = PolicyRegistry.load(DEFAULT_ROUTING_POLICIES_PATH, policy_pack: policy_pack)
      active_goals = registry.active_policies.map(&:name)
      variances = []
      recorded_goals = {}

      # 1) Config-based targets: могут указывать на ineligible / execution-failed провайдеров.
      active_goals.each do |goal|
        target = config_target_for_goal(goal, providers)
        next if target.nil?

        target_name = target.payment_system.to_s
        next if target_name.empty?

        if execution_failed[target_name]
          variances << {
            "goal" => goal,
            "target_provider" => target_name,
            "cause" => "target_provider_execution_failed"
          }
          recorded_goals[goal] = true
          next
        end

        unless eligible_names.include?(target_name)
          variances << {
            "goal" => goal,
            "target_provider" => target_name,
            "cause" => "target_provider_ineligible"
          }
          recorded_goals[goal] = true
        end
      end

      # 2) Scoring-based conflicts среди eligible: soft-цель ведёт к другому кандидату,
      # которого router не выбрал и который не упал на execution.
      if eligible.any? && active_goals.any?
        scores = SoftGoalsScorer.score(eligible, operation: operation, state: state, policy_pack: policy_pack)
        selected_name = selected.payment_system.to_s

        scores_by_name = scores.each_with_object({}) do |score, acc|
          acc[score.provider.payment_system.to_s] = score
        end

        active_goals.each do |goal|
          next if recorded_goals[goal]

          best = scores.max_by do |score|
            part = score.parts[goal]
            [(part || 0.0), score.provider.payment_system.to_s]
          end
          next if best.nil?

          target_name = best.provider.payment_system.to_s
          next if target_name.empty?
          next if execution_failed[target_name]
          next unless eligible_names.include?(target_name)
          next if selected_name == target_name

          variances << {
            "goal" => goal,
            "target_provider" => target_name,
            "cause" => "higher_priority_goal_conflict"
          }
          recorded_goals[goal] = true
        end
      end

      validate_soft_goal_variances!(variances, path: registry.path)
      variances
    end

    def config_target_for_goal(goal, providers)
      case goal
      when "traffic_share"
        candidates = providers.select do |provider|
          SmartRouter.finite_number?(provider.traffic_percentage) &&
            provider.traffic_percentage.to_f.positive?
        end
        return nil if candidates.empty?

        candidates.max_by { |provider| [provider.traffic_percentage.to_f, provider.payment_system.to_s] }
      when "volume_share"
        candidates = providers.select do |provider|
          value = provider.volume_share_pct
          SmartRouter.finite_number?(value) && value.to_f.positive?
        end
        return nil if candidates.empty?

        candidates.max_by { |provider| [provider.volume_share_pct.to_f, provider.payment_system.to_s] }
      when "conversion_rate"
        candidates = providers.select do |provider|
          value = provider.conversion_24h
          SmartRouter.finite_number?(value) && value.to_f.positive?
        end
        return nil if candidates.empty?

        candidates.max_by { |provider| [provider.conversion_24h.to_f, provider.payment_system.to_s] }
      when "financial_commitment"
        candidates = providers.select do |provider|
          provider.limit_amount_min || provider.limit_amount_max || provider.daily_amount_limit
        end
        return nil if candidates.empty?

        candidates.max_by do |provider|
          daily_limit = provider.daily_amount_limit || 0.0
          min = provider.limit_amount_min
          max = provider.limit_amount_max
          range =
            if SmartRouter.finite_number?(min) && SmartRouter.finite_number?(max)
              max.to_f - min.to_f
            else
              0.0
            end
          [daily_limit.to_f, range.to_f, provider.payment_system.to_s]
        end
      else
        nil
      end
    end

    def validate_soft_goal_variances!(entries, path:)
      entries.each do |entry|
        unless entry.is_a?(Hash)
          raise InputError.new("soft_goal_variances entry must be an object", path: path)
        end

        goal = entry["goal"]
        cause = entry["cause"]

        if goal.nil? || goal.to_s.strip.empty?
          raise InputError.new("soft_goal_variances entry missing goal", path: path)
        end

        unless SOFT_GOAL_VARIANCE_CAUSES.include?(cause)
          raise InputError.new("invalid soft_goal_variances cause", path: path)
        end
      end
    end

    def copy_attempts(attempts)
      Array(attempts).map do |row|
        row.to_h.transform_keys(&:to_s).dup
      end
    end

    def latency_sec(provider)
      [provider.avg_latency_sec.to_i, 1].max
    end
  end
end
