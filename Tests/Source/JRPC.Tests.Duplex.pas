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
///   TJRPCClient over a persistent channel (RoundTrip = False): the peer is a
///   queue the test writes to and reads from, behind a TJRPCPullTransport, so
///   every case is a full exchange with a real reader thread and no socket.
/// </summary>
unit JRPC.Tests.Duplex;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Generics.Collections,
  System.JSON,
  DUnitX.TestFramework,

  JRPC.Core,
  JRPC.Server,
  JRPC.Transport,
  JRPC.Client;

type
  TTransportSendProc = reference to procedure(const AText: string);

  /// <summary>
  ///   A pull transport backed by a queue: Push is the peer sending, SentText
  ///   is what the client wrote, PeerClose is the peer hanging up.
  /// </summary>
  TMemoryMessageTransport = class(TJRPCPullTransport)
  private
    FQueue: TThreadedQueue<string>;
    FOnSend: TTransportSendProc;
    FSent: TStringList;
    FLock: TCriticalSection;
  protected
    function Receive(out AText: string): Boolean; override;
    procedure DoSend(const AText: string); override;
    procedure DoClose; override;
  public
    constructor Create;
    destructor Destroy; override;

    /// <summary>The peer sends a message to the client.</summary>
    procedure Push(const AText: string);

    /// <summary>The peer closes its side: Receive returns False.</summary>
    procedure PeerClose;

    function SentCount: Integer;
    function SentText(AIndex: Integer): string;

    /// <summary>Called for every message the client writes.</summary>
    property OnSend: TTransportSendProc read FOnSend write FOnSend;
  end;

  [TestFixture]
  TJRPCDuplexTest = class
  private
    FTransport: TMemoryMessageTransport;
    FClient: TJRPCClient;

    function NewRequest(const AMethod: string): TJRPCRequest;
    class function RequestIdOf(const AText: string): string; static;
    function EchoReply(const AText: string): string;
    function WaitUntil(const ACondition: TFunc<Boolean>; ATimeout: Integer = 3000): Boolean;
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;

    // Calls
    [Test] procedure TestCallCorrelatesResponse;
    [Test] procedure TestCallAssignsAnId;
    [Test] procedure TestRemoteErrorRaises;
    [Test] procedure TestTimeoutRaises;
    [Test] procedure TestTimeoutFiresOnCallEnded;
    [Test] procedure TestCallAsyncCanBeCancelled;
    [Test] procedure TestTwoConcurrentCalls;
    [Test] procedure TestUnknownIdIsReported;
    [Test] procedure TestDuplicatePendingIdRaisesClientError;
    [Test] procedure TestNotifySends;

    // What the peer sends on its own
    [Test] procedure TestNotificationDelivered;
    [Test] procedure TestInboundRequestAnswered;
    [Test] procedure TestInboundRequestAnsweredLater;
    [Test] procedure TestUnansweredRequestIsAnswered;
    [Test] procedure TestUnhandledRequestIsAnswered;
    [Test] procedure TestServerAnswersInboundRequests;
    [Test] procedure TestRaisingRequestHandlerIsAnswered;
    [Test] procedure TestHandlerCanCallTheClient;
    [Test] procedure TestSlowHandlerDoesNotDelayAnswers;

    // Malformed traffic
    [Test] procedure TestMalformedPeerRequestIsAnsweredNotRouted;
    [Test] procedure TestMalformedResponseFailsCallLocally;
    [Test] procedure TestMalformedNotificationIsReportedNotAnswered;
    [Test] procedure TestRaisingOnErrorKeepsReaderAlive;
    [Test] procedure TestArrayOfOneStrayAnswerIsReported;
    [Test] procedure TestUnparseableFrameIsAnswered;
    [Test] procedure TestPeerBatchRequestsAreAnswered;
    [Test] procedure TestBlankFrameIsIgnored;

    // Closing
    [Test] procedure TestPeerCloseFailsPending;
    [Test] procedure TestLocalCloseReportsLocal;
    [Test] procedure TestCallAfterCloseRaises;
    [Test] procedure TestFreeAfterCloseFromHandlerWaitsForHandler;
    [Test] procedure TestFreeAfterCloseFromDirectHandlerWaitsForReader;

    // The asynchronous loopback
    [Test] procedure TestLoopbackCorrelatesOutOfOrder;
  end;

implementation

uses
  System.Threading, System.StrUtils, System.Diagnostics, System.Rtti,

  JRPC.Tests.Api;

{ TMemoryMessageTransport }

constructor TMemoryMessageTransport.Create;
begin
  inherited Create;
  FQueue := TThreadedQueue<string>.Create(1024, JRPC_INFINITE, JRPC_INFINITE);
  FSent := TStringList.Create;
  FLock := TCriticalSection.Create;
end;

destructor TMemoryMessageTransport.Destroy;
begin
  // The inherited destructor joins the reader, which still pops from the queue.
  inherited;
  FLock.Free;
  FSent.Free;
  FQueue.Free;
end;

function TMemoryMessageTransport.Receive(out AText: string): Boolean;
var
  LText: string;
