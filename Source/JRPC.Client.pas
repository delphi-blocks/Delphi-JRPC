{******************************************************************************}
{                                                                              }
{  Delphi-JRPC - JSON-RPC 2.0 Library for Delphi                               }
{                                                                              }
{  Copyright (c) 2026     Paolo Rossi <dev@paolorossi.net>                     }
{                         Luca Minuti <code@lucaminuti.it>                     }
{                                                                              }
{  All rights reserved                                                         }
{  Licensed under the MIT license                                              }
{                                                                              }
{******************************************************************************}
unit JRPC.Client;

interface

uses
  System.Classes, System.SysUtils, System.Rtti, System.JSON, System.SyncObjs,

  Neon.Core.Persistence,

  JRPC.Core;

type
  /// <summary>
  ///   A failure of the client itself: no transport, an unreadable answer, an
  ///   answer that does not belong to the request that was sent.
  /// </summary>
  /// <remarks>
  ///   Deliberately distinct from EJRPCRemoteError: this one says "the call
  ///   never completed", the other says "the call completed and the peer said
  ///   no". Retrying makes sense for the first and rarely for the second. It
  ///   carries the inherited -32603, so a client used as a gateway can turn it
  ///   into a well formed error response without inventing a code.
  /// </remarks>
  EJRPCClientError = class(EJRPCException);

  /// <summary>
  ///   The "error" member the peer sent back, raised as a Delphi exception.
  ///   Code and Message are the server's own; ErrorData is the untouched
  ///   "data" member, when the server sent one.
  /// </summary>
  /// <remarks>
  ///   Two things are worth knowing about how this is filled in.
  ///
  ///   The inherited Code is read-only and EJRPCException.AfterConstruction
  ///   stamps -32603 over any code left at 0 - which would silently rewrite a
  ///   peer that legitimately answered 0. The remote code is therefore kept
  ///   aside and re-applied in this class's AfterConstruction, which runs
  ///   *after* the inherited one: whatever came off the wire is what Code
  ///   reports.
  ///
  ///   ErrorData is read from the raw JSON, not from TJRPCErrorDetails.Data:
  ///   that property is a TValue fed by TJValueSerializer, which maps only
  ///   numbers, strings and booleans and hands back an empty TValue for an
  ///   object or an array - so every structured payload (MCP defines several)
  ///   would be lost on the way in.
  /// </remarks>
  EJRPCRemoteError = class(EJRPCException)
  private
    FRemoteCode: Integer;
    FErrorData: TJSONValue;
  public
    /// <summary>
    ///   Takes ownership of AErrorData, which may be nil.
    /// </summary>
    constructor Create(ACode: Integer; const AMessage: string;
      AErrorData: TJSONValue); reintroduce;
    destructor Destroy; override;

    procedure AfterConstruction; override;

    /// <summary>
    ///   The "data" member of the error object, owned by the exception, or nil
    ///   when the peer sent none. Clone it if it must outlive the handler.
    /// </summary>
    property ErrorData: TJSONValue read FErrorData;
  end;

  /// <summary>
  ///   Builds a Request in one expression:
  ///   TJRPCRequestBuilder.New.SetMethod('dir/list').AddNamedParam('path', APath)
  /// </summary>
  /// <remarks>
  ///   Interfaced, so the request it is building is freed with the builder and
  ///   no call site needs a try/finally. Build only lends the request out - the
  ///   builder keeps ownership - so the interface must stay in scope for as
  ///   long as the request is in use. Passing the builder straight to ExecuteAs
  ///   does exactly that.
  ///
  ///   Named and positional params never mix in one message: JSON-RPC 2.0 has
  ///   no shape for that, and TJRPCMethod raises if they are combined.
  ///
  ///   IJRPCNotificationBuilder is the twin of this one, and the two share no
  ///   ancestor interface on purpose: Delphi has no covariant return types, so
  ///   an inherited SetMethod could only hand back the base interface, and the
  ///   chain would lose its type halfway through - along with Build and the
  ///   Execute overload that takes it. What the two do share is the
  ///   implementation, in TJRPCMethodBuilder.
  /// </remarks>
  IJRPCRequestBuilder = interface
    ['{04F411DA-409A-4917-995D-046C1C683B55}']
    function SetMethod(const AName: string): IJRPCRequestBuilder;

    function AddPositionParam(const AValue: TValue): IJRPCRequestBuilder;
    function AddNamedParam(const AName: string; const AValue: TValue): IJRPCRequestBuilder;

    /// <summary>
    ///   The request built so far, still owned by the builder.
    /// </summary>
    function Build: TJRPCRequest;
  end;

  /// <summary>
  ///   Builds a Notification in one expression:
  ///   TJRPCNotificationBuilder.New.SetMethod('log/write').AddNamedParam('text', AText)
  /// </summary>
  /// <remarks>
  ///   The same shape and the same ownership rule as IJRPCRequestBuilder, minus
  ///   the id: a notification carries none, the peer answers nothing, and there
  ///   is nothing to correlate. TJRPCClient.Execute takes this interface
  ///   directly, which keeps the notification alive for the whole call.
  /// </remarks>
  IJRPCNotificationBuilder = interface
    ['{0E86228E-44D6-4CDB-A94E-5A22D6D06138}']
    function SetMethod(const AName: string): IJRPCNotificationBuilder;

    function AddPositionParam(const AValue: TValue): IJRPCNotificationBuilder;
    function AddNamedParam(const AName: string; const AValue: TValue): IJRPCNotificationBuilder;

    /// <summary>
    ///   The notification built so far, still owned by the builder.
    /// </summary>
    function Build: TJRPCNotification;
  end;

  TJRPCMethodClass = class of TJRPCMethod;

  /// <summary>
  ///   What the two builders have in common: the message being filled in, its
  ///   lifetime, and the operations that live on TJRPCMethod rather than on a
  ///   Request or a Notification.
  /// </summary>
  /// <remarks>
  ///   It implements no interface of its own - each descendant declares one, so
  ///   that the fluent chain keeps the concrete type all the way to Build. The
  ///   message class arrives as a parameter rather than through a virtual hook:
  ///   the descendant names it once, and nothing virtual is dispatched from a
  ///   constructor.
  /// </remarks>
  TJRPCMethodBuilder = class abstract(TInterfacedObject)
  protected
    FMethod: TJRPCMethod;

    /// <summary>
    ///   Creates the message AMethodClass names; the builder owns it.
    /// </summary>
    constructor Create(AMethodClass: TJRPCMethodClass);
  public
    destructor Destroy; override;
  end;

  TJRPCRequestBuilder = class(TJRPCMethodBuilder, IJRPCRequestBuilder)
  public
    /// <summary>The way in: returns the interface, so nothing is freed by hand.</summary>
    class function New: IJRPCRequestBuilder;

    constructor Create;

    function SetMethod(const AName: string): IJRPCRequestBuilder;

    function AddPositionParam(const AValue: TValue): IJRPCRequestBuilder;
    function AddNamedParam(const AName: string; const AValue: TValue): IJRPCRequestBuilder;

    function Build: TJRPCRequest;
  end;

  TJRPCNotificationBuilder = class(TJRPCMethodBuilder, IJRPCNotificationBuilder)
  public
    /// <summary>The way in: returns the interface, so nothing is freed by hand.</summary>
    class function New: IJRPCNotificationBuilder;

    constructor Create;

    function SetMethod(const AName: string): IJRPCNotificationBuilder;

    function AddPositionParam(const AValue: TValue): IJRPCNotificationBuilder;
    function AddNamedParam(const AName: string; const AValue: TValue): IJRPCNotificationBuilder;

    function Build: TJRPCNotification;
  end;

  /// <summary>
  ///   How a TJRPCClient reaches its peer.
  /// </summary>
  /// <remarks>
  ///   Two methods, because the two halves of JSON-RPC behave differently on
  ///   the wire: a Request is written and its answer is read back, while a
  ///   Notification is written and nothing at all comes back - reading after
  ///   one would block until the transport times out. Implement it over
  ///   whatever is at hand (Indy, WinINet, a named pipe, an in-process
  ///   server); the library itself never links a transport.
  /// </remarks>
  IJRPCClientTransport = interface
  ['{2A0C0A4E-9F7A-4C4B-9B44-3F2B5F21A7E1}']
    /// <summary>
    ///   Writes ARequest and returns the whole answer. Returning an empty
    ///   string for a payload that carries an id is reported as a protocol
    ///   failure, not as an empty result.
    /// </summary>
    function SendAndReceive(const ARequest: string): string;

    /// <summary>
    ///   Writes ARequest and returns at once, without reading anything back.
    ///   Used for notifications and for batches made only of notifications.
    /// </summary>
    procedure Send(const ARequest: string);
  end;

  /// <summary>
  ///   The ad-hoc form of IJRPCClientTransport.SendAndReceive.
  /// </summary>
  /// <remarks>
  ///   When it is used for a notification too (because neither Transport nor
  ///   OnNotify was assigned) the client discards what it returns - but the
  ///   callback must not *block* waiting for an answer that will never come. A
  ///   callback wrapping a synchronous ProcessRequest (a loopback, a test) is
  ///   safe by construction; one wrapping WriteLn/ReadLn is not, and should be
  ///   paired with OnNotify.
  /// </remarks>
  TJRPCTransportFunc = reference to function(const ARequest: string): string;

  /// <summary>
  ///   Fire-and-forget counterpart of TJRPCTransportFunc.
  /// </summary>
  TJRPCNotifyFunc = reference to procedure(const ARequest: string);

  /// <summary>
  ///   Called with the exact text going out and the exact text coming in.
  ///   Meant for logging and for tests; it cannot alter the payload.
  /// </summary>
  TJRPCTraceProc = reference to procedure(const AJSON: string);

  /// <summary>
  ///   Called with the exception a failed call raised, on its way out. A
  ///   reporting hook: it observes the failure, it does not handle it.
  /// </summary>
  TJRPCErrorProc = reference to procedure(E: Exception);

  /// <summary>
  ///   Standalone JSON-RPC 2.0 client, the mirror image of TJRPCServer.
  ///
  ///   Transport-agnostic: it serializes the request, hands the JSON to
  ///   whatever was plugged in as a transport, classifies what comes back and
  ///   gives you either the result - raw, or deserialized into a Delphi type -
  ///   or an exception carrying the peer's error. Where TJRPCServer turns a
  ///   string into a string, this turns a request into a string and a string
  ///   back into a value.
  /// </summary>
  /// <remarks>
  ///   Calls are synchronous: write, read, done. There is no pending-request
  ///   map and no inbound notification pump, so a peer that pushes unsolicited
  ///   messages needs a layer above this one. What there *is* - and what a
  ///   hand-written client almost never does - is the correlation check: the
  ///   id echoed by the peer is compared with the one that went out, so a
  ///   desynchronised stream is reported instead of quietly returning the
  ///   previous call's answer.
  /// </remarks>
  TJRPCClient = class(TComponent)
  private
    class var FIdSeed: Integer;
  private
    FNeonConfig: INeonConfiguration;
    FCompactPayload: Boolean;
    FOnBeforeSend: TJRPCTraceProc;
    FOnAfterReceive: TJRPCTraceProc;
    FOnError: TJRPCErrorProc;

    /// <summary>
    ///   Hands E to OnError, if anyone is listening. The caller re-raises
    ///   either way.
    /// </summary>
    procedure ReportError(E: Exception);

    /// <summary>
    ///   The round trip itself, which always raises on failure. The public
    ///   entry points wrap it; keeping it separate is what stops a nested call
    ///   from reporting the same error to OnError twice.
    /// </summary>
    function DoExecute(ARequest: TJRPCRequest): TJSONValue;

    function Transmit(const AJSON: string; AExpectAnswer: Boolean): string;
    function ReadReply(const AReply: string; const AExpectedId: TJRPCID): TJSONValue;
    function ReadBatchReply(const AReply: string; ASent: TJRPCMessages): TJRPCMessages;
    function BuildRemoteError(AError: TJRPCError; ARawMessage: TJSONObject): EJRPCRemoteError;
    procedure CheckReplyId(const AActual, AExpected: TJRPCID);

    class function SameId(const ALeft, ARight: TJRPCID): Boolean; static;
    class function Compact(const AJSON: string): string; static;
    class function MessageId(AMessage: TJRPCMessage; out AId: TJRPCID): Boolean; static;
  protected
    // A descendant that wraps one fixed transport (an Indy client, a pipe)
    // wires these in its own constructor instead of leaving it to every
    // call site.
    FTransport: IJRPCClientTransport;
    FOnTransport: TJRPCTransportFunc;
    FOnNotify: TJRPCNotifyFunc;
  public
    constructor Create(AOwner: TComponent); override;

    /// <summary>
    ///   A fresh request id, unique across every client in the process.
    /// </summary>
    /// <remarks>
    ///   Integer ids from a single interlocked counter: thread-safe without a
    ///   lock, and monotonic, which makes a log readable. The counter is
    ///   shared by all instances on purpose - two clients over the same
    ///   connection would otherwise hand the peer the same id twice.
    /// </remarks>
    class function NewId: TJRPCID; static;

    /// <summary>
    ///   Sends ARequest and deserializes the "result" member into T.
    /// </summary>
    /// <remarks>
    ///   Marshalling follows the same split the server's invoker uses: a class
    ///   type goes through TNeon.JSONToObject, anything else through
    ///   TNeon.JSONToValue. When T is a class the instance is created here and
    ///   belongs to the caller.
    ///   Raises EJRPCRemoteError when the peer answered with an error.
    /// </remarks>
    function ExecuteAs<T>(ARequest: TJRPCRequest): T; overload;
    function ExecuteAs<T>(ARequest: IJRPCRequestBuilder): T; overload;

    /// <summary>
    ///   Same call, but the "result" member comes back as JSON. The returned
    ///   value is a clone and belongs to the caller. It is never nil: a
    ///   "result" of null arrives as a live TJSONNull, so "nothing" and "no
    ///   answer" stay distinguishable.
    /// </summary>
    function ExecuteAsJSONValue(ARequest: TJRPCRequest): TJSONValue; overload;
    function ExecuteAsJSONValue(ARequest: IJRPCRequestBuilder): TJSONValue; overload;

    /// <summary>
    ///   Same call, with the "result" member rendered as compact JSON text.
    ///   Nothing to free - the convenient one for a UI or a log line.
    /// </summary>
    function ExecuteAsJsonString(ARequest: TJRPCRequest): string; overload;
    function ExecuteAsJsonString(ARequest: IJRPCRequestBuilder): string; overload;

    /// <summary>
    ///   Sends a Request and checks the answer, discarding the result: for a
    ///   call made for its effect, where only the failure matters.
    /// </summary>
    /// <remarks>
    ///   A procedure rather than a function returning the result, so that
    ///   Execute(LRequest) as a statement cannot silently leak a TJSONValue
    ///   nobody took. An id is generated when the request carries none; an id
    ///   the caller set is kept and verified.
    /// </remarks>
    procedure Execute(ARequest: TJRPCRequest); overload;

    /// <summary>
    ///   Sends a Notification. Nothing is read back - per the spec the peer
    ///   answers nothing, and waiting for it would hang.
    /// </summary>
    procedure Execute(ANotification: TJRPCNotification); overload;

    /// <summary>
    ///   The same two calls, taking a builder: what was built stays owned by
    ///   the builder, which lives until the statement ends.
    /// </summary>
    procedure Execute(ARequest: IJRPCRequestBuilder); overload;
    procedure Execute(ANotification: IJRPCNotificationBuilder); overload;

    /// <summary>
    ///   Sends a batch and returns the answers, which the caller owns.
    ///   Requests with no id are given one; Single is forced to False, so the
    ///   payload always goes out as a JSON array.
    /// </summary>
    /// <remarks>
    ///   An error inside a batch is *returned*, not raised: the answers to the
    ///   elements that did succeed would be lost with it. Every returned
    ///   message is checked to belong to an id that was actually sent, but the
    ///   order is not: the spec lets a server answer a batch in any order, so
    ///   pair them with FindById rather than by index. A batch made only of
    ///   notifications reads nothing back and returns an empty list.
    /// </remarks>
    function ExecuteBatch(AMessages: TJRPCMessages): TJRPCMessages;

    /// <summary>
    ///   Sends AJSON verbatim and returns the answer verbatim - no building,
    ///   no parsing, no id check. The escape hatch for a payload that is
    ///   deliberately malformed (provoking -32700 by hand) or already built.
    /// </summary>
    function ExecuteRaw(const AJSON: string): string;

    /// <summary>
    ///   The message in AMessages carrying AId, or nil. The way to line up a
    ///   batch answer with what was sent.
    /// </summary>
    class function FindById(AMessages: TJRPCMessages; const AId: TJRPCID): TJRPCMessage; static;

    /// <summary>
    ///   The transport used for every call. Takes precedence over OnTransport,
    ///   and is the only one that can send a notification with no risk of
    ///   blocking on a read.
    /// </summary>
    property Transport: IJRPCClientTransport read FTransport write FTransport;

    /// <summary>
    ///   Ad-hoc transport: a function from request JSON to answer JSON. Used
    ///   when Transport is nil - a closure over an existing connection, or
    ///   over a TJRPCServer.ProcessRequest for an in-process loopback.
    /// </summary>
    property OnTransport: TJRPCTransportFunc read FOnTransport write FOnTransport;

    /// <summary>
    ///   Ad-hoc fire-and-forget transport, used for notifications when
    ///   Transport is nil. Assign it whenever OnTransport would block on a
    ///   read.
    /// </summary>
    property OnNotify: TJRPCNotifyFunc read FOnNotify write FOnNotify;

    /// <summary>
    ///   Called with the payload about to go out, after compaction.
    /// </summary>
    property OnBeforeSend: TJRPCTraceProc read FOnBeforeSend write FOnBeforeSend;

    /// <summary>
    ///   Called with the answer as it arrived, before it is parsed - so it
    ///   sees even the payloads that turn out to be unreadable.
    /// </summary>
    property OnAfterReceive: TJRPCTraceProc read FOnAfterReceive write FOnAfterReceive;

    /// <summary>
    ///   One place to log a failed call. Sees both an EJRPCRemoteError from the
    ///   peer and an EJRPCClientError from the client itself.
    /// </summary>
    /// <remarks>
    ///   It reports, it does not handle: the exception carries on out to the
    ///   caller exactly as if nothing were assigned, so the flow of a failed
    ///   call is the same whether anyone is listening or not. Centralize the
    ///   logging here and keep whatever error handling the call site needs.
    ///
    ///   A failure is reported once, not once per layer: the entry points wrap
    ///   the round trip rather than each other.
    /// </remarks>
    property OnError: TJRPCErrorProc read FOnError write FOnError;

    /// <summary>
    ///   Collapses an outgoing payload onto a single line when it contains a
    ///   line break. True by default, and free on the normal path: both a
    ///   single message and a batch serialize compactly as long as the Neon
    ///   configuration says so, and the guard costs one Pos() call. It earns
    ///   its keep on a line-framed transport, where a pretty-printed payload
    ///   would be read as several truncated messages.
    /// </summary>
    property CompactPayload: Boolean read FCompactPayload write FCompactPayload default True;
  end;

