<p align="center">
  <img src="logo-for-light.png" alt="Delphi-JRPC" width="400" height="400" />
</p>

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
- **Transport Agnostic**: integrate into any transport layer (HTTP, WebSockets, named pipes, STDIO) — on both sides: `TJRPCServer` takes a string and returns one, `TJRPCClient` is handed an `IJRPCTransport`, as small as one function.
- **Typed Client**: call a remote method and get a Delphi value back — `ExecuteAs<T>` deserializes `result` through Neon, and an `error` member arrives as an exception.
- **One Client, Any Channel**: the same `TJRPCClient` over HTTP, a socket or stdio: calls in flight matched by id (`ExecuteAsync`), timeouts and cancellation, notifications, and requests from the peer answered by a handler or a local `TJRPCServer`.
- **Streaming Answers**: over HTTP, the notifications that arrive on the answer stream of a call (an SSE body) reach that call, and a long-lived stream (a subscription) is just a call that stays open.
- **Notifications from a running method**: a server method sends progress to its client before answering, through a `TJRPCNotifier` injected with `[Context]`.
- **Batch Processing**: multiple requests in a single batch.
- **Notification Support**: full JSON-RPC notification pattern.

## 📦 Core Components

| Component | Description |
| :--- | :--- |
| **JRPC.Core** | Base protocol types, message classes (`Request`, `Response`, `Notification`, `Error`), error codes, serialization logic and the class registry (`TJRPCRegistry`). |
| **JRPC.Invoker** | Maps JSON-RPC requests to Delphi method calls using RTTI and attributes. |
| **JRPC.Classes** | Supporting utilities: garbage collection, context management, route matching. |
| **JRPC.Server** | Transport-agnostic server component (`TJRPCServer`) that parses, dispatches and answers requests, including batches, and the `TJRPCNotifier` a method uses to notify its client while it runs. |
| **JRPC.Transport** | The transport contract (`IJRPCTransport`), the base class for persistent streams (`TJRPCPullTransport`), a transport made of closures (`TJRPCFuncTransport`) and an asynchronous in-process loopback (`TJRPCLoopbackTransport`). |
| **JRPC.Client** | Transport-agnostic client component (`TJRPCClient`): builds requests, keeps the calls in flight and matches the answers by id, deserializes `result` into a Delphi type, raises the peer's `error`, and serves what the peer sends on its own. |

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

`ProcessRequest` answers a single request with a single Response object, a batch with an array of Response objects, and a notification with an empty string (per the spec, a server never answers a notification).

### 3. Call it from a client

`TJRPCClient` is the mirror image, and one class serves every channel: HTTP, a socket, a child process over stdio, an in-process server. It links no transport either: you hand it an `IJRPCTransport`, and the transport is the only thing that changes from one channel to another. The library ships the generic ones (a transport made of closures, an in-process loopback, a base class for persistent streams); a network or process transport is written on top of them with whatever library is at hand (see Demos/CommandsTCP for an Indy socket).

```delphi
uses
  JRPC.Core,
  JRPC.Transport,
  JRPC.Client;

var
  LClient: TJRPCClient;
begin
  LClient := TJRPCClient.Create(nil);
  try
    // The quickest transport: a function that sends a payload and returns the
    // answer. A real HTTP client goes here - or LServer.ProcessRequest, to
    // loop back in-process.
    LClient.Transport := TJRPCFuncTransport.Create(
      function (const AText: string): string
      begin
        Result := MyHttp.Post(MyUrl, AText);
      end);

    // The id is generated, sent, and matched with the answer.
    WriteLn(LClient.ExecuteAs<Integer>(
      TJRPCRequestBuilder.New
        .SetMethod('math/sum')
        .AddNamedParam('a', 10)
        .AddNamedParam('b', 20)));
  finally
    LClient.Free;
  end;
end;
```

A failure the peer reports arrives as `EJRPCRemoteError`, carrying its `Code`, `Message` and structured `ErrorData`; a failure of the call itself (no transport, an unreadable answer, no answer at all, a timeout) arrives as `EJRPCClientError`. Assign `OnError` to log every failure in one place. By default the exception carries on as usual; the handler can change that through its `var AAction` parameter: `Raise` (the default), `Abort` (an `EAbort` is raised instead, which stops the flow silently) or `Ignore` (nothing is raised and the call returns an empty result: `Default(T)`, `nil`, `''` or an empty list). For an asynchronous call the choice applies when `Value` is read. `OnError` also sees the failures of the channel itself that no caller is waiting for; for those the action has no effect.

