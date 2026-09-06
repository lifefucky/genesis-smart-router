# frozen_string_literal: true

module SmartRouter
  # Read-only soft-goal context: actual traffic and volume shares by payment_system.
  # Share values are fractions in 0.0..1.0 (already normalized across providers).
  # Sources for the two maps may diverge later without changing strategy code.
  ShareState = Data.define(:traffic_shares, :volume_shares, :path) do
    def initialize(traffic_shares: {}, volume_shares: {}, path: "state")
      super(
        traffic_shares: self.class.normalize_share_map(
          traffic_shares, path: path, key: "traffic_shares"
        ),
        volume_shares: self.class.normalize_share_map(
          volume_shares, path: path, key: "volume_shares"
        ),
        path: path
      )
    end

    def self.coerce(state, default_path: "state")
      case state
      when nil
        new(path: default_path)
      when self
        state
      when Hash
        raw = state.transform_keys(&:to_s)
        new(
          traffic_shares: raw.fetch("traffic_shares", {}),
          volume_shares: raw.fetch("volume_shares", {}),
          path: raw["path"] || default_path
        )
      else
        unless state.respond_to?(:traffic_shares) && state.respond_to?(:volume_shares)
          raise InputError.new("soft-goal state must be a share map", path: default_path)
        end

        path = state.respond_to?(:path) && state.path ? state.path : default_path
        new(
          traffic_shares: state.traffic_shares,
          volume_shares: state.volume_shares,
          path: path
        )
      end
    end

    def self.normalize_share_map(value, path:, key:)
      return {}.freeze if value.nil?
      unless value.is_a?(Hash)
        raise InputError.new("#{key} must be an object", path: path)
      end

      value.each_with_object({}) do |(payment_system, share), acc|
        id = payment_system.to_s
        if id.strip.empty?
          raise InputError.new("invalid #{key} payment_system", path: path)
        end
        unless SmartRouter.finite_number?(share) && share >= 0.0 && share <= 1.0
          raise InputError.new(
            "invalid #{key} share for #{payment_system}",
            path: path
          )
        end
        if acc.key?(id)
          raise InputError.new("duplicate #{key} share for #{id}", path: path)
        end

        acc[id] = share.to_f
      end.freeze
    end
  end

  # Symmetric linear deficit/surplus: score = clamp(0.5 + (target_frac - actual), 0, 1).
  module ShareDeficit
    NEUTRAL = 0.5
    SLOPE = 1.0

    def self.score_share(target_pct:, shares:, payment_system:, field:, path:)
      target = normalize_target(target_pct, field: field, path: path)
      return NEUTRAL unless meaningful?(shares)
      return NEUTRAL if target.nil?

      actual = shares.fetch(payment_system.to_s, 0.0)
      apply(target, actual)
    end

    def self.meaningful?(shares)
      shares.is_a?(Hash) && shares.any? { |_key, value| value.to_f != 0.0 }
    end

    def self.normalize_target(value, field:, path:)
      return nil if value.nil?
      unless SmartRouter.finite_number?(value)
        raise InputError.new("invalid #{field} target share", path: path)
      end

      pct = value.to_f
      if pct.negative? || pct > 100.0
        raise InputError.new("invalid #{field} target share", path: path)
      end

      return nil if pct == 0.0

      pct
    end

    def self.apply(target_pct, actual)
      raw = NEUTRAL + (SLOPE * ((target_pct / 100.0) - actual.to_f))
      raw.clamp(0.0, 1.0)
    end
    private_class_method :apply
  end
end
