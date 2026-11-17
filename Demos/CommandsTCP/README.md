# TCP Commands Protocol

The wire protocol for the `Demos/CommandsTCP` client/server pair: the client sends a
JSON-RPC 2.0 request over a TCP connection, the server runs it and answers. That is the
whole protocol.

- Transport: TCP (Indy `TIdTCPServer` / `TIdTCPClient`)
- Payload: JSON-RPC 2.0, dispatched by `TJRPCServer.ProcessRequest`
- Encoding: UTF-8, no BOM

## The demo

```
Demos/CommandsTCP/
  Server/  Server.Form.Main.pas      the Indy transport - the whole server
           Server.Protocol.Api.pas   the five commands
  Client/  Client.Form.Main.pas      one TJRPCClient, three transports to pick from
           Client.Transport.pas      the socket kept open, as a TJRPCPullTransport
```

Build both projects from `CommandsTCP.groupproj`, then run `Bin\Server.exe` and
`Bin\Client.exe`.

The server starts listening on **port 11099** as soon as its window opens
(`Server.exe <port>` overrides it) and logs every line in and out. The client has one
button per command, editable arguments, and a **send raw** box for typing malformed JSON
by hand to watch `-32700`, `-32600` and `-32601` come back.

Before connecting, the client picks its transport: a socket that writes a line and reads
the next one, a socket kept open and read on a thread of its own, or a `TJRPCServer` in
the client process, with no `Server.exe` at all (see
[Three transports, one client](#three-transports-one-client)). Besides the commands it
has a timeout, a **burst** of calls in flight at once, a **batch** and a **notify** button.

## Design rules

The point of this demo is to show how little you need to write. Four rules keep it there:

1. **A command is a method.** `sys/info`, `dir/list`, `ping` are JSON-RPC method names,
   mapped to Delphi methods by `[JRPCMethod]`. There is no command catalog, no `cmd/run`
   indirection, no command names hidden inside `params`.
2. **Every command is synchronous.** A request is answered before the next one is read. No
   jobs, no ids to track, no status, no cancel.
3. **The server keeps no state.** No handshake, no session, no login. Every request stands
   on its own, and connections are interchangeable.
4. **Errors are the five standard JSON-RPC codes.** No application code range.


---

## 1. Framing

JSON-RPC does not define message boundaries, so the protocol adds one rule:

> **One JSON message per line, terminated by LF (`#10`).**

Compact JSON never contains a raw newline (the RTL escapes control characters inside
strings), so a line break is an unambiguous terminator — and it is exactly one Indy call
on each side.

| Rule | Value |
| --- | --- |
| Terminator | `LF` (a trailing `CR` must be tolerated and stripped) |
| Empty line | Ignored — usable as a cheap keepalive |
| Max message size | 1 MiB |
| Encoding | UTF-8, no BOM |

> **Indy gotcha:** `TIdIOHandler.MaxLineLength` defaults to 16 KiB
> (`IdMaxLineLengthDefault`) and `ReadLn` raises `EIdReadLnMaxLineLengthExceeded` past it.
> Set it to the max message size on both sides.

## 2. Request and response

One line in, one line out:

```
client                                   server
  |-- {"jsonrpc":"2.0","id":1,...} ------->|
  |<------- {"jsonrpc":"2.0","id":1,...} --|
```

- The client owns the `id` and uses monotonic integers from 1. The server echoes it.
- Because calls are synchronous and answered in order, a client may simply write a line and
  read the next one. Checking the echoed `id` is still recommended — it catches a desync
  immediately instead of silently pairing the wrong answer to the wrong call. `TJRPCClient`
  does both: it generates the id and verifies the one that comes back.
- **A notification (a message with no `id`) gets no answer line at all.** If the client ever
  sends one, it must not block waiting for a response. The demo client sends requests only.
- Batches work (a JSON array in, a JSON array of responses out) because the library handles
  them; the demo does not use them from the UI.

Three things the wire actually shows, worth knowing before you write a client:

- **Nothing may carry a line break.** `TJRPCMessages.ToJson` follows the Neon configuration's
  pretty-print flag, which is off, so both a single message and a batch come out compact
  today. A payload built with a pretty-printing configuration would break the
  one-message-per-line rule, so both sides guard against it anyway: `Server.Form.Main`
  re-compacts any response containing a line break (`CompactJson`), and `TJRPCClient` does
  the same on the way out (`CompactPayload`, on by default).
- **A request with no parameters omits the `params` member.** `ShouldInclude` keeps it out of
  the JSON rather than emitting `"params":null`, which is neither an Array nor an Object and
  which a strict peer may answer `-32602`. This server accepts the member either way.
- **Non-ASCII travels as `\uXXXX` escapes** (`"àccenti"` goes out as `"àccenti"`), so the
  payload is pure ASCII on the wire and decodes back to the original text.

## 3. Commands

| Method | Params | Result |
| --- | --- | --- |
| `ping` | — | `"pong"` |
| `sys/info` | — | server info object |
| `sys/time` | — | ISO-8601 timestamp string |
| `echo` | `text` | the same text |
| `dir/list` | `path`, `mask` | array of directory entries |

`ping` and `echo` carry no path prefix: with `[JRPCPath('')]` (or no class attribute at
all) the `[JRPCMethod]` name *is* the full JSON-RPC method name. The others are grouped
under a path, so `[JRPCPath('sys')]` + `[JRPCMethod('info')]` answers `sys/info`.

### ping

```json
--> {"jsonrpc":"2.0","id":1,"method":"ping"}
<-- {"jsonrpc":"2.0","id":1,"result":"pong"}
```

### sys/info

The structured-result case: a Delphi class serialized by Neon straight into `result`.

```json
--> {"jsonrpc":"2.0","id":2,"method":"sys/info"}
<-- {"jsonrpc":"2.0","id":2,"result":{
      "host":"NB-PAOLO","os":"Windows 11","cpuCount":16,
      "serverVersion":"1.0.0","uptimeSec":3812}}
```

### sys/time

```json
--> {"jsonrpc":"2.0","id":3,"method":"sys/time"}
<-- {"jsonrpc":"2.0","id":3,"result":"2026-08-25T11:42:03.117Z"}
```

### echo

The parameter-passing case. Named parameters are the norm; positional
(`"params":["hello"]`) works too, since the library accepts both.

```json
--> {"jsonrpc":"2.0","id":4,"method":"echo","params":{"text":"hello JRPC"}}
<-- {"jsonrpc":"2.0","id":4,"result":"hello JRPC"}
```

### dir/list

The one that actually passes information both ways.

```json
--> {"jsonrpc":"2.0","id":5,"method":"dir/list",
     "params":{"path":"C:\\Temp","mask":"*.log"}}
<-- {"jsonrpc":"2.0","id":5,"result":[
      {"name":"app.log","size":90112,"modified":"2026-08-24T18:03:11Z"},
      {"name":"old.log","size":30720,"modified":"2026-08-20T09:15:44Z"}]}
```

> **Every parameter is required.** The invoker has no notion of an optional parameter: a
> missing one is `-32602`, not a default. So `mask` must be sent (use `"*.*"`), or the
> command needs a second method for the one-argument form. Worth knowing before designing
> a command's signature.

## 4. Errors

Only the standard codes, all produced by the library without any code of yours:

| Code | Meaning | When |
| --- | --- | --- |
| `-32700` | Parse error | the line was not valid JSON |
| `-32600` | Invalid request | valid JSON, but not a Request object |
| `-32601` | Method not found | no command by that name |
| `-32602` | Invalid params | a parameter is missing or of the wrong type |
| `-32603` | Internal error | the command raised an exception |

A command reports a failure by raising: `EJRPCException` carries its message into
`error.message` and maps to `-32603`, and any other exception maps there too.

```json
--> {"jsonrpc":"2.0","id":6,"method":"dir/list","params":{"path":"C:\\Nope","mask":"*.*"}}
<-- {"jsonrpc":"2.0","id":6,"error":{"code":-32603,"message":"Path not found: C:\\Nope"}}
```

```pascal
if not TDirectory.Exists(path) then
  raise EJRPCException.CreateFmt('Path not found: %s', [path]);
```

No exception class of your own is needed. (Custom codes would need one: `EJRPCException.Code`
is read-only and `AfterConstruction` forces `-32603`, so a subclass has to re-apply the code
*after* `inherited`. This demo deliberately does not go there.)

## 5. Delphi mapping

### Server API classes

```pascal
[JRPCPath('sys')]
TSysApi = class
public
  [JRPCMethod('info')]
  function Info: TServerInfo;

  [JRPCMethod('time')]
  function Time: string;
end;

[JRPCPath('dir')]
TDirApi = class
public
  [JRPCMethod('list')]
  function List([JRPCParam('path')] const path: string;
    [JRPCParam('mask')] const mask: string): TArray<TDirEntry>;
end;

// No path attribute: the method names are the full JSON-RPC method names.
TBasicApi = class
public
  [JRPCMethod('ping')]
  function Ping: string;

  [JRPCMethod('echo')]
  function Echo([JRPCParam('text')] const text: string): string;
end;
```

Register once, at startup, with a CamelCase Neon configuration so the JSON keys look like
this document:

```pascal
TJRPCRegistry.Instance.RegisterClass(TSysApi, TNeonConfiguration.Camel);
TJRPCRegistry.Instance.RegisterClass(TDirApi, TNeonConfiguration.Camel);
TJRPCRegistry.Instance.RegisterClass(TBasicApi);
```

`TServerInfo` and the `TDirEntry` items are created by the command and handed back: the
per-request garbage collector frees them once the response is serialized, so a command
never frees its own result.

### The server transport, in full

```pascal
procedure TServerForm.tcpServerExecute(AContext: TIdContext);
var
  LLine, LResponse: string;
begin
  LLine := AContext.Connection.IOHandler.ReadLn(IndyTextEncoding_UTF8);
  if LLine.Trim = '' then
    Exit;                                   // keepalive

  LResponse := FJRPCServer.ProcessRequest(LLine);
  if LResponse <> '' then                   // '' means it was a notification
    AContext.Connection.IOHandler.WriteLn(LResponse, IndyTextEncoding_UTF8);
end;
```

One `TJRPCServer` instance serves every connection. It holds no per-request state — the
context, the garbage collector and the API instances are all created and released inside
`ProcessRequest` — so no lock is needed as long as the commands themselves are
thread-safe.

That last clause carries all the weight: Indy runs `OnExecute` on a thread per
connection, so every command runs concurrently with the others. This demo's commands are
pure functions over their parameters, which is why it gets away with no locking at all —
a real server with a database, a cache or any shared state does not. The rules are spelled
out in the `THREAD SAFETY` comment at the top of `TServerForm.tcpServerExecute`; read it
before adding a command that touches anything outside its own arguments.

### The client call

`TJRPCClient` is the mirror image of `TJRPCServer`: where the server turns a string into a
string, the client turns a method call into a string and the answer back into a value. It
links no transport of its own, so the form says how a line reaches the socket - in the
simplest of its three transports, a `TJRPCFuncTransport` made of two closures:

```pascal
FClient := TJRPCClient.Create(nil);

FClient.Transport := TJRPCFuncTransport.Create(
  function (const ARequest: string): string
  begin
    tcpClient.IOHandler.WriteLn(ARequest, IndyTextEncoding_UTF8);
    Result := tcpClient.IOHandler.ReadLn(IndyTextEncoding_UTF8);
  end,
  // A notification gets no answer line at all, so it must not read one.
  procedure (const ARequest: string)
  begin
    tcpClient.IOHandler.WriteLn(ARequest, IndyTextEncoding_UTF8);
  end);
```

The form also points `OnError` at its logger once, so no button handler needs a
`try/except` of its own:

```pascal
FClient.OnError :=
  procedure (AError: Exception; var AAction: TJRPCErrorAction)
  begin
    LogError(AError);
    AAction := TJRPCErrorAction.Abort;
  end;
```

Setting `AAction` to `Abort` makes a failed call raise `EAbort` instead of its own
exception, once it has been logged: the rest of the button's code is skipped, and the VCL
drops an `EAbort` without showing a dialog. Left at its default, `Raise`, the exception
would carry on out of the call exactly as if nothing were assigned; `Ignore` would make the
call return an empty result instead of raising.

After that a call is one expression, and the result comes back as a Delphi type:

```pascal
LText := FClient.ExecuteAs<string>(
  TJRPCRequestBuilder.New
    .SetMethod('echo')
    .AddNamedParam('text', 'hello JRPC'));

LEntries := FClient.ExecuteAs<TArray<TDirEntry>>(   // the entries are yours to free
  TJRPCRequestBuilder.New
    .SetMethod('dir/list')
    .AddNamedParam('path', APath)
    .AddNamedParam('mask', AMask));
```

`ExecuteAsJSONValue` hands back the raw `TJSONValue` instead and `ExecuteAsJsonString` its
text, while `Execute` covers a call made for its effect, `Notify` a notification and
`ExecuteBatch` a batch. The **send raw** box writes its text straight on the socket, past
the client, which is how it still provokes `-32700` by hand.

Three things the client does that hand-written code usually skips:

- **The id is generated and matched.** `TJRPCClient.NewId` hands out interlocked integers,
  and an answer goes only to the call whose id it echoes - kind included, so the string
  `"7"` never passes for the number `7`. An answer nobody waits for is reported, and the
  call that got none fails, instead of quietly returning the previous call's answer.
- **An `error` member becomes an exception.** `EJRPCRemoteError` carries the server's own
  `Code`, `Message` and, in `ErrorData`, the `data` member - *lifted from the raw JSON*,
  because `TJRPCErrorDetails.Data` is a `TValue` that only survives numbers, strings and
  booleans. A failure of the client itself (no transport, unreadable answer, no answer)
  raises `EJRPCClientError` instead, so "the server said no" stays distinct from "the call
  never completed".
- **The reply is classified before it is read.** Note that `TJRPCResponse.CreateFromJson`
  **raises** when there is no `result` member - which is exactly what an error reply is - so
  a reply must go through `TJRPCMessages.CreateFromJson` first. The client does this for
  you; code that parses answers by hand has to remember it.

`TJRPCRequestBuilder` is interfaced, so the request it is building is freed with it and no
call site needs a `try/finally`. But `Build` only **lends** the request out - the builder
keeps ownership - so anything that *adopts* a request takes a plain `TJRPCRequest.Create`
instead. `ExecuteBatch` is the case that matters: `TJRPCMessages` owns what it is given,
and a built request handed to it would be freed twice.

Building by hand is otherwise unchanged: `AddNamedParam` / `AddPositionParam` build the
`params` member (never both in one message - JSON-RPC 2.0 has no shape for that), while
assigning `Request.Params` directly **takes ownership** of the `TJSONValue` you hand it,
so never free that object yourself.

### Three transports, one client

The combo box at the top picks the transport before **Connect**. Everything below it - the
buttons, the hooks, the log - is the same code whatever was picked: the client only knows
an `IJRPCTransport`.

| Transport | Class | How a message travels |
|---|---|---|
| Socket, one line per call | `TJRPCFuncTransport` | `Send` writes the request and reads the next line as its answer |
| Socket kept open | `TJRPCPullTransport` (`TIndyLineTransport`) | `Send` only writes; a reader thread reads every line and the client matches it to its call by id |
| In process, no server | `TJRPCLoopbackTransport` | a `TJRPCServer` in the client process runs each message on a task of its own |

**One line per call** is the transport of [The client call](#the-client-call), with two
additions that only `ExecuteAsync` makes necessary. The closures run on tasks of the
thread pool, several at once, and one socket only takes one exchange at a time, so they
take a lock. And a call that times out leaves its answer on the socket, where the next call
would read it as its own, so the form drops the connection instead of carrying on out of
step.

**Socket kept open** derives from `TJRPCPullTransport`, which owns the reader thread and
serializes the writes. `Client.Transport.pas` implements a blocking `Receive`, a `DoSend`
and a `DoClose`, one JSON message per line:

```pascal
function TIndyLineTransport.Receive(out AText: string): Boolean;
begin
  while not Closed do
  begin
    AText := FClient.IOHandler.ReadLn(LF, RECEIVE_POLL_MS, FMaxLineLength, IndyTextEncoding_UTF8);
    if FClient.IOHandler.ReadLnTimedout or (AText.Trim = '') then
      Continue;                             // nothing yet, or a keepalive
    Exit(True);
  end;
  Result := False;                          // DoClose was called
end;
```

`DoClose` must unblock a pending `Receive`. Disconnecting an Indy socket from another
thread while `ReadLn` runs on it is a race, so `Receive` reads with a short timeout and
`DoClose` only raises a flag. The form disconnects the socket itself, and only after
`TJRPCClient.Close` has joined the reader. A server that goes away ends `ReadLn` with
`EIdConnClosedGracefully`, which `Receive` turns into `False`: the client fails the pending
calls and fires `OnClose` with the reason.

**In process** needs no `Server.exe` at all. The client project links
`Server\Server.Protocol.Api.pas`, whose `initialization` registers `TBasicApi` with the
global registry, and the form creates a `TJRPCServer` of its own. The answers come back in
whatever order the tasks finish, exactly as over a real persistent channel.

Whatever the transport, connecting is the same:

```pascal
FClient := TJRPCClient.Create(nil);
FClient.Transport := CreateTransport(FKind);  // one of the three
FClient.OnBeforeSend := ...;                  // the trace, '-->'
FClient.OnAfterReceive := ...;                // the trace, '<--'
FClient.OnError := ...;                       // every failure, once
FClient.OnCallEnded := ...;                   // a call that stopped waiting
FClient.OnNotification := ...;                // runs on the client's dispatch thread
FClient.OnClose := ...;                       // with a TJRPCCloseInfo
FClient.Open;
```

What the buttons show:

- **Synchronous** - the five commands with `ExecuteAs<T>` and the timeout from the top bar:
  `ExecuteAs<string>` for `ping`, `sys/time` and `echo`, `ExecuteAsJsonString` for the
  object `sys/info` returns, `ExecuteAs<TArray<TDirEntry>>` for `dir/list`. Set a timeout
  of 1 ms to watch one expire. Over the socket kept open the late answer still shows up in
  the trace, and the client reports it as an answer nobody waits for; over one line per
  call the connection is closed.
- **Asynchronous** - **burst** sends N `echo` requests with `ExecuteAsync<string>` before
  reading any answer, then waits for each call and reads its `Value`. Compare the time it
  takes over the three transports.
- **ExecuteBatch and Notify** - **batch** sends `ping`, `echo`, a method that does not
  exist and a notification as one JSON array. The error comes back in the list rather than
  as an exception, and the notification gets no answer at all. **notify ping** sends a
  notification on its own: the server runs `ping` and answers nothing.
- **Raw, past the client** - writes the text straight on the socket, which is how it still
  provokes `-32700` by hand. Only over one line per call: with a reader thread the answer
  would be the reader's.

The threads the hooks run on depend on the transport: the caller's, a task of the pool,
the reader, or the client's dispatch thread (`OnNotification`, `OnRequest`). The form never
touches the VCL from them: it buffers the log lines and a timer writes them to the memo.

The server never pushes, so `OnNotification` stays silent here. There is no `OnRequest`
either: a request from the server would be answered `-32601` by the client itself.

## 6. Adding a command

1. Add a method to an API class, with `[JRPCMethod('name')]` and a `[JRPCParam]` per argument.
2. Return whatever it produces — a string, a number, a class, an array of classes. Neon
   serializes it; the garbage collector owns it.
3. Raise `EJRPCException` to report a failure.

There is no step 4: nothing is registered per command, and the client needs no change to
be able to call it.