begin
  // After DoShutDown PopItem still answers wrSignaled, with an empty item:
  // the queue itself says whether it is over.
  Result := (FQueue.PopItem(LText) = wrSignaled) and not FQueue.ShutDown;
  AText := LText;
end;

procedure TMemoryMessageTransport.DoSend(const AText: string);
begin
  FLock.Enter;
  try
    FSent.Add(AText);
  finally
    FLock.Leave;
  end;

  if Assigned(FOnSend) then
    FOnSend(AText);
end;

procedure TMemoryMessageTransport.DoClose;
begin
  FQueue.DoShutDown;
end;

procedure TMemoryMessageTransport.Push(const AText: string);
begin
  FQueue.PushItem(AText);
end;

procedure TMemoryMessageTransport.PeerClose;
begin
  FQueue.DoShutDown;
end;

function TMemoryMessageTransport.SentCount: Integer;
begin
  FLock.Enter;
  try
    Result := FSent.Count;
  finally
    FLock.Leave;
  end;
end;

function TMemoryMessageTransport.SentText(AIndex: Integer): string;
begin
  FLock.Enter;
  try
    Result := FSent[AIndex];
  finally
    FLock.Leave;
  end;
end;

{ TJRPCDuplexTest }

procedure TJRPCDuplexTest.Setup;
begin
  FTransport := TMemoryMessageTransport.Create;
  FClient := TJRPCClient.Create(nil);
  FClient.Transport := FTransport;
  FClient.Open;
end;

procedure TJRPCDuplexTest.TearDown;
begin
  // The client holds the transport's interface reference: freeing it releases
  // the last one, so FTransport must not be freed here as well.
  FClient.Free;
  FTransport := nil;
end;

function TJRPCDuplexTest.NewRequest(const AMethod: string): TJRPCRequest;
begin
  Result := TJRPCRequest.Create;
  Result.Method := AMethod;
end;

class function TJRPCDuplexTest.RequestIdOf(const AText: string): string;
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

function TJRPCDuplexTest.EchoReply(const AText: string): string;
var
  LId: string;
begin
  LId := RequestIdOf(AText);
  Result := Format('{"jsonrpc":"2.0","id":%s,"result":%s}', [LId, LId]);
end;

function TJRPCDuplexTest.WaitUntil(const ACondition: TFunc<Boolean>; ATimeout: Integer): Boolean;
var
  LWaited: Integer;
begin
  LWaited := 0;
  while not ACondition() do
  begin
    if LWaited >= ATimeout then
      Exit(False);
    Sleep(10);
    Inc(LWaited, 10);
  end;
  Result := True;
end;

procedure TJRPCDuplexTest.TestCallCorrelatesResponse;
var
  LRequest: TJRPCRequest;
  LResult: TJSONValue;
begin
  FTransport.OnSend :=
    procedure (const AText: string)
    begin
      FTransport.Push(Format('{"jsonrpc":"2.0","id":%s,"result":42}', [RequestIdOf(AText)]));
    end;

  LRequest := NewRequest('math/sum');
  try
    LResult := FClient.ExecuteAsJSONValue(LRequest, 2000);
    try
      Assert.AreEqual('42', LResult.ToJSON);
    finally
      LResult.Free;
    end;
  finally
    LRequest.Free;
  end;
end;

procedure TJRPCDuplexTest.TestCallAssignsAnId;
var
  LRequest: TJRPCRequest;
begin
  FTransport.OnSend :=
    procedure (const AText: string)
    begin
      FTransport.Push(Format('{"jsonrpc":"2.0","id":%s,"result":1}', [RequestIdOf(AText)]));
    end;

  LRequest := NewRequest('math/sum');
  try
    Assert.IsTrue(LRequest.Id.IsNull, 'the request starts without an id');
    FClient.Execute(LRequest, 2000);
    Assert.IsFalse(LRequest.Id.IsNull, 'the client gives the request an id');
    Assert.IsTrue(FTransport.SentText(0).Contains(LRequest.Id.AsString), FTransport.SentText(0));
  finally
    LRequest.Free;
  end;
end;

procedure TJRPCDuplexTest.TestRemoteErrorRaises;
begin
  FTransport.OnSend :=
    procedure (const AText: string)
    begin
      FTransport.Push(Format(
        '{"jsonrpc":"2.0","id":%s,"error":{"code":-32602,"message":"bad","data":{"detail":7}}}',
        [RequestIdOf(AText)]));
    end;

  try
    FClient.Execute(TJRPCRequestBuilder.New.SetMethod('math/sum'), 2000);
    Assert.Fail('expected EJRPCRemoteError');
  except
    on E: EJRPCRemoteError do
    begin
      Assert.AreEqual(-32602, E.Code);
      Assert.AreEqual('bad', E.Message);
      Assert.AreEqual(7, (E.ErrorData as TJSONObject).GetValue<Integer>('detail'));
    end;
  end;
end;

procedure TJRPCDuplexTest.TestTimeoutRaises;
begin
  // No OnSend: the peer never answers.
  try
    FClient.Execute(TJRPCRequestBuilder.New.SetMethod('math/slim'), 150);
    Assert.Fail('expected EJRPCClientError');
  except
    on E: EJRPCClientError do
      Assert.IsTrue(E.Message.Contains('150'), E.Message);
  end;
end;

