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
///   TJRPCClient, exercised against a real TJRPCServer wired straight into its
///   OnTransport - an in-process loopback, so every test is a full round trip
///   with no socket, no thread and no timing.
/// </summary>
unit JRPC.Tests.Client;

interface

uses
  System.SysUtils, System.JSON,
  DUnitX.TestFramework,

  JRPC.Core,
  JRPC.Server,
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
    ///   A bare Request, for the cases the builder cannot serve.
    /// </summary>
    /// <remarks>
    ///   TJRPCRequestBuilder owns what it builds, and TJRPCMessages takes
    ///   ownership of what it is given: handing a built request to a batch
    ///   would have the two free the same object.
    /// </remarks>
    function NewRequest(const AMethod: string): TJRPCRequest;
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

    // Errors from the peer
    [Test] procedure TestMethodNotFoundRaisesRemoteError;
    [Test] procedure TestInvalidParamsRaisesRemoteError;
    [Test] procedure TestRemoteErrorKeepsStructuredData;
    [Test] procedure TestRemoteErrorKeepsCodeZero;
    [Test] procedure TestRemoteErrorWithNullIdIsAccepted;

    // Malformed replies
    [Test] procedure TestEmptyReplyRaises;
    [Test] procedure TestUnparsableReplyRaises;
    [Test] procedure TestBatchReplyToSingleRequestRaises;
    [Test] procedure TestReplyWithResultAndErrorRaises;

    // OnError
    [Test] procedure TestOnErrorReportsAndStillRaises;
    [Test] procedure TestOnErrorReportsOncePerCall;

    // Notifications
    [Test] procedure TestNotificationIsNeverRead;
    [Test] procedure TestNotificationOverLoopback;
    [Test] procedure TestNotificationBuilder;
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
    [Test] procedure TestExecuteRawIsUntouched;
  end;

implementation

uses
  System.Classes, System.Rtti, System.Generics.Collections, System.Threading,
  System.SyncObjs,

  JRPC.Tests.Api;

{ TJRPCClientTest }

procedure TJRPCClientTest.Setup;
begin
  FSent := '';
  FServer := TJRPCServer.Create(nil);
  FClient := TJRPCClient.Create(nil);

  // The whole trick: the server *is* the transport.
  FClient.OnTransport :=
    function(const ARequest: string): string
    begin
      FSent := ARequest;
      Result := FServer.ProcessRequest(ARequest);
    end;
end;

procedure TJRPCClientTest.TearDown;
begin
  FClient.Free;
  FServer.Free;
end;

procedure TJRPCClientTest.StubReply(const AReply: string);
begin
  FClient.OnTransport :=
    function(const ARequest: string): string
    begin
      FSent := ARequest;
      Result := AReply;
    end;
end;

function TJRPCClientTest.NewRequest(const AMethod: string): TJRPCRequest;
begin
  Result := TJRPCRequest.Create;
  Result.Method := AMethod;
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
  // CamelCase: the PascalCase API would be testing a casing mismatch instead.
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
  // arrive as a live TJSONNull, not as nil: "nothing" and "no answer" are
  // different things.
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

  // JSON-RPC 2.0 wants the member absent, not null: a strict peer answers
  // -32602 to "params": null.
  Assert.IsFalse(FSent.Contains('"params"'), 'no params member expected: ' + FSent);
end;

