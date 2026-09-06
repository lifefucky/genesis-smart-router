# frozen_string_literal: true

module SmartRouter
  class ReportBuilder
    def self.build(records, providers, period:)
      new.build(records, providers, period: period)
    end

    def build(records, providers, period:)
      decisions = copy_records(records)
      catalog = Array(providers)
      total = decisions.length

      {
        "period" => period.to_s,
        "total_operations" => total,
        "distribution" => build_distribution(decisions, catalog, total),
        "skip_reasons" => build_skip_reasons(decisions),
        "projected_daily_utilization" => build_projected_daily_utilization(catalog),
        "recommendations" => build_recommendations(decisions, catalog)
      }
    end

    private

    def copy_records(records)
      Array(records).map { |row| stringify_hash(row) }
    end

    def stringify_hash(value)
      return {} unless value.respond_to?(:to_h)

      value.to_h.transform_keys(&:to_s)
    end

    def build_distribution(decisions, catalog, total)
      return {} if total.zero?

      counts = Hash.new(0)
      decisions.each do |row|
        name = row["selected_provider"].to_s
        next if name.empty?

        counts[name] += 1
      end

      catalog.each_with_object({}) do |provider, distribution|
        name = provider.payment_system.to_s
        next if name.empty? || distribution.key?(name)

        count = counts[name]
        target_pct = provider.traffic_percentage.to_f
        share_pct = (count * 100.0) / total
        signed_deviation = share_pct - target_pct

        distribution[name] = {
          "count" => count,
          "share_pct" => share_pct,
          "target_pct" => target_pct,
          "signed_deviation" => signed_deviation,
          "absolute_deviation" => signed_deviation.abs
        }
      end
    end

    def build_skip_reasons(decisions)
      tallies = Hash.new(0)

      decisions.each do |row|
        Array(row["attempts"]).each do |attempt|
          entry = stringify_hash(attempt)
          next unless entry["decision"] == "skipped"

          reason = entry["reason"].to_s
          next if reason.empty?

          tallies[reason] += 1
        end
      end

      tallies.keys.sort.each_with_object({}) do |reason, ordered|
        ordered[reason] = tallies[reason]
      end
    end

    def build_projected_daily_utilization(catalog)
      catalog.each_with_object({}) do |provider, result|
        name = provider.payment_system.to_s
        next if name.empty? || result.key?(name)

        limit = provider.daily_amount_limit
        unless finite_positive_number?(limit)
          result[name] = {
            "limit_amount" => nil,
            "used_amount" => nil,
            "utilization_pct" => nil
          }
          next
        end

        used = provider.daily_approved_amount.to_f + provider.in_progress_amount.to_f
        utilization = (used * 100.0) / limit

        result[name] = {
          "limit_amount" => limit,
          "used_amount" => used,
          "utilization_pct" => utilization
        }
      end
    end

    def build_recommendations(decisions, catalog)
      distribution = build_distribution(decisions, catalog, decisions.length)
      utilization = build_projected_daily_utilization(catalog)
      limit_recommendations = build_limit_pressure_recommendations(utilization)
      share_recommendations = build_share_deviation_recommendations(distribution)

      (limit_recommendations + share_recommendations).sort_by do |entry|
        [entry.fetch("provider"), entry.fetch("type"), entry.fetch("reason")]
      end
    end

    def build_limit_pressure_recommendations(utilization)
      threshold = 90.0

      utilization.each_with_object([]) do |(name, stats), recs|
        pct = stats["utilization_pct"]
        limit = stats["limit_amount"]
        used = stats["used_amount"]

        next unless finite_positive_number?(limit) && finite_positive_number?(pct) && pct >= threshold

        recs << {
          "provider" => name,
          "type" => "limit_pressure",
          "reason" => "near_daily_limit",
          "evidence" => {
            "utilization_pct" => pct,
            "limit_amount" => limit,
            "used_amount" => used
          },
          "message" => "Провайдер #{name} использует #{pct.round(2)}% дневного лимита (#{used} из #{limit}). Рассмотрите снижение traffic_percentage или увеличение лимита."
        }
      end
    end

    def build_share_deviation_recommendations(distribution)
      threshold = 10.0

      distribution.each_with_object([]) do |(name, stats), recs|
        share = stats["share_pct"]
        target = stats["target_pct"]
        signed = stats["signed_deviation"]

        next unless finite_number?(share) && finite_number?(target) && finite_number?(signed)
        next unless signed.abs > threshold

        if signed > threshold
          recs << {
            "provider" => name,
            "type" => "share_deviation",
            "reason" => "over_target_share",
            "evidence" => {
              "share_pct" => share,
              "target_pct" => target,
              "signed_deviation" => signed
            },
            "message" => "Фактическая доля провайдера #{name} (#{share.round(2)}%) значительно выше целевой (#{target.round(2)}%). Рассмотрите снижение traffic_percentage или пересмотр стратегии."
          }
        elsif signed < -threshold
          recs << {
            "provider" => name,
            "type" => "share_deviation",
            "reason" => "under_target_share",
            "evidence" => {
              "share_pct" => share,
              "target_pct" => target,
              "signed_deviation" => signed
            },
            "message" => "Фактическая доля провайдера #{name} (#{share.round(2)}%) значительно ниже целевой (#{target.round(2)}%). Рассмотрите повышение traffic_percentage или пересмотр стратегии распределения трафика."
          }
        end
      end
    end

    def finite_positive_number?(value)
      value.is_a?(Numeric) && value.finite? && value.positive?
    end

    def finite_number?(value)
      value.is_a?(Numeric) && value.finite?
    end
  end
end
