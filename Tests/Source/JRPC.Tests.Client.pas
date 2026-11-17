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

/// <summary>
///   TJRPCClient over a RoundTrip transport: a TJRPCFuncTransport wired
///   straight into a real TJRPCServer, so every test is a full round trip
///   with no socket. The streamed answers (an SSE body) and the asynchronous
///   calls are exercised here too; the persistent channel lives in
///   JRPC.Tests.Duplex.
/// </summary>
unit JRPC.Tests.Client;

interface

uses
  System.SysUtils, System.JSON,
  DUnitX.TestFramework,

  JRPC.Core,
  JRPC.Server,
  JRPC.Transport,
  JRPC.Client;

type
  [TestFixture]
  TJRPCClientTest = class
  private
    FServer: TJRPCServer;
    FClient: TJRPCClient;
    /// <summary>The payload the client actually put on the wire.</summary>
    FSent: string;

    /// <summary>
    ///   Replaces the loopback with a transport that answers AReply verbatim,
    ///   for the malformed and desynchronised cases a real server never
    ///   produces.
    /// </summary>
    procedure StubReply(const AReply: string);

    /// <summary>
    ///   Replaces the loopback with a transport that answers with AFrames, one
    ///   message at a time, and then raises AFailure when one is given.
    /// </summary>
    procedure StubFrames(const AFrames: array of string; const AFailure: string = '');

    /// <summary>
    ///   Starts a call whose notification handler captures the call itself, and
    ///   returns without clearing anything - the way a caller's method ends.
    /// </summary>
    procedure RunSelfCapturingCall(AFreed: PBoolean);

    /// <summary>
    ///   A bare Request, for the cases the builder cannot serve.
    /// </summary>
    function NewRequest(const AMethod: string): TJRPCRequest;

    class function IdOf(const AText: string): string; static;
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;

    // Typed results
    [Test] procedure TestExecuteAsInteger;
    [Test] procedure TestExecuteAsString;
    [Test] procedure TestExecuteAsObject;
    [Test] procedure TestExecuteAsDynamicArray;
    [Test] procedure TestExecuteAsJSONValueNullResultIsJSONNull;
    [Test] procedure TestExecuteAsJsonString;

    // The request builder
    [Test] procedure TestBuilderNamedParams;
    [Test] procedure TestBuilderPositionalParams;
    [Test] procedure TestBuilderNoParamsOmitsTheMember;
    [Test] procedure TestBuilderMixedParamsRaise;
    [Test] procedure TestBuilderAcceptedDirectly;

    // Ids and correlation
    [Test] procedure TestRequestCarriesAnId;
    [Test] procedure TestNewIdIsMonotonic;
    [Test] procedure TestNewIdIsThreadSafe;
    [Test] procedure TestIdMismatchIsDetected;
    [Test] procedure TestStringIdAnsweredWithNumberIsDetected;
    [Test] procedure TestIdEquality;
    [Test] procedure TestIdInequalityAcrossKinds;
    [Test] procedure TestIdEqualityIsNotTruncated;

    // Errors from the peer
    [Test] procedure TestMethodNotFoundRaisesRemoteError;
    [Test] procedure TestInvalidParamsRaisesRemoteError;
    [Test] procedure TestRemoteErrorKeepsStructuredData;
    [Test] procedure TestRemoteErrorKeepsCodeZero;
    [Test] procedure TestRemoteErrorWithNullIdIsAccepted;

    // Malformed replies
    [Test] procedure TestEmptyReplyRaises;
    [Test] procedure TestUnparsableReplyRaises;
    [Test] procedure TestArrayReplyIsMatchedById;
    [Test]
    [TestCase('ErrorInside', '[{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"x"}}]|EJRPCRemoteError', '|')]
    [TestCase('ResultInside', '[{"jsonrpc":"2.0","id":1,"result":1}]|', '|')]
    [TestCase('NotAnObject', '[42]|EJRPCClientError', '|')]
    procedure TestArrayOfOneReply(const AReply, AExpected: string);
    [Test] procedure TestReplyWithResultAndErrorRaises;

    // OnError
    [Test] procedure TestOnErrorReportsAndStillRaises;
    [Test] procedure TestOnErrorReportsOncePerCall;
    [Test] procedure TestOnErrorSeesAnAnswerNobodyWaitsFor;
    [Test] procedure TestOnErrorAbortRaisesEAbort;
    [Test] procedure TestOnErrorIgnoreReturnsAnEmptyResult;
    [Test] procedure TestOnErrorIgnoreAppliesToValue;
    [Test] procedure TestOnErrorIgnoreAppliesToAFailedStart;
    [Test] procedure TestOnErrorThatRaisesStillRaisesTheFailure;

    // Notifications
    [Test] procedure TestNotificationIsNeverRead;
    [Test] procedure TestNotificationOverLoopback;
    [Test] procedure TestExecuteTakesARequestBuilder;

    // Batches
    [Test] procedure TestExecuteBatchPairsAnswersById;
    [Test] procedure TestExecuteBatchGoesOutAsAnArray;
    [Test] procedure TestExecuteBatchOfNotificationsReadsNothing;
    [Test] procedure TestExecuteBatchEmptyRaises;

    // Plumbing
    [Test] procedure TestNoTransportRaises;
    [Test] procedure TestTraceHooksSeeThePayloads;
    [Test] procedure TestExecuteDiscardsTheResult;
    [Test] procedure TestClosedClientRaisesUntilANewTransport;

    // Streamed answers
    [Test] procedure TestStreamNotificationGoesToItsCall;
    [Test] procedure TestStreamNotificationWithoutHandlerGoesToOnNotification;
    [Test] procedure TestStreamErrorFrameRaises;
    [Test] procedure TestStreamArrayOfOneErrorFrameRaises;
    [Test] procedure TestStreamResultSurvivesFailureAfterIt;
    [Test] procedure TestStreamErrorSurvivesFailureAfterIt;
    [Test] procedure TestStreamFailureBeforeAnswerRaises;
    [Test] procedure TestStreamEndsWithoutResponseRaises;
    [Test] procedure TestStreamWrongIdRaises;
    [Test] procedure TestStreamPeerRequestIsAnswered;
    [Test] procedure TestStreamArrayFrameIsMatchedById;
    [Test] procedure TestStreamTraceSeesEachFrame;

    // Asynchronous calls
    [Test] procedure TestExecuteAsyncValue;
    [Test] procedure TestExecuteAsyncRemoteError;
    [Test] procedure TestExecuteAsyncCallsOverlap;
    [Test] procedure TestExecuteAsyncFailureRaisedOnceThenQuoted;
    [Test] procedure TestExecuteAsyncDeliversItsNotifications;
    [Test] procedure TestCancelAbortsTheRead;
    [Test] procedure TestCancelledBeforeItStartsNeverSends;
    [Test] procedure TestReleasesSelfCapturingHandler;

    // Configuration
    [Test] procedure TestNeonConfigIsHonoured;
  end;

implementation

uses
  System.Classes, System.Rtti, System.Generics.Collections, System.Threading,
  System.SyncObjs, System.StrUtils, System.Diagnostics,

  Neon.Core.Persistence,

  JRPC.Tests.Api;