```pascal
FClient.OnError :=
  procedure (E: Exception; var AAction: TJRPCErrorAction)
  begin
    Log(E.Message);
    if E is EJRPCRemoteError then
      AAction := TJRPCErrorAction.Abort;
  end;
```

`ExecuteAsJSONValue` returns the raw `TJSONValue` instead and `ExecuteAsJsonString` its text, while `Execute` covers a call made for its effect, `Notify` a notification and `ExecuteBatch` a batch. Every synchronous call takes an optional timeout; `DefaultTimeout` applies when it is 0.

`TJRPCRequestBuilder` is interfaced, so the request is freed with it and no call site needs a `try/finally`. `Build` only *lends* the request out - the builder keeps ownership - so anything that adopts a request, `TJRPCMessages` in a batch above all, gets a plain `TJRPCRequest.Create` instead.

#### Calls in flight

`ExecuteAsync<T>` returns at once with an `IJRPCCall<T>`; `Value` waits and returns the result (or raises), `Cancel` gives up on it. The client keeps a map of the calls in flight and matches every answer by id, so calls overlap and may be answered in any order.

```delphi
var
  LInfo: IJRPCCall<TSysInfo>;
  LFiles: IJRPCCall<TArray<TDirEntry>>;
begin
  LInfo := LClient.ExecuteAsync<TSysInfo>(TJRPCRequestBuilder.New.SetMethod('sys/info'));
  LFiles := LClient.ExecuteAsync<TArray<TDirEntry>>(
    TJRPCRequestBuilder.New.SetMethod('dir/list').AddNamedParam('path', 'C:\'));

  if not LFiles.Wait(5000) then
    LFiles.Cancel                      // OnCallEnded fires: tell the peer, if it cares
  else
    ShowFiles(LFiles.Value);

  ShowInfo(LInfo.Value);
end;
```

#### Transports: two shapes

A transport says which shape it has through `RoundTrip`:

- **`RoundTrip = True`**: the answer is the outcome of the write (HTTP, a function over `ProcessRequest`). `Send` returns once the exchange is over, and hands every message of the answer to the client before returning: one body, or several SSE events with notifications before the response. No thread is involved; `ExecuteAsync` runs `Send` on a task of the thread pool so that calls overlap. `TJRPCFuncTransport` is one, and its `CreateFramed` constructor serves an answer made of several messages.
- **`RoundTrip = False`**: a persistent stream (stdio, a socket, a pipe). `Send` writes and returns, and whatever comes in is read on a thread of the transport, at any time. Derive from `TJRPCPullTransport` and implement three methods - `Receive` (blocking), `DoSend` and `DoClose`, which must unblock `Receive`; the reader thread and the serialized writes come with the base class. `TJRPCLoopbackTransport` is one, over a `TJRPCServer` that runs each request on a task: the answers come back out of order, as on a real channel.

```delphi
type
  TMyPipeTransport = class(TJRPCPullTransport)
  protected
    function Receive(out AText: string): Boolean; override;   // False at EOF
    procedure DoSend(const AText: string); override;
    procedure DoClose; override;
  end;
```

A transport that can stop reading the answer to one request (a long-lived subscription) also implements `IJRPCAbortableTransport`; the client calls it when such a call times out or is cancelled. None of the transports in the library implements it: a cancelled call over `TJRPCFuncTransport` stops waiting at once, but the function keeps running until the peer ends the answer.

#### What the peer sends on its own

Notifications go to `OnNotification`. Requests go to `OnRequest`, or to a local `TJRPCServer` assigned to `Server` (attributes, `[Context]` and errors work as on the server side); without either they are answered `-32601`. A request is answered through an `IJRPCReply`, from any thread, even after the handler returned; a reply released without an answer answers `-32603`, so the peer is never left waiting.

```delphi
LClient.OnRequest :=
  procedure (const ARequest: TJRPCRequest; const AReply: IJRPCReply)
  var
    LReply: IJRPCReply;
  begin
    LReply := AReply;
    TTask.Run(
      procedure
      begin
        LReply.Result(DoTheSlowThing);   // a TJSONValue, or any value Neon serializes
      end);
  end;
```

These handlers run on a dispatch thread of the client (`DispatchMode = Queue`, the default), one at a time, in arrival order: a handler can call the client synchronously, and a slow one never delays the answers to the calls in flight, which complete as soon as they arrive. `DispatchMode = Direct` runs them on the thread that received the message instead.

Since answers do not wait in that queue, with `Queue` a call can complete - and `Value` return - before `OnNotification` has run for a notification the peer sent ahead of the answer. When that order matters (a progress bar that must reach its end before the result shows), use `Direct`, as Demos/ProgressTCP does; it is safe as long as no handler calls the peer and waits.