procedure TJRPCDuplexTest.TestTimeoutFiresOnCallEnded;
var
  LRequest: TJRPCRequest;
  LReason: TJRPCCallEnd;
  LId: string;
begin
  // The place to tell the peer it can stop (notifications/cancelled in MCP).
  LId := '';
  FClient.OnCallEnded :=
    procedure (const AId: TJRPCID; AReason: TJRPCCallEnd)
    begin
      LId := AId.AsString;
      LReason := AReason;
    end;

  LRequest := NewRequest('math/slim');
  try
    try
      FClient.Execute(LRequest, 100);
    except
      on E: EJRPCClientError do
        ; // expected
    end;

    Assert.AreEqual(LRequest.Id.AsString, LId);
    Assert.IsTrue(LReason = TJRPCCallEnd.Timeout);
  finally
    FClient.OnCallEnded := nil;
    LRequest.Free;
  end;
end;

procedure TJRPCDuplexTest.TestCallAsyncCanBeCancelled;
var
  LCall: IJRPCCall<Integer>;
begin
  LCall := FClient.ExecuteAsync<Integer>(TJRPCRequestBuilder.New.SetMethod('math/slim'));
  LCall.Cancel;

  Assert.IsTrue(LCall.Wait(2000), 'cancelling completes the call');
  Assert.IsTrue(LCall.Completed);
  Assert.WillRaise(
    procedure
    begin
      LCall.Value;
    end,
    EJRPCClientError);
end;

procedure TJRPCDuplexTest.TestTwoConcurrentCalls;
var
  LThread1, LThread2: TThread;
  LResult1, LResult2: Integer;
  LId1, LId2: string;
begin
  FTransport.OnSend :=
    procedure (const AText: string)
    begin
      FTransport.Push(EchoReply(AText));
    end;

  LThread1 := TThread.CreateAnonymousThread(
    procedure
    var
      LRequest: TJRPCRequest;
    begin
      LRequest := NewRequest('echo/one');
      try
        LResult1 := FClient.ExecuteAs<Integer>(LRequest, 5000);
        LId1 := LRequest.Id.AsString;
      finally
        LRequest.Free;
      end;
    end);
  LThread1.FreeOnTerminate := False;

  LThread2 := TThread.CreateAnonymousThread(
    procedure
    var
      LRequest: TJRPCRequest;
    begin
      LRequest := NewRequest('echo/two');
      try
        LResult2 := FClient.ExecuteAs<Integer>(LRequest, 5000);
        LId2 := LRequest.Id.AsString;
      finally
        LRequest.Free;
      end;
    end);
  LThread2.FreeOnTerminate := False;

  try
    LThread1.Start;
    LThread2.Start;
    LThread1.WaitFor;
    LThread2.WaitFor;
  finally
    LThread1.Free;
    LThread2.Free;
  end;

  Assert.IsTrue(LId1 <> LId2, 'each call gets its own id');
  Assert.AreEqual(LId1, LResult1.ToString, 'the first call got the other answer');
  Assert.AreEqual(LId2, LResult2.ToString, 'the second call got the other answer');
end;

procedure TJRPCDuplexTest.TestUnknownIdIsReported;
var
  LReported: string;
begin
  LReported := '';
  FClient.OnError :=
    procedure (E: Exception; var AAction: TJRPCErrorAction)
    begin
      LReported := E.Message;
    end;

  FTransport.OnSend :=
    procedure (const AText: string)
    begin
      FTransport.Push(Format('{"jsonrpc":"2.0","id":%s,"result":1}', [RequestIdOf(AText)]));
    end;

  // An answer nobody asked for, then a normal call: the stray one must not
  // corrupt the pending map, and it is reported.
  FTransport.Push('{"jsonrpc":"2.0","id":999999,"result":1}');

  Assert.AreEqual(1, FClient.ExecuteAs<Integer>(TJRPCRequestBuilder.New.SetMethod('math/sum'), 2000));
  Assert.IsTrue(WaitUntil(
    function: Boolean
    begin
      Result := LReported <> '';
    end), 'the stray answer must be reported');
  Assert.IsTrue(LReported.Contains('999999'), LReported);
  FClient.OnError := nil;
end;

procedure TJRPCDuplexTest.TestDuplicatePendingIdRaisesClientError;
var
  LFirst, LSecond, LThird: TJRPCRequest;
  LCall: IJRPCCall<Integer>;
  LError: TClass;
  LMessage: string;
begin
  LFirst := NewRequest('math/slow');
  LSecond := NewRequest('math/other');
  LThird := NewRequest('math/third');
  try
    // No OnSend: the first call stays pending
    LFirst.Id := 5;
    LCall := FClient.ExecuteAsync<Integer>(LFirst);

    LSecond.Id := 5;
    LError := nil;
    try
      FClient.ExecuteAsync<Integer>(LSecond);
    except
      on E: Exception do
      begin
        LError := E.ClassType;
        LMessage := E.Message;
      end;
    end;

    Assert.IsTrue(LError = EJRPCClientError, 'expected EJRPCClientError, got ' +
      IfThen(Assigned(LError), LError.ClassName + ': ' + LMessage, 'no exception'));
    Assert.AreEqual(1, FTransport.SentCount, 'the refused call is never sent');

    // The string "5" is a different id on the wire, so it is not a duplicate
    LThird.Id := '5';
    FClient.ExecuteAsync<Integer>(LThird);
    Assert.AreEqual(2, FTransport.SentCount);

    // The first call is untouched and still gets its answer
    Assert.IsFalse(LCall.Completed);
    FTransport.Push('{"jsonrpc":"2.0","id":5,"result":1}');
    Assert.IsTrue(LCall.Wait(2000), 'the pending call must still be answered');
    Assert.AreEqual(1, LCall.Value);
  finally
    LThird.Free;
    LSecond.Free;
    LFirst.Free;
  end;