type
  /// <summary>
  ///   A type whose member is snake_case on the wire, for the NeonConfig test.
  ///   A property rather than a field: the default Neon configuration reads
  ///   properties from a class and fields only from a record.
  /// </summary>
  TNeonSnakeProbe = class
  private
    FSomeValue: Integer;
  public
    property SomeValue: Integer read FSomeValue write FSomeValue;
  end;

  /// <summary>
  ///   A RoundTrip transport whose answer is a long-lived stream: one
  ///   notification, then a read that only Abort ends - the shape of a
  ///   subscription. It clears its abort state as each Send starts, the way a
  ///   reusable transport does, and gives up after 3 s.
  /// </summary>
  TListenTransport = class(TInterfacedObject, IJRPCTransport, IJRPCAbortableTransport)
  private
    FListener: IJRPCTransportListener;
    FAborted: Integer;
    FSends: Integer;
    FAborts: Integer;
    FSilent: Boolean;
  public
    constructor Create(ASilent: Boolean);

    // IJRPCTransport
    procedure Open(const AListener: IJRPCTransportListener);
    procedure Send(const AText: string; const AOrigin: TJRPCID);
    procedure Close;
    function RoundTrip: Boolean;

    // IJRPCAbortableTransport
    procedure Abort(const AOrigin: TJRPCID);

    property Sends: Integer read FSends;
    property Aborts: Integer read FAborts;
  end;

  /// <summary>
  ///   Sets a flag when it is freed: captured by a handler, it tells when the
  ///   handler's closure frame goes.
  /// </summary>
  TReleaseProbe = class(TInterfacedObject)
  private
    FFreed: PBoolean;
  public
    constructor Create(AFreed: PBoolean);
    destructor Destroy; override;
  end;

{ TListenTransport }

constructor TListenTransport.Create(ASilent: Boolean);
begin
  inherited Create;
  FSilent := ASilent;
end;

procedure TListenTransport.Open(const AListener: IJRPCTransportListener);
begin
  FListener := AListener;
end;

procedure TListenTransport.Send(const AText: string; const AOrigin: TJRPCID);
var
  LWaited: Integer;
begin
  TInterlocked.Increment(FSends);

  // A new read starts clean: an Abort that came before it is forgotten
  TInterlocked.Exchange(FAborted, 0);

  if not FSilent then
    FListener.MessageReceived('{"jsonrpc":"2.0","method":"notifications/first"}', AOrigin);

  LWaited := 0;
  while (TInterlocked.CompareExchange(FAborted, 0, 0) = 0) and (LWaited < 3000) do
  begin
    Sleep(5);
    Inc(LWaited, 5);
  end;
end;

procedure TListenTransport.Close;
begin
  TInterlocked.Exchange(FAborted, 1);
  if Assigned(FListener) then
    FListener.TransportClosed(TJRPCCloseInfo.Local);
  FListener := nil;
end;

function TListenTransport.RoundTrip: Boolean;
begin
  Result := True;
end;

procedure TListenTransport.Abort(const AOrigin: TJRPCID);
begin
  TInterlocked.Increment(FAborts);
  TInterlocked.Exchange(FAborted, 1);
end;

{ TReleaseProbe }

constructor TReleaseProbe.Create(AFreed: PBoolean);
begin
  inherited Create;
  FFreed := AFreed;
end;

destructor TReleaseProbe.Destroy;
begin
  FFreed^ := True;
  inherited;
end;

{ TJRPCClientTest }

procedure TJRPCClientTest.Setup;
begin
  FSent := '';
  FServer := TJRPCServer.Create(nil);
  FClient := TJRPCClient.Create(nil);

  // The whole trick: the server *is* the transport.
  FClient.Transport := TJRPCFuncTransport.Create(
    function (const AText: string): string
    begin
      FSent := AText;
      Result := FServer.ProcessRequest(AText);
    end);
end;

procedure TJRPCClientTest.TearDown;
begin
  FClient.Free;
  FServer.Free;
end;

procedure TJRPCClientTest.StubReply(const AReply: string);
begin
  FClient.Transport := TJRPCFuncTransport.Create(
    function (const AText: string): string
    begin
      FSent := AText;
      Result := AReply;
    end);
end;

procedure TJRPCClientTest.StubFrames(const AFrames: array of string;
  const AFailure: string);
var
  LFrames: TArray<string>;
  LIndex: Integer;
begin
  SetLength(LFrames, Length(AFrames));
  for LIndex := 0 to High(AFrames) do
    LFrames[LIndex] := AFrames[LIndex];

  FClient.Transport := TJRPCFuncTransport.CreateFramed(
    procedure (const AText: string; const AOnFrame: TJRPCFrameSink)
    var
      LFrame: string;
    begin
      FSent := AText;
      for LFrame in LFrames do
        AOnFrame(LFrame);
      if AFailure <> '' then
        raise Exception.Create(AFailure);
    end);
end;

function TJRPCClientTest.NewRequest(const AMethod: string): TJRPCRequest;
begin
  Result := TJRPCRequest.Create;
  Result.Method := AMethod;
end;

class function TJRPCClientTest.IdOf(const AText: string): string;
var
  LValue: TJSONValue;
begin
  LValue := TJSONObject.ParseJSONValue(AText);
  try
    Result := (LValue as TJSONObject).GetValue('id').ToJSON;
  finally
    LValue.Free;
  end;
end;

procedure TJRPCClientTest.TestExecuteAsInteger;
begin
  Assert.AreEqual(42, FClient.ExecuteAs<Integer>(
    TJRPCRequestBuilder.New
      .SetMethod('math/sum')
      .AddNamedParam('a', 2)
      .AddNamedParam('b', 40)));
end;

procedure TJRPCClientTest.TestExecuteAsString;
begin
  Assert.AreEqual('hello world', FClient.ExecuteAs<string>(
    TJRPCRequestBuilder.New
      .SetMethod('math/concat')
      .AddNamedParam('left', 'hello ')
      .AddNamedParam('right', 'world')));
end;

procedure TJRPCClientTest.TestExecuteAsObject;
var
  LPerson: TPerson;
begin
  // The instance-type branch: Neon creates it, the caller owns it. "camel/" and
  // not "object/" because the client deserializes with JRPCNeonConfig, which is
  // CamelCase.
  LPerson := FClient.ExecuteAs<TPerson>(TJRPCRequestBuilder.New.SetMethod('camel/person'));
  try
    Assert.IsNotNull(LPerson);
    Assert.AreEqual('Paolo', LPerson.Name);
    Assert.AreEqual(42, LPerson.Age);
  finally
    LPerson.Free;
  end;
end;

procedure TJRPCClientTest.TestExecuteAsDynamicArray;
var
  LList: TArray<Integer>;
begin
  LList := FClient.ExecuteAs<TArray<Integer>>(
    TJRPCRequestBuilder.New.SetMethod('math/emptylist'));
  Assert.AreEqual(0, Length(LList));
end;

procedure TJRPCClientTest.TestExecuteAsJSONValueNullResultIsJSONNull;
var
  LValue: TJSONValue;
begin
  // "math/reset" is a procedure, so the Response carries "result": null. It must
  // arrive as a live TJSONNull, not as nil.
  LValue := FClient.ExecuteAsJSONValue(TJRPCRequestBuilder.New.SetMethod('math/reset'));
  try
    Assert.IsNotNull(LValue);
    Assert.IsTrue(LValue is TJSONNull, 'expected a TJSONNull, got ' + LValue.ClassName);
  finally
    LValue.Free;
  end;
end;

procedure TJRPCClientTest.TestExecuteAsJsonString;
begin
  Assert.AreEqual('42', FClient.ExecuteAsJsonString(
    TJRPCRequestBuilder.New
      .SetMethod('math/sum')
      .AddNamedParam('a', 40)
      .AddNamedParam('b', 2)));
end;

procedure TJRPCClientTest.TestBuilderNamedParams;
begin
  FClient.ExecuteAs<Integer>(
    TJRPCRequestBuilder.New
      .SetMethod('math/sum')
      .AddNamedParam('a', 1)
      .AddNamedParam('b', 2));

  Assert.IsTrue(FSent.Contains('"params":{'), 'named params go out as an object: ' + FSent);
  Assert.IsTrue(FSent.Contains('"a":1'), FSent);
  Assert.IsTrue(FSent.Contains('"b":2'), FSent);
end;

