# Delphi-JRPC: JSON-RPC 2.0 Library for Delphi

A modern, attribute-driven **JSON-RPC 2.0** framework for Delphi, built on RTTI and the [Neon](https://github.com/paolo-rossi/delphi-neon) serialization library.

## 🚀 Key Features

- **Protocol Compliance**: full support for the [JSON-RPC 2.0](https://www.jsonrpc.org/specification) specification.
- **Attribute-Driven**: map Delphi methods to JSON-RPC endpoints with simple attributes like `[JRPCMethod]` and `[JRPCParam]`.
- **Automatic Marshaling**: seamless conversion between JSON and Delphi types (integers, strings, enums, classes, records, arrays).
- **Memory Management**: built-in **garbage collector** for request-scoped objects.
- **Context Injection**: per-request dependency injection via the `[Context]` attribute.
- **Flexible Routing**: `TRouteMatcher` for URI-style template matching and parameter extraction.
- **Flexible Naming**: `path` + separator + `method`, a custom separator, or *flat* classes (`[JRPCPath('')]`) whose methods declare the full name (`tools/call`).
- **High Performance**: powered by [Neon](https://github.com/paolo-rossi/delphi-neon), with built-in **TStopwatch [PERF] instrumentation** in the invoker and the server.
- **Transport Agnostic**: integrate into any transport layer (HTTP, WebSockets, named pipes, STDIO).
- **Batch Processing**: multiple requests in a single batch.
- **Notification Support**: full JSON-RPC notification pattern.

## 📦 Core Components

| Component | Description |
| :--- | :--- |
| **JRPC.Core** | Base protocol types, message classes (`Request`, `Response`, `Notification`, `Error`), error codes, serialization logic and the class registry (`TJRPCRegistry`). |
| **JRPC.Invoker** | Maps JSON-RPC requests to Delphi method calls using RTTI and attributes. |
| **JRPC.Classes** | Supporting utilities: garbage collection, context management, route matching. |
| **JRPC.Server** | Transport-agnostic server component (`TJRPCServer`) that parses, dispatches and answers requests, including batches. |
| **Logify** | The logging backend for the [PERF] TStopwatch instrumentation (via the global `Logger`). Register an adapter (`TLoggerAdapterRegistry.Instance.RegisterFactory(...)`) to see the timing logs. |

## 🛠️ Quick Start

### 1. Define an API class

```delphi
type
  [JRPCPath('math')]
  TMathApi = class
  public
    [JRPCMethod('sum')]
    function Sum([JRPCParam('a')] A: Integer; [JRPCParam('b')] B: Integer): Integer;

    [JRPCMethod('echo')]
    function Echo([JRPCParam('message')] const AMessage: string): string;
  end;

function TMathApi.Sum(A, B: Integer): Integer;
begin
  Result := A + B;
end;
```

### 2. Register and serve

```delphi
uses
  JRPC.Core,
  JRPC.Server;

// Once, at startup:
TJRPCRegistry.Instance.RegisterClass(TMathApi);

// Per request (a transport feeds the raw JSON in, sends the JSON out):
var
  LServer: TJRPCServer;
  LResponse: string;
begin
  LServer := TJRPCServer.Create(nil);
  try
    LResponse := LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":1,"method":"math/sum","params":{"a":10,"b":20}}');
    // LResponse = {"result":30,"id":1,"jsonrpc":"2.0"}
  finally
    LServer.Free;
  end;
end;
```

``ProcessRequest`` answers a single request with a single Response object, a
batch with an array of Response objects, and a notification with an empty
string (per the spec, a server never answers a notification).

### 3. Method naming

By default a method is addressed as `path` + separator + `method`, where the
separator is `/` (or whatever a class declares with the `separator=` tag):

```delphi
  [JRPCPath('math')]        // math/sum
  [JRPCPath('custom', 'separator=.')]  // custom.hello
```

A class that contributes **no path** - no attribute at all, or an explicitly
empty `[JRPCPath('')]` - is *flat*: its methods declare the full JSON-RPC method
name themselves, which is handy for protocols whose names are fixed
(`tools/list`, `resources/read`, ...). Classes are registered explicitly, never
discovered, so the attribute is only needed when it has something to say:

```delphi
type
  TToolsApi = class          // no attribute needed
  public
    [JRPCMethod('tools/list')]
    function ToolsList: string;

    [JRPCMethod('tools/call')]
    function ToolsCall([JRPCParam('name')] const AName: string): string;

    [JRPCMethod('ping')]      // no separator needed at all
    function Ping: string;
  end;
```

Flat and path-based classes coexist in the same registry: a fully qualified
flat name is resolved first, and everything else falls back to the usual
path lookup. In a flat class every exposed method needs its `[JRPCMethod]`
attribute - there is no implicit fallback to the Delphi method name, and two
classes claiming the same flat name are rejected at registration time.

## 🧩 Context Injection & Memory Management

```delphi
type
  [JRPCPath('ctx')]
  TContextApi = class
  private
    [Context] FGC: IGarbageCollector;
    [Context] Request: TJRPCRequest;
  public
    [JRPCMethod('method')]
    function GetRequestMethod: string;
  end;

function TContextApi.GetRequestMethod: string;
begin
  Result := 'request=' + Request.Method;

  // Objects registered with the garbage collector are freed automatically
  // when the request finishes - no manual Free here.
  var LScoped := TStringList.Create;
  FGC.Add(LScoped);
  LScoped.Add('freed with the request');
end;
```

## 🎯 Demo

Demo/JRPCDemo is a console test runner that exercises the library end to end:
named/positional parameters, notifications, batches (including batches with
invalid elements), all standard error codes, object results with default and
per-class Neon casing, whole-params objects (`[JRPCParams]`), enum parameters,
null-id round trips, context injection, garbage collection and custom
separators. It exits with a non-zero code when any assertion fails, and it
registers a Logify console adapter at startup so the [PERF] timing lines are
printed between every request/response pair.

```
BuildDemo.bat
```

Demo/JRPCExample showcases a realistic example API - a notes CRUD service
over an in-memory store (object params/results, array results, enums), plus
custom separators, per-class Neon casing and context injection - as a guided
showcase followed by an interactive prompt where any request can be typed and
answered:

```
BuildExample.bat
```

## ⚙️ Requirements

- **Delphi 11** or newer.

## 📦 Required dependencies

- **Neon**: high-performance JSON serialization for Delphi ([github.com/paolo-rossi/delphi-neon](https://github.com/paolo-rossi/delphi-neon)).
- **Logify**: meta-logger used by the [PERF] instrumentation ([github.com/delphi-blocks/Logify](https://github.com/delphi-blocks/Logify)).

Clone both dependencies into `Libs\` (the demo and test projects resolve them from there):

```
git clone https://github.com/paolo-rossi/delphi-neon Libs\Neon
git clone https://github.com/delphi-blocks/Logify Libs\Logify
```

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.