end;

procedure TJRPCDuplexTest.TestNotifySends;
begin
  FClient.Notify(TJRPCNotificationBuilder.New.SetMethod('notifications/cancelled'));

  Assert.AreEqual(1, FTransport.SentCount);
  Assert.IsTrue(FTransport.SentText(0).Contains('notifications/cancelled'), FTransport.SentText(0));
end;

procedure TJRPCDuplexTest.TestNotificationDelivered;
var
  LReceived: TEvent;
  LMethod: string;
begin
  LMethod := '';
  LReceived := TEvent.Create(nil, True, False, '');
  try
    FClient.OnNotification :=
      procedure (const ANotification: TJRPCNotification)
      begin
        LMethod := ANotification.Method;
        LReceived.SetEvent;
      end;

    FTransport.Push('{"jsonrpc":"2.0","method":"notifications/progress","params":{"n":1}}');

    Assert.IsTrue(LReceived.WaitFor(3000) = wrSignaled, 'the notification must arrive');
    Assert.AreEqual('notifications/progress', LMethod);
  finally
    FClient.OnNotification := nil;
    LReceived.Free;
  end;
end;

procedure TJRPCDuplexTest.TestInboundRequestAnswered;
begin
  FClient.OnRequest :=
    procedure (const ARequest: TJRPCRequest; const AReply: IJRPCReply)
    begin
      AReply.Result(TJSONNumber.Create(7));
    end;

  FTransport.Push('{"jsonrpc":"2.0","id":"srv-1","method":"sampling/createMessage","params":{}}');

  Assert.IsTrue(WaitUntil(
    function: Boolean
    begin
      Result := FTransport.SentCount > 0;
    end), 'the request must be answered');
  Assert.AreEqual(1, FTransport.SentCount);
  Assert.IsTrue(FTransport.SentText(0).Contains('"id":"srv-1"'), FTransport.SentText(0));
  Assert.IsTrue(FTransport.SentText(0).Contains('"result":7'), FTransport.SentText(0));
end;

procedure TJRPCDuplexTest.TestInboundRequestAnsweredLater;
var
  LHandlerDone: TEvent;
begin
  // The handler keeps the reply and returns at once; the answer comes later,
  // from a task - the way a slow sampling request is served.
  LHandlerDone := TEvent.Create(nil, True, False, '');
  try
    FClient.OnRequest :=
      procedure (const ARequest: TJRPCRequest; const AReply: IJRPCReply)
      var
        LReply: IJRPCReply;
      begin
        LReply := AReply;
        TTask.Run(
          procedure
          begin
            Sleep(200);
            LReply.Result(TValue.From<string>('later'));
          end);
        LHandlerDone.SetEvent;
      end;

    FTransport.Push('{"jsonrpc":"2.0","id":"srv-2","method":"sampling/createMessage"}');

    Assert.IsTrue(LHandlerDone.WaitFor(3000) = wrSignaled, 'the handler must run');
    Assert.AreEqual(0, FTransport.SentCount, 'nothing is answered when the handler returns');

    Assert.IsTrue(WaitUntil(
      function: Boolean
      begin
        Result := FTransport.SentCount > 0;
      end), 'the late answer must go out');
    Assert.AreEqual(1, FTransport.SentCount);
    Assert.IsTrue(FTransport.SentText(0).Contains('"result":"later"'), FTransport.SentText(0));
  finally
    LHandlerDone.Free;
  end;
end;

procedure TJRPCDuplexTest.TestUnansweredRequestIsAnswered;
begin
  // A handler that neither answers nor keeps the reply: the peer gets -32603
  // instead of waiting forever.
  FClient.OnRequest :=
    procedure (const ARequest: TJRPCRequest; const AReply: IJRPCReply)
    begin
    end;

  FTransport.Push('{"jsonrpc":"2.0","id":"srv-3","method":"peer/forgotten"}');

  Assert.IsTrue(WaitUntil(
    function: Boolean
    begin
      Result := FTransport.SentCount > 0;
    end), 'the request must be answered');
  Assert.IsTrue(FTransport.SentText(0).Contains('-32603'), FTransport.SentText(0));
  Assert.IsTrue(FTransport.SentText(0).Contains('"id":"srv-3"'), FTransport.SentText(0));
end;