procedure TJRPCClientTest.TestBuilderPositionalParams;
begin
  Assert.AreEqual(42, FClient.ExecuteAs<Integer>(
    TJRPCRequestBuilder.New
      .SetMethod('math/sum')
      .AddPositionParam(10)
      .AddPositionParam(32)));

  Assert.IsTrue(FSent.Contains('"params":['), 'positional params go out as an array: ' + FSent);
end;

procedure TJRPCClientTest.TestBuilderNoParamsOmitsTheMember;
begin
  FClient.ExecuteAs<string>(TJRPCRequestBuilder.New.SetMethod('ping'));

  // JSON-RPC 2.0 wants the member absent, not null.
  Assert.IsFalse(FSent.Contains('"params"'), 'no params member expected: ' + FSent);
end;

procedure TJRPCClientTest.TestBuilderMixedParamsRaise;
begin
  Assert.WillRaise(
    procedure
    begin
      TJRPCRequestBuilder.New
        .SetMethod('math/sum')
        .AddNamedParam('a', 1)
        .AddPositionParam(2);
    end,
    EJRPCException);

  Assert.WillRaise(
    procedure
    begin
      TJRPCRequestBuilder.New
        .SetMethod('math/sum')
        .AddPositionParam(1)
        .AddNamedParam('b', 2);
    end,
    EJRPCException);
end;

procedure TJRPCClientTest.TestBuilderAcceptedDirectly;
var
  LBuilder: IJRPCRequestBuilder;
begin
  LBuilder := TJRPCRequestBuilder.New
    .SetMethod('math/sum')
    .AddNamedParam('a', 20)
    .AddNamedParam('b', 22);

  Assert.AreEqual(42, FClient.ExecuteAs<Integer>(LBuilder.Build));
end;

procedure TJRPCClientTest.TestRequestCarriesAnId;
begin
  FClient.ExecuteAs<Integer>(
    TJRPCRequestBuilder.New
      .SetMethod('math/sum')
      .AddNamedParam('a', 1)
      .AddNamedParam('b', 1));

  Assert.IsTrue(FSent.Contains('"id":'), 'the request must carry an id: ' + FSent);
end;

procedure TJRPCClientTest.TestNewIdIsMonotonic;
var
  LFirst, LSecond: TJRPCID;
begin
  LFirst := TJRPCClient.NewId;
  LSecond := TJRPCClient.NewId;

  Assert.IsTrue(LFirst.IsInteger, 'ids are integers');
  Assert.IsTrue(LSecond.AsInteger > LFirst.AsInteger, 'ids must increase');
end;

procedure TJRPCClientTest.TestNewIdIsThreadSafe;
const
  THREAD_COUNT = 4;
  PER_THREAD = 500;
var
  LSeen: TList<Integer>;
  LLock: TCriticalSection;
begin
  LSeen := TList<Integer>.Create;
  LLock := TCriticalSection.Create;
  try
    TParallel.For(1, THREAD_COUNT,
      procedure (AIndex: Integer)
      var
        LLocal: TArray<Integer>;
        LStep: Integer;
      begin
        SetLength(LLocal, PER_THREAD);
        for LStep := 0 to PER_THREAD - 1 do
          LLocal[LStep] := TJRPCClient.NewId.AsInteger;

        LLock.Enter;
        try
          LSeen.AddRange(LLocal);
        finally
          LLock.Leave;
        end;
      end);

    LSeen.Sort;
    for var LIndex := 1 to LSeen.Count - 1 do
      if LSeen[LIndex] = LSeen[LIndex - 1] then
        Assert.Fail(Format('duplicate id %d handed out twice', [LSeen[LIndex]]));

    Assert.AreEqual(THREAD_COUNT * PER_THREAD, LSeen.Count);
  finally
    LLock.Free;
    LSeen.Free;
  end;
end;

procedure TJRPCClientTest.TestIdMismatchIsDetected;
begin
  // The answer to another call, returned as if it were this one: it matches no
  // pending call, so this one ends without an answer.
  StubReply('{"jsonrpc":"2.0","id":999,"result":42}');

  Assert.WillRaise(
    procedure
    begin
      FClient.ExecuteAs<Integer>(TJRPCRequestBuilder.New.SetMethod('math/sum'));
    end,
    EJRPCClientError);
end;

procedure TJRPCClientTest.TestStringIdAnsweredWithNumberIsDetected;
var
  LRequest: TJRPCRequest;
begin
  // The string "7" and the number 7 are different ids.
  StubReply('{"jsonrpc":"2.0","id":7,"result":42}');

  LRequest := NewRequest('math/sum');
  try
    LRequest.Id := '7';

    Assert.WillRaise(
      procedure
      begin
        FClient.Execute(LRequest);
      end,
      EJRPCClientError);
  finally
    LRequest.Free;
  end;
end;

procedure TJRPCClientTest.TestIdEquality;
var
  LFirst, LSecond, LAbsent, LDefaultAbsent: TJRPCID;
begin
  LFirst := 7;
  LSecond := 7;
  LAbsent := nil;

  Assert.IsTrue(LFirst = LSecond, 'the same number is the same id');
  Assert.IsFalse(LFirst = LAbsent, 'an id is not the absent id');
  Assert.IsTrue(LAbsent = LDefaultAbsent, 'two absent ids are equal');
  Assert.IsTrue(LAbsent = TJRPCID.Null, 'TJRPCID.Null is the absent id');
end;

procedure TJRPCClientTest.TestIdInequalityAcrossKinds;
var
  LNumber, LText: TJRPCID;
begin
  LNumber := 7;
  LText := '7';

  // AsString would render both as '7': the kind is part of the identity.
  Assert.IsFalse(LNumber = LText);
  Assert.IsTrue(LNumber <> LText);
end;

procedure TJRPCClientTest.TestIdEqualityIsNotTruncated;
var
  LLarge, LLargeAgain, LZero: TJRPCID;
begin
  // 2^32: AsInteger would truncate it to 0 and make it equal to the id 0.
  LLarge := Int64(4294967296);
  LLargeAgain := Int64(4294967296);
  LZero := 0;

  Assert.IsFalse(LLarge = LZero);
  Assert.IsTrue(LLarge = LLargeAgain);
end;

procedure TJRPCClientTest.TestMethodNotFoundRaisesRemoteError;
begin
  try
    FClient.ExecuteAs<string>(TJRPCRequestBuilder.New.SetMethod('no/such/method'));
    Assert.Fail('an unknown method must raise');
  except
    on E: EJRPCRemoteError do
      Assert.AreEqual(JRPC_METHOD_NOT_FOUND, E.Code);
  end;
end;

procedure TJRPCClientTest.TestInvalidParamsRaisesRemoteError;
begin
  try
    FClient.ExecuteAs<Integer>(
      TJRPCRequestBuilder.New
        .SetMethod('math/sum')
        .AddNamedParam('a', 'nope')
        .AddNamedParam('b', 1));
    Assert.Fail('a bad parameter must raise');
  except
    on E: EJRPCRemoteError do
    begin
      Assert.AreEqual(JRPC_INVALID_PARAMS, E.Code);
      Assert.IsNotNull(E.ErrorData, 'the invoker says which parameter was wrong');
    end;
  end;
end;

procedure TJRPCClientTest.TestRemoteErrorKeepsStructuredData;
var
  LRequest: TJRPCRequest;
begin
  // TJValueSerializer maps only numbers, strings and booleans into
  // TJRPCErrorDetails.Data, so an object payload has to be lifted out of the
  // raw document instead.
  StubReply('{"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"nope",' +
    '"data":{"retryAfter":30,"reason":"busy"}}}');

  LRequest := NewRequest('math/sum');
  try
    LRequest.Id := 1;

    try
      FClient.Execute(LRequest);
      Assert.Fail('an error reply must raise');
    except
      on E: EJRPCRemoteError do
      begin
        Assert.AreEqual(-32001, E.Code);
        Assert.IsNotNull(E.ErrorData, 'the structured data must survive');
        Assert.IsTrue(E.ErrorData is TJSONObject, 'expected an object, got ' + E.ErrorData.ClassName);
        Assert.AreEqual('30', (E.ErrorData as TJSONObject).GetValue('retryAfter').ToJSON);
      end;
    end;
  finally
    LRequest.Free;
  end;
