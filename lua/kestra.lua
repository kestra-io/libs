-- Sends outputs, metrics, logs and assets from Lua script tasks to Kestra, and reads the execution context.
-- Each send call prints one `::{...}::` line to stdout, which Kestra parses. Pure Lua, for Lua 5.1 to 5.5 and LuaJIT.

local kestra = {}

local CONTEXT_FILE = '.kestra-execution-context.json'
local MAX_DEPTH = 512
local ARRAY = {}

local unpack = table.unpack or unpack
local pack = table.pack or function(...) return { n = select('#', ...), ... } end

local function fail(message)
  error(message, 0)
end

-- tostring can raise, or return a non-string on Lua 5.1, from a __tostring metamethod.
local function safe_tostring(value)
  local ok, text = pcall(tostring, value)
  if ok and type(text) == 'string' then return text end
  return '<' .. type(value) .. '>'
end

local function is_integer(value)
  if math.type then return math.type(value) == 'integer' end
  return value == math.floor(value) and value > -2 ^ 53 and value < 2 ^ 53
end

local function is_finite_number(value)
  return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function number_text(value)
  if math.type and math.type(value) == 'integer' then return string.format('%d', value) end
  -- The shortest form that reads back as the same number. A locale can write a comma.
  local text = string.format('%.14g', value)
  if tonumber(text) ~= value then text = string.format('%.17g', value) end
  return (text:gsub(',', '.'))
end

-- Length of the valid UTF-8 sequence at i, or nil.
local function utf8_length(s, i)
  local b1, b2, b3, b4 = s:byte(i, i + 3)
  local function tail(b) return b and b >= 0x80 and b <= 0xBF end
  if b1 >= 0xC2 and b1 <= 0xDF then
    return tail(b2) and 2 or nil
  elseif b1 >= 0xE0 and b1 <= 0xEF then
    -- E0 rules out overlong forms and ED rules out surrogates.
    local low, high = b1 == 0xE0 and 0xA0 or 0x80, b1 == 0xED and 0x9F or 0xBF
    return b2 and b2 >= low and b2 <= high and tail(b3) and 3 or nil
  elseif b1 >= 0xF0 and b1 <= 0xF4 then
    local low, high = b1 == 0xF0 and 0x90 or 0x80, b1 == 0xF4 and 0x8F or 0xBF
    return b2 and b2 >= low and b2 <= high and tail(b3) and tail(b4) and 4 or nil
  end
  return nil
end

local ESCAPES = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
-- Java treats U+0085, U+2028 and U+2029 as line terminators, so a raw one would split the line.
local LINE_TERMINATORS = { ['\194\133'] = '\\u0085', ['\226\128\168'] = '\\u2028', ['\226\128\169'] = '\\u2029' }