procedure TJRPCDuplexTest.TestUnhandledRequestIsAnswered;
begin
  // No OnRequest and no Server: Method Not Found, rather than a peer left
  // waiting.
  FTransport.Push('{"jsonrpc":"2.0","id":"srv-2","method":"unknown/method"}');

  Assert.IsTrue(WaitUntil(
    function: Boolean
    begin
      Result := FTransport.SentCount > 0;
    end), 'the request must be answered');
  Assert.AreEqual(1, FTransport.SentCount);
  Assert.IsTrue(FTransport.SentText(0).Contains('-32601'), FTransport.SentText(0));
  Assert.IsTrue(FTransport.SentText(0).Contains('"id":"srv-2"'), FTransport.SentText(0));
end;

procedure TJRPCDuplexTest.TestServerAnswersInboundRequests;
var
  LServer: TJRPCServer;
begin
  // The peer's requests served by a TJRPCServer: the same methods, attributes
  // and errors as on the server side.
  LServer := TJRPCServer.Create(nil);
  try
    FClient.Server := LServer;

    FTransport.Push('{"jsonrpc":"2.0","id":"srv-4","method":"math/sum","params":{"a":2,"b":3}}');
    FTransport.Push('{"jsonrpc":"2.0","id":"srv-5","method":"no/such/method"}');

    Assert.IsTrue(WaitUntil(
      function: Boolean
      begin
        Result := FTransport.SentCount >= 2;
      end), 'both requests must be answered');
    Assert.IsTrue(FTransport.SentText(0).Contains('"id":"srv-4"'), FTransport.SentText(0));
    Assert.IsTrue(FTransport.SentText(0).Contains('"result":5'), FTransport.SentText(0));
    Assert.IsTrue(FTransport.SentText(1).Contains('-32601'), FTransport.SentText(1));
  finally
    FClient.Close;
    FClient.Server := nil;
    LServer.Free;
  end;
end;

procedure TJRPCDuplexTest.TestRaisingRequestHandlerIsAnswered;
var
  LReported: Integer;
  LGeneric, LTyped: string;
  LIndex: Integer;
begin
  // Answered the way TJRPCServer answers a method that raised: a protocol
  // exception keeps its code and message, anything else is -32603 with the
  // details kept off the wire. Both are still reported.
  LReported := 0;
  FClient.OnError :=
    procedure (E: Exception; var AAction: TJRPCErrorAction)
    begin
      TInterlocked.Increment(LReported);
    end;

  FClient.OnRequest :=
    procedure (const ARequest: TJRPCRequest; const AReply: IJRPCReply)
    begin
      if ARequest.Method = 'peer/typed' then
        raise EJRPCInvalidParamsError.Create('the x argument is missing');
      raise Exception.Create('secret internal detail');
    end;

  FTransport.Push('{"jsonrpc":"2.0","id":"srv-5","method":"peer/generic"}');
  FTransport.Push('{"jsonrpc":"2.0","id":"srv-6","method":"peer/typed"}');

  Assert.IsTrue(WaitUntil(
    function: Boolean
    begin
      Result := (FTransport.SentCount >= 2) and (LReported >= 2);
    end), 'both requests must be answered and reported');

  LGeneric := '';
  LTyped := '';
  for LIndex := 0 to FTransport.SentCount - 1 do
    if FTransport.SentText(LIndex).Contains('"srv-5"') then
      LGeneric := FTransport.SentText(LIndex)
    else if FTransport.SentText(LIndex).Contains('"srv-6"') then
      LTyped := FTransport.SentText(LIndex);

  Assert.IsTrue(LGeneric.Contains('-32603'), LGeneric);
  Assert.IsFalse(LGeneric.Contains('secret internal detail'), LGeneric);
  Assert.IsTrue(LTyped.Contains('-32602'), LTyped);
  Assert.IsTrue(LTyped.Contains('the x argument is missing'), LTyped);
  Assert.AreEqual(2, LReported, 'both failures are reported once');

  FClient.OnError := nil;
  FClient.OnRequest := nil;
end;

procedure TJRPCDuplexTest.TestHandlerCanCallTheClient;
var
  LAnswer: Integer;
begin
  // A handler that asks the peer something before answering. On the reader
  // thread this deadlocks - the answer it waits for is on the thread it
  // blocks. The dispatch thread leaves the reader free.
  LAnswer := 0;
  FTransport.OnSend :=
    procedure (const AText: string)
    begin
      if AText.Contains('"method":"peer/question"') then
        FTransport.Push(Format('{"jsonrpc":"2.0","id":%s,"result":41}', [RequestIdOf(AText)]));
    end;

  FClient.OnRequest :=
    procedure (const ARequest: TJRPCRequest; const AReply: IJRPCReply)
    begin
      LAnswer := FClient.ExecuteAs<Integer>(
        TJRPCRequestBuilder.New.SetMethod('peer/question'), 2000);
      AReply.Result(LAnswer + 1);
    end;

  FTransport.Push('{"jsonrpc":"2.0","id":"srv-7","method":"client/compute"}');

  Assert.IsTrue(WaitUntil(
    function: Boolean
    var
      LIndex: Integer;
    begin
      Result := False;
      for LIndex := 0 to FTransport.SentCount - 1 do
        if FTransport.SentText(LIndex).Contains('"id":"srv-7"') then
          Exit(True);
    end), 'the handler must be able to call the peer and answer');
  Assert.AreEqual(41, LAnswer);
  FClient.OnRequest := nil;
