# frozen_string_literal: true

module SmartRouter
  class Provider
    REQUIRED_KEYS = %w[
      payment_system
      status
      priority
      traffic_percentage
      limit_amount_min
      limit_amount_max
      daily_amount_limit
      daily_approved_amount
      in_progress_count_limit
      in_progress_count
      in_progress_amount_limit
      in_progress_amount
      available_requisites
      conversion_24h
      avg_latency_sec
      banks
      exclude_banks
      provider_margin_pct
      merchant_margin_pct
      allow_negative_agreement
    ].freeze

    LIMIT_KEYS = %w[
      limit_amount_min
      limit_amount_max
      daily_amount_limit
      in_progress_count_limit
      in_progress_amount_limit
    ].freeze

    NUMERIC_KEYS = %w[
      priority
      traffic_percentage
      daily_approved_amount
      in_progress_count
      in_progress_amount
      available_requisites
      conversion_24h
      avg_latency_sec
      provider_margin_pct
      merchant_margin_pct
    ].freeze

    BOOLEAN_KEYS = %w[exclude_banks allow_negative_agreement].freeze

    attr_reader :payment_system, :status, :priority, :traffic_percentage,
                :limit_amount_min, :limit_amount_max, :daily_amount_limit,
                :daily_approved_amount, :in_progress_count_limit, :in_progress_count,
                :in_progress_amount_limit, :in_progress_amount, :available_requisites,
                :conversion_24h, :avg_latency_sec, :banks, :exclude_banks,
                :provider_margin_pct, :merchant_margin_pct, :allow_negative_agreement,
                :note

    def self.from_hash(hash, path:)
      unless hash.is_a?(Hash)
        raise InputError.new("provider must be an object", path: path)
      end

      raw = hash.transform_keys(&:to_s)
      missing = REQUIRED_KEYS.reject { |key| raw.key?(key) }
      if missing.any?
        raise InputError.new("missing provider keys (#{missing.join(', ')})", path: path)
      end

      require_present_string(raw["payment_system"], "payment_system", path: path)
      require_present_string(raw["status"], "status", path: path)
      LIMIT_KEYS.each { |key| require_optional_number(raw[key], key, path: path) }
      NUMERIC_KEYS.each { |key| require_number(raw[key], key, path: path) }
      unless raw["banks"].is_a?(Array)
        raise InputError.new("banks must be an array", path: path)
      end
      BOOLEAN_KEYS.each { |key| require_boolean(raw[key], key, path: path) }

      new(raw)
    end

    def initialize(attrs)
      raw = attrs.transform_keys(&:to_s)
      @payment_system = raw.fetch("payment_system")
      @status = raw.fetch("status")
      @priority = raw.fetch("priority")
      @traffic_percentage = raw.fetch("traffic_percentage")
      @limit_amount_min = raw.fetch("limit_amount_min")
      @limit_amount_max = raw.fetch("limit_amount_max")
      @daily_amount_limit = raw.fetch("daily_amount_limit")
      @daily_approved_amount = raw.fetch("daily_approved_amount")
      @in_progress_count_limit = raw.fetch("in_progress_count_limit")
      @in_progress_count = raw.fetch("in_progress_count")
      @in_progress_amount_limit = raw.fetch("in_progress_amount_limit")
      @in_progress_amount = raw.fetch("in_progress_amount")
      @available_requisites = raw.fetch("available_requisites")
      @conversion_24h = raw.fetch("conversion_24h")
      @avg_latency_sec = raw.fetch("avg_latency_sec")
      @banks = raw.fetch("banks").dup
      @exclude_banks = raw.fetch("exclude_banks")
      @provider_margin_pct = raw.fetch("provider_margin_pct")
      @merchant_margin_pct = raw.fetch("merchant_margin_pct")
      @allow_negative_agreement = raw.fetch("allow_negative_agreement")
      @note = raw["note"]
    end

    def dup
      self.class.new(
        "payment_system" => payment_system,
        "status" => status,
        "priority" => priority,
        "traffic_percentage" => traffic_percentage,
        "limit_amount_min" => limit_amount_min,
        "limit_amount_max" => limit_amount_max,
        "daily_amount_limit" => daily_amount_limit,
        "daily_approved_amount" => daily_approved_amount,
        "in_progress_count_limit" => in_progress_count_limit,
        "in_progress_count" => in_progress_count,
        "in_progress_amount_limit" => in_progress_amount_limit,
        "in_progress_amount" => in_progress_amount,
        "available_requisites" => available_requisites,
        "conversion_24h" => conversion_24h,
        "avg_latency_sec" => avg_latency_sec,
        "banks" => banks,
        "exclude_banks" => exclude_banks,
        "provider_margin_pct" => provider_margin_pct,
        "merchant_margin_pct" => merchant_margin_pct,
        "allow_negative_agreement" => allow_negative_agreement,
        "note" => note
      )
    end

    def write_tracked_metrics(in_progress_count, in_progress_amount,
                              daily_approved_amount, available_requisites)
      @in_progress_count = in_progress_count
      @in_progress_amount = in_progress_amount
      @daily_approved_amount = daily_approved_amount
      @available_requisites = available_requisites
    end
    private :write_tracked_metrics

    def self.require_present_string(value, field, path:)
      return if value.is_a?(String) && !value.strip.empty?

      raise InputError.new("missing #{field}", path: path)
    end
    private_class_method :require_present_string

    def self.require_optional_number(value, field, path:)
      return if value.nil? || SmartRouter.finite_number?(value)

      raise InputError.new("#{field} is not numeric", path: path)
    end
    private_class_method :require_optional_number

    def self.require_number(value, field, path:)
      return if SmartRouter.finite_number?(value)

      raise InputError.new("#{field} is not numeric", path: path)
    end
    private_class_method :require_number

    def self.require_boolean(value, field, path:)
      return if value == true || value == false

      raise InputError.new("#{field} must be a boolean", path: path)
    end
    private_class_method :require_boolean
  end
end
