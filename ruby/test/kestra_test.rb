require "minitest/autorun"
require "json"
require "tmpdir"
require "bigdecimal"
require "kestra"

class KestraTest < Minitest::Test
  def emitted(&block)
    out, = capture_io(&block)
    out.lines.map(&:chomp)
  end

  def payload(line)
    assert_match(/\A::\{.*\}::\z/, line)
    JSON.parse(line[2..-3])
  end

  def test_outputs_are_one_line_with_nested_values
    lines = emitted { Kestra.outputs(accuracy: 0.912345678, model: "glm", ids: [1, 2], nested: { ok: true }, missing: nil) }

    assert_equal ['::{"outputs":{"accuracy":0.912345678,"model":"glm","ids":[1,2],"nested":{"ok":true},"missing":null}}::'], lines
  end

  def test_multi_line_strings_and_java_line_terminators_stay_on_one_line
    text = "a\nb\u2028c\u2029d\u0085e"
    lines = emitted { Kestra.outputs(text: text) }

    assert_equal 1, lines.size
    assert_includes lines.first, 'a\nb\u2028c\u2029d\u0085e'
    assert_equal text, payload(lines.first)["outputs"]["text"]
  end

  def test_values_json_cannot_encode_fail_with_a_plain_sentence
    error = assert_raises(ArgumentError) { Kestra.outputs(score: Float::NAN) }
    assert_match(/cannot be sent to Kestra as JSON.*Replace NaN and Infinity with nil/, error.message)
    assert_raises(ArgumentError) { Kestra.outputs(body: "bad \xff") }
  end

  def test_outputs_must_be_a_non_empty_hash
    assert_raises(ArgumentError) { Kestra.outputs({}) }
    assert_raises(ArgumentError) { Kestra.outputs([1, 2]) }
  end

  def test_metrics_default_to_empty_tags_and_accept_tags
    assert_equal ['::{"metrics":[{"name":"rows","type":"counter","value":15000,"tags":{}}]}::'],
                 emitted { Kestra.counter("rows", 15000) }
    assert_equal ['::{"metrics":[{"name":"queue","type":"gauge","value":3,"tags":{"env":"prod"}}]}::'],
                 emitted { Kestra.gauge("queue", 3, tags: { env: "prod" }) }
  end

  def test_metrics_reject_invalid_input
    assert_raises(ArgumentError) { Kestra.counter("", 1) }
    assert_raises(ArgumentError) { Kestra.gauge("queue", Float::NAN) }
    assert_raises(ArgumentError) { Kestra.gauge("queue", "3") }
    assert_raises(ArgumentError) { Kestra.counter("rows", 1, tags: ["a"]) }
  end

  def test_timer_times_a_block_and_returns_its_result
    result = nil
    lines = emitted { result = Kestra.timer("fit") { sleep 0.2; 42 } }

    assert_equal 42, result
    metric = payload(lines.first)["metrics"].first
    assert_equal "timer", metric["type"]
    assert_operator metric["value"], :>=, 0.2
  end

  def test_timer_needs_exactly_one_of_seconds_or_block
    assert_equal ['::{"metrics":[{"name":"export","type":"timer","value":2.5,"tags":{}}]}::'],
                 emitted { Kestra.timer("export", 2.5) }
    assert_raises(ArgumentError) { Kestra.timer("export") }
    assert_raises(ArgumentError) { Kestra.timer("export", 1) { 1 } }
  end

  def test_logger_maps_ruby_severities_to_kestra_levels
    Kestra.instance_variable_set(:@logger, nil)
    lines = emitted do
      Kestra.logger.debug("caf\u00e9")
      Kestra.logger.warn("3 rows skipped")
      Kestra.logger.fatal("boom")
      Kestra.logger.info("bad \xff byte")
    end

    assert_equal [%(::{"logs":[{"level":"DEBUG","message":"caf\u00e9"}]}::),
                  '::{"logs":[{"level":"WARN","message":"3 rows skipped"}]}::',
                  '::{"logs":[{"level":"ERROR","message":"boom"}]}::',
                  %(::{"logs":[{"level":"INFO","message":"bad \ufffd byte"}]}::)], lines
  end

  def test_logger_follows_stdout_when_it_is_replaced
    Kestra.logger
    assert_equal ['::{"logs":[{"level":"INFO","message":"later"}]}::'], emitted { Kestra.logger.info("later") }
  end

  def test_metric_values_are_numbers_and_tags_are_strings
    lines = emitted do
      Kestra.gauge("ratio", Rational(1, 4), tags: { shard: 2, primary: true })
      Kestra.gauge("price", BigDecimal("1.5"))
    end

    assert_equal ['::{"metrics":[{"name":"ratio","type":"gauge","value":0.25,"tags":{"shard":"2","primary":"true"}}]}::',
                  '::{"metrics":[{"name":"price","type":"gauge","value":1.5,"tags":{}}]}::'], lines
    assert_raises(ArgumentError) { Kestra.gauge("queue", 1, tags: { a: [1] }) }
    assert_raises(ArgumentError) { Kestra.gauge("queue", 1, tags: { a: nil }) }
  end

  def test_timer_is_sent_when_the_block_returns_early
    timed = lambda do
      Kestra.timer("early") { return 5 }
      6
    end
    result = nil
    lines = emitted { result = timed.call }

    assert_equal 5, result
    assert_equal "early", payload(lines.first)["metrics"].first["name"]
  end

  def test_concurrent_calls_write_whole_lines
    lines = emitted do
      8.times.map { |i| Thread.new { 200.times { Kestra.outputs(i: i) } } }.each(&:join)
    end

    assert_equal 1600, lines.size
    lines.each { |line| payload(line) }
  end

  def test_assets_are_sent_as_given
    assets = { inputs: [{ id: "raw.orders" }], outputs: [{ id: "sales.orders", type: "TABLE", metadata: { owner: "team_a" } }] }

    assert_equal ['::{"assets":{"inputs":[{"id":"raw.orders"}],"outputs":[{"id":"sales.orders","type":"TABLE","metadata":{"owner":"team_a"}}]}}::'],
                 emitted { Kestra.assets(assets) }
    assert_raises(ArgumentError) { Kestra.assets({}) }
  end

  def with_context
    Dir.mktmpdir do |dir|
      file = File.join(dir, "context.json")
      File.write(file, '{"labels":{"env":"prod"},"inputs":{"text":"a\\nb caf\\u00e9"}}')
      saved = %w[KESTRA_EXECUTION_CONTEXT_FILE KESTRA_CONTEXT].to_h { |key| [key, ENV.fetch(key, nil)] }
      ENV["KESTRA_EXECUTION_CONTEXT_FILE"] = file
      ENV.delete("KESTRA_CONTEXT")
      Kestra.instance_variable_set(:@context_json, nil)
      yield file, dir
    ensure
      saved.each { |key, value| ENV[key] = value }
      Kestra.instance_variable_set(:@context_json, nil)
    end
  end

  def test_context_is_read_from_the_file_once
    with_context do |file|
      context = Kestra.context
      assert_equal "prod", context["labels"]["env"]
      assert_equal "a\nb caf\u00e9", context["inputs"]["text"]

      File.delete(file)
      context["labels"]["env"] = "changed"
      assert_equal "prod", Kestra.context["labels"]["env"]
    end
  end

  def test_context_from_an_explicit_path_or_base64_variable
    with_context do |file, dir|
      assert_equal "prod", Kestra.context(file)["labels"]["env"]

      ENV["KESTRA_EXECUTION_CONTEXT_FILE"] = File.join(dir, "missing.json")
      ENV["KESTRA_CONTEXT"] = ['{"vars":{"n":42}}'].pack("m0")
      assert_equal 42, Kestra.context["vars"]["n"]
    end
  end

  def test_explicit_path_never_falls_back_to_the_variable
    with_context do |_file, dir|
      ENV["KESTRA_CONTEXT"] = ['{"vars":{"n":42}}'].pack("m0")
      assert_raises(Errno::ENOENT) { Kestra.context(File.join(dir, "typo.json")) }
    end
  end

  def test_empty_file_variable_means_the_default_file
    with_context do |file, dir|
      ENV["KESTRA_EXECUTION_CONTEXT_FILE"] = ""
      Dir.chdir(dir) do
        File.rename(file, Kestra::CONTEXT_FILE)
        assert_equal "prod", Kestra.context["labels"]["env"]
      end
    end
  end

  def test_context_that_is_not_an_object_names_the_source
    with_context do |file|
      ["", "null", "[1]", "{"].each do |content|
        File.write(file, content)
        error = assert_raises(JSON::ParserError) { Kestra.context(file) }
        assert_includes error.message, file
      end
    end
  end

  def test_context_fails_clearly_outside_kestra
    with_context do |_file, dir|
      ENV["KESTRA_EXECUTION_CONTEXT_FILE"] = File.join(dir, "missing.json")
      error = assert_raises(Errno::ENOENT) { Kestra.context }
      assert_match(/No Kestra execution context found/, error.message)
    end
  end
end