end;

procedure TJRPCDuplexTest.TestSlowHandlerDoesNotDelayAnswers;
var
  LWatch: TStopwatch;
  LStarted: TEvent;
begin
  // A notification handler that takes its time: the answers to the calls keep
  // arriving, since they complete on the reader, not behind the handler.
  LStarted := TEvent.Create(nil, True, False, '');
  try
    FClient.OnNotification :=
      procedure (const ANotification: TJRPCNotification)
      begin
        LStarted.SetEvent;
        Sleep(1000);
      end;

    FTransport.OnSend :=
      procedure (const AText: string)
      begin
        FTransport.Push(EchoReply(AText));
      end;

    FTransport.Push('{"jsonrpc":"2.0","method":"notifications/slow"}');
    Assert.IsTrue(LStarted.WaitFor(3000) = wrSignaled, 'the handler must start');

    LWatch := TStopwatch.StartNew;
    FClient.ExecuteAs<Integer>(TJRPCRequestBuilder.New.SetMethod('math/fast'), 3000);
    LWatch.Stop;

    Assert.IsTrue(LWatch.ElapsedMilliseconds < 500,
      Format('the answer waited for the handler: %d ms', [LWatch.ElapsedMilliseconds]));
  finally
    FClient.Close;
    FClient.OnNotification := nil;
    LStarted.Free;
  end;
end;

procedure TJRPCDuplexTest.TestMalformedPeerRequestIsAnsweredNotRouted;
var
  LRequest: TJRPCRequest;
  LId: string;
begin
  // The peer sends a request it got wrong ("jsonrpc":"1.0") under the same id
  // as our pending call. The parser's -32600 is an answer the peer is owed, not
  // an error the peer sent: it must not complete our call.
  FTransport.OnSend :=
    procedure (const AText: string)
    begin
      if not AText.Contains('"method"') then
        Exit;

      LId := RequestIdOf(AText);
      FTransport.Push(Format('{"jsonrpc":"1.0","id":%s,"method":"peer/ask"}', [LId]));
      FTransport.Push(EchoReply(AText));
    end;

  LRequest := NewRequest('math/sum');
  try
    Assert.AreEqual(FClient.ExecuteAsJsonString(LRequest, 2000), LRequest.Id.AsString,
      'the call completes with its real answer');

    Assert.IsTrue(WaitUntil(
      function: Boolean
      begin
        Result := FTransport.SentCount >= 2;
      end), 'the malformed request must be answered');
    Assert.IsTrue(FTransport.SentText(1).Contains('-32600'), FTransport.SentText(1));
    Assert.IsTrue(FTransport.SentText(1).Contains('"id":' + LId), FTransport.SentText(1));
  finally
    LRequest.Free;
  end;
end;

procedure TJRPCDuplexTest.TestMalformedResponseFailsCallLocally;
begin
  // A response carrying both "result" and "error" is not a response. The call
  // it names fails - as a client error, since the peer never said -32600.
  FTransport.OnSend :=
    procedure (const AText: string)
    begin
      FTransport.Push(Format(
        '{"jsonrpc":"2.0","id":%s,"result":1,"error":{"code":-1,"message":"m"}}',
        [RequestIdOf(AText)]));
    end;

  try
    FClient.Execute(TJRPCRequestBuilder.New.SetMethod('math/sum'), 2000);
    Assert.Fail('expected EJRPCClientError');
  except
    on E: EJRPCRemoteError do
      Assert.Fail('a response the parser rejected was reported as the peer''s error: ' + E.Message);
    on E: EJRPCClientError do
      Assert.IsTrue(E.Message.Contains('could not be read'), E.Message);
  end;

  // A response is never answered
  Assert.AreEqual(1, FTransport.SentCount);
end;

procedure TJRPCDuplexTest.TestMalformedNotificationIsReportedNotAnswered;
var
  LReported: TEvent;
  LMessage: string;
begin
  LReported := TEvent.Create(nil, True, False, '');
  try
    FClient.OnError :=
      procedure (E: Exception; var AAction: TJRPCErrorAction)
      begin
        LMessage := E.Message;
        LReported.SetEvent;
      end;

    FTransport.Push('{"jsonrpc":"1.0","method":"peer/tell"}');

    Assert.IsTrue(LReported.WaitFor(3000) = wrSignaled, 'the rejection must be reported');
    Assert.IsTrue(LMessage.Contains('notification'), LMessage);
    Assert.AreEqual(0, FTransport.SentCount);
  finally
    FClient.OnError := nil;
    LReported.Free;
  end;
end;

procedure TJRPCDuplexTest.TestRaisingOnErrorKeepsReaderAlive;
begin
  // OnError is called from the reader: an exception it raises must not end
  // the reader and leave every later call waiting.
  FClient.OnError :=
    procedure (E: Exception; var AAction: TJRPCErrorAction)
    begin
      raise Exception.Create('the handler failed too');
    end;
  try
    FTransport.Push('this is not JSON');

    FTransport.OnSend :=
      procedure (const AText: string)
      begin
        FTransport.Push(EchoReply(AText));
      end;

    FClient.ExecuteAs<Integer>(TJRPCRequestBuilder.New.SetMethod('math/sum'), 2000);
  finally
    FClient.OnError := nil;
  end;
