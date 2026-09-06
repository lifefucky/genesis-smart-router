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
        "skip_reasons" => build_skip_reasons(decisions)
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
  end
end
