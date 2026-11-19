"""
Sends outputs, metrics, logs and assets from Julia script tasks to Kestra, and reads the execution context.
Each send call prints one `::{...}::` line to stdout, which Kestra parses. One file, standard library only, Julia 1.6 and later.
"""
module Kestra

using Base64: base64decode
using Dates: Dates, FixedPeriod, Period, TimeType
using Logging: Logging, AbstractLogger, BelowMinLevel, Debug, Info, Warn, Error

const CONTEXT_FILE = ".kestra-execution-context.json"
const MAX_DEPTH = 512
const STDOUT_LOCK = ReentrantLock()
const CONTEXT_JSON = Ref{Union{Nothing,String}}(nothing)
const BASE64 = r"^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$"

const Map = Union{AbstractDict,NamedTuple}
const List = Union{AbstractVector,Tuple,AbstractSet}

cannot_send(reason) = throw(ArgumentError("This value cannot be sent to Kestra as JSON: $reason"))

function write_string(io::IO, s::AbstractString, is_lenient::Bool)
    s = String(s)
    if !isvalid(s)
        is_lenient || cannot_send("a string is not valid UTF-8.")
    end
    print(io, '"')
    for c in s
        if !isvalid(c)
            print(io, '�')
        elseif c == '"' || c == '\\'
            print(io, '\\', c)
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\r'
            print(io, "\\r")
        elseif c == '\t'
            print(io, "\\t")
        # Java reads U+0085, U+2028 and U+2029 as line terminators, which would split the line.
        elseif c < ' ' || c == '\u85' || c == ' ' || c == ' '
            print(io, "\\u", string(UInt32(c), base = 16, pad = 4))
        else
            print(io, c)
        end
    end
    print(io, '"')
end

json_key(key::Union{AbstractString,Symbol,AbstractChar,Integer}) = string(key)
json_key(key) = cannot_send("a key must be a string, symbol or integer, not $(typeof(key)).")

write_json(io::IO, ::Union{Nothing,Missing}, depth) = print(io, "null")
write_json(io::IO, value::Bool, depth) = print(io, value ? "true" : "false")
write_json(io::IO, value::Integer, depth) = print(io, value)
function write_json(io::IO, value::AbstractFloat, depth)
    # Kestra reads numbers as doubles, so a BigFloat past the double range would read as Infinity.
    isfinite(Float64(value)) || cannot_send("replace NaN and Inf with nothing.")
    print(io, value)
end
write_json(io::IO, value::Real, depth) = write_json(io, Float64(value), depth)
write_json(io::IO, value::AbstractString, depth) = write_string(io, value, false)
write_json(io::IO, value::Union{Symbol,AbstractChar,TimeType,Period,Base.UUID,Enum}, depth) = write_string(io, string(value), false)

function write_json(io::IO, value::Map, depth)
    depth < MAX_DEPTH || cannot_send("it is nested too deep or contains itself.")
    keys = Set{String}()
    print(io, '{')
    for (key, item) in pairs(value)
        text = json_key(key)
        # 1 and "1", or :a and "a", are distinct keys that read as the same JSON key.
        text in keys && cannot_send("two keys read as '$text'.")
        isempty(keys) || print(io, ',')
        push!(keys, text)
        write_string(io, text, false)
        print(io, ':')
        write_json(io, item, depth + 1)
    end
    print(io, '}')
end

function write_json(io::IO, value::List, depth)
    depth < MAX_DEPTH || cannot_send("it is nested too deep or contains itself.")
    print(io, '[')
    for (i, item) in enumerate(value)
        i == 1 || print(io, ',')
        write_json(io, item, depth + 1)
    end
    print(io, ']')
end

write_json(io::IO, value, depth) = cannot_send("$(typeof(value)) is not a dictionary, vector, string, number, boolean or date. " *
    "Convert it first, for example with string(value).")

"""
    Kestra.format(map) -> String

Returns the `::{...}::` line for a dictionary or named tuple, without sending it.
"""
function format(map)
    map isa Map || throw(ArgumentError("Kestra lines hold a dictionary, for example Dict(\"outputs\" => Dict(\"rows\" => 42))."))
    io = IOBuffer()
    write_json(io, map, 0)
    "::" * String(take!(io)) * "::"
end

function send_line(line::String)
    # One write per line, flushed, so Kestra gets each line when it is written and not at exit.
    lock(STDOUT_LOCK) do
        write(stdout, line * "\n")
        flush(stdout)
    end
    nothing
end

send(map) = send_line(format(map))

