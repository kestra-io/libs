// F# calls of the same library. Run from the dotnet directory after `dotnet build Kestra -c Release -o out`:
// dotnet fsi Kestra.Tests/fsharp.fsx
#r "../out/Kestra.dll"

let capture f =
    let real = System.Console.Out
    let writer = new System.IO.StringWriter()
    System.Console.SetOut writer
    try f () finally System.Console.SetOut real
    writer.ToString()

let expect expected actual =
    if actual <> expected then failwithf "expected %A, got %A" expected actual

expect "::{\"outputs\":{\"pair\":[1,\"a\"],\"rows\":42,\"some\":3,\"tiers\":[\"gold\"]}}::\n"
    (capture (fun () -> Kestra.Outputs {| rows = 42; tiers = [ "gold" ]; pair = (1, "a"); some = Some 3 |}))
expect "::{\"metrics\":[{\"name\":\"orders\",\"type\":\"counter\",\"value\":120,\"tags\":{\"env\":\"qa\"}}]}::\n"
    (capture (fun () -> Kestra.Counter("orders", 120, dict [ ("env", "qa") ])))
expect "::{\"logs\":[{\"level\":\"WARN\",\"message\":\"2 orders had no customer\"}]}::\n"
    (capture (fun () -> Kestra.Logger.Warning("{Count} orders had no customer", 2)))
let mutable result = 0
capture (fun () -> result <- Kestra.Timer("fetch", fun () -> 42)) |> ignore
expect 42 result
printfn "F# calls pass"
