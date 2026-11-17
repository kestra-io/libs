require "minitest/autorun"
require "json"
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
    lines = emitted do
      logger = Logger.new($stdout, formatter: Kestra::LogFormatter.new)
      logger.debug("caf\u00e9")
      logger.warn("3 rows skipped")
      logger.fatal("boom")
    end

    assert_equal [%(::{"logs":[{"level":"DEBUG","message":"caf\u00e9"}]}::),
                  '::{"logs":[{"level":"WARN","message":"3 rows skipped"}]}::',
                  '::{"logs":[{"level":"ERROR","message":"boom"}]}::'], lines
  end
end
