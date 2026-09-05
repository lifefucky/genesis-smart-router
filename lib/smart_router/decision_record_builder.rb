# frozen_string_literal: true

module SmartRouter
  class DecisionRecordBuilder
    def self.build(context)
      new.build(context)
    end

    def build(context)
      operation = context.operation
      provider = context.selected_provider
      if operation.nil? || provider.nil?
        raise InputError.new("decision record requires a selected provider")
      end

      {
        "operation_id" => operation.operation_id,
        "selected_provider" => provider.payment_system,
        "attempts" => copy_attempts(context.attempts),
        "simulated_result" => self.class.simulate_result(operation, provider),
        "latency_sec" => latency_sec(provider)
      }
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