procedure TJRPCClientTest.TestBuilderMixedParamsRaise;
begin
  // JSON-RPC 2.0 has no shape for a message carrying both: "params" is either
  // an Array or an Object.
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
  // Build only lends the request out - the builder frees it - so the two ways
  // in must agree, and neither may leak.
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
  // The interlocked counter is the only thing standing between two threads and
  // a duplicate id on the wire.
  LSeen := TList<Integer>.Create;
  LLock := TCriticalSection.Create;
  try
    TParallel.For(1, THREAD_COUNT,
      procedure(AIndex: Integer)
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
  // The desync a hand-written client never notices: the answer to the previous
  // call, returned as if it were this one.
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
  // The string "7" and the number 7 are different ids: AsString alone cannot
  // tell them apart, which is why SameId compares the kind first.
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
    // "a" is an Integer: a string is -32602.
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
  // The regression that matters: TJValueSerializer maps only numbers, strings
  // and booleans into TJRPCErrorDetails.Data, so an object payload arrives
  // empty there. It has to be lifted out of the raw document instead.
  StubReply('{"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"nope",' +
    '"data":{"retryAfter":30,"reason":"busy"}}}');

  // An explicit id, because a canned reply cannot echo the generated one - and
  // the client would rightly call that a desync.
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
  // EJRPCException.AfterConstruction stamps -32603 over a zero code; a peer may
  // legitimately answer 0, so the wire value has to be put back.
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
  // A null id is what a peer answers when it could not read ours: that is not
  // a desync, it is the documented shape of a parse error.
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

procedure TJRPCClientTest.TestBatchReplyToSingleRequestRaises;
begin
  StubReply('[{"jsonrpc":"2.0","id":1,"result":1},{"jsonrpc":"2.0","id":2,"result":2}]');

  Assert.WillRaise(
    procedure
    begin
      FClient.ExecuteAs<Integer>(TJRPCRequestBuilder.New.SetMethod('math/sum'));
    end,
    EJRPCClientError);
end;

procedure TJRPCClientTest.TestReplyWithResultAndErrorRaises;
begin
  // Mutually exclusive per the spec; TJRPCMessages.GetMessageType rejects it.
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
    procedure(E: Exception)
    begin
      LSeen := E.Message;
    end;

  // OnError observes, it does not handle: assigning it must not change the
  // flow of a failed call.
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
    procedure(E: Exception)
    begin
      Inc(LCount);
    end;

  // ExecuteAs goes through the private round trip rather than through
  // ExecuteAsJSONValue, so one failed call is one report - not one per layer.
  try
    FClient.ExecuteAs<Integer>(TJRPCRequestBuilder.New.SetMethod('no/such/method'));
  except
    on E: EJRPCRemoteError do
      ; // expected
  end;

  Assert.AreEqual(1, LCount);
end;

procedure TJRPCClientTest.TestNotificationIsNeverRead;
var
  LNotified: string;
  LNotification: TJRPCNotification;
begin
  LNotified := '';

  // If the client ever tried to read after a notification, this would raise.
  FClient.OnTransport :=
    function(const ARequest: string): string
    begin
      Assert.Fail('a notification must not go through the read path');
      Result := '';
    end;

  FClient.OnNotify :=
    procedure(const ARequest: string)
    begin
      LNotified := ARequest;
    end;

  LNotification := TJRPCNotification.Create;
  try
    LNotification.Method := 'math/notif';
    LNotification.AddNamedParam('a', 1);
    LNotification.AddNamedParam('b', 2);

    FClient.Execute(LNotification);
  finally
    LNotification.Free;
  end;

  Assert.IsTrue(LNotified.Contains('"method":"math/notif"'), LNotified);
  Assert.IsFalse(LNotified.Contains('"id"'), 'a notification carries no id: ' + LNotified);
end;

procedure TJRPCClientTest.TestNotificationOverLoopback;
var
  LNotification: TJRPCNotification;
begin
  // With only OnTransport wired, the loopback returns '' for a notification and
  // the client must not try to make sense of it.
  LNotification := TJRPCNotification.Create;
  try
    LNotification.Method := 'math/notif';
    LNotification.AddNamedParam('a', 1);
    LNotification.AddNamedParam('b', 2);

    FClient.Execute(LNotification);
  finally
    LNotification.Free;
  end;

  Assert.IsFalse(FSent.Contains('"id"'), 'a notification carries no id: ' + FSent);
end;

procedure TJRPCClientTest.TestNotificationBuilder;
var
  LNotified: string;
begin
  LNotified := '';

  // Same guarantee as TestNotificationIsNeverRead, reached through the builder.
  FClient.OnTransport :=
    function(const ARequest: string): string
    begin
      Assert.Fail('a notification must not go through the read path');
      Result := '';
    end;

  FClient.OnNotify :=
    procedure(const ARequest: string)
    begin
      LNotified := ARequest;
    end;

  // The builder owns the notification for the whole statement, so there is
  // nothing to free and no try/finally.
  FClient.Execute(
    TJRPCNotificationBuilder.New
      .SetMethod('math/notif')
      .AddNamedParam('a', 1)
      .AddNamedParam('b', 2));

  Assert.IsTrue(LNotified.Contains('"method":"math/notif"'), LNotified);
  Assert.IsFalse(LNotified.Contains('"id"'), 'a notification carries no id: ' + LNotified);
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
      // An error inside a batch is returned, never raised: raising would throw
      // away the answers to the elements that did succeed.
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
    // A batch of one still goes out as an array: Single would make ToJson emit
    // a bare object.
    LRequest := NewRequest('math/sum');
    LRequest.AddNamedParam('a', 1);
    LRequest.AddNamedParam('b', 2);
    LBatch.AddMessage(LRequest);

    LAnswers := FClient.ExecuteBatch(LBatch);
    try
      Assert.IsTrue(FSent.StartsWith('['), 'a batch is an array: ' + FSent);
      // Line-framed transports read a payload up to the first LF.
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
    procedure(const AJSON: string)
    begin
      LOut := AJSON;
      Inc(LOutCount);
    end;

  FClient.OnAfterReceive :=
    procedure(const AJSON: string)
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

    // Nothing to free at the call site, and an error would still surface.
    FClient.Execute(LRequest);
    Assert.IsTrue(FSent.Contains('"method":"math/sum"'), FSent);
  finally
    LRequest.Free;
  end;
end;

procedure TJRPCClientTest.TestExecuteRawIsUntouched;
var
  LReply: string;
begin
  // Deliberately malformed: the escape hatch must not tidy it up on the way out.
  LReply := FClient.ExecuteRaw('{not json');

  Assert.AreEqual('{not json', FSent, 'the raw payload goes out verbatim');
  Assert.IsTrue(LReply.Contains('-32700'), 'the server answers a parse error: ' + LReply);
end;

end.
