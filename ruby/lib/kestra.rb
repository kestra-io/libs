require "json"
require "logger"

# Sends outputs, metrics and logs from Ruby script tasks to Kestra.
# Each call prints one `::{...}::` line to stdout, which Kestra parses.
module Kestra
  VERSION = "0.1.0"

  # Kestra matches one line, and Java treats these as line terminators.
  LINE_TERMINATORS = { "\u0085" => "\\u0085", "\u2028" => "\\u2028", "\u2029" => "\\u2029" }.freeze
  LINE_TERMINATOR = Regexp.union(LINE_TERMINATORS.keys)

  # Ruby severities without a Kestra equivalent.
  LEVELS = { "FATAL" => "ERROR", "ANY" => "INFO" }.freeze

  class << self
    def format(map)
      "::#{JSON.generate(map).gsub(LINE_TERMINATOR, LINE_TERMINATORS)}::"
    end

    def outputs(outputs)
      unless outputs.is_a?(Hash) && !outputs.empty?
        raise ArgumentError, "Outputs must be a non-empty Hash, for example Kestra.outputs(rows: 42)."
      end

      send_message(outputs: outputs)
    end

    def counter(name, value, tags: {})
      send_metric(name, "counter", value, tags)
    end

    def gauge(name, value, tags: {})
      send_metric(name, "gauge", value, tags)
    end

    # Pass seconds, or a block that is timed and whose result is returned. No metric is sent if the block raises.
    def timer(name, seconds = nil, tags: {})
      unless block_given?
        raise ArgumentError, "Timer '#{name}' needs a duration in seconds or a block." if seconds.nil?

        return send_metric(name, "timer", seconds, tags)
      end
      raise ArgumentError, "Timer '#{name}' takes either seconds or a block, not both." unless seconds.nil?

      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      send_metric(name, "timer", Process.clock_gettime(Process::CLOCK_MONOTONIC) - start, tags)
      result
    end

    # A standard Logger, so it can be passed to any code that accepts one.
    def logger
      @logger ||= Logger.new($stdout, formatter: LogFormatter.new)
    end

    private

    def send_message(map)
      $stdout.puts(format(map))
      nil
    end

    def send_metric(name, type, value, tags)
      raise ArgumentError, "Metric name must be a non-empty String." unless name.is_a?(String) && !name.empty?
      unless value.is_a?(Numeric) && value.real? && value.finite?
        raise ArgumentError, "Metric '#{name}' value must be a finite number."
      end
      raise ArgumentError, "Metric '#{name}' tags must be a Hash, for example tags: { env: \"prod\" }." unless tags.is_a?(Hash)

      send_message(metrics: [{ name: name, type: type, value: value, tags: tags }])
    end
  end

  class LogFormatter < Logger::Formatter
    def call(severity, _time, _progname, msg)
      "#{Kestra.format(logs: [{ level: LEVELS.fetch(severity, severity), message: msg2str(msg) }])}\n"
    end
  end
end