end;

procedure TJRPCDuplexTest.TestArrayOfOneStrayAnswerIsReported;
var
  LReported: TEvent;
  LClass: string;
  LMessage: string;
begin
  // An error wrapped in an array of one, for an id nobody waits for: read
  // element by element (it once raised EInvalidCast), and reported as an
  // answer nobody waits for. A reply is never answered.
  LReported := TEvent.Create(nil, True, False, '');
  try
    FClient.OnError :=
      procedure (E: Exception; var AAction: TJRPCErrorAction)
      begin
        LClass := E.ClassName;
        LMessage := E.Message;
        LReported.SetEvent;
      end;

    FTransport.Push('[{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"x"}}]');

    Assert.IsTrue(LReported.WaitFor(3000) = wrSignaled, 'the frame must be reported');
    Assert.AreEqual(EJRPCClientError.ClassName, LClass, LMessage);
    Assert.IsTrue(LMessage.Contains('not pending'), LMessage);
    Assert.AreEqual(0, FTransport.SentCount, 'a reply is never answered');
  finally
    FClient.OnError := nil;
    LReported.Free;
  end;
end;

procedure TJRPCDuplexTest.TestUnparseableFrameIsAnswered;
begin
  FTransport.Push('{"jsonrpc":"2.0","id":1,"method":');

  Assert.IsTrue(WaitUntil(
    function: Boolean
    begin
      Result := FTransport.SentCount > 0;
    end), 'a parse error must be answered');
  Assert.IsTrue(FTransport.SentText(0).Contains('-32700'), FTransport.SentText(0));
  Assert.IsTrue(FTransport.SentText(0).Contains('"id":null'), FTransport.SentText(0));
end;

procedure TJRPCDuplexTest.TestPeerBatchRequestsAreAnswered;
var
  LHandled: Integer;
  LReply: string;
begin
  // The requests in a batch are waiting: each gets a -32600 under its own id,
  // in one array. The notification in it gets nothing, and the request handler
  // sees none of them.
  LHandled := 0;
  FClient.OnRequest :=
    procedure (const ARequest: TJRPCRequest; const AReply: IJRPCReply)
    begin
      TInterlocked.Increment(LHandled);
    end;

  FTransport.Push(
    '[{"jsonrpc":"2.0","id":"a","method":"peer/one"},' +
    '{"jsonrpc":"2.0","method":"peer/tell"},' +
    '{"jsonrpc":"2.0","id":"b","method":"peer/two"}]');

  Assert.IsTrue(WaitUntil(
    function: Boolean
    begin
      Result := FTransport.SentCount > 0;
    end), 'the batch must be answered');
  Assert.AreEqual(1, FTransport.SentCount, 'one reply, an array');

  LReply := FTransport.SentText(0);
  Assert.IsTrue(LReply.StartsWith('['), LReply);
  Assert.IsTrue(LReply.Contains('"id":"a"'), LReply);
  Assert.IsTrue(LReply.Contains('"id":"b"'), LReply);
  Assert.IsTrue(LReply.Contains('-32600'), LReply);
  Assert.AreEqual(0, LHandled);
  FClient.OnRequest := nil;
end;

procedure TJRPCDuplexTest.TestBlankFrameIsIgnored;
var
  LDelivered: TEvent;
  LReported: Integer;
begin
  LReported := 0;
  LDelivered := TEvent.Create(nil, True, False, '');
  try
    FClient.OnError :=
      procedure (E: Exception; var AAction: TJRPCErrorAction)
      begin
        TInterlocked.Increment(LReported);
      end;
    FClient.OnNotification :=
      procedure (const ANotification: TJRPCNotification)
      begin
        LDelivered.SetEvent;
      end;

    FTransport.Push('   ');
    FTransport.Push('{"jsonrpc":"2.0","method":"peer/tell"}');

    Assert.IsTrue(LDelivered.WaitFor(3000) = wrSignaled, 'the notification must arrive');
    Assert.AreEqual(0, FTransport.SentCount);
    Assert.AreEqual(0, LReported);
  finally
    FClient.OnError := nil;
    FClient.OnNotification := nil;
    LDelivered.Free;
  end;
end;

procedure TJRPCDuplexTest.TestPeerCloseFailsPending;
var
  LCall: IJRPCCall<Integer>;
  LMessage: string;
  LClosed: TEvent;
  LInfo: TJRPCCloseInfo;
begin
  LClosed := TEvent.Create(nil, True, False, '');
  try
    FClient.OnClose :=
      procedure (const AInfo: TJRPCCloseInfo)
      begin
        LInfo := AInfo;
        LClosed.SetEvent;
      end;

    LCall := FClient.ExecuteAsync<Integer>(TJRPCRequestBuilder.New.SetMethod('math/slim'));

    // The peer closes its side: the reader sees Receive return False.
    FTransport.PeerClose;

    Assert.IsTrue(LCall.Wait(3000), 'the pending call must fail');
    LMessage := '';
    try
      LCall.Value;
    except
      on E: EJRPCClientError do
        LMessage := E.Message;
    end;
    Assert.IsTrue(LMessage.Contains('peer closed'), LMessage);

    Assert.IsTrue(LClosed.WaitFor(3000) = wrSignaled, 'OnClose must fire');
    Assert.IsTrue(LInfo.Kind = TJRPCCloseKind.Peer);
    Assert.IsFalse(FClient.Active);
  finally
    LClosed.Free;
  end;