"""
    Kestra.outputs(outputs)
    Kestra.outputs(; outputs...)

Sends task outputs, read in later tasks as `outputs.<task>.vars`. Takes a dictionary, a named tuple or keyword arguments.
An empty one sends nothing, as in Python, so outputs built in a loop over no rows do not fail the task.
"""
function outputs(outputs::Map)
    isempty(outputs) || send(Dict("outputs" => outputs))
    nothing
end
outputs(; kwargs...) = outputs(values(kwargs))
outputs(_) = throw(ArgumentError("Outputs must be a dictionary or a named tuple, for example Kestra.outputs(rows = 42)."))

"""
    Kestra.assets(; inputs = [...], outputs = [...])

Declares the input and output assets of the task, each a vector of dictionaries or named tuples. An empty call sends nothing.
"""
function assets(assets::Map)
    for (key, value) in pairs(assets)
        name = key isa Union{AbstractString,Symbol} ? string(key) : nothing
        name in ("inputs", "outputs") || throw(ArgumentError("Assets hold only inputs and outputs, not '$key'."))
        value isa List || throw(ArgumentError("Asset $name must be a vector, for example [(id = \"sales.orders\", type = \"TABLE\")]."))
    end
    isempty(assets) || send(Dict("assets" => assets))
    nothing
end
assets(; kwargs...) = assets(values(kwargs))
assets(_) = throw(ArgumentError("Assets must be a dictionary or a named tuple, for example Kestra.assets(outputs = [(id = \"sales.orders\", type = \"TABLE\")])."))

function send_metric(name, type, value, tags)
    name isa AbstractString && !isempty(name) || throw(ArgumentError("Metric name must be a non-empty string."))
    # Kestra reads the value as a double, so a BigInt past the double range would read as Infinity.
    value isa Real && !(value isa Bool) && isfinite(Float64(value)) || throw(ArgumentError("Metric '$name' value must be a finite number."))
    tags === nothing || tags isa Map || throw(ArgumentError("Metric '$name' tags must be a dictionary or a named tuple, for example (env = \"prod\",)."))
    string_tags = Dict{String,String}()
    for (key, tag) in pairs(something(tags, NamedTuple()))
        text = json_key(key)
        haskey(string_tags, text) && throw(ArgumentError("Metric '$name' has two tags named '$text'."))
        if tag === nothing || tag === missing || tag isa Union{Map,List,AbstractArray}
            throw(ArgumentError("Metric '$name' tag '$text' must be a single value, for example (env = \"prod\",)."))
        end
        # Kestra reads tags as a map of strings.
        string_tags[text] = string(tag)
    end
    send(Dict("metrics" => [(name = name, type = type, value = value, tags = string_tags)]))
end

"""
    Kestra.counter(name, value, tags = nothing)

Sends a counter metric. `tags` is a dictionary or named tuple, sent as strings.
"""
counter(name, value, tags = nothing) = send_metric(name, "counter", value, tags)

"""
    Kestra.gauge(name, value, tags = nothing)

Sends a gauge metric. `tags` is a dictionary or named tuple, sent as strings.
"""
gauge(name, value, tags = nothing) = send_metric(name, "gauge", value, tags)

"""
    Kestra.timer(name, seconds, tags = nothing)
    Kestra.timer(name, tags = nothing) do ... end

Sends a timer metric in seconds, or a `Dates` period such as `now() - start`. With a function or a do-block, times it and
returns its result. No metric is sent if it throws.
"""
timer(name, seconds, tags = nothing) = send_metric(name, "timer", seconds, tags)
timer(name, duration::FixedPeriod, tags = nothing) = send_metric(name, "timer", Dates.toms(duration) / 1000, tags)
# Python's order, timer(name, f), as well as the do-block order.
timer(name, f::Function, tags = nothing) = timer(f, name, tags)
function timer(f::Function, name, tags = nothing)
    start = time_ns()
    result = f()
    send_metric(name, "timer", (time_ns() - start) / 1e9, tags)
    result
end

function text(value)
    try
        string(value)
    catch
        "[FAILED string()]"
    end
end

function exception_text(value)
    try
        value isa Tuple{Exception,Any} ? sprint(showerror, value[1], value[2]) :
            value isa Exception ? sprint(showerror, value) : string(value)
    catch
        "[FAILED showerror()]"
    end
end

function level_name(level)
    level < Debug ? "TRACE" : level < Info ? "DEBUG" : level < Warn ? "INFO" : level < Error ? "WARN" : "ERROR"
end

"""
A `Logging.AbstractLogger` that sends each record to Kestra at its level, with its key-value pairs as `key=value`.
An `exception = (e, catch_backtrace())` pair is sent with its stack trace. A log call never fails on its values.
"""
struct Logger <: AbstractLogger
    counts::Dict{Any,Int}
    lock::ReentrantLock
