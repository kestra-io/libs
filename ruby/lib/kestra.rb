require "json"
require "logger"
require "time"

# Sends outputs, metrics, logs and assets from Ruby script tasks to Kestra, and reads the execution context.
# Each send call prints one `::{...}::` line to stdout, which Kestra parses.
module Kestra
  # Kestra matches one line, and Java treats these as line terminators.
  LINE_TERMINATORS = { "\u0085" => "\\u0085", "\u2028" => "\\u2028", "\u2029" => "\\u2029" }.freeze
  LINE_TERMINATOR = Regexp.union(LINE_TERMINATORS.keys)

  CONTEXT_FILE = ".kestra-execution-context.json"

  # Also stops a structure that contains itself.
  MAX_DEPTH = 100

  # Ruby severities without a Kestra equivalent.
  LEVELS = { "FATAL" => "ERROR", "ANY" => "INFO" }.freeze

  @context_json = nil

  class << self
    def format(map)
      "::#{JSON.generate(map).gsub(LINE_TERMINATOR, LINE_TERMINATORS)}::"
    end

    # Empty outputs send nothing.
    def outputs(outputs)
      raise ArgumentError, "Outputs must be a Hash, for example Kestra.outputs(rows: 42)." unless outputs.is_a?(Hash)

      send_message(outputs: outputs) unless outputs.empty?
    end

    # Empty assets send nothing.
    def assets(assets)
      unless assets.is_a?(Hash)
        raise ArgumentError, "Assets must be a Hash, for example Kestra.assets(outputs: [{ id: \"sales.orders\", type: \"TABLE\" }])."
      end

      assets.each do |key, value|
        raise ArgumentError, "Assets hold only inputs and outputs, not '#{key}'." unless %w[inputs outputs].include?(key.to_s)
        unless value.is_a?(Array)
          raise ArgumentError, "Asset #{key} must be an Array, for example [{ id: \"sales.orders\", type: \"TABLE\" }]."
        end
      end
      send_message(assets: assets) unless assets.empty?
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

      # Checked before the block runs, so a typo does not cost a long run.
      metric_tags(name, tags)
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
    # An empty path counts as none. Only a missing file falls back: a directory or an unreadable file raises its read error.
    def context(path = nil)
      path = nil if path == ""
      return JSON.parse(@context_json) if path.nil? && @context_json

      env_file = ENV.fetch("KESTRA_EXECUTION_CONTEXT_FILE", "")
      file = path || (env_file.empty? ? CONTEXT_FILE : env_file)
      encoded = ENV.fetch("KESTRA_CONTEXT", "")
      source = file
      json = if File.exist?(file)
               File.read(file, encoding: "UTF-8")
             elsif path.nil? && !encoded.empty?
               source = "KESTRA_CONTEXT"
               begin
                 encoded.gsub(/\s/, "").unpack1("m0").force_encoding("UTF-8")
               rescue ArgumentError
                 raise ArgumentError, "The KESTRA_CONTEXT environment variable is not valid base64."
               end
             elsif path
               raise Errno::ENOENT, "Kestra execution context file '#{file}' does not exist."
             else
               raise Errno::ENOENT, "No Kestra execution context found: '#{file}' does not exist and the KESTRA_CONTEXT " \
                                    "environment variable is not set. The execution context is only available when the script runs inside a Kestra task."
             end
      context = begin
        JSON.parse(json)
      rescue JSON::ParserError => e
        raise JSON::ParserError, "The execution context in #{source} is not valid JSON (#{e.message})."
      end
      raise JSON::ParserError, "The execution context in #{source} is not a JSON object." unless context.is_a?(Hash)

      @context_json = json if path.nil?
      context
    end

    private

    def send_message(map)
      Output.write("#{format(json_value(map, 0))}\n")
      nil
    rescue JSON::NestingError
      raise ArgumentError, "This value cannot be sent to Kestra as JSON: it is nested more than #{MAX_DEPTH} levels deep or contains itself."
    rescue JSON::GeneratorError
      raise ArgumentError, "This value cannot be sent to Kestra as JSON: make strings valid UTF-8, for example with String#scrub."
    end

    # A copy with String keys and Times as ISO 8601 text, after checking what JSON.generate would send wrong or fail on.
    def json_value(value, depth)
      if depth > MAX_DEPTH
        raise ArgumentError, "This value cannot be sent to Kestra as JSON: it is nested more than #{MAX_DEPTH} levels deep or contains itself."
      end

      case value
      when Hash
        value.each_with_object({}) do |(key, item), copy|
          text = key.to_s
          # 1 and "1", or :a and "a", are distinct keys that read as the same JSON key.
          raise ArgumentError, "This value cannot be sent to Kestra as JSON: two keys read as '#{text}'." if copy.key?(text)

          copy[text] = json_value(item, depth + 1)
        end
      when Array then value.map { |item| json_value(item, depth + 1) }
      when Float
        raise ArgumentError, "This value cannot be sent to Kestra as JSON: replace NaN and Infinity with nil." unless value.finite?

        value
      when Time then value.iso8601(value.subsec.zero? ? 0 : 6)
      else value
      end
    end

    def send_metric(name, type, value, tags)
      string_tags = metric_tags(name, tags)
      unless value.is_a?(Numeric) && value.real? && value.finite?
        raise ArgumentError, "Metric '#{name}' value must be a finite number."
      end

      # JSON writes BigDecimal and Rational as strings.
      value = value.to_f unless value.is_a?(Integer)
      send_message(metrics: [{ name: name, type: type, value: value, tags: string_tags }])
    end

    # Checks the name and returns the tags as strings, since Kestra reads tags as a map of strings.
    def metric_tags(name, tags)
      raise ArgumentError, "Metric name must be a non-empty String." unless name.is_a?(String) && !name.empty?
      raise ArgumentError, "Metric '#{name}' tags must be a Hash, for example tags: { env: \"prod\" }." unless tags.is_a?(Hash)

      tags.each_with_object({}) do |(key, tag), string_tags|
        if tag.nil? || tag.is_a?(Enumerable)
          raise ArgumentError, "Metric '#{name}' tag '#{key}' must be a single value, for example tags: { env: \"prod\" }."
        end

        text = key.to_s
        raise ArgumentError, "Metric '#{name}' has two tags named '#{text}'." if string_tags.key?(text)

        string_tags[text] = tag.to_s
      end
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
      message = text(msg)
      message = message.dup.force_encoding(Encoding::UTF_8) if message.encoding == Encoding::BINARY
      message = message.encode(Encoding::UTF_8, invalid: :replace, undef: :replace).scrub
      "#{Kestra.format(logs: [{ level: LEVELS.fetch(severity, severity), message: message }])}\n"
    end

    private

    # An inspect or message method can raise or return a non-String, and a log call must not fail.
    def text(msg)
      text = begin
        msg2str(msg)
      rescue StandardError
        nil
      end
      return text if text.is_a?(String)

      begin
        "#<#{msg.class}>"
      rescue StandardError
        "#<BasicObject>"
      end
    end
  end
end
