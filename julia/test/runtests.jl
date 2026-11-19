# Run from the julia directory: julia test/runtests.jl
using Base64: base64encode
using Dates: Dates, Date, DateTime, Millisecond
using Logging: Logging, with_logger, @logmsg
using Test

include(joinpath(@__DIR__, "..", "Kestra.jl"))

function capture(f)
    mktemp() do path, io
        redirect_stdout(f, io)
        flush(io)
        read(path, String)
    end
end

struct Unprintable end
Base.show(::IO, ::Unprintable) = error("boom")

@enum Tier gold silver

@testset "Kestra" begin
    @testset "a line escapes line terminators and keeps UTF-8" begin
        line = Kestra.format(Dict("outputs" => Dict("v" => "a\nb\"\\ \x01 \u85     café")))
        @test line == "::{\"outputs\":{\"v\":\"a\\nb\\\"\\\\ \\u0001 \\u0085 \\u2028 \\u2029 café\"}}::"
        @test !occursin('\n', line)
    end

    @testset "outputs send everyday values" begin
        out = capture() do
            Kestra.outputs(rows = 42, ok = 3 < 1, ratio = 3 // 2, big = big(2)^70, f32 = 0.1f0, none = nothing, gap = missing,
                day = Date(2026, 1, 2), at = DateTime(2026, 1, 2, 3, 4, 5), tier = gold, kind = :csv, ids = (1, 2), range = 1:3,
                set = Set(["a"]), took = Millisecond(1500), nested = (country = "FR", keys = Dict(7 => [1.5, -0.0])), id = Base.UUID(0))
        end
        @test out == "::{\"outputs\":{\"rows\":42,\"ok\":false,\"ratio\":1.5,\"big\":1180591620717411303424,\"f32\":0.1,\"none\":null," *
            "\"gap\":null,\"day\":\"2026-01-02\",\"at\":\"2026-01-02T03:04:05\",\"tier\":\"gold\",\"kind\":\"csv\",\"ids\":[1,2]," *
            "\"range\":[1,2,3],\"set\":[\"a\"],\"took\":\"1500 milliseconds\",\"nested\":{\"country\":\"FR\",\"keys\":{\"7\":[1.5,-0.0]}}," *
            "\"id\":\"00000000-0000-0000-0000-000000000000\"}}::\n"
        @test capture(() -> Kestra.outputs(Dict("rows" => 42))) == "::{\"outputs\":{\"rows\":42}}::\n"
    end

    @testset "an empty output or asset sends nothing, as in Python" begin
        @test capture() do
            Kestra.outputs()
            Kestra.outputs(Dict())
            Kestra.assets()
        end == ""
    end

    @testset "values Kestra cannot read fail before anything is sent" begin
        loop = Any[]
        push!(loop, loop)
        for (value, message) in [
            (NaN, "replace NaN and Inf"), (big"1e400", "replace NaN and Inf"), (1 // 0, "replace NaN and Inf"),
            ("\xff", "not valid UTF-8"), (1 + 2im, "Complex{Int64} is not a dictionary"), ([1 2; 3 4], "is not a dictionary"),
            (Unprintable(), "Convert it first"), (Dict(1 => "a", "1" => "b"), "two keys read as '1'"),
            (loop, "nested too deep or contains itself"),
        ]
            out = capture(() -> @test_throws ArgumentError Kestra.outputs(v = value))
            @test out == ""
            err = try Kestra.outputs(v = value) catch e e end
            @test occursin(message, err.msg)
        end
        @test_throws ArgumentError Kestra.outputs(Dict(:a => 1, "a" => 2))
        @test_throws ArgumentError Kestra.outputs(nothing)
        @test_throws ArgumentError Kestra.outputs([1, 2])
    end

    @testset "assets keep empty lists and empty metadata" begin
        line = capture(() -> Kestra.assets(inputs = [], outputs = [(id = "sales.orders", type = "TABLE", metadata = Dict())]))
        @test line == "::{\"assets\":{\"inputs\":[],\"outputs\":[{\"id\":\"sales.orders\",\"type\":\"TABLE\",\"metadata\":{}}]}}::\n"
    end

    @testset "assets need inputs and outputs as vectors, and no other keys" begin
        err(f) = try f() catch e e.msg end
        @test err(() -> Kestra.assets(outputs = (id = "a", type = "TABLE"))) ==
            "Asset outputs must be a vector, for example [(id = \"sales.orders\", type = \"TABLE\")]."
        @test err(() -> Kestra.assets(foo = 1)) == "Assets hold only inputs and outputs, not 'foo'."
    end

    @testset "metrics send numbers and string tags, and empty tags as {}" begin
        lines = capture() do
            Kestra.counter("rows", 3, (source = "shop", retried = false, shard = 2, day = Date(2026, 1, 2)))
            Kestra.gauge("size", 2.5, Dict(7 => "x"))
            Kestra.timer("fetch", 3 // 2)
            Kestra.timer("fetch", Millisecond(1500))
        end
        @test lines == "::{\"metrics\":[{\"name\":\"rows\",\"type\":\"counter\",\"value\":3,\"tags\":" *
            lines[findfirst("\"tags\":", lines).stop+1:findfirst("}}]}::", lines).start] * "}]}::\n" *
            "::{\"metrics\":[{\"name\":\"size\",\"type\":\"gauge\",\"value\":2.5,\"tags\":{\"7\":\"x\"}}]}::\n" *
            "::{\"metrics\":[{\"name\":\"fetch\",\"type\":\"timer\",\"value\":1.5,\"tags\":{}}]}::\n" ^ 2
        for tag in ("\"source\":\"shop\"", "\"retried\":\"false\"", "\"shard\":\"2\"", "\"day\":\"2026-01-02\"")
            @test occursin(tag, lines)
        end
    end

    @testset "metrics refuse values Kestra would drop" begin
        err(f) = try f(); "" catch e e.msg end
        @test err(() -> Kestra.counter("", 1)) == "Metric name must be a non-empty string."
        for value in ("3", true, NaN, Inf, big(10)^400, nothing)
            @test err(() -> Kestra.counter("rows", value)) == "Metric 'rows' value must be a finite number."
        end
        @test err(() -> Kestra.counter("rows", 1, "prod")) == "Metric 'rows' tags must be a dictionary or a named tuple, for example (env = \"prod\",)."
        @test err(() -> Kestra.counter("rows", 1, Dict(1 => "a", "1" => "b"))) == "Metric 'rows' has two tags named '1'."
        for tag in (nothing, [1], (env = "x",))
            @test err(() -> Kestra.counter("rows", 1, (env = tag,))) == "Metric 'rows' tag 'env' must be a single value, for example (env = \"prod\",)."
        end
        @test capture(() -> try Kestra.counter("rows", NaN) catch end) == ""
    end

    @testset "a timed block returns its result, and sends nothing when it throws" begin
        result = nothing
        line = capture(() -> result = Kestra.timer("fetch", (env = "qa",)) do
            sleep(0.02)
            [1, 2]
        end)
        @test result == [1, 2]
        m = match(r"^::\{\"metrics\":\[\{\"name\":\"fetch\",\"type\":\"timer\",\"value\":([0-9.e-]+),\"tags\":\{\"env\":\"qa\"\}\}\]\}::\n$", line)
        @test m !== nothing && parse(Float64, m[1]) > 0
        @test capture(() -> @test_throws ErrorException Kestra.timer(() -> error("boom"), "fetch")) == ""
        @test capture(() -> @test(Kestra.timer("fetch", () -> 7) == 7)) != ""
        @test_throws ArgumentError Kestra.timer("fetch", Dates.Month(1))
    end

    @testset "the logger sends each level, key-value pairs and exceptions, and never fails" begin
        # Julia drops levels below Debug unless this is called.
        Logging.disable_logging(Logging.BelowMinLevel)
        lines = capture() do
            with_logger(Kestra.logger()) do
                @logmsg Logging.Debug - 1 "t"
                @debug "d"
                @info "rows" n = 3 bad = Unprintable()
                @warn "caf\xe9   two\nlines"
                @error "failed" exception = (ErrorException("boom"), backtrace())
                @info Unprintable()
                for _ in 1:3
                    @info "once" maxlog = 1
                end
            end
        end
        logs = split(chomp(lines), '\n')
        @test logs[1:4] == [
            "::{\"logs\":[{\"level\":\"TRACE\",\"message\":\"t\"}]}::",
            "::{\"logs\":[{\"level\":\"DEBUG\",\"message\":\"d\"}]}::",
            "::{\"logs\":[{\"level\":\"INFO\",\"message\":\"rows n=3 bad=[FAILED string()]\"}]}::",
            "::{\"logs\":[{\"level\":\"WARN\",\"message\":\"caf� \\u2028 two\\nlines\"}]}::",
        ]
        @test startswith(logs[5], "::{\"logs\":[{\"level\":\"ERROR\",\"message\":\"failed\\nboom\\nStacktrace:")
        @test logs[6] == "::{\"logs\":[{\"level\":\"INFO\",\"message\":\"[FAILED string()]\"}]}::"
        @test logs[7] == "::{\"logs\":[{\"level\":\"INFO\",\"message\":\"once\"}]}::"
        @test length(logs) == 7
    end

    @testset "context" begin
        json = "{\"labels\":{\"team\":\"caf\\u00e9\",\"emoji\":\"\\ud83d\\ude00\"},\"inputs\":{\"text\":\"a\\nb\",\"list\":[1,null,2.5,true]}," *
            "\"vars\":{\"n\":-42,\"e\":1.5e3,\"big\":123456789012345678901234567890,\"empty\":{}}}"
        reset() = (Kestra.CONTEXT_JSON[] = nothing)
        clean = ("KESTRA_CONTEXT" => nothing, "KESTRA_EXECUTION_CONTEXT_FILE" => nothing)
        in_dir(f, files...) = mktempdir() do dir
            cd(dir) do
                for (name, content) in files
                    write(name, content)
                end
                reset()
                withenv(f, clean...)
            end
        end
        errorof(f) = try f(); nothing catch e e end

        @testset "is read from the default file once, and each call returns a new dictionary" begin
            in_dir(Kestra.CONTEXT_FILE => json) do
                context = Kestra.context()
                @test context["labels"]["team"] == "café" && context["labels"]["emoji"] == "😀"
                @test context["inputs"]["list"] == Any[1, nothing, 2.5, true]
                @test context["vars"]["n"] === -42 && context["vars"]["e"] === 1500.0
                @test context["vars"]["big"] == big"123456789012345678901234567890"
                rm(Kestra.CONTEXT_FILE)
                context["labels"] = Dict()
                @test Kestra.context()["labels"]["team"] == "café"
            end
        end

        @testset "a file wins over KESTRA_CONTEXT, and KESTRA_EXECUTION_CONTEXT_FILE over the default file" begin
            in_dir(Kestra.CONTEXT_FILE => "{\"id\":\"default\"}", "other.json" => "{\"id\":\"env-file\"}") do
                withenv("KESTRA_CONTEXT" => base64encode("{\"id\":\"from-env\"}")) do
                    @test Kestra.context()["id"] == "default"
                    reset()
                    withenv(() -> @test(Kestra.context()["id"] == "env-file"), "KESTRA_EXECUTION_CONTEXT_FILE" => "other.json")
                    reset()
                    withenv(() -> @test(Kestra.context()["id"] == "default"), "KESTRA_EXECUTION_CONTEXT_FILE" => "")
                end
            end
        end

        @testset "falls back to KESTRA_CONTEXT without a file, also for an empty or nothing path" begin
            in_dir() do
                withenv("KESTRA_CONTEXT" => base64encode("{\"id\":\"from-env\"}")) do
                    @test [Kestra.context("")["id"], Kestra.context(nothing)["id"], Kestra.context()["id"]] == fill("from-env", 3)
                end
            end
        end

        @testset "an explicit path is never cached and never falls back" begin
            in_dir(Kestra.CONTEXT_FILE => "{\"id\":\"default\"}", "explicit.json" => "{\"id\":\"explicit\"}") do
                @test [Kestra.context("explicit.json")["id"], Kestra.context()["id"], Kestra.context("explicit.json")["id"]] ==
                    ["explicit", "default", "explicit"]
                withenv("KESTRA_CONTEXT" => base64encode("{}")) do
                    e = errorof(() -> Kestra.context("typo.json"))
                    @test e isa SystemError && e.errnum == Libc.ENOENT
                    @test sprint(showerror, e) == "SystemError: Kestra execution context file 'typo.json': No such file or directory"
                end
            end
        end

        @testset "a directory fails instead of falling back" begin
            in_dir() do
                mkdir("ctx")
                withenv("KESTRA_EXECUTION_CONTEXT_FILE" => "ctx", "KESTRA_CONTEXT" => base64encode("{}")) do
                    e = errorof(Kestra.context)
                    @test e isa SystemError && e.errnum == Libc.EISDIR
                end
            end
        end

        @testset "bad content gets a distinct message that names its source" begin
            for (content, message) in [
                ("[1, 2]", "The execution context in .kestra-execution-context.json is not a JSON object."),
                ("null", "The execution context in .kestra-execution-context.json is not a JSON object."),
                ("{\"a\":", "The execution context in .kestra-execution-context.json is not valid JSON: it ends early."),
                ("{\"a\":1} x", "The execution context in .kestra-execution-context.json is not valid JSON: it fails at byte 9."),
                ("{\"a\":01}", "The execution context in .kestra-execution-context.json is not valid JSON: it fails at byte 6."),
                ("\xff", "The execution context in .kestra-execution-context.json is not valid JSON: it is not valid UTF-8."),
            ]
                in_dir(Kestra.CONTEXT_FILE => content) do
                    e = errorof(Kestra.context)
                    @test e isa ArgumentError && e.msg == message
                end
            end
            in_dir() do
                for (encoded, message) in [
                    ("{\"a\":1}", "The KESTRA_CONTEXT environment variable is not valid base64."),
                    ("e30", "The KESTRA_CONTEXT environment variable is not valid base64."),
                    (base64encode("[]"), "The execution context in KESTRA_CONTEXT is not a JSON object."),
                ]
                    withenv(() -> @test(errorof(Kestra.context).msg == message), "KESTRA_CONTEXT" => encoded)
                end
            end
        end

        @testset "fails clearly outside Kestra" begin
            in_dir() do
                e = errorof(Kestra.context)
                @test e isa SystemError && e.errnum == Libc.ENOENT
                @test occursin("only available when the script runs inside a Kestra task", sprint(showerror, e))
            end
        end
    end
end