end;

procedure TJRPCClientTest.TestRemoteErrorKeepsCodeZero;
var
  LRequest: TJRPCRequest;
begin
  StubReply('{"jsonrpc":"2.0","id":1,"error":{"code":0,"message":"zero"}}');

  LRequest := NewRequest('math/sum');
  try
    LRequest.Id := 1;

    try
      FClient.Execute(LRequest);
      Assert.Fail('an error reply must raise');
    except
      on E: EJRPCRemoteError do
        Assert.AreEqual(0, E.Code, 'the code the peer sent must survive');
    end;
  finally
    LRequest.Free;
  end;
end;

procedure TJRPCClientTest.TestRemoteErrorWithNullIdIsAccepted;
begin
  // A null id is what a peer answers when it could not read ours. On the
  // answer stream of a call, it is that call's answer.
  StubReply('{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"parse"}}');

  try
    FClient.ExecuteAs<Integer>(TJRPCRequestBuilder.New.SetMethod('math/sum'));
    Assert.Fail('an error reply must raise');
  except
    on E: EJRPCRemoteError do
      Assert.AreEqual(JRPC_PARSE_ERROR, E.Code);
  end;
end;

procedure TJRPCClientTest.TestEmptyReplyRaises;
begin
  StubReply('');

  Assert.WillRaise(
    procedure
    begin
      FClient.ExecuteAs<Integer>(TJRPCRequestBuilder.New.SetMethod('math/sum'));
    end,
    EJRPCClientError);
end;

procedure TJRPCClientTest.TestUnparsableReplyRaises;
begin
  StubReply('this is not json');

  Assert.WillRaise(
    procedure
    begin
      FClient.ExecuteAs<Integer>(TJRPCRequestBuilder.New.SetMethod('math/sum'));
    end,
    EJRPCParseError);
end;

procedure TJRPCClientTest.TestArrayReplyIsMatchedById;
var
  LRequest: TJRPCRequest;
begin
  // An array is matched element by element: the element carrying our id is
  // our answer, the other one belongs to nobody.
  StubReply('[{"jsonrpc":"2.0","id":2,"result":2},{"jsonrpc":"2.0","id":1,"result":5}]');

  LRequest := NewRequest('math/sum');
  try
    LRequest.Id := 1;
    Assert.AreEqual(5, FClient.ExecuteAs<Integer>(LRequest));
  finally
    LRequest.Free;
  end;
end;

procedure TJRPCClientTest.TestArrayOfOneReply(const AReply, AExpected: string);
var
  LRequest: TJRPCRequest;
  LError: string;
  LMessage: string;
begin
  // An array of one is read element by element like any other: an error
  // inside raised EInvalidCast once, and "[42]" must not become a -32600 the
  // peer never sent.
  StubReply(AReply);

  LRequest := NewRequest('math/sum');
  try
    LRequest.Id := 1;
    LError := '';
    try
      FClient.ExecuteAs<Integer>(LRequest);
    except
      on E: Exception do
      begin
        LError := E.ClassName;
        LMessage := E.Message;
      end;
    end;
  finally
    LRequest.Free;
  end;

  Assert.AreEqual(AExpected, LError, LMessage);
end;

procedure TJRPCClientTest.TestReplyWithResultAndErrorRaises;
begin
  // Mutually exclusive per the spec; the call fails as a client error.
  StubReply('{"jsonrpc":"2.0","id":1,"result":1,"error":{"code":-1,"message":"x"}}');

  Assert.WillRaise(
    procedure
    begin
      FClient.ExecuteAs<Integer>(TJRPCRequestBuilder.New.SetMethod('math/sum'));
    end);
end;

procedure TJRPCClientTest.TestOnErrorReportsAndStillRaises;
var
  LSeen: string;
begin
  LSeen := '';
  FClient.OnError :=
    procedure (E: Exception; var AAction: TJRPCErrorAction)
    begin
      LSeen := E.Message;
    end;

  Assert.WillRaise(
    procedure
    begin
      FClient.ExecuteAs<string>(TJRPCRequestBuilder.New.SetMethod('no/such/method'));
    end,
    EJRPCRemoteError);

  Assert.IsTrue(LSeen.Contains('no/such/method'), 'OnError saw: ' + LSeen);
end;

procedure TJRPCClientTest.TestOnErrorReportsOncePerCall;
var
  LCount: Integer;
begin
  LCount := 0;
  FClient.OnError :=
    procedure (E: Exception; var AAction: TJRPCErrorAction)
    begin
      Inc(LCount);
    end;

  try
    FClient.ExecuteAs<Integer>(TJRPCRequestBuilder.New.SetMethod('no/such/method'));
  except
    on E: EJRPCRemoteError do
      ; // expected
  end;

  Assert.AreEqual(1, LCount);
end;

procedure TJRPCClientTest.TestOnErrorSeesAnAnswerNobodyWaitsFor;
var
  LSeen: TStringList;
begin
  LSeen := TStringList.Create;
  try
    FClient.OnError :=
      procedure (E: Exception; var AAction: TJRPCErrorAction)
      begin
        LSeen.Add(E.Message);
      end;

    StubReply('{"jsonrpc":"2.0","id":999,"result":42}');
    try
      FClient.ExecuteAs<Integer>(TJRPCRequestBuilder.New.SetMethod('math/sum'));
    except
      on E: EJRPCClientError do
        ; // expected
    end;

    // The stray answer, then the call that got none.
    Assert.AreEqual(2, LSeen.Count, LSeen.Text);
    Assert.IsTrue(LSeen[0].Contains('999'), LSeen[0]);
  finally
    FClient.OnError := nil;
    LSeen.Free;
  end;
end;

procedure TJRPCClientTest.TestOnErrorAbortRaisesEAbort;
begin
  FClient.OnError :=
    procedure (E: Exception; var AAction: TJRPCErrorAction)
    begin
      AAction := TJRPCErrorAction.Abort;
    end;

  Assert.WillRaise(
    procedure
    begin
      FClient.ExecuteAs<Integer>(TJRPCRequestBuilder.New.SetMethod('no/such/method'));
    end,
    EAbort);
end;

procedure TJRPCClientTest.TestOnErrorIgnoreReturnsAnEmptyResult;
var
  LValue: TJSONValue;
begin
  FClient.OnError :=
    procedure (E: Exception; var AAction: TJRPCErrorAction)
    begin
      AAction := TJRPCErrorAction.Ignore;
    end;

  Assert.AreEqual(0, FClient.ExecuteAs<Integer>(
    TJRPCRequestBuilder.New.SetMethod('no/such/method')));
  Assert.AreEqual('', FClient.ExecuteAsJsonString(
    TJRPCRequestBuilder.New.SetMethod('no/such/method')));
  FClient.Execute(TJRPCRequestBuilder.New.SetMethod('no/such/method'));

  LValue := FClient.ExecuteAsJSONValue(TJRPCRequestBuilder.New.SetMethod('no/such/method'));
  Assert.IsNull(LValue);
end;

procedure TJRPCClientTest.TestOnErrorIgnoreAppliesToValue;
var
  LCall: IJRPCCall<Integer>;
begin
  FClient.OnError :=
    procedure (E: Exception; var AAction: TJRPCErrorAction)
    begin
      AAction := TJRPCErrorAction.Ignore;
    end;

  LCall := FClient.ExecuteAsync<Integer>(TJRPCRequestBuilder.New.SetMethod('no/such/method'));
  Assert.AreEqual(0, LCall.Value);
  // The choice sticks: a second read does not raise either.
  Assert.AreEqual(0, LCall.Value);
