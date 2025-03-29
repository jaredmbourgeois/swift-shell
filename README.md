# swift-shell

## A `Shell` command executor.

### `Shell.execute` can be injected for easy mocking and custom implementations.

## `Shell.execute` returns a `ShellResult`

```swift
struct ShellResult: Sendable {
    let error: ShellError?
    // stdout, stderr
    let processOutput: ShellProcessOutput
    // reason, status
    let termination: ShellTermination
}
```

### `ShellProcessOutput.Typed` provdes opportunity to decode `stdout` and `stderr`

```swift
struct Typed<Output: Sendable & Decodable, Error: Sendable & Decodable>: Sendable {
    let shellProcessOutput: ShellProcessOutput
    let stdoutTyped: Output
    let stderrTyped: Error
}
```

## `ShellStream` as an `execute` parameter provides input after the `Shell` command is started

```swift
struct ShellStream: Sendable {
    let onOutput: @Sendable (ShellProcessOutput, Data) async -> Data?
    let onError: @Sendable (ShellProcessOutput, Data) async -> Data?
}
```

### Typed `ShellStream`s provide opportunity to decode `ShellProcessOutput` and encode `stdin`.
- eg, `ShellStream.stringStream`

```swift
extension ShellStream {
    static func stringStream(
        encoding: String.Encoding = .utf8,
        onOutput: @escaping @Sendable (ShellProcessOutput.Typed<String, String>, _ incrementalData: Data) async throws -> String?,
        onError: @escaping @Sendable (ShellProcessOutput.Typed<String, String>, _ incrementalData: Data) async throws -> String?
    ) -> ShellStream {
        .typedStream(
            encodeInput: {
                guard let data = $0.data(using: encoding) else {
                    throw StringStreamError.encode
                }
                return data
            },
            onOutput: onOutput,
            onOutputDecode: {
                guard let data = String(data: $0, encoding: encoding) else {
                    throw StringStreamError.decodeOutput($0.count)
                }
                return data
            },
            onError: onError,
            onErrorDecode: {
                guard let data = String(data: $0, encoding: encoding) else {
                    throw StringStreamError.decodeError($0.count)
                }
                return data
            }
        )
    }
}
```  

## Inject a `ShellObserver` to see commands and their results

- `ShellObserver` is by `Shell` vs `ShellStream` is per command.
- `ShellStream`s allow `stdin` vs `ShellObserver`s do not.

```swift
struct ShellObserver: Sendable {
    let onError: (@Sendable (String, ShellProcessOutput, Data) async -> Void)?
    let onOutput: (@Sendable (String, ShellProcessOutput, Data) async -> Void)?
    let onResult: (@Sendable (String, ShellResult) async -> Void)?
}
```

## Example

```swift
let shell = Shell.atPath()
let result: ShellResult = await shell.execute("echo 'hello world'")
let stringOutput = try result.processOutput.stringProcessOutput()
asssert(stringOutput.stderrTyped.isEmpty)
print(stringOutput.stdoutTyped)
```

Copyright (c) 2025 Jared Bourgeois

Licensed under Apache License v2.0 with Runtime Library Exception
