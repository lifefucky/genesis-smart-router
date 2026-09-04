# frozen_string_literal: true

module SmartRouter
  HistoryRecord = Data.define(
    :operation_id,
    :created_at,
    :amount,
    :bank,
    :payment_system,
    :status,
    :latency_sec
  )

  class RunInputs
    REQUIRED_HISTORY_HEADERS = %w[
      operation_id created_at amount bank payment_system status latency_sec
    ].freeze

    attr_reader :providers, :operations, :history

    def self.load(
      providers_path: DEFAULT_PROVIDERS_PATH,
      queue_path: DEFAULT_QUEUE_PATH,
      history_path: DEFAULT_HISTORY_PATH
    )
      new(
        providers: RoutingConfig.load(providers_path),
        operations: load_operations(queue_path),
        history: load_history(history_path)
      )
    end

    def initialize(providers:, operations:, history:)
      @providers = providers
      @operations = operations
      @history = history
    end

    def self.load_operations(path)
      case SmartRouter.read_json(path)
      in Array => rows
        rows.map { |row| Operation.from_hash(row, path: path) }
      else
        raise InputError.new("operations queue must be a JSON array", path: path)
      end
    end
    private_class_method :load_operations

    def self.load_history(path)
      rows =
        begin
          CSV.parse(
            SmartRouter.read_file(path),
            headers: true,
            header_converters: ->(header) { header.to_s.strip }
          )
        rescue CSV::MalformedCSVError, ArgumentError, EncodingError => e
          raise InputError.new("invalid CSV (#{e.message})", path: path)
        end

      headers = Array(rows.headers)
      if headers.empty? || (REQUIRED_HISTORY_HEADERS - headers).any?
        raise InputError.new("CSV headers are missing", path: path)
      end

      rows.map { |row| parse_history_row(row, path: path) }
    end
    private_class_method :load_history

    def self.parse_history_row(row, path:)
      values = REQUIRED_HISTORY_HEADERS.to_h { |key| [key, row[key]] }
      values.each do |key, value|
        if value.nil? || value.to_s.strip.empty?
          raise InputError.new("missing #{key}", path: path)
        end
      end

      HistoryRecord.new(
        operation_id: values["operation_id"],
        created_at: parse_iso8601(values["created_at"], path: path),
        amount: parse_csv_numeric(values["amount"], path: path, field: "amount"),
        bank: values["bank"],
        payment_system: values["payment_system"],
        status: values["status"],
        latency_sec: parse_csv_numeric(values["latency_sec"], path: path, field: "latency_sec")
      )
    end
    private_class_method :parse_history_row

    def self.parse_iso8601(value, path:)
      Time.iso8601(value)
    rescue ArgumentError, TypeError
      raise InputError.new("created_at is invalid", path: path)
    end
    private_class_method :parse_iso8601

    def self.parse_csv_numeric(value, path:, field:)
      stripped = value.to_s.strip
      number =
        begin
          Integer(stripped, 10)
        rescue ArgumentError
          Float(stripped)
        end
      unless SmartRouter.finite_number?(number)
        raise InputError.new("#{field} is not numeric", path: path)
      end
      number
    rescue ArgumentError
      raise InputError.new("#{field} is not numeric", path: path)
    end
    private_class_method :parse_csv_numeric
  end
end
