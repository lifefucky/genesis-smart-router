# frozen_string_literal: true

module SmartRouter
  class RoutingConfig
    def self.load(path = DEFAULT_PROVIDERS_PATH)
      data = SmartRouter.read_json(path)
      providers = data.is_a?(Hash) ? data["providers"] : nil

      case providers
      in []
        raise InputError.new("providers catalog is empty", path: path)
      in Array => rows
        rows.map { |row| Provider.from_hash(row, path: path) }
      else
        raise InputError.new("providers catalog is invalid", path: path)
      end
    end
  end
end