A notification that arrives on the answer stream of a call (an SSE body) goes to that call when `ExecuteAsync` was given a handler for it, which is how progress reaches the right caller. A persistent channel (a socket, stdio) does not tie a notification to a call: there it goes to `OnNotification`.

```delphi
LCall := LClient.ExecuteAsync<TToolResult>(LRequest,
  procedure (const ANotification: TJRPCNotification)
  begin
    UpdateProgressBar(ANotification.Params);
  end);
```

`Close` fails every call in flight with `EJRPCClientError` and closes the transport; `OnClose` fires once, with a `TJRPCCloseInfo` saying who ended it and why. A closed client opens again once a new `Transport` is assigned. `NeonConfig` lets a client deserialize results with a configuration other than the default camel-cased one.

### 4. Method naming

By default a method is addressed as `path` + separator + `method`, where the separator is `/` (or whatever a class declares with the `separator=` tag):

```delphi
  [JRPCPath('math')]        // math/sum
  [JRPCPath('custom', 'separator=.')]  // custom.hello
```

A class that contributes **no path** - no attribute at all, or an explicitly empty `[JRPCPath('')]` - is *flat*: its methods declare the full JSON-RPC method name themselves, which is handy for protocols whose names are fixed (`tools/list`, `resources/read`, ...). Classes are registered explicitly, never discovered, so the attribute is only needed when it has something to say:

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

Flat and path-based classes coexist in the same registry: a fully qualified flat name is resolved first, and everything else falls back to the usual path lookup. In a flat class every exposed method needs its `[JRPCMethod]` attribute - there is no implicit fallback to the Delphi method name, and two classes claiming the same flat name are rejected at registration time.

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

### Notifications while a method runs

A transport with a channel back to the client (a socket, stdio) can pass `ProcessRequest` a sink: TJRPCServer then puts a `TJRPCNotifier` in the context, and a method sends notifications through it while it runs - progress, log lines - ahead of its answer.

```delphi
type
  TJobApi = class
  private
    [Context] FNotifier: TJRPCNotifier;
  public
    [JRPCMethod('job/run')]
    function Run([JRPCParam('steps')] ASteps: Integer): string;
  end;

// In the method: build a TJRPCNotification and FNotifier.Send(it).

// In the transport, on the connection's thread:
LResponse := FJRPCServer.ProcessRequest(LLine,
  procedure (const AText: string)
  begin
    AContext.Connection.IOHandler.WriteLn(AText, IndyTextEncoding_UTF8);
  end);
```

Without a sink there is no notifier: a plain `[Context]` field makes the call fail with `-32603` before the method runs, while `[Context([TContextOption.Optional])]` leaves the field nil, for a method that can do without. The notifier lives as long as the request: never keep it, nor use it from a thread that outlives the method.

## 🎯 Demo

Demos/CommandsTCP is a server and a client, two VCL executables over TCP, one JSON message per line. The server exposes five commands on a `TJRPCServer`; the client calls them with one `TJRPCClient` over the transport picked before connecting - a socket opened for each call (`TJRPCFuncTransport`), a socket kept open (`TIndyLineTransport`, a `TJRPCPullTransport` on Indy) or an in-process server (`TJRPCLoopbackTransport`) - and the same buttons show `ExecuteAs<T>`, `ExecuteAsJsonString`, `ExecuteAsync`, `ExecuteBatch` and `Notify` on all three. Its README describes the wire protocol.

Demos/ProgressTCP shows a call that talks back while it runs: a server and a client, two executables over TCP, one JSON message per line. The server's `job/run` is a plain `[JRPCMethod]` on a `TJRPCServer`; after every step it sends a `job/progress` notification through the `TJRPCNotifier` injected in its `[Context]` field, which writes on the connection of the request being served, ahead of the answer. The client starts the call with `ExecuteAsync`, moves a progress bar with each notification as it arrives, and shows the result once the call completes. It reuses the persistent line transport of CommandsTCP (`Client.Transport.pas`).

Each demo has a group project (`CommandsTCP.groupproj`, `ProgressTCP.groupproj`); the executables land in the demo's `Bin` folder.

## 🧪 Tests

`Tests/JRPC.Tests.Framework.dproj` is the DUnitX suite: protocol messages, the server, the invoker, the client over a function transport and over a persistent channel. `BuildTests.bat` builds and runs it; it needs the `DUnitX` environment variable set to the DUnitX Source folder.

```
BuildTests.bat
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
