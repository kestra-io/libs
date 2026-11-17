require "json"
require "logger"

# Sends outputs, metrics, logs and assets from Ruby script tasks to Kestra, and reads the execution context.
# Each send call prints one `::{...}::` line to stdout, which Kestra parses.
module Kestra
  # Kestra matches one line, and Java treats these as line terminators.
  LINE_TERMINATORS = { "\u0085" => "\\u0085", "\u2028" => "\\u2028", "\u2029" => "\\u2029" }.freeze
  LINE_TERMINATOR = Regexp.union(LINE_TERMINATORS.keys)

  CONTEXT_FILE = ".kestra-execution-context.json"

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

    def assets(assets)
      unless assets.is_a?(Hash) && !assets.empty?
        raise ArgumentError, "Assets must be a non-empty Hash, for example Kestra.assets(outputs: [{ id: \"sales.orders\", type: \"TABLE\" }])."
      end

      send_message(assets: assets)
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
      begin
        yield
      rescue Exception
        raised = true
        raise
      ensure
        # Also sent when the block leaves with return, break or throw.
        send_metric(name, "timer", Process.clock_gettime(Process::CLOCK_MONOTONIC) - start, tags) unless raised
      end
    end

    # A standard Logger, so it can be passed to any code that accepts one.
    def logger
      @logger ||= Logger.new(Output, formatter: LogFormatter.new)
    end

    # The execution context as a Hash, read from path, KESTRA_EXECUTION_CONTEXT_FILE or .kestra-execution-context.json
    # (written when the task sets executionContext: true). Without a path, falls back to the base64 KESTRA_CONTEXT variable.
    # The default context is read once, and each call returns a new Hash the caller may change. Raises Errno::ENOENT outside a Kestra task.
    def context(path = nil)
      return JSON.parse(@context_json) if path.nil? && @context_json

      env_file = ENV.fetch("KESTRA_EXECUTION_CONTEXT_FILE", "")
      file = path || (env_file.empty? ? CONTEXT_FILE : env_file)
      encoded = ENV.fetch("KESTRA_CONTEXT", "")
      json = if File.file?(file)
               File.read(file, encoding: "UTF-8")
             elsif path.nil? && !encoded.empty?
               encoded.unpack1("m").force_encoding("UTF-8")
             elsif path
               raise Errno::ENOENT, "Kestra execution context file '#{file}' does not exist."
             else
               raise Errno::ENOENT, "No Kestra execution context found: '#{file}' does not exist and the KESTRA_CONTEXT " \
                                    "environment variable is not set. The execution context is only available when the script runs inside a Kestra task."
             end
      source = File.file?(file) ? file : "KESTRA_CONTEXT"
      context = begin
        JSON.parse(json)
      rescue JSON::ParserError
        nil
      end
      raise JSON::ParserError, "The execution context in #{source} is not a JSON object." unless context.is_a?(Hash)

      @context_json = json if path.nil?
      context
    end

    private

    def send_message(map)
      Output.write("#{format(map)}\n")
      nil
    rescue JSON::GeneratorError => e
      raise ArgumentError, "This value cannot be sent to Kestra as JSON (#{e.message}). Replace NaN and Infinity with nil, " \
                           "and make strings valid UTF-8, for example with String#scrub."
    end

    def send_metric(name, type, value, tags)
      raise ArgumentError, "Metric name must be a non-empty String." unless name.is_a?(String) && !name.empty?
      unless value.is_a?(Numeric) && value.real? && value.finite?
        raise ArgumentError, "Metric '#{name}' value must be a finite number."
      end
      raise ArgumentError, "Metric '#{name}' tags must be a Hash, for example tags: { env: \"prod\" }." unless tags.is_a?(Hash)

      # JSON writes BigDecimal and Rational as strings, and Kestra reads tags as a map of strings.
      value = value.to_f unless value.is_a?(Integer)
      tags = tags.to_h do |key, tag|
        if tag.nil? || tag.is_a?(Hash) || tag.is_a?(Array)
          raise ArgumentError, "Metric '#{name}' tag '#{key}' must be a single value, for example tags: { env: \"prod\" }."
        end

        [key.to_s, tag.to_s]
      end
      send_message(metrics: [{ name: name, type: type, value: value, tags: tags }])
    end
  end

  # Writes to the current $stdout and flushes each line, so Kestra gets every line when it is written,
  # not at exit, and lines from several threads never merge.
  module Output
    MUTEX = Mutex.new

    def self.write(line)
      MUTEX.synchronize do
        $stdout.write(line)
        $stdout.flush
      end
    end

    def self.close; end
  end

  class LogFormatter < Logger::Formatter
    def call(severity, _time, _progname, msg)
      # Binary strings (Net::HTTP bodies, File.binread) usually hold UTF-8, so read them as UTF-8.
      # Invalid bytes become U+FFFD, so a log call never fails.
      message = msg2str(msg)
      message = message.dup.force_encoding(Encoding::UTF_8) if message.encoding == Encoding::BINARY
      message = message.encode(Encoding::UTF_8, invalid: :replace, undef: :replace).scrub
      "#{Kestra.format(logs: [{ level: LEVELS.fetch(severity, severity), message: message }])}\n"
    end
  end
end