-- Invalid UTF-8 becomes U+FFFD when is_lenient, or fails.
local function string_json(s, is_lenient)
  if not s:find('[%c"\\\128-\255]') then return '"' .. s .. '"' end
  local parts, i, length = {}, 1, #s
  while i <= length do
    local byte = s:byte(i)
    if byte < 0x80 then
      local char = s:sub(i, i)
      parts[#parts + 1] = ESCAPES[char] or (byte < 0x20 and string.format('\\u%04x', byte)) or char
      i = i + 1
    else
      local size = utf8_length(s, i)
      if size then
        local char = s:sub(i, i + size - 1)
        parts[#parts + 1] = LINE_TERMINATORS[char] or char
        i = i + size
      elseif is_lenient then
        parts[#parts + 1] = '\239\191\189'
        i = i + 1
      else
        fail('This value cannot be sent to Kestra as JSON: a string is not valid UTF-8. Lua strings are bytes, so convert text '
          .. 'to UTF-8 and cut it on character boundaries.')
      end
    end
  end
  return '"' .. table.concat(parts) .. '"'
end

-- 'array' for the keys 1 to n or a table made with kestra.array, else 'object'.
local function table_kind(t)
  local count, max, is_sequence = 0, 0, true
  -- next, not pairs, so a __pairs metamethod cannot list keys the table does not hold.
  for key in next, t do
    count = count + 1
    if type(key) == 'number' and key >= 1 and is_integer(key) then
      max = math.max(max, key)
    else
      is_sequence = false
    end
  end
  -- Distinct integer keys from 1 whose largest is their count are exactly 1 to n.
  is_sequence = is_sequence and max == count
  if getmetatable(t) == ARRAY then
    if not is_sequence then
      fail('This value cannot be sent to Kestra as JSON: a table made with kestra.array must hold only the keys 1 to n.')
    end
    return 'array', count
  end
  if count > 0 and is_sequence then return 'array', count end
  return 'object', count
end

local encode

local function object_json(t, depth)
  local keys, by_text = {}, {}
  for key in next, t do
    local text
    if type(key) == 'string' then
      text = key
    elseif is_finite_number(key) then
      text = number_text(key)
    else
      fail('This value cannot be sent to Kestra as JSON: a table key must be a string or a finite number.')
    end
    if by_text[text] ~= nil then
      fail("This value cannot be sent to Kestra as JSON: the keys " .. text .. " and '" .. text .. "' are both in one table.")
    end
    by_text[text] = key
    keys[#keys + 1] = text
  end
  table.sort(keys)
  local parts = {}
  for i, text in ipairs(keys) do
    parts[i] = string_json(text, false) .. ':' .. encode(t[by_text[text]], depth + 1)
  end
  return '{' .. table.concat(parts, ',') .. '}'
end

encode = function(value, depth)
  local kind = type(value)
  if kind == 'string' then
    return string_json(value, false)
  elseif kind == 'number' then
    if not is_finite_number(value) then
      fail('This value cannot be sent to Kestra as JSON: replace NaN and infinity with nil.')
    end
    return number_text(value)
  elseif kind == 'boolean' then
    return tostring(value)
  elseif kind == 'table' then
    if depth > MAX_DEPTH then
      fail('This value cannot be sent to Kestra as JSON: it is nested more than 512 levels deep or contains itself.')
    end
    local shape, count = table_kind(value)
    if shape == 'object' then return object_json(value, depth) end
    local parts = {}
    for i = 1, count do parts[i] = encode(value[i], depth + 1) end
    return '[' .. table.concat(parts, ',') .. ']'
  end
  fail('This value cannot be sent to Kestra as JSON: a ' .. kind .. ' is not a table, string, number or boolean.')
end

local function send_line(line)
  -- One write per line, flushed, so Kestra gets each line when it is written and not at exit.
  io.stdout:write(line .. '\n')
  io.stdout:flush()
end

-- An empty table sends nothing, as in Python, so outputs built in a loop over no rows do not fail the task.
local function is_empty_or_map(value)
  return type(value) == 'table' and (next(value) == nil or table_kind(value) == 'object')
end

function kestra.format(map)
  if type(map) ~= 'table' or table_kind(map) ~= 'object' then
    fail('Kestra lines hold a table with string keys, for example { outputs = { rows = 42 } }.')
  end
  return '::' .. encode(map, 0) .. '::'
end

-- Marks t, or a new empty table, to be sent as a JSON array, since an empty table is sent as {}.
function kestra.array(t)
  t = t or {}
  local metatable = getmetatable(t)
  if metatable ~= nil and metatable ~= ARRAY then
    fail('kestra.array takes a plain table, and this one has a metatable. Copy its values into a new table first.')
  end
  return setmetatable(t, ARRAY)
end

function kestra.outputs(outputs)
  if not is_empty_or_map(outputs) then
    fail('Outputs must be a table with string keys, for example kestra.outputs({ rows = 42 }).')
  end
  if next(outputs) == nil then return end
  send_line(kestra.format({ outputs = outputs }))
end

function kestra.assets(assets)
  if not is_empty_or_map(assets) then
    fail("Assets must be a table, for example kestra.assets({ outputs = { { id = 'sales.orders', type = 'TABLE' } } }).")
  end
  if next(assets) == nil then return end
  local copy = {}
  for key, value in next, assets do
    if key ~= 'inputs' and key ~= 'outputs' then
      fail("Assets hold only inputs and outputs, not '" .. safe_tostring(key) .. "'.")
    end
    -- Kestra reads inputs and outputs as lists, and an empty table would be sent as {}.
    if type(value) == 'table' and next(value) == nil then
      value = kestra.array()
    elseif type(value) ~= 'table' or table_kind(value) ~= 'array' then
      fail('Asset ' .. key .. " must be a list, for example { { id = 'sales.orders', type = 'TABLE' } }.")
    end
    copy[key] = value
  end
  send_line(kestra.format({ assets = copy }))
end

local function metric_tags(name, tags)
  if type(name) ~= 'string' or name == '' then fail('Metric name must be a non-empty string.') end
  if tags ~= nil and type(tags) ~= 'table' then
    fail("Metric '" .. name .. "' tags must be a table, for example { env = 'prod' }.")
  end
  if tags ~= nil and next(tags) ~= nil and table_kind(tags) == 'array' then
    fail("Metric '" .. name .. "' tags must be a table of names to values, for example { env = 'prod' }.")
  end
  local string_tags = {}
  for tag_key, tag in next, tags or {} do
    local key = tag_key
    if type(key) ~= 'string' and type(key) ~= 'number' then
      fail("Metric '" .. name .. "' tags must be a table of names to values, for example { env = 'prod' }.")
    end
    -- As in Python, a number key is sent as its text.
    if type(key) == 'number' then key = number_text(key) end
    if string_tags[key] then
      fail("Metric '" .. name .. "' has two tags named '" .. key .. "'.")
    end
    local kind = type(tag)
    if kind ~= 'string' and kind ~= 'number' and kind ~= 'boolean' then
      fail("Metric '" .. name .. "' tag '" .. key .. "' must be a string, number or boolean.")
    end
    -- Kestra reads tags as a map of strings.
    string_tags[key] = kind == 'number' and number_text(tag) or tostring(tag)
  end
  return string_tags
end

local function send_metric(name, metric_type, value, tags)
  local string_tags = metric_tags(name, tags)
  if not is_finite_number(value) then fail("Metric '" .. name .. "' value must be a finite number.") end
  send_line(kestra.format({ metrics = { { name = name, type = metric_type, value = value, tags = string_tags } } }))
end

function kestra.counter(name, value, tags) send_metric(name, 'counter', value, tags) end

function kestra.gauge(name, value, tags) send_metric(name, 'gauge', value, tags) end

-- Plain Lua has no precise clock: /proc/uptime counts in 10 ms steps on Linux, os.time in seconds elsewhere.
local function now()
  local file = io.open('/proc/uptime')
  if file then
    local seconds = file:read('*n')
    file:close()
    if seconds then return seconds end
  end
  return os.time()
end

-- Pass seconds, or a function that is timed and whose results are returned. No metric is sent if it fails.
local function is_callable(value)
  if type(value) == 'function' then return true end
  local metatable = getmetatable(value)
  return type(metatable) == 'table' and metatable.__call ~= nil
end

function kestra.timer(name, seconds_or_function, tags)
  if not is_callable(seconds_or_function) then
    send_metric(name, 'timer', seconds_or_function, tags)
    return
  end
  -- Checked first, so a bad name or tag does not fail after the function has done its work.
  metric_tags(name, tags)
  local start = now()
  local results = pack(seconds_or_function())
  -- Rounded to the clock's 10 ms steps, which subtraction leaves as 1.2700000000004366.
  send_metric(name, 'timer', math.floor((now() - start) * 100 + 0.5) / 100, tags)
  return unpack(results, 1, results.n)
end

-- LuaLogging method names, mapped to Kestra levels.
local LEVELS = { trace = 'TRACE', debug = 'DEBUG', info = 'INFO', warn = 'WARN', error = 'ERROR', fatal = 'ERROR' }

local logger = {}
for method, level in pairs(LEVELS) do
  -- Takes a message, or a string.format pattern and its values. Works called with : or with .
  logger[method] = function(...)
    local args = pack(...)
    -- rawequal, as == would call a value's own __eq.
    local first = rawequal(args[1], logger) and 2 or 1
    local message = safe_tostring(args[first])
    if args.n > first then
      -- Lua 5.1 formats only strings and numbers with %s.
      for i = first + 1, args.n do
        local kind = type(args[i])
        if kind ~= 'string' and kind ~= 'number' then args[i] = safe_tostring(args[i]) end
      end
      local _, conversions = (message:gsub('%%%%', '')):gsub('%%', '')
      local ok, formatted = pcall(string.format, message, unpack(args, first + 1, math.min(args.n, first + conversions)))
      -- string.format ignores extra values, and a pattern that does not match its values fails. Either way the values
      -- it did not use follow the message, as in logger:error('failed:', err), so a log call never fails or drops one.
      local rest = ok and first + conversions + 1 or first + 1
      for i = rest, args.n do args[i] = safe_tostring(args[i]) end
      message = (ok and formatted or message) .. (rest <= args.n and ' ' .. table.concat(args, ' ', rest, args.n) or '')
    end
    -- Invalid UTF-8 becomes U+FFFD.
    local text = string_json(message, true)
    send_line('::{"logs":[{"level":"' .. level .. '","message":' .. text .. '}]}::')
  end
end
kestra.logger = logger

local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

local function base64_decode(encoded)
  local bytes, bits, bit_count = {}, 0, 0
  for char in encoded:gmatch('[%w%+/]') do
    bits = bits * 64 + B64:find(char, 1, true) - 1
    bit_count = bit_count + 6
    if bit_count >= 8 then
      bit_count = bit_count - 8
      local divisor = 2 ^ bit_count
      bytes[#bytes + 1] = string.char(math.floor(bits / divisor))
      bits = bits % divisor
    end
  end
  return table.concat(bytes)
end

local function utf8_char(code)
  if code < 0x80 then return string.char(code) end
  if code < 0x800 then return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40) end
  if code < 0x10000 then
    return string.char(0xE0 + math.floor(code / 0x1000), 0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
  end
  return string.char(0xF0 + math.floor(code / 0x40000), 0x80 + math.floor(code / 0x1000) % 0x40,
    0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end

local DECODE_ESCAPES = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }

local INVALID = {}

-- Decodes JSON, with null as nil. Returns true and the value, or false and the byte where invalid JSON starts.
local function decode(json)
  local pos = 1
  local value

  local function skip()
    pos = json:find('[^ \t\r\n]', pos) or #json + 1
  end

  local function invalid() error(INVALID, 0) end

  local function read_string()
    local parts = {}
    pos = pos + 1
    while true do
      local from, to = json:find('^[^"\\\1-\31]+', pos)
      if from then
        parts[#parts + 1] = json:sub(from, to)
        pos = to + 1
      end
      local char = json:sub(pos, pos)
      if char == '"' then
        pos = pos + 1
        return table.concat(parts)
      elseif char ~= '\\' then
        invalid()
      end
      local escape = json:sub(pos + 1, pos + 1)
      if escape == 'u' then
        local code = tonumber(json:match('^%x%x%x%x', pos + 2) or '', 16) or invalid()
        pos = pos + 6
        if code >= 0xD800 and code <= 0xDBFF then
          local low = tonumber(json:match('^\\u(%x%x%x%x)', pos) or '', 16)
          if low and low >= 0xDC00 and low <= 0xDFFF then
            code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
            pos = pos + 6
          end
        end
        -- A lone surrogate cannot be written as UTF-8.
        parts[#parts + 1] = utf8_char((code >= 0xD800 and code <= 0xDFFF) and 0xFFFD or code)
      else
        parts[#parts + 1] = DECODE_ESCAPES[escape] or invalid()
        pos = pos + 2
      end
    end
  end

  value = function(depth)
    if depth > MAX_DEPTH then invalid() end
    skip()
    local char = json:sub(pos, pos)
    if char == '{' then
      local object = {}
      pos = pos + 1
      skip()
      if json:sub(pos, pos) == '}' then pos = pos + 1 return object end
      repeat
        skip()
        if json:sub(pos, pos) ~= '"' then invalid() end
        local key = read_string()
        skip()
        if json:sub(pos, pos) ~= ':' then invalid() end
        pos = pos + 1
        object[key] = value(depth + 1)
        skip()
        char = json:sub(pos, pos)
        pos = pos + 1
      until char ~= ','
      if char ~= '}' then invalid() end
      return object
    elseif char == '[' then
      local array, count = {}, 0
      pos = pos + 1
      skip()
      if json:sub(pos, pos) == ']' then pos = pos + 1 return array end
      repeat
        count = count + 1
        array[count] = value(depth + 1)
        skip()
        char = json:sub(pos, pos)
        pos = pos + 1
      until char ~= ','
      if char ~= ']' then invalid() end
      return array
    elseif char == '"' then
      return read_string()
    end
    if json:sub(pos, pos + 3) == 'true' then pos = pos + 4 return true end
    if json:sub(pos, pos + 4) == 'false' then pos = pos + 5 return false end
    if json:sub(pos, pos + 3) == 'null' then pos = pos + 4 return nil end
    -- Strict JSON numbers: no leading zero, and digits after a dot or an exponent.
    local number = json:match('^-?%d+', pos) or invalid()
    if number:match('^-?0%d') then invalid() end
    number = number .. (json:match('^%.%d+', pos + #number) or '')
    number = number .. (json:match('^[eE][-+]?%d+', pos + #number) or '')
    pos = pos + #number
    if json:find('^[.eE]', pos) then invalid() end
    return tonumber(number)
  end

  local ok, result = pcall(function()
    local decoded = value(0)
    skip()
    if pos <= #json then invalid() end
    return decoded
  end)
  if ok then return true, result end
  if result ~= INVALID then error(result, 0) end
  return false, pos
end

local function read_file(path)
  local file, message, code = io.open(path, 'rb')
  if not file then
    if code == 2 then return nil end
    fail("Kestra execution context file '" .. path .. "' cannot be read: " .. message .. '.')
  end
  local content = file:read('*a')
  file:close()
  if not content then fail("Kestra execution context file '" .. path .. "' cannot be read: it is not a file.") end
  return content
end

local context_json

-- The execution context as a table, read from path, KESTRA_EXECUTION_CONTEXT_FILE or .kestra-execution-context.json
-- (written when the task sets executionContext: true). Without a path, falls back to the base64 KESTRA_CONTEXT
-- variable. The default context is read once, and each call returns a new table the caller may change.
function kestra.context(path)
  -- An empty path means the default lookup, as in the other libraries.
  if path == '' then path = nil end
  local json, source = context_json, nil
  if path ~= nil or json == nil then
    local env_file = os.getenv('KESTRA_EXECUTION_CONTEXT_FILE') or ''
    local file = path or (env_file ~= '' and env_file or CONTEXT_FILE)
    local encoded = (os.getenv('KESTRA_CONTEXT') or ''):gsub('%s', '')
    json = read_file(file)
    source = file
    if json == nil and path ~= nil then
      fail("Kestra execution context file '" .. file .. "' does not exist.")
    elseif json == nil and encoded ~= '' then
      if #encoded % 4 ~= 0 or not encoded:find('^[%w%+/]+=?=?$') then
        fail('The KESTRA_CONTEXT environment variable is not valid base64.')
      end
      json, source = base64_decode(encoded), 'KESTRA_CONTEXT'
    elseif json == nil then
      fail("No Kestra execution context found: '" .. file .. "' does not exist and the KESTRA_CONTEXT environment "
        .. 'variable is not set. The execution context is only available when the script runs inside a Kestra task.')
    end
  end
  if not pcall(string_json, json, false) then
    fail('The execution context in ' .. source .. ' is not valid JSON: it is not valid UTF-8.')
  end
  local ok, context = decode(json)
  if not ok then
    fail('The execution context in ' .. source .. ' is not valid JSON: it fails at byte ' .. context .. '.')
  end
  if json:match('^%s*(.)') ~= '{' then
    fail('The execution context in ' .. source .. ' is not a JSON object.')
  end
  if path == nil then context_json = json end
  return context
end

return kestra