implementation

uses
  System.TypInfo,

  Neon.Core.Utils,
  Neon.Core.Persistence.JSON;

{ EJRPCRemoteError }

constructor EJRPCRemoteError.Create(ACode: Integer; const AMessage: string;
  AErrorData: TJSONValue);
begin
  inherited Create(AMessage);
  FRemoteCode := ACode;
  FErrorData := AErrorData;
end;

destructor EJRPCRemoteError.Destroy;
begin
  FErrorData.Free;
  inherited;
end;

procedure EJRPCRemoteError.AfterConstruction;
begin
  inherited;
  // Runs after EJRPCException.AfterConstruction, which defaults a zero code to
  // -32603. A peer may legitimately answer 0, so the wire value is restored
  // here rather than being left to that default.
  FCode := FRemoteCode;
end;

{ TJRPCClient }

constructor TJRPCClient.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FCompactPayload := True;

  // Once per instance: JRPCNeonConfig builds a fresh configuration, registering
  // six serializers, on every call.
  FNeonConfig := JRPCNeonConfig;
end;

class function TJRPCClient.NewId: TJRPCID;
begin
  Result := TInterlocked.Increment(FIdSeed);
end;

class function TJRPCClient.SameId(const ALeft, ARight: TJRPCID): Boolean;
begin
  if ALeft.IsNull or ARight.IsNull then
    Exit(ALeft.IsNull and ARight.IsNull);

  // Kind first, then value: AsString renders a numeric id as text, so it cannot
  // tell the string "7" from the number 7 - and the spec wants the id echoed
  // with the type it was sent with.
  if ALeft.IsInteger and ARight.IsInteger then
    Exit(ALeft.AsInteger = ARight.AsInteger);

  if ALeft.IsString and ARight.IsString then
    Exit(ALeft.AsString = ARight.AsString);

  Result := False;