end

const LOGGER = Logger(Dict{Any,Int}(), ReentrantLock())

"""
    Kestra.logger() -> Kestra.Logger

The logger to install with `global_logger(Kestra.logger())`, or to use with `with_logger`. Then `@info`, `@warn` and the
other logging macros send their records to Kestra. Levels below `Debug` are sent as TRACE, once
`Logging.disable_logging(Logging.BelowMinLevel)` lets Julia emit them.
"""
logger() = LOGGER

Logging.min_enabled_level(::Logger) = BelowMinLevel
Logging.shouldlog(::Logger, level, _module, group, id) = true
Logging.catch_exceptions(::Logger) = true

function Logging.handle_message(logger::Logger, level, message, _module, group, id, file, line; maxlog = nothing, kwargs...)
    if maxlog isa Integer
        count = lock(() -> logger.counts[id] = get(logger.counts, id, 0) + 1, logger.lock)
        count > maxlog && return nothing
    end
    io = IOBuffer()
    print(io, text(message))
    for (key, value) in kwargs
        key === :exception ? print(io, '\n', exception_text(value)) : print(io, ' ', key, '=', text(value))
    end
    line = IOBuffer()
    print(line, "::{\"logs\":[{\"level\":\"", level_name(level), "\",\"message\":")
    # Invalid UTF-8 becomes U+FFFD.
    write_string(line, String(take!(io)), true)
    print(line, "}]}::")
    send_line(String(take!(line)))
end

struct JSONError <: Exception
    message::String
end

mutable struct Parser
    bytes::Vector{UInt8}
    i::Int
end

peek_byte(p::Parser) = p.i <= length(p.bytes) ? p.bytes[p.i] : 0x00

function skip_space(p::Parser)
    while p.i <= length(p.bytes) && p.bytes[p.i] in (0x20, 0x09, 0x0a, 0x0d)
        p.i += 1
    end
end

parse_fail(p::Parser) = throw(JSONError(p.i > length(p.bytes) ? "it ends early" : "it fails at byte $(p.i)"))

function expect(p::Parser, literal::String, value)
    bytes = codeunits(literal)
    p.i + length(bytes) - 1 <= length(p.bytes) && view(p.bytes, p.i:p.i+length(bytes)-1) == bytes || parse_fail(p)
    p.i += length(bytes)
    value
end

function parse_value(p::Parser, depth::Int)
    depth < MAX_DEPTH || throw(JSONError("it is nested too deep"))
    skip_space(p)
    b = peek_byte(p)
    b == UInt8('{') ? parse_object(p, depth) :
    b == UInt8('[') ? parse_array(p, depth) :
    b == UInt8('"') ? parse_string(p) :
    b == UInt8('t') ? expect(p, "true", true) :
    b == UInt8('f') ? expect(p, "false", false) :
    b == UInt8('n') ? expect(p, "null", nothing) :
    b == UInt8('-') || UInt8('0') <= b <= UInt8('9') ? parse_number(p) : parse_fail(p)
end

function parse_object(p::Parser, depth::Int)
    p.i += 1
    object = Dict{String,Any}()
    skip_space(p)
    peek_byte(p) == UInt8('}') && (p.i += 1; return object)
    while true
        skip_space(p)
        peek_byte(p) == UInt8('"') || parse_fail(p)
        key = parse_string(p)
        skip_space(p)
        peek_byte(p) == UInt8(':') || parse_fail(p)
        p.i += 1
        object[key] = parse_value(p, depth + 1)
        skip_space(p)
        b = peek_byte(p)
        p.i += 1
        b == UInt8('}') && return object
        b == UInt8(',') || (p.i -= 1; parse_fail(p))
    end
end

function parse_array(p::Parser, depth::Int)
    p.i += 1
    array = Any[]
    skip_space(p)
    peek_byte(p) == UInt8(']') && (p.i += 1; return array)
    while true
        push!(array, parse_value(p, depth + 1))
        skip_space(p)
        b = peek_byte(p)
        p.i += 1
        b == UInt8(']') && return array
        b == UInt8(',') || (p.i -= 1; parse_fail(p))
    end
end

function parse_hex4(p::Parser)
    p.i + 3 <= length(p.bytes) || parse_fail(p)
    code = tryparse(UInt16, String(p.bytes[p.i:p.i+3]), base = 16)
    code === nothing && parse_fail(p)
    p.i += 4
    code
end

