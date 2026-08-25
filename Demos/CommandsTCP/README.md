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
  Client/  Client.Form.Main.pas      one button per command
```

Build both projects with `BuildTCPCommands.bat` in the repository root, then run
`Server\Win32\Debug\Server.exe` and `Client\Win32\Debug\Client.exe`.

The server starts listening on **port 11099** as soon as its window opens
(`Server.exe <port>` overrides it) and logs every line in and out. The client has one
button per command, editable arguments, and a **send raw** box for typing malformed JSON
by hand to watch `-32700`, `-32600` and `-32601` come back.

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
  immediately instead of silently pairing the wrong answer to the wrong call.
- **A notification (a message with no `id`) gets no answer line at all.** If the client ever
  sends one, it must not block waiting for a response. The demo client sends requests only.
- Batches work (a JSON array in, a JSON array of responses out) because the library handles
  them; the demo does not use them from the UI.

Three things the wire actually shows, worth knowing before you write a client:

- **A batch answer must be compacted before it is sent.** `TJRPCMessages.ToJson` serializes a
  single response compactly, but a batch goes through `TNeon.Print(..., True)` and comes back
  *pretty-printed* — which would break the one-message-per-line rule. `Server.Form.Main`
  re-compacts any response containing a line break (`CompactJson`).
- **A request with no parameters carries `"params":null`.** That is what `TJRPCRequest.ToJson`
  emits, and this server accepts it, as it accepts `params` being absent entirely.
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

```pascal
var
  LRequest: TJRPCRequest;
  LResponse: string;
begin
  LRequest := TJRPCRequest.Create;
  try
    Inc(FLastId);
    LRequest.Id := FLastId;                     // Integer, string and Int64 ids all work
    LRequest.Method := 'echo';
    LRequest.AddNamedParam('text', 'hello JRPC');

    tcpClient.IOHandler.WriteLn(LRequest.ToJson, IndyTextEncoding_UTF8);
    LResponse := tcpClient.IOHandler.ReadLn(IndyTextEncoding_UTF8);
  finally
    LRequest.Free;
  end;
```

`AddNamedParam` / `AddPositionParam` build the `params` member for you. Assigning
`Request.Params` directly works too, but it **takes ownership** of the `TJSONValue` you
hand it (the request frees it), so never free that object yourself.

Parse the answer with `TJRPCResponse.CreateFromJson` (or `TJRPCMessages.CreateFromJson`
when batches are in play) and check for an `error` member before reading `result`.

## 6. Adding a command

1. Add a method to an API class, with `[JRPCMethod('name')]` and a `[JRPCParam]` per argument.
2. Return whatever it produces — a string, a number, a class, an array of classes. Neon
   serializes it; the garbage collector owns it.
3. Raise `EJRPCException` to report a failure.

There is no step 4: nothing is registered per command, and the client needs no change to
be able to call it.