end;

procedure TJRPCClientTest.TestOnErrorIgnoreAppliesToAFailedStart;
var
  LCall: IJRPCCall<Integer>;
begin
  FClient.OnError :=
    procedure (E: Exception; var AAction: TJRPCErrorAction)
    begin
      AAction := TJRPCErrorAction.Ignore;
    end;
  // No transport: the call fails before anything is sent.
  FClient.Transport := nil;

  Assert.AreEqual(0, FClient.ExecuteAs<Integer>(TJRPCRequestBuilder.New.SetMethod('math/sum')));

  LCall := FClient.ExecuteAsync<Integer>(TJRPCRequestBuilder.New.SetMethod('math/sum'));
  Assert.IsTrue(LCall.Completed);
  Assert.AreEqual(0, LCall.Value);

  FClient.Notify(TJRPCNotificationBuilder.New.SetMethod('log'));
end;

procedure TJRPCClientTest.TestOnErrorThatRaisesStillRaisesTheFailure;
begin
  FClient.OnError :=
    procedure (E: Exception; var AAction: TJRPCErrorAction)
    begin
      AAction := TJRPCErrorAction.Ignore;
      raise Exception.Create('the handler failed');
    end;

  Assert.WillRaise(
    procedure
    begin
      FClient.ExecuteAs<Integer>(TJRPCRequestBuilder.New.SetMethod('no/such/method'));
    end,
    EJRPCRemoteError);
end;

procedure TJRPCClientTest.TestNotificationIsNeverRead;
var
  LNotified: string;
begin
  LNotified := '';

  // If the client ever tried to read after a notification, this would fail.
  FClient.Transport := TJRPCFuncTransport.Create(
    function (const AText: string): string
    begin
      Assert.Fail('a notification must not go through the read path');
      Result := '';
    end,
    procedure (const AText: string)
    begin
      LNotified := AText;
    end);

  FClient.Notify(
    TJRPCNotificationBuilder.New
      .SetMethod('math/notif')
      .AddNamedParam('a', 1)
      .AddNamedParam('b', 2));

  Assert.IsTrue(LNotified.Contains('"method":"math/notif"'), LNotified);
  Assert.IsFalse(LNotified.Contains('"id"'), 'a notification carries no id: ' + LNotified);
end;

procedure TJRPCClientTest.TestNotificationOverLoopback;
var
  LNotification: TJRPCNotification;
begin
  // Without a send-only function the notification goes through the loopback,
  // which answers '' - nothing to make sense of.
  LNotification := TJRPCNotification.Create;
  try
    LNotification.Method := 'math/notif';
    LNotification.AddNamedParam('a', 1);
    LNotification.AddNamedParam('b', 2);

    FClient.Notify(LNotification);
  finally
    LNotification.Free;
  end;

  Assert.IsFalse(FSent.Contains('"id"'), 'a notification carries no id: ' + FSent);
end;

procedure TJRPCClientTest.TestExecuteTakesARequestBuilder;
begin
  FClient.Execute(TJRPCRequestBuilder.New.SetMethod('math/reset'));

  Assert.IsTrue(FSent.Contains('"method":"math/reset"'), FSent);
  Assert.IsTrue(FSent.Contains('"id":'), 'a request must carry an id: ' + FSent);
end;

procedure TJRPCClientTest.TestExecuteBatchPairsAnswersById;
var
  LBatch, LAnswers: TJRPCMessages;
  LFirst, LSecond, LBad: TJRPCRequest;
  LNotification: TJRPCNotification;
  LAnswer: TJRPCMessage;
begin
  LBatch := TJRPCMessages.Create(True);
  try
    LFirst := NewRequest('math/sum');
    LFirst.AddNamedParam('a', 1);
    LFirst.AddNamedParam('b', 2);

    LSecond := NewRequest('math/sum');
    LSecond.AddNamedParam('a', 10);
    LSecond.AddNamedParam('b', 20);

    LBad := NewRequest('no/such/method');

    LNotification := TJRPCNotification.Create;
    LNotification.Method := 'math/notif';
    LNotification.AddNamedParam('a', 1);
    LNotification.AddNamedParam('b', 1);

    LBatch.AddMessage(LFirst);
    LBatch.AddMessage(LSecond);
    LBatch.AddMessage(LBad);
    LBatch.AddMessage(LNotification);

    LAnswers := FClient.ExecuteBatch(LBatch);
    try
      // An error inside a batch is returned, never raised.
      Assert.AreEqual(3, Integer(LAnswers.Count), 'the notification is not answered');

      LAnswer := TJRPCClient.FindById(LAnswers, LSecond.Id);
      Assert.IsNotNull(LAnswer, 'the second request must have an answer');
      Assert.IsTrue(LAnswer is TJRPCResponse);
      Assert.AreEqual('30', (LAnswer as TJRPCResponse).Result.ToJSON);

      LAnswer := TJRPCClient.FindById(LAnswers, LBad.Id);
      Assert.IsNotNull(LAnswer, 'the bad method must have an answer too');
      Assert.IsTrue(LAnswer is TJRPCError, 'expected an error, got ' + LAnswer.ClassName);
    finally
      LAnswers.Free;
    end;
  finally
    LBatch.Free;
  end;
end;

procedure TJRPCClientTest.TestExecuteBatchGoesOutAsAnArray;
var
  LBatch, LAnswers: TJRPCMessages;
  LRequest: TJRPCRequest;
