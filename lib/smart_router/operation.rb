# frozen_string_literal: true

module SmartRouter
  class Operation < Data.define(:operation_id, :created_at, :amount, :bank)
    REQUIRED_KEYS = %w[operation_id created_at amount bank].freeze

    def self.from_hash(hash, path:)
      unless hash.is_a?(Hash)
        raise InputError.new("operation must be an object", path: path)
      end

      row = hash.transform_keys(&:to_s)
      REQUIRED_KEYS.each do |key|
        value = row[key]
        if !row.key?(key) || value.nil? || (value.is_a?(String) && value.strip.empty?)
          raise InputError.new("missing #{key}", path: path)
        end
      end

      unless row["operation_id"].is_a?(String)
        raise InputError.new("missing operation_id", path: path)
      end
      unless row["bank"].is_a?(String)
        raise InputError.new("missing bank", path: path)
      end
      unless SmartRouter.finite_number?(row["amount"])
        raise InputError.new("amount is not numeric", path: path)
      end

      new(
        operation_id: row["operation_id"],
        created_at: parse_created_at(row["created_at"], path: path),
        amount: row["amount"],
        bank: row["bank"]
      )
    end

    def self.parse_created_at(value, path:)
      Time.iso8601(value)
    rescue ArgumentError, TypeError
      raise InputError.new("created_at is invalid", path: path)
    end
    private_class_method :parse_created_at
  end
end
