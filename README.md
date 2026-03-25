# swift-shell

A Swift 6 shell command executor with streaming I/O, typed output decoding, and injectable execution for mocking. macOS 14+, no dependencies.

## Core Types

`Shell<Error>` is generic over `ShellExecutionError`. The built-in implementation is `ShellAtPath` (typealias for `Shell<ShellAtPathError>`), which runs commands via `/bin/bash -c`.

```swift
let shell = Shell.atPath()
let result = await shell.execute("echo 'hello world'")
let output = try result.get().decodeString()
print(output.stdoutTyped) // "hello world\n"
```

**`ShellResult<Error>`** — returned by every `execute` call:
- `error: Error?` — nil on success
- `processOutput: ShellProcessOutput` — raw `stdout`/`stderr` as `Data`
- `termination: ShellTermination` — `.reason` (exit/uncaughtSignal/unknown) and `.status`
- `get() throws(Error) -> ShellProcessOutput` — throws if error is non-nil

**`ShellProcessOutput`** — decode stdout/stderr via:
- `.decodeString()` → `Decoded<String, String>`
- `.decodeStringLines()` → `Decoded<[String], [String]>`
- `.decodeJSON()` → `Decoded<Output, Error>` (generic, uses `JSONDecoder`)
- `.decode(stderrDecode:stdoutDecode:)` → custom decoding

## Execute Options

```swift
shell.execute(
    "command",
    dryRun: Bool,                    // wraps command in echo
    estimatedOutputSize: Int?,       // pre-allocates stdout buffer
    estimatedErrorSize: Int?,        // pre-allocates stderr buffer
    statusesForResult: .init(        // configurable success/cancellation statuses
        cancellations: [15],
        successes: [0]
    ),
    stream: ShellStream?,            // interactive stdin (see below)
    timeout: TimeInterval?           // kills process after interval
)
```

## Streaming I/O

`ShellStream` enables interactive stdin by responding to incremental stdout/stderr data. Callbacks receive the cumulative `ShellProcessOutput` plus incremental `Data`, and return optional `Data` to write to stdin.

```swift
// Convenience constructor for String-based interaction:
let stream = ShellStream.stringStream(
    onError: { allOutput, allStderr, incrementalData in nil },
    onOutput: { allOutput, allStdout, incrementalData in
        return "input to stdin\n"  // or nil for no input
    }
)
```

## Observing

`ShellObserver<Error>` attaches to a `Shell` instance (vs `ShellStream` which is per-command). Observers cannot write to stdin.

```swift
let observer = ShellObserver(
    onError:  { command, allOutput, stderrIncremental in },
    onOutput: { command, allOutput, stdoutIncremental in },
    onResult: { command, result in }
)
let shell = Shell.atPath(shellObserver: observer)
```

## Mocking

`Shell` accepts a custom `ShellExecute` closure, making it injectable:

```swift
let mock = Shell { command, dryRun, _, _, _, _, _ in
    .success(stdout: "mocked output")!
}
```

## Internals

- **`ShellSerialize`** — actor-based serial queue ensuring ordered I/O processing
- **`ReadWriteLock<Value>`** — pthread rwlock wrapper for synchronous shared state
- **`ShellTaskCancellationHandler`** — tracks and cancels spawned tasks on termination
- **`ShellAtPathError`** — error kinds: `cancelled`, `run`, `streamInputWriteErr/Out`, `streamOnErr/Out`, `termination`, `timeout`

## License

Copyright (c) 2025 Jared Bourgeois — Apache License v2.0 with Runtime Library Exception