begin
  LBatch := TJRPCMessages.Create(True);
  try
    LRequest := NewRequest('math/sum');
    LRequest.AddNamedParam('a', 1);
    LRequest.AddNamedParam('b', 2);
    LBatch.AddMessage(LRequest);

    LAnswers := FClient.ExecuteBatch(LBatch);
    try
      Assert.IsTrue(FSent.StartsWith('['), 'a batch is an array: ' + FSent);
      Assert.AreEqual(0, Pos(#10, FSent), 'the payload must stay on one line: ' + FSent);
      Assert.AreEqual(1, Integer(LAnswers.Count));
    finally
      LAnswers.Free;
    end;
  finally
    LBatch.Free;
  end;
end;

procedure TJRPCClientTest.TestExecuteBatchOfNotificationsReadsNothing;
var
  LBatch, LAnswers: TJRPCMessages;
  LNotification: TJRPCNotification;
  LIndex: Integer;
begin
  LBatch := TJRPCMessages.Create(True);
  try
    for LIndex := 1 to 2 do
    begin
      LNotification := TJRPCNotification.Create;
      LNotification.Method := 'math/notif';
      LNotification.AddNamedParam('a', LIndex);
      LNotification.AddNamedParam('b', LIndex);
      LBatch.AddMessage(LNotification);
    end;

    LAnswers := FClient.ExecuteBatch(LBatch);
    try
      Assert.IsTrue(LAnswers.IsEmpty, 'nothing is answered, so nothing comes back');
    finally
      LAnswers.Free;
    end;
  finally
    LBatch.Free;
  end;
end;

procedure TJRPCClientTest.TestExecuteBatchEmptyRaises;
var
  LBatch: TJRPCMessages;
begin
  LBatch := TJRPCMessages.Create(True);
  try
    Assert.WillRaise(
      procedure
      begin
        FClient.ExecuteBatch(LBatch).Free;
      end,
      EJRPCClientError);
  finally
    LBatch.Free;
  end;
end;

procedure TJRPCClientTest.TestNoTransportRaises;
var
  LClient: TJRPCClient;
begin
  LClient := TJRPCClient.Create(nil);
  try
    Assert.WillRaise(
      procedure
      begin
        LClient.ExecuteAsJsonString(TJRPCRequestBuilder.New.SetMethod('ping'));
      end,
      EJRPCClientError);
  finally
    LClient.Free;
  end;
end;

procedure TJRPCClientTest.TestTraceHooksSeeThePayloads;
var
  LOut, LIn: string;
  LOutCount, LInCount: Integer;
begin
  LOutCount := 0;
  LInCount := 0;

  FClient.OnBeforeSend :=
    procedure (const AJSON: string)
    begin
      LOut := AJSON;
      Inc(LOutCount);
    end;

  FClient.OnAfterReceive :=
    procedure (const AJSON: string)
    begin
      LIn := AJSON;
      Inc(LInCount);
    end;

  FClient.ExecuteAs<Integer>(
    TJRPCRequestBuilder.New
      .SetMethod('math/sum')
      .AddNamedParam('a', 2)
      .AddNamedParam('b', 40));

  Assert.AreEqual(1, LOutCount, 'OnBeforeSend fires once per call');
  Assert.AreEqual(1, LInCount, 'OnAfterReceive fires once per call');
  Assert.AreEqual(FSent, LOut, 'the hook sees exactly what the transport saw');
  Assert.IsTrue(LIn.Contains('"result":42'), LIn);
end;

procedure TJRPCClientTest.TestExecuteDiscardsTheResult;
var
  LRequest: TJRPCRequest;
begin
  LRequest := NewRequest('math/sum');
  try
    LRequest.AddNamedParam('a', 1);
    LRequest.AddNamedParam('b', 1);

    FClient.Execute(LRequest);
    Assert.IsTrue(FSent.Contains('"method":"math/sum"'), FSent);
  finally
    LRequest.Free;
  end;
end;

procedure TJRPCClientTest.TestClosedClientRaisesUntilANewTransport;
var
  LClosed: Integer;
  LKind: TJRPCCloseKind;
begin
  LClosed := 0;
  LKind := TJRPCCloseKind.Error;
  FClient.OnClose :=
    procedure (const AInfo: TJRPCCloseInfo)
    begin
      Inc(LClosed);
      LKind := AInfo.Kind;
    end;

  FClient.Open;
  Assert.IsTrue(FClient.Active);

  FClient.Close;
  FClient.Close;
  Assert.IsFalse(FClient.Active);
  Assert.AreEqual(1, LClosed, 'OnClose fires once');
  Assert.IsTrue(LKind = TJRPCCloseKind.Local);

  Assert.WillRaise(
    procedure
    begin
      FClient.ExecuteAs<Integer>(TJRPCRequestBuilder.New.SetMethod('math/sum'));
    end,
    EJRPCClientError);

  // A new transport opens the client again.
  FClient.Transport := TJRPCFuncTransport.Create(
    function (const AText: string): string
    begin
      Result := FServer.ProcessRequest(AText);
    end);

  Assert.AreEqual(3, FClient.ExecuteAs<Integer>(
    TJRPCRequestBuilder.New.SetMethod('math/sum').AddNamedParam('a', 1).AddNamedParam('b', 2)));
end;

procedure TJRPCClientTest.TestStreamNotificationGoesToItsCall;
var
  LBuilder: IJRPCRequestBuilder;
  LCall: IJRPCCall<Integer>;
  LMethods: TStringList;
  LGlobal: Integer;
begin
  LGlobal := 0;
  LMethods := TStringList.Create;
  try
    StubFrames([
      '{"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":1}}',
      '{"jsonrpc":"2.0","id":7,"result":42}']);

    FClient.OnNotification :=
      procedure (const ANotification: TJRPCNotification)
      begin
        Inc(LGlobal);
      end;

    // The frames are scripted with id 7.
    LBuilder := TJRPCRequestBuilder.New.SetMethod('stream/echo');
    LBuilder.Build.Id := 7;

    LCall := FClient.ExecuteAsync<Integer>(LBuilder,
      procedure (const ANotification: TJRPCNotification)
      begin
        LMethods.Add(ANotification.Method);
      end);

    // The handler of the call runs before the answer that follows it.
    Assert.AreEqual(42, LCall.Value);
    Assert.AreEqual(1, LMethods.Count, 'the notification goes to its call');
    Assert.AreEqual('notifications/progress', LMethods[0]);
    Assert.AreEqual(0, LGlobal, 'and not to OnNotification');
  finally
    FClient.OnNotification := nil;
    LMethods.Free;
  end;
end;

procedure TJRPCClientTest.TestStreamNotificationWithoutHandlerGoesToOnNotification;
var
  LBuilder: IJRPCRequestBuilder;
  LCount: Integer;
  LMethod: string;
begin
  LCount := 0;
  LMethod := '';

  StubFrames([
    '{"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":1}}',
    '{"jsonrpc":"2.0","id":7,"result":42}']);

  // Direct: the handler runs on the thread that reads the stream, so it has
  // run by the time the call returns.
  FClient.DispatchMode := TJRPCDispatchMode.Direct;
  FClient.OnNotification :=
    procedure (const ANotification: TJRPCNotification)
    begin
      Inc(LCount);
      LMethod := ANotification.Method;
    end;

  LBuilder := TJRPCRequestBuilder.New.SetMethod('stream/echo');
  LBuilder.Build.Id := 7;

  Assert.AreEqual<Integer>(42, FClient.ExecuteAs<Integer>(LBuilder));
  Assert.AreEqual(1, LCount, 'the notification must be delivered');
  Assert.AreEqual('notifications/progress', LMethod);
end;

procedure TJRPCClientTest.TestStreamErrorFrameRaises;
var
  LBuilder: IJRPCRequestBuilder;
begin
  StubFrames([
    '{"jsonrpc":"2.0","id":7,"error":{"code":-32602,"message":"bad args","data":{"detail":1}}}']);

  LBuilder := TJRPCRequestBuilder.New.SetMethod('stream/echo');
  LBuilder.Build.Id := 7;

  try
    FClient.ExecuteAs<Integer>(LBuilder);
    Assert.Fail('expected EJRPCRemoteError');
  except
    on E: EJRPCRemoteError do
    begin
      Assert.AreEqual(-32602, E.Code);
      Assert.IsNotNull(E.ErrorData);
      Assert.AreEqual(1, (E.ErrorData as TJSONObject).GetValue<Integer>('detail'));
    end;
  end;
end;

procedure TJRPCClientTest.TestStreamArrayOfOneErrorFrameRaises;
var
  LBuilder: IJRPCRequestBuilder;
begin
  StubFrames([
    '[{"jsonrpc":"2.0","id":7,"error":{"code":-32602,"message":"bad args","data":{"detail":1}}}]']);

  LBuilder := TJRPCRequestBuilder.New.SetMethod('stream/echo');
  LBuilder.Build.Id := 7;

  try
    FClient.ExecuteAs<Integer>(LBuilder);
    Assert.Fail('expected EJRPCRemoteError');
  except
    on E: EJRPCRemoteError do
    begin
      Assert.AreEqual(-32602, E.Code);
      // The raw element is what the data is read from, inside the array too.
      Assert.IsNotNull(E.ErrorData);
    end;
  end;
end;

procedure TJRPCClientTest.TestStreamResultSurvivesFailureAfterIt;
var
  LBuilder: IJRPCRequestBuilder;
begin
  // The answer arrives, then the transport fails winding down. The caller
  // asked for the answer and has it.
  StubFrames(['{"jsonrpc":"2.0","id":7,"result":42}'], 'connection reset while closing');

  LBuilder := TJRPCRequestBuilder.New.SetMethod('stream/echo');
  LBuilder.Build.Id := 7;

  Assert.AreEqual(42, FClient.ExecuteAs<Integer>(LBuilder));
end;

procedure TJRPCClientTest.TestStreamErrorSurvivesFailureAfterIt;
var
  LBuilder: IJRPCRequestBuilder;
begin
  StubFrames([
    '{"jsonrpc":"2.0","id":7,"error":{"code":-32602,"message":"bad args","data":{"detail":1}}}'],
    'connection reset while closing');

  LBuilder := TJRPCRequestBuilder.New.SetMethod('stream/echo');
  LBuilder.Build.Id := 7;

  try
    FClient.ExecuteAs<Integer>(LBuilder);
    Assert.Fail('expected EJRPCRemoteError');
  except
    on E: EJRPCRemoteError do
      Assert.AreEqual(-32602, E.Code);
  end;
end;

procedure TJRPCClientTest.TestStreamFailureBeforeAnswerRaises;
var
  LBuilder: IJRPCRequestBuilder;
  LMessage: string;
begin
  // No answer yet: the failure is the outcome of the call, raised as it is.
  StubFrames(['{"jsonrpc":"2.0","method":"notifications/progress"}'],
    'connection reset mid-stream');

  LBuilder := TJRPCRequestBuilder.New.SetMethod('stream/echo');
  LBuilder.Build.Id := 7;

  LMessage := '';
  try
    FClient.ExecuteAs<Integer>(LBuilder);
  except
    on E: Exception do
      LMessage := E.Message;
  end;
  Assert.AreEqual('connection reset mid-stream', LMessage);
end;

procedure TJRPCClientTest.TestStreamEndsWithoutResponseRaises;
var
  LBuilder: IJRPCRequestBuilder;
begin
  StubFrames(['{"jsonrpc":"2.0","method":"notifications/progress","params":{}}']);

  LBuilder := TJRPCRequestBuilder.New.SetMethod('stream/echo');
  LBuilder.Build.Id := 7;

  try
    FClient.ExecuteAs<Integer>(LBuilder);
    Assert.Fail('expected EJRPCClientError');
  except
    on E: EJRPCClientError do
      Assert.IsTrue(E.Message <> '', 'the failure must explain itself');
  end;
end;

procedure TJRPCClientTest.TestStreamWrongIdRaises;
var
  LBuilder: IJRPCRequestBuilder;
  LReported: string;
begin
  LReported := '';
  FClient.OnError :=
    procedure (E: Exception; var AAction: TJRPCErrorAction)
    begin
      if LReported = '' then
        LReported := E.Message;
    end;

  StubFrames(['{"jsonrpc":"2.0","id":8,"result":42}']);

  LBuilder := TJRPCRequestBuilder.New.SetMethod('stream/echo');
  LBuilder.Build.Id := 7;

  Assert.WillRaise(
    procedure
    begin
      FClient.ExecuteAs<Integer>(LBuilder);
    end,
    EJRPCClientError);
  Assert.IsTrue(LReported.Contains('[8]'), 'the stray answer is reported: ' + LReported);
end;

procedure TJRPCClientTest.TestStreamPeerRequestIsAnswered;
var
  LBuilder: IJRPCRequestBuilder;
  LReplies: TStringList;
begin
  // A request of the peer inside the answer stream (sampling, in legacy MCP):
  // it is served like any other, and the answer goes out as a new message.
  LReplies := TStringList.Create;
  try
    FClient.Transport := TJRPCFuncTransport.CreateFramed(
      procedure (const AText: string; const AOnFrame: TJRPCFrameSink)
      begin
        AOnFrame('{"jsonrpc":"2.0","id":"s1","method":"server/ping"}');
        AOnFrame('{"jsonrpc":"2.0","id":7,"result":42}');
      end,
      procedure (const AText: string)
      begin
        LReplies.Add(AText);
      end);

    FClient.DispatchMode := TJRPCDispatchMode.Direct;
    FClient.OnRequest :=
      procedure (const ARequest: TJRPCRequest; const AReply: IJRPCReply)
      begin
        AReply.Result('pong');
      end;

    LBuilder := TJRPCRequestBuilder.New.SetMethod('stream/echo');
    LBuilder.Build.Id := 7;

    Assert.AreEqual(42, FClient.ExecuteAs<Integer>(LBuilder));
    Assert.AreEqual(1, LReplies.Count, LReplies.Text);
    Assert.IsTrue(LReplies[0].Contains('"id":"s1"'), LReplies[0]);
    Assert.IsTrue(LReplies[0].Contains('"result":"pong"'), LReplies[0]);
  finally
    FClient.OnRequest := nil;
    FClient.Transport := nil;
    LReplies.Free;
  end;
end;

procedure TJRPCClientTest.TestStreamArrayFrameIsMatchedById;
var
  LBuilder: IJRPCRequestBuilder;
begin
  StubFrames(['[{"jsonrpc":"2.0","id":7,"result":1},{"jsonrpc":"2.0","id":8,"result":2}]']);

  LBuilder := TJRPCRequestBuilder.New.SetMethod('stream/echo');
  LBuilder.Build.Id := 7;

  Assert.AreEqual(1, FClient.ExecuteAs<Integer>(LBuilder));
end;

procedure TJRPCClientTest.TestStreamTraceSeesEachFrame;
var
  LBuilder: IJRPCRequestBuilder;
  LCount: Integer;
begin
  LCount := 0;

  StubFrames([
    '{"jsonrpc":"2.0","method":"notifications/progress","params":{}}',
    '{"jsonrpc":"2.0","id":7,"result":42}']);

  FClient.OnAfterReceive :=
    procedure (const AJSON: string)
    begin
      Inc(LCount);
    end;

  LBuilder := TJRPCRequestBuilder.New.SetMethod('stream/echo');
  LBuilder.Build.Id := 7;

  FClient.ExecuteAs<Integer>(LBuilder);
  Assert.AreEqual(2, LCount, 'OnAfterReceive sees every frame, not the whole body');
end;

procedure TJRPCClientTest.TestExecuteAsyncValue;
var
  LCall: IJRPCCall<Integer>;
begin
  LCall := FClient.ExecuteAsync<Integer>(
    TJRPCRequestBuilder.New.SetMethod('math/sum').AddNamedParam('a', 20).AddNamedParam('b', 22));

  Assert.IsTrue(LCall.Wait(5000), 'the call must complete');
  Assert.IsTrue(LCall.Completed);
  Assert.IsFalse(LCall.Id.IsNull, 'the call carries the id it went out with');
  Assert.AreEqual(42, LCall.Value);
  // Value can be read again
  Assert.AreEqual(42, LCall.Value);
end;

procedure TJRPCClientTest.TestExecuteAsyncRemoteError;
var
  LCall: IJRPCCall<Integer>;
begin
  LCall := FClient.ExecuteAsync<Integer>(TJRPCRequestBuilder.New.SetMethod('no/such/method'));

  try
    LCall.Value;
    Assert.Fail('expected EJRPCRemoteError');
  except
    on E: EJRPCRemoteError do
      Assert.AreEqual(JRPC_METHOD_NOT_FOUND, E.Code);
  end;
end;

procedure TJRPCClientTest.TestExecuteAsyncCallsOverlap;
const
  CALLS = 4;
  DELAY_MS = 300;
var
  LCalls: TArray<IJRPCCall<Integer>>;
  LWatch: TStopwatch;
  LIndex: Integer;
begin
  // A RoundTrip Send blocks for the whole exchange: the client runs each one
  // on a task, so four slow answers take about as long as one.
  FClient.Transport := TJRPCFuncTransport.Create(
    function (const AText: string): string
    begin
      Sleep(DELAY_MS);
      Result := FServer.ProcessRequest(AText);
    end);

  LWatch := TStopwatch.StartNew;
  SetLength(LCalls, CALLS);
  for LIndex := 0 to CALLS - 1 do
    LCalls[LIndex] := FClient.ExecuteAsync<Integer>(
      TJRPCRequestBuilder.New.SetMethod('math/sum')
        .AddNamedParam('a', LIndex).AddNamedParam('b', 100));

  for LIndex := 0 to CALLS - 1 do
    Assert.AreEqual(100 + LIndex, LCalls[LIndex].Value);
  LWatch.Stop;

  Assert.IsTrue(LWatch.ElapsedMilliseconds < CALLS * DELAY_MS,
    Format('the calls ran one after the other: %d ms', [LWatch.ElapsedMilliseconds]));
end;

procedure TJRPCClientTest.TestExecuteAsyncFailureRaisedOnceThenQuoted;
var
  LCall: IJRPCCall<Integer>;
  LFirst, LSecond: string;
begin
  StubFrames(['{"jsonrpc":"2.0","method":"notifications/progress"}'], 'link down');

  LCall := FClient.ExecuteAsync<Integer>(TJRPCRequestBuilder.New.SetMethod('stream/echo'));

  LFirst := '';
  try
    LCall.Value;
  except
    on E: Exception do
      LFirst := E.ClassName + ': ' + E.Message;
  end;

  LSecond := '';
  try
    LCall.Value;
  except
    on E: Exception do
      LSecond := E.ClassName + ': ' + E.Message;
  end;

  // The transport's own exception, then a client error that quotes it.
  Assert.AreEqual('Exception: link down', LFirst);
  Assert.IsTrue(LSecond.StartsWith(EJRPCClientError.ClassName), LSecond);
  Assert.IsTrue(LSecond.Contains('link down'), LSecond);
end;

procedure TJRPCClientTest.TestExecuteAsyncDeliversItsNotifications;
var
  LCall: IJRPCCall<Integer>;
  LCount: Integer;
  LGlobal: Integer;
begin
  LCount := 0;
  LGlobal := 0;

  // A subscription that ends abruptly: three notifications and no answer.
  StubFrames([
    '{"jsonrpc":"2.0","method":"notifications/first"}',
    '{"jsonrpc":"2.0","method":"notifications/second"}',
    '{"jsonrpc":"2.0","method":"notifications/third"}']);

  FClient.DispatchMode := TJRPCDispatchMode.Direct;
  FClient.OnNotification :=
    procedure (const ANotification: TJRPCNotification)
    begin
      Inc(LGlobal);
    end;

  LCall := FClient.ExecuteAsync<Integer>(
    TJRPCRequestBuilder.New.SetMethod('subscriptions/listen'),
    procedure (const ANotification: TJRPCNotification)
    begin
      TInterlocked.Increment(LCount);
    end);

  Assert.IsTrue(LCall.Wait(5000), 'the call must end');
  Assert.AreEqual(3, LCount, 'every notification goes to the call');
  Assert.AreEqual(0, LGlobal, 'none of them to OnNotification');
  Assert.WillRaise(
    procedure
    begin
      LCall.Value;
    end,
    EJRPCClientError);
end;

procedure TJRPCClientTest.TestCancelAbortsTheRead;
var
  LTransport: TListenTransport;
  LCall: IJRPCCall<Integer>;
  LFirst: TEvent;
  LEnded: TJRPCCallEnd;
  LEndedId: string;
  LWatch: TStopwatch;
begin
  LFirst := TEvent.Create(nil, True, False, '');
  try
    LTransport := TListenTransport.Create(False);
    FClient.Transport := LTransport;

    LEndedId := '';
    FClient.OnCallEnded :=
      procedure (const AId: TJRPCID; AReason: TJRPCCallEnd)
      begin
        LEnded := AReason;
        LEndedId := AId.AsString;
      end;

    LCall := FClient.ExecuteAsync<Integer>(
      TJRPCRequestBuilder.New.SetMethod('subscriptions/listen'),
      procedure (const ANotification: TJRPCNotification)
      begin
        LFirst.SetEvent;
      end);

    Assert.IsTrue(LFirst.WaitFor(5000) = wrSignaled, 'the first notification must arrive');
    Assert.IsFalse(LCall.Wait(100), 'the read is still going');

    LCall.Cancel;

    Assert.IsTrue(LCall.Completed, 'Cancel completes the call');
    Assert.AreEqual(1, LTransport.Aborts, 'and aborts the read');
    Assert.IsTrue(LEnded = TJRPCCallEnd.Cancelled);
    Assert.AreEqual(LCall.Id.AsString, LEndedId);
    Assert.WillRaise(
      procedure
      begin
        LCall.Value;
      end,
      EJRPCClientError);

    // Close waits for the aborted Send, which ends at once.
    LWatch := TStopwatch.StartNew;
    FClient.Transport := nil;
    Assert.IsTrue(LWatch.ElapsedMilliseconds < 1000,
      Format('the aborted read held Close for %d ms', [LWatch.ElapsedMilliseconds]));
  finally
    FClient.OnCallEnded := nil;
    LFirst.Free;
  end;
end;

procedure TJRPCClientTest.TestCancelledBeforeItStartsNeverSends;
var
  LTransport: TListenTransport;
  LCall: IJRPCCall<Integer>;
  LRound: Integer;
  LWatch: TStopwatch;
begin
  // Cancel right after ExecuteAsync usually lands before the task has called
  // the transport, which would then clear the abort as its read starts and
  // wait on a silent peer. Several rounds, since which side wins is up to the
  // scheduler.
  for LRound := 1 to 10 do
  begin
    LTransport := TListenTransport.Create(True);
    FClient.Transport := LTransport;

    LCall := FClient.ExecuteAsync<Integer>(
      TJRPCRequestBuilder.New.SetMethod('subscriptions/listen'));
    LCall.Cancel;
    Assert.IsTrue(LCall.Wait(100));
    LCall := nil;

    LWatch := TStopwatch.StartNew;
    FClient.Transport := nil;
    Assert.IsTrue(LWatch.ElapsedMilliseconds < 1500,
      Format('round %d: a call cancelled before it started held Close for %d ms',
        [LRound, LWatch.ElapsedMilliseconds]));
  end;
end;

procedure TJRPCClientTest.RunSelfCapturingCall(AFreed: PBoolean);
var
  LCall: IJRPCCall<Integer>;
  LProbe: IInterface;
begin
  LProbe := TReleaseProbe.Create(AFreed);

  LCall := FClient.ExecuteAsync<Integer>(
    TJRPCRequestBuilder.New.SetMethod('subscriptions/listen'),
    procedure (const ANotification: TJRPCNotification)
    begin
      // Captures the call: the natural way to stop it from its own handler.
      if ANotification.Method = 'never' then
        LCall.Cancel;
      if not Assigned(LProbe) then
        Exit;
    end);

  Assert.IsTrue(LCall.Wait(5000), 'the call must end');
  // No LCall := nil: the method ends with the call still captured.
end;

procedure TJRPCClientTest.TestReleasesSelfCapturingHandler;
var
  LFreed: Boolean;
  LWait: Integer;
begin
  LFreed := False;

  StubFrames(['{"jsonrpc":"2.0","method":"notifications/first"}']);
  RunSelfCapturingCall(@LFreed);

  // The task lets go of its references just after the call completes.
  LWait := 0;
  while not LFreed and (LWait < 2000) do
  begin
    Sleep(20);
    Inc(LWait, 20);
  end;

  Assert.IsTrue(LFreed, 'a handler that captures its own call must not keep it alive');
end;

procedure TJRPCClientTest.TestNeonConfigIsHonoured;
var
  LProbe: TNeonSnakeProbe;
begin
  // Echo the id the client chose, so the test does not depend on the shared
  // id counter's value.
  FClient.Transport := TJRPCFuncTransport.Create(
    function (const AText: string): string
    begin
      Result := Format('{"jsonrpc":"2.0","id":%s,"result":{"some_value":42}}', [IdOf(AText)]);
    end);

  // The default configuration expects someValue; Snake is what reads this one.
  FClient.NeonConfig := TNeonConfiguration.Snake;

  LProbe := FClient.ExecuteAs<TNeonSnakeProbe>(
    TJRPCRequestBuilder.New.SetMethod('config/probe'));
  try
    Assert.AreEqual(42, LProbe.SomeValue);
  finally
    LProbe.Free;
  end;
end;

end.