end;

class function TJRPCClient.MessageId(AMessage: TJRPCMessage; out AId: TJRPCID): Boolean;
begin
  Result := True;

  if AMessage is TJRPCRequest then
    AId := (AMessage as TJRPCRequest).Id
  else if AMessage is TJRPCResponse then
    AId := (AMessage as TJRPCResponse).Id
  else if AMessage is TJRPCError then
    AId := (AMessage as TJRPCError).Id
  else
    // A Notification carries no id at all, by definition.
    Result := False;
end;

class function TJRPCClient.FindById(AMessages: TJRPCMessages; const AId: TJRPCID): TJRPCMessage;
var
  LMessage: TJRPCMessage;
  LId: TJRPCID;
begin
  for LMessage in AMessages.List do
    if MessageId(LMessage, LId) and SameId(LId, AId) then
      Exit(LMessage);

  Result := nil;
end;

class function TJRPCClient.Compact(const AJSON: string): string;
var
  LValue: TJSONValue;
begin
  if Pos(#10, AJSON) = 0 then
    Exit(AJSON);

  LValue := TJSONObject.ParseJSONValue(AJSON);
  if not Assigned(LValue) then
    // Deliberately malformed text (the "send raw" case) goes out untouched:
    // compaction is a framing aid, never a validation step.
    Exit(AJSON);

  try
    Result := LValue.ToJSON;
  finally
    LValue.Free;
  end;
end;

procedure TJRPCClient.CheckReplyId(const AActual, AExpected: TJRPCID);
begin
  if SameId(AActual, AExpected) then
    Exit;

  raise EJRPCClientError.CreateFmt(SJRPCClientIdMismatch,
    [AActual.AsString, AExpected.AsString]);
end;

function TJRPCClient.Transmit(const AJSON: string; AExpectAnswer: Boolean): string;
var
  LPayload: string;
begin
  Result := '';

  LPayload := AJSON;
  if FCompactPayload then
    LPayload := Compact(LPayload);

  if Assigned(FOnBeforeSend) then
    FOnBeforeSend(LPayload);

  // The transport is picked once, here, so that no call site has to remember
  // that a notification must not read anything back.
  if Assigned(FTransport) then
  begin
    if AExpectAnswer then
      Result := FTransport.SendAndReceive(LPayload)
    else
      FTransport.Send(LPayload);
  end
  else if not AExpectAnswer and Assigned(FOnNotify) then
    FOnNotify(LPayload)
  else if Assigned(FOnTransport) then
  begin
    // For a notification the answer is discarded - see the remark on
    // TJRPCTransportFunc about callbacks that would block reading one.
    if AExpectAnswer then
      Result := FOnTransport(LPayload)
    else
      FOnTransport(LPayload);
  end
  else
    raise EJRPCClientError.Create(SJRPCClientNoTransport);

  if AExpectAnswer and Assigned(FOnAfterReceive) then
    FOnAfterReceive(Result);
end;

function TJRPCClient.BuildRemoteError(AError: TJRPCError; ARawMessage: TJSONObject): EJRPCRemoteError;
var
  LCode: Integer;
  LMessage: string;
  LData: TJSONValue;
  LErrorNode: TJSONValue;
begin
  LCode := JRPC_INTERNAL_ERROR;
  if AError.Error.Code.HasValue then
    LCode := AError.Error.Code.Value;

  LMessage := SJRPCUnexpectedError;
  if AError.Error.Message.HasValue then
    LMessage := AError.Error.Message.Value;

  // Straight from the raw document: TJRPCErrorDetails.Data is a TValue fed by
  // TJValueSerializer, which returns an empty TValue for an object or an array
  // - so a structured payload never survives the trip through the message.
  LData := nil;
  LErrorNode := ARawMessage.FindValue('error');
  if LErrorNode is TJSONObject then
  begin
    LErrorNode := (LErrorNode as TJSONObject).FindValue('data');
    if Assigned(LErrorNode) then
      LData := LErrorNode.Clone as TJSONValue;
  end;

  Result := EJRPCRemoteError.Create(LCode, LMessage, LData);
end;

function TJRPCClient.ReadReply(const AReply: string; const AExpectedId: TJRPCID): TJSONValue;
var
  LDocument: TJSONValue;
  LMessages: TJRPCMessages;
  LMessage: TJRPCMessage;
  LRemoteError: EJRPCRemoteError;
begin
  if AReply.Trim = '' then
    raise EJRPCClientError.Create(SJRPCClientEmptyReply);

  LDocument := TJSONObject.ParseJSONValue(AReply);
  if not Assigned(LDocument) then
    raise EJRPCParseError.Create(SJRPCInvalidJSONReceived);

  Result := nil;
  LRemoteError := nil;
  try
    // Never TJRPCResponse.CreateFromJson: it raises on a reply with no "result"
    // member, which is exactly what an error reply is. TJRPCMessages validates
    // the version, rejects "result" and "error" together, and discriminates.
    LMessages := TJRPCMessages.CreateFromJson(LDocument);
    try
      if LMessages.Count <> 1 then
        raise EJRPCClientError.CreateFmt(SJRPCClientNotSingleReply, [LMessages.Count]);

      LMessage := LMessages.List[0];

      if LMessage is TJRPCResponse then
      begin
        CheckReplyId((LMessage as TJRPCResponse).Id, AExpectedId);
        // Result is never nil - the constructor installs a TJSONNull - so a
        // "result" of null comes back as a live value, not as nil.
        Result := (LMessage as TJRPCResponse).Result.Clone as TJSONValue;
      end
      else if LMessage is TJRPCError then
      begin
        // A null id is accepted here: per the spec that is what a peer answers
        // when it could not read the id we sent.
        if not (LMessage as TJRPCError).Id.IsNull then
          CheckReplyId((LMessage as TJRPCError).Id, AExpectedId);

        LRemoteError := BuildRemoteError(LMessage as TJRPCError, LDocument as TJSONObject);
      end
      else
        raise EJRPCClientError.CreateFmt(SJRPCClientUnexpectedReply, [LMessage.ClassName]);
    finally
      LMessages.Free;
    end;
  finally
    LDocument.Free;
  end;

  // Raised only once the document it was built from has been released: the
  // exception owns a clone, so nothing it carries dies with the cleanup.
  if Assigned(LRemoteError) then
    raise LRemoteError;
end;

function TJRPCClient.ReadBatchReply(const AReply: string; ASent: TJRPCMessages): TJRPCMessages;
var
  LDocument: TJSONValue;
  LMessage: TJRPCMessage;
  LId: TJRPCID;
begin
  if AReply.Trim = '' then
    raise EJRPCClientError.Create(SJRPCClientEmptyReply);

  LDocument := TJSONObject.ParseJSONValue(AReply);
  if not Assigned(LDocument) then
    raise EJRPCParseError.Create(SJRPCInvalidJSONReceived);

  try
    Result := TJRPCMessages.CreateFromJson(LDocument);
    try
      for LMessage in Result.List do
      begin
        if not MessageId(LMessage, LId) then
          Continue;

        // A null id is the peer rejecting the batch as a whole, not an answer
        // to one element.
        if LId.IsNull then
          Continue;

        if not Assigned(FindById(ASent, LId)) then
          raise EJRPCClientError.CreateFmt(SJRPCClientUnknownReplyId, [LId.AsString]);
      end;
    except
      Result.Free;
      raise;
    end;
  finally
    LDocument.Free;
  end;
end;

procedure TJRPCClient.ReportError(E: Exception);
begin
  if Assigned(FOnError) then
    FOnError(E);
end;

function TJRPCClient.DoExecute(ARequest: TJRPCRequest): TJSONValue;
begin
  // A request the caller built by hand may carry no id: give it one, so the
  // answer can be correlated at all.
  if ARequest.Id.IsNull then
    ARequest.Id := NewId;

  Result := ReadReply(Transmit(ARequest.ToJson, True), ARequest.Id);
end;

function TJRPCClient.ExecuteAsJSONValue(ARequest: TJRPCRequest): TJSONValue;
begin
  try
    Result := DoExecute(ARequest);
  except
    on E: Exception do
    begin
      ReportError(E);
      raise;
    end;
  end;
end;

function TJRPCClient.ExecuteAs<T>(ARequest: TJRPCRequest): T;
var
  LValue: TJSONValue;
  LType: TRttiType;
  LObject: TObject;
  LResult: TValue;
begin
  // DoExecute, not ExecuteAsJSONValue: going through the public entry point
  // would report the same failure to OnError twice.
  try
    LValue := DoExecute(ARequest);
    try
      LType := TRttiUtils.Context.GetType(TypeInfo(T));
      if not Assigned(LType) then
        raise EJRPCClientError.Create(SJRPCClientUnknownResultType);

      // The same split the server's invoker uses to bind a parameter, run the
      // other way round.
      if LType.IsInstance then
      begin
        LObject := TNeon.JSONToObject(LType, LValue, FNeonConfig);
        TValue.Make(@LObject, LType.Handle, LResult);
        Result := LResult.AsType<T>;
      end
      else
        Result := TNeon.JSONToValue<T>(LValue, FNeonConfig);
    finally
      LValue.Free;
    end;
  except
    on E: Exception do
    begin
      ReportError(E);
      raise;
    end;
  end;
end;

function TJRPCClient.ExecuteAs<T>(ARequest: IJRPCRequestBuilder): T;
begin
  Result := ExecuteAs<T>(ARequest.Build);
end;

function TJRPCClient.ExecuteAsJsonString(ARequest: TJRPCRequest): string;
var
  LValue: TJSONValue;
begin
  try
    LValue := DoExecute(ARequest);
    try
      Result := LValue.ToJSON;
    finally
      LValue.Free;
    end;
  except
    on E: Exception do
    begin
      ReportError(E);
      raise;
    end;
  end;
end;

function TJRPCClient.ExecuteAsJsonString(ARequest: IJRPCRequestBuilder): string;
begin
  Result := ExecuteAsJsonString(ARequest.Build);
end;

function TJRPCClient.ExecuteAsJSONValue(
  ARequest: IJRPCRequestBuilder): TJSONValue;
begin
  Result := ExecuteAsJSONValue(ARequest.Build);
end;

procedure TJRPCClient.Execute(ARequest: TJRPCRequest);
begin
  // The result is discarded; a failure still reaches OnError and the caller.
  ExecuteAsJSONValue(ARequest).Free;
end;

procedure TJRPCClient.Execute(ANotification: TJRPCNotification);
begin
  try
    // False: nothing is read back. The peer answers a notification with
    // silence, and a read here would block until the transport gave up.
    Transmit(ANotification.ToJson, False);
  except
    on E: Exception do
    begin
      ReportError(E);
      raise;
    end;
  end;
end;

procedure TJRPCClient.Execute(ARequest: IJRPCRequestBuilder);
begin
  Execute(ARequest.Build);
end;

procedure TJRPCClient.Execute(ANotification: IJRPCNotificationBuilder);
begin
  Execute(ANotification.Build);
end;

function TJRPCClient.ExecuteBatch(AMessages: TJRPCMessages): TJRPCMessages;
var
  LMessage: TJRPCMessage;
  LExpectsAnswer: Boolean;
  LReply: string;
begin
  try
    if AMessages.IsEmpty then
      raise EJRPCClientError.Create(SJRPCClientEmptyBatch);

    // A batch always goes out as an array, whatever it holds: Single would make
    // ToJson emit a bare object for a batch of one.
    AMessages.Single := False;

    for LMessage in AMessages.List do
      if (LMessage is TJRPCRequest) and (LMessage as TJRPCRequest).Id.IsNull then
        (LMessage as TJRPCRequest).Id := NewId;

    // Types is maintained as messages are added, so no scan is needed.
    LExpectsAnswer := TJRPCMessageType.Request in AMessages.Types;

    LReply := Transmit(AMessages.ToJson, LExpectsAnswer);

    if not LExpectsAnswer then
      Exit(TJRPCMessages.Create(True));

    Result := ReadBatchReply(LReply, AMessages);
  except
    on E: Exception do
    begin
      ReportError(E);
      raise;
    end;
  end;
end;

function TJRPCClient.ExecuteRaw(const AJSON: string): string;
begin
  try
    Result := Transmit(AJSON, True);
  except
    on E: Exception do
    begin
      ReportError(E);
      raise;
    end;
  end;
end;

{ TJRPCMethodBuilder }

constructor TJRPCMethodBuilder.Create(AMethodClass: TJRPCMethodClass);
begin
  inherited Create;
  FMethod := AMethodClass.Create;
end;

destructor TJRPCMethodBuilder.Destroy;
begin
  FMethod.Free;
  inherited;
end;

{ TJRPCRequestBuilder }

class function TJRPCRequestBuilder.New: IJRPCRequestBuilder;
begin
  Result := TJRPCRequestBuilder.Create;
end;

constructor TJRPCRequestBuilder.Create;
begin
  inherited Create(TJRPCRequest);
end;

function TJRPCRequestBuilder.SetMethod(const AName: string): IJRPCRequestBuilder;
begin
  FMethod.Method := AName;
  Result := Self;
end;

function TJRPCRequestBuilder.AddPositionParam(const AValue: TValue): IJRPCRequestBuilder;
begin
  FMethod.AddPositionParam(AValue);
  Result := Self;
end;

function TJRPCRequestBuilder.AddNamedParam(const AName: string;
  const AValue: TValue): IJRPCRequestBuilder;
begin
  FMethod.AddNamedParam(AName, AValue);
  Result := Self;
end;

function TJRPCRequestBuilder.Build: TJRPCRequest;
begin
  Result := FMethod as TJRPCRequest;
end;

{ TJRPCNotificationBuilder }

class function TJRPCNotificationBuilder.New: IJRPCNotificationBuilder;
begin
  Result := TJRPCNotificationBuilder.Create;
end;

constructor TJRPCNotificationBuilder.Create;
begin
  inherited Create(TJRPCNotification);
end;

function TJRPCNotificationBuilder.SetMethod(const AName: string): IJRPCNotificationBuilder;
begin
  FMethod.Method := AName;
  Result := Self;
end;

function TJRPCNotificationBuilder.AddPositionParam(const AValue: TValue): IJRPCNotificationBuilder;
begin
  FMethod.AddPositionParam(AValue);
  Result := Self;
end;

function TJRPCNotificationBuilder.AddNamedParam(const AName: string;
  const AValue: TValue): IJRPCNotificationBuilder;
begin
  FMethod.AddNamedParam(AName, AValue);
  Result := Self;
end;

function TJRPCNotificationBuilder.Build: TJRPCNotification;
begin
  Result := FMethod as TJRPCNotification;
end;

end.