function parse_string(p::Parser)
    p.i += 1
    out = IOBuffer()
    while true
        p.i <= length(p.bytes) || parse_fail(p)
        b = p.bytes[p.i]
        if b == UInt8('"')
            p.i += 1
            return String(take!(out))
        elseif b == UInt8('\\')
            p.i += 1
            e = peek_byte(p)
            p.i += 1
            if e == UInt8('u')
                code = UInt32(parse_hex4(p))
                if 0xd800 <= code <= 0xdbff && peek_byte(p) == UInt8('\\') && p.i + 1 <= length(p.bytes) && p.bytes[p.i+1] == UInt8('u')
                    p.i += 2
                    low = UInt32(parse_hex4(p))
                    code = 0xdc00 <= low <= 0xdfff ? 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00) : (p.i -= 6; 0xfffd)
                end
                print(out, 0xd800 <= code <= 0xdfff ? '�' : Char(code))
            else
                escaped = Dict(UInt8('"') => '"', UInt8('\\') => '\\', UInt8('/') => '/', UInt8('b') => '\b',
                    UInt8('f') => '\f', UInt8('n') => '\n', UInt8('r') => '\r', UInt8('t') => '\t')
                haskey(escaped, e) || (p.i -= 1; parse_fail(p))
                print(out, escaped[e])
            end
        elseif b < 0x20
            parse_fail(p)
        else
            write(out, b)
            p.i += 1
        end
    end
end

function parse_number(p::Parser)
    start = p.i
    while p.i <= length(p.bytes) && p.bytes[p.i] in codeunits("+-0123456789.eE")
        p.i += 1
    end
    text = String(p.bytes[start:p.i-1])
    occursin(r"^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$", text) || (p.i = start; parse_fail(p))
    occursin(r"[.eE]", text) && return parse(Float64, text)
    something(tryparse(Int64, text), parse(BigInt, text))
end

function parse_json(json::String)
    isvalid(json) || throw(JSONError("it is not valid UTF-8"))
    p = Parser(Vector{UInt8}(codeunits(json)), 1)
    value = parse_value(p, 0)
    skip_space(p)
    p.i <= length(p.bytes) && parse_fail(p)
    value
end

nonempty(value) = value === nothing || isempty(value) ? nothing : value

"""
    Kestra.context(path = nothing) -> Dict{String,Any}

The execution context, read from `path`, `KESTRA_EXECUTION_CONTEXT_FILE` or `.kestra-execution-context.json` (written when
the task sets `executionContext: true`). Without `path`, or with an empty one, falls back to the base64 `KESTRA_CONTEXT`
variable. The default context is read once, and each call returns a new dictionary the caller may change. JSON `null`
reads as `nothing`.

Throws a `SystemError` with `Libc.ENOENT` when no context is found, a `SystemError` when the file cannot be read, and an
`ArgumentError` when `KESTRA_CONTEXT` is not base64 or the context is not a JSON object.
"""
function context(path::Union{Nothing,AbstractString} = nothing)
    is_explicit = nonempty(path) !== nothing
    json = is_explicit ? nothing : CONTEXT_JSON[]
    source = "the cached context"
    if json === nothing
        file = is_explicit ? String(path) : something(nonempty(get(ENV, "KESTRA_EXECUTION_CONTEXT_FILE", nothing)), CONTEXT_FILE)
        source = file
        # Julia reads a directory as an empty string.
        isdir(file) && throw(SystemError("Kestra execution context file '$file' cannot be read", Libc.EISDIR))
        try
            json = read(file, String)
        catch e
            # Only a missing file falls back. An unreadable file is a misconfiguration to report.
            e isa SystemError && e.errnum == Libc.ENOENT || rethrow()
            # SystemError appends the errno text, so these read "...: No such file or directory".
            is_explicit && throw(SystemError("Kestra execution context file '$file'", Libc.ENOENT))
            encoded = replace(get(ENV, "KESTRA_CONTEXT", ""), r"\s" => "")
            isempty(encoded) && throw(SystemError("No Kestra execution context found, the KESTRA_CONTEXT environment variable is not set " *
                "and the execution context is only available when the script runs inside a Kestra task. Context file '$file'", Libc.ENOENT))
            occursin(BASE64, encoded) || throw(ArgumentError("The KESTRA_CONTEXT environment variable is not valid base64."))
            json = String(base64decode(encoded))
            source = "KESTRA_CONTEXT"
        end
    end
    context = try
        parse_json(json)
    catch e
        e isa JSONError || rethrow()
        throw(ArgumentError("The execution context in $source is not valid JSON: $(e.message)."))
    end
    context isa Dict || throw(ArgumentError("The execution context in $source is not a JSON object."))
    is_explicit || (CONTEXT_JSON[] = json)
    context
end

end
