-- Run from the lua directory: lua test/kestra_test.lua
local unpack = table.unpack or unpack

local tests, failures = {}, 0

local function test(name, body) tests[#tests + 1] = { name = name, body = body } end

local function eq(actual, expected)
  if actual ~= expected then
    error(string.format('expected %q, got %q', tostring(expected), tostring(actual)), 2)
  end
end

local function fresh()
  package.loaded.kestra = nil
  return require('kestra')
end

-- Runs fn with stdout captured, and returns the written text and the flush count.
local function capture(fn)
  local real, written, flushes = io.stdout, {}, 0
  io.stdout = {
    write = function(self, ...) for _, part in ipairs({ ... }) do written[#written + 1] = part end return self end,
    flush = function() flushes = flushes + 1 end,
  }
  local ok, err = pcall(fn)
  io.stdout = real
  if not ok then error(err, 0) end
  return table.concat(written), flushes
end

local function error_of(fn)
  local ok, err = pcall(fn)
  if ok then error('expected an error', 2) end
  return err
end

-- Runs fn with os.getenv answering from env.
local function with_env(env, fn)
  local real = os.getenv
  os.getenv = function(name) return env[name] end
  local ok, err = pcall(fn)
  os.getenv = real
  if not ok then error(err, 0) end
end

local function write_file(path, content)
  local file = assert(io.open(path, 'wb'))
  file:write(content)
  file:close()
  return path
end

local kestra = fresh()

test('outputs send one flushed line with nested values and sorted keys', function()
  local line, flushes = capture(function()
    kestra.outputs({ rows = 42, ratio = 0.1, ok = true, nested = { list = { 1, 'two', { a = false } } } })
  end)
  eq(line, '::{"outputs":{"nested":{"list":[1,"two",{"a":false}]},"ok":true,"ratio":0.1,"rows":42}}::\n')
  eq(flushes, 1)
end)

test('line terminators, controls, quotes and non-ASCII text stay on one line', function()
  local line = capture(function()
    kestra.outputs({ text = 'a\nb\r"c"\\\0\1 caf\195\169 \194\133\226\128\168\226\128\169 \240\159\152\128' })
  end)
  eq(line, '::{"outputs":{"text":"a\\nb\\r\\"c\\"\\\\\\u0000\\u0001 caf\195\169 \\u0085\\u2028\\u2029 \240\159\152\128"}}::\n')
end)

test('numbers keep their value and integer keys become strings', function()
  local line = capture(function()
    kestra.outputs({ big = 2 ^ 53, third = 1 / 3, negative = -1.5e-7, ids = { [1001] = 'a', [7] = 'b' }, holes = { 1, nil, 3 } })
  end)
  eq(line, '::{"outputs":{"big":9007199254740992,"holes":{"1":1,"3":3},"ids":{"1001":"a","7":"b"},'
    .. '"negative":-1.5e-07,"third":0.33333333333333331}}::\n')
end)

test('an empty table is an object, and kestra.array makes a list', function()
  eq(kestra.format({ a = {}, b = kestra.array(), c = kestra.array({ 'x' }) }), '::{"a":{},"b":[],"c":["x"]}::')
  local listed = setmetatable({ a = 1 }, { __pairs = function() return next, { z = 9 }, nil end })
  eq(kestra.format({ t = listed }), '::{"t":{"a":1}}::')
end)

for _, case in ipairs({
  { 'NaN', { v = 0 / 0 }, 'replace NaN and infinity with nil' },
  { 'infinity', { v = math.huge }, 'replace NaN and infinity with nil' },
  { 'a function', { v = print }, 'a function is not a table' },
  { 'invalid UTF-8', { v = 'caf\233' }, 'a string is not valid UTF-8' },
  { 'a surrogate', { v = '\237\160\128' }, 'a string is not valid UTF-8' },
  { 'an overlong form', { v = '\192\175' }, 'a string is not valid UTF-8' },
  { 'colliding keys', { v = { [1] = 'a', ['1'] = 'b' } }, "the keys 1 and '1'" },
  { 'a boolean key', { v = { [true] = 1 } }, 'a table key must be a string or a finite number' },
  { 'kestra.array with a name', { v = kestra.array({ x = 1 }) }, 'must hold only the keys 1 to n' },
}) do
  test('outputs refuse ' .. case[1], function()
    local err = error_of(function() kestra.outputs(case[2]) end)
    assert(err:find(case[3], 1, true), err)
  end)
end

test('a table that contains itself fails clearly', function()
  local loop = {}
  loop.self = loop
  local err = error_of(function() kestra.outputs({ loop = loop }) end)
  assert(err:find('contains itself', 1, true), err)
end)

test('outputs need a table with string keys, and an empty one sends nothing', function()
  for _, value in ipairs({ { 1, 2 }, 'rows' }) do
    eq(error_of(function() kestra.outputs(value) end),
      'Outputs must be a table with string keys, for example kestra.outputs({ rows = 42 }).')
  end
  eq(capture(function() kestra.outputs({}) kestra.assets({}) end), '')
end)

test('metrics send numbers and string tags, and empty tags as {}', function()
  local lines = capture(function()
    kestra.counter('rows', 3, { source = 'shop', retried = false, shard = 2, ratio = 0.5, [7] = 'x' })
    kestra.gauge('size', 2.5)
    kestra.timer('fetch', 1.25, {})
  end)
  eq(lines, '::{"metrics":[{"name":"rows","tags":{"7":"x","ratio":"0.5","retried":"false","shard":"2","source":"shop"},"type":"counter","value":3}]}::\n'
    .. '::{"metrics":[{"name":"size","tags":{},"type":"gauge","value":2.5}]}::\n'
    .. '::{"metrics":[{"name":"fetch","tags":{},"type":"timer","value":1.25}]}::\n')
end)

test('metrics refuse values Kestra would drop', function()
  eq(error_of(function() kestra.counter('', 1) end), 'Metric name must be a non-empty string.')
  for _, value in ipairs({ '3', 0 / 0, math.huge, true }) do
    eq(error_of(function() kestra.counter('rows', value) end), "Metric 'rows' value must be a finite number.")
  end
  eq(error_of(function() kestra.counter('rows', 1, 'prod') end), "Metric 'rows' tags must be a table, for example { env = 'prod' }.")
  eq(error_of(function() kestra.counter('rows', 1, { 'prod' }) end),
    "Metric 'rows' tags must be a table of names to values, for example { env = 'prod' }.")
  eq(error_of(function() kestra.counter('rows', 1, { [1] = 'a', ['1'] = 'b' }) end), "Metric 'rows' has two tags named '1'.")
  eq(error_of(function() kestra.counter('rows', 1, { env = {} }) end), "Metric 'rows' tag 'env' must be a string, number or boolean.")
end)

test('a timed function returns all its results, nil included', function()
  local count, first, second, third
  local line = capture(function()
    count = select('#', kestra.timer('t', function() return 1, nil, 3 end))
    first, second, third = kestra.timer('t', function() return 1, nil, 3 end)
  end)
  eq(second, nil)
  eq(count, 3)
  eq(first, 1)
  eq(third, 3)
  assert(line:match('^::{"metrics":%[{"name":"t","tags":{},"type":"timer","value":[%d.e-]+}%]}::\n::'), line)
end)

test('a failing timed function sends no metric', function()
  local line = capture(function()
    local ok = pcall(kestra.timer, 't', function() error('boom') end)
    eq(ok, false)
    local is_run = false
    ok = pcall(kestra.timer, 't', function() is_run = true end, { env = {} })
    eq(ok, false)
    eq(is_run, false)
  end)
  eq(line, '')
end)

test('logger levels, format values and both call styles', function()
  local lines = capture(function()
    kestra.logger:trace('t')
    kestra.logger:debug('%d rows, %s %s %s', 3, nil, true, 'x')
    kestra.logger.info('dot call')
    kestra.logger:warn('100%')
    kestra.logger:info('%d rows', 'many')
    kestra.logger:error('failed:', 'disk full', 3)
    kestra.logger:info('%d of %d', 1, 2, 'extra')
    kestra.logger.info(setmetatable({}, { __eq = function() error('eq') end, __tostring = function() return 'eq-safe' end }))
    kestra.logger:error(nil)
    kestra.logger:fatal('caf\233 \226\128\168')
  end)
  eq(lines, '::{"logs":[{"level":"TRACE","message":"t"}]}::\n'
    .. '::{"logs":[{"level":"DEBUG","message":"3 rows, nil true x"}]}::\n'
    .. '::{"logs":[{"level":"INFO","message":"dot call"}]}::\n'
    .. '::{"logs":[{"level":"WARN","message":"100%"}]}::\n'
    .. '::{"logs":[{"level":"INFO","message":"%d rows many"}]}::\n'
    .. '::{"logs":[{"level":"ERROR","message":"failed: disk full 3"}]}::\n'
    .. '::{"logs":[{"level":"INFO","message":"1 of 2 extra"}]}::\n'
    .. '::{"logs":[{"level":"INFO","message":"eq-safe"}]}::\n'
    .. '::{"logs":[{"level":"ERROR","message":"nil"}]}::\n'
    .. '::{"logs":[{"level":"ERROR","message":"caf\239\191\189 \\u2028"}]}::\n')
end)

test('assets send empty inputs and outputs as lists and empty metadata as {}', function()
  local line = capture(function()
    kestra.assets({ inputs = {}, outputs = { { id = 'sales.orders', type = 'TABLE', metadata = {} } } })
  end)
  eq(line, '::{"assets":{"inputs":[],"outputs":[{"id":"sales.orders","metadata":{},"type":"TABLE"}]}}::\n')
end)

test('assets need inputs and outputs as lists, and no other keys', function()
  eq(error_of(function() kestra.assets({ outputs = { id = 'a', type = 'TABLE' } }) end),
    "Asset outputs must be a list, for example { { id = 'sales.orders', type = 'TABLE' } }.")
  eq(error_of(function() kestra.assets({ foo = 1 }) end), "Assets hold only inputs and outputs, not 'foo'.")
  local key = setmetatable({}, { __tostring = function() error('boom') end })
  eq(error_of(function() kestra.assets({ [key] = {} }) end), "Assets hold only inputs and outputs, not '<table>'.")
end)

test('a callable table is timed like a function', function()
  local result
  local line = capture(function()
    result = kestra.timer('t', setmetatable({}, { __call = function() return 7 end }))
  end)
  eq(result, 7)
  assert(line:match('"name":"t"'), line)
end)

test('kestra.array refuses a table that already has a metatable', function()
  local object = setmetatable({}, { __index = { hello = true } })
  eq(error_of(function() kestra.array(object) end),
    'kestra.array takes a plain table, and this one has a metatable. Copy its values into a new table first.')
  eq(object.hello, true)
end)

test('a log call never fails on a __tostring that raises or returns a non-string', function()
  local raises = setmetatable({}, { __tostring = function() error('boom') end })
  local number = setmetatable({}, { __tostring = function() return 1 end })
  -- Lua 5.2 and later turn the returned number into text, 5.1 and LuaJIT do not.
  local ok, text = pcall(tostring, number)
  local number_message = ok and type(text) == 'string' and text or '<table>'
  eq(capture(function()
    kestra.logger:info(raises)
    kestra.logger:info('%s and %s', raises, 'x')
    kestra.logger:info(number)
  end), '::{"logs":[{"level":"INFO","message":"<table>"}]}::\n'
    .. '::{"logs":[{"level":"INFO","message":"<table> and x"}]}::\n'
    .. '::{"logs":[{"level":"INFO","message":"' .. number_message .. '"}]}::\n')
end)

local CONTEXT = '{"labels":{"team":"caf\\u00e9","raw":"x\127y","emoji":"\\ud83d\\ude00"},"inputs":{"text":"a\\nb \\"q\\"","list":[1,null,2.5,true]},'
  .. '"vars":{"n":-42,"e":1.5e3,"empty":{},"none":null}}'
local DIR = os.tmpname()
os.remove(DIR)
local DEFAULT_FILE = '.kestra-execution-context.json'

test('context is read from the default file once, and each call returns a new table', function()
  write_file(DEFAULT_FILE, CONTEXT)
  local k = fresh()
  local context
  with_env({}, function() context = k.context() end)
  os.remove(DEFAULT_FILE)
  eq(context.labels.team, 'caf\195\169')
  eq(context.labels.emoji, '\240\159\152\128')
  eq(context.labels.raw, 'x\127y')
  eq(context.inputs.text, 'a\nb "q"')
  eq(context.inputs.list[2], nil)
  eq(context.inputs.list[3], 2.5)
  eq(context.inputs.list[4], true)
  eq(context.vars.n, -42)
  eq(context.vars.e, 1500)
  eq(next(context.vars.empty), nil)
  context.labels = nil
  with_env({}, function() eq(k.context().labels.team, 'caf\195\169') end)
end)

test('a file wins over KESTRA_CONTEXT, and KESTRA_EXECUTION_CONTEXT_FILE over the default file', function()
  write_file(DEFAULT_FILE, '{"id":"default"}')
  local env_file = write_file(DIR .. '-env.json', '{"id":"env-file"}')
  local encoded = 'eyJpZCI6ImZyb20tZW52In0='
  with_env({ KESTRA_CONTEXT = encoded }, function() eq(fresh().context().id, 'default') end)
  with_env({ KESTRA_CONTEXT = encoded, KESTRA_EXECUTION_CONTEXT_FILE = env_file }, function() eq(fresh().context().id, 'env-file') end)
  with_env({ KESTRA_EXECUTION_CONTEXT_FILE = '' }, function() eq(fresh().context().id, 'default') end)
  os.remove(DEFAULT_FILE)
  os.remove(env_file)
end)

test('falls back to the base64 KESTRA_CONTEXT variable without a file', function()
  -- The context above, and one per padding length.
  for _, encoded in ipairs({ 'eyJsYWJlbHMiOnsidGVhbSI6ImNhZsOpIiwiZW1vamkiOiLwn5iAIn0sImlucHV0cyI6eyJ0ZXh0IjoiYVxuYiBcInFcIiIsImxpc3QiOlsxLG51bGwsMi41LHRydWVdfSwidmFycyI6eyJuIjotNDIsImUiOjEuNWUzLCJlbXB0eSI6e30sIm5vbmUiOm51bGx9fQ==', 'eyJhIjoxfQ==', 'eyJhYiI6MX0=', 'eyJhYmMiOjF9' }) do
    with_env({ KESTRA_CONTEXT = encoded }, function()
      local context = fresh().context()
      assert(context.labels and context.labels.team == 'caf\195\169' or context.a or context.ab or context.abc, encoded)
    end)
  end
end)

test('an explicit path is read as given and never cached as the default context', function()
  write_file(DEFAULT_FILE, '{"id":"default"}')
  local explicit = write_file(DIR .. '-explicit.json', '{"id":"explicit"}')
  local k = fresh()
  with_env({}, function()
    eq(k.context(explicit).id, 'explicit')
    eq(k.context().id, 'default')
    eq(k.context(explicit).id, 'explicit')
  end)
  os.remove(DEFAULT_FILE)
  os.remove(explicit)
end)

test('an empty path means the default lookup', function()
  with_env({ KESTRA_CONTEXT = 'eyJhIjoxfQ==' }, function() eq(fresh().context('').a, 1) end)
end)

test('a context path that is a directory fails instead of falling back', function()
  with_env({ KESTRA_EXECUTION_CONTEXT_FILE = '/', KESTRA_CONTEXT = 'eyJhIjoxfQ==' }, function()
    eq(error_of(function() fresh().context() end), "Kestra execution context file '/' cannot be read: it is not a file.")
  end)
end)

test('an explicit path never falls back to KESTRA_CONTEXT', function()
  with_env({ KESTRA_CONTEXT = 'eyJhIjoxfQ==' }, function()
    eq(error_of(function() fresh().context('typo.json') end), "Kestra execution context file 'typo.json' does not exist.")
  end)
end)

test('content that is not a JSON object names its source', function()
  for _, json in ipairs({ '[1, 2]', 'null', '42' }) do
    write_file(DEFAULT_FILE, json)
    with_env({}, function()
      eq(error_of(function() fresh().context() end), 'The execution context in .kestra-execution-context.json is not a JSON object.')
    end)
  end
  os.remove(DEFAULT_FILE)
  for json, byte in pairs({ ['{oops'] = 2, ['{"a":1} x'] = 9, ['{"a":"\\x"}'] = 7, [''] = 1, ['{"a":'] = 6, ['{"a":01}'] = 6,
    ['{"a":1.}'] = 7, [string.rep('[', 600)] = 514 }) do
    write_file(DEFAULT_FILE, json)
    with_env({}, function()
      eq(error_of(function() fresh().context() end),
        'The execution context in .kestra-execution-context.json is not valid JSON: it fails at byte ' .. byte .. '.')
    end)
  end
  write_file(DEFAULT_FILE, '{"a":"caf\233"}')
  with_env({}, function()
    eq(error_of(function() fresh().context() end), 'The execution context in .kestra-execution-context.json is not valid JSON: it is not valid UTF-8.')
  end)
  write_file(DEFAULT_FILE, '{"a":"x\\ud800y"}')
  with_env({}, function() eq(fresh().context().a, 'x\239\191\189y') end)
  os.remove(DEFAULT_FILE)
  with_env({ KESTRA_CONTEXT = '{"a":1}' }, function()
    eq(error_of(function() fresh().context() end), 'The KESTRA_CONTEXT environment variable is not valid base64.')
  end)
  with_env({ KESTRA_CONTEXT = 'W10=' }, function()
    eq(error_of(function() fresh().context() end), 'The execution context in KESTRA_CONTEXT is not a JSON object.')
  end)
end)

test('fails clearly outside Kestra', function()
  with_env({}, function()
    eq(error_of(function() fresh().context() end),
      "No Kestra execution context found: '.kestra-execution-context.json' does not exist and the KESTRA_CONTEXT environment "
      .. 'variable is not set. The execution context is only available when the script runs inside a Kestra task.')
  end)
end)

for _, t in ipairs(tests) do
  local ok, err = pcall(t.body)
  -- A failed assertion leaves its context file behind, which would fail the next tests too.
  os.remove(DEFAULT_FILE)
  if ok then
    print('ok - ' .. t.name)
  else
    failures = failures + 1
    print('not ok - ' .. t.name .. '\n    ' .. tostring(err))
  end
end
print(string.format('%d tests, %d failed', #tests, failures))
os.exit(failures == 0 and 0 or 1)