end;

procedure TJRPCDuplexTest.TestLocalCloseReportsLocal;
var
  LCount: Integer;
  LInfo: TJRPCCloseInfo;
begin
  LCount := 0;
  FClient.OnClose :=
    procedure (const AInfo: TJRPCCloseInfo)
    begin
      Inc(LCount);
      LInfo := AInfo;
    end;

  FClient.Close;
  FClient.Close;

  Assert.AreEqual(1, LCount, 'OnClose fires once');
  Assert.IsTrue(LInfo.Kind = TJRPCCloseKind.Local);
end;

procedure TJRPCDuplexTest.TestCallAfterCloseRaises;
begin
  FClient.Close;

  try
    FClient.Execute(TJRPCRequestBuilder.New.SetMethod('math/sum'), 1000);
    Assert.Fail('expected EJRPCClientError');
  except
    on E: EJRPCClientError do
      Assert.IsTrue(E.Message.Contains('closed'), E.Message);
  end;
end;

procedure TJRPCDuplexTest.TestFreeAfterCloseFromHandlerWaitsForHandler;
var
  LInHandler: TEvent;
  LHandlerDone: Boolean;
begin
  // A handler closes the client and goes on working; the owner sees it closed
  // and frees it on its own thread. Destroy must wait for the handler.
  LHandlerDone := False;
  LInHandler := TEvent.Create(nil, True, False, '');
  try
    FClient.OnRequest :=
      procedure (const ARequest: TJRPCRequest; const AReply: IJRPCReply)
      begin
        FClient.Close;
        LInHandler.SetEvent;
        Sleep(300);
        LHandlerDone := True;
      end;

    FTransport.Push('{"jsonrpc":"2.0","id":"srv-9","method":"peer/shutdown"}');
    Assert.IsTrue(LInHandler.WaitFor(3000) = wrSignaled, 'the handler must run');
    Assert.IsFalse(FClient.Active);

    FClient.Free;
    FClient := nil;

    Assert.IsTrue(LHandlerDone,
      'Destroy returned while the handler that closed the client was still running');
  finally
    LInHandler.Free;
  end;
end;

procedure TJRPCDuplexTest.TestFreeAfterCloseFromDirectHandlerWaitsForReader;
var
  LInHandler: TEvent;
  LHandlerDone: Boolean;
begin
  // The same with the handler on the reader itself: the transport cannot join
  // its own reader there, and joins it when it is released.
  FClient.Free;
  FTransport := TMemoryMessageTransport.Create;
  FClient := TJRPCClient.Create(nil);
  FClient.DispatchMode := TJRPCDispatchMode.Direct;
  FClient.Transport := FTransport;
  FClient.Open;

  LHandlerDone := False;
  LInHandler := TEvent.Create(nil, True, False, '');
  try
    FClient.OnNotification :=
      procedure (const ANotification: TJRPCNotification)
      begin
        FClient.Close;
        LInHandler.SetEvent;
        Sleep(300);
        LHandlerDone := True;
      end;

    FTransport.Push('{"jsonrpc":"2.0","method":"peer/shutdown"}');
    Assert.IsTrue(LInHandler.WaitFor(3000) = wrSignaled, 'the handler must run');

    FClient.Free;
    FClient := nil;

    Assert.IsTrue(LHandlerDone,
      'Destroy returned while the handler on the reader was still running');
  finally
    LInHandler.Free;
  end;
end;

procedure TJRPCDuplexTest.TestLoopbackCorrelatesOutOfOrder;
const
  CALLS = 20;
var
  LServer: TJRPCServer;
  LClient: TJRPCClient;
  LCalls: TArray<IJRPCCall<Integer>>;
  LIndex: Integer;
begin
  // Every request processed on a task of its own: the answers come back in
  // whatever order the tasks finish, and each must still reach its call.
  LServer := TJRPCServer.Create(nil);
  LClient := TJRPCClient.Create(nil);
  try
    LClient.Transport := TJRPCLoopbackTransport.Create(LServer);

    SetLength(LCalls, CALLS);
    for LIndex := 0 to CALLS - 1 do
      LCalls[LIndex] := LClient.ExecuteAsync<Integer>(
        TJRPCRequestBuilder.New.SetMethod('math/sum')
          .AddNamedParam('a', LIndex).AddNamedParam('b', 1000));

    for LIndex := 0 to CALLS - 1 do
    begin
      Assert.IsTrue(LCalls[LIndex].Wait(5000), Format('call %d must complete', [LIndex]));
      Assert.AreEqual(1000 + LIndex, LCalls[LIndex].Value);
    end;

    Assert.AreEqual(7, LClient.ExecuteAs<Integer>(
      TJRPCRequestBuilder.New.SetMethod('math/sum').AddNamedParam('a', 3).AddNamedParam('b', 4), 5000));
  finally
    LClient.Free;
    LServer.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TJRPCDuplexTest);

end.
