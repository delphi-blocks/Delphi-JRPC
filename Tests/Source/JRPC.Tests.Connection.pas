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
///   TJRPCConnection over an in-memory transport: the peer is a queue the test
///   writes to and reads from, so every case is a full round trip with no
///   socket.
/// </summary>
unit JRPC.Tests.Connection;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Generics.Collections,
  DUnitX.TestFramework,

  JRPC.Core,
  JRPC.Connection;

type
  TTransportSendProc = reference to procedure(const AText: string);

  /// <summary>
  ///   A message transport backed by a queue: Push is the peer sending,
  ///   SentText is what the connection wrote.
  /// </summary>
  TMemoryMessageTransport = class(TInterfacedObject, IJRPCMessageTransport)
  private
    FQueue: TThreadedQueue<string>;
    FClosed: Integer;
    FOnSend: TTransportSendProc;
    FSent: TStringList;
    FLock: TCriticalSection;
  public
    constructor Create;
    destructor Destroy; override;

    function Receive(out AText: string): Boolean;
    procedure Send(const AText: string);
    procedure Close;

    /// <summary>The peer sends a message to the connection.</summary>
    procedure Push(const AText: string);

    function SentCount: Integer;
    function SentText(AIndex: Integer): string;

    /// <summary>Called for every message the connection writes.</summary>
    property OnSend: TTransportSendProc read FOnSend write FOnSend;
  end;

  [TestFixture]
  TJRPCConnectionTest = class
  private
    FTransport: TMemoryMessageTransport;
    FConnection: TJRPCConnection;

    function NewRequest(const AMethod: string): TJRPCRequest;
    class function RequestIdOf(const AText: string): string; static;
    function EchoReply(const AText: string): string;
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;

    [Test] procedure TestCallCorrelatesResponse;
    [Test] procedure TestCallAssignsAnId;
    [Test] procedure TestRemoteErrorRaises;
    [Test] procedure TestTimeoutRaises;
    [Test] procedure TestCallAsyncCanBeCancelled;
    [Test] procedure TestNotificationDelivered;
    [Test] procedure TestInboundRequestAnswered;
    [Test] procedure TestUnhandledRequestIsAnswered;
    [Test] procedure TestPeerCloseFailsPending;
    [Test] procedure TestCallAfterCloseRaises;
    [Test] procedure TestNotifySends;
    [Test] procedure TestUnknownIdIsDropped;
    [Test] procedure TestTwoConcurrentCalls;
    [Test] procedure TestMalformedPeerRequestIsAnsweredNotRouted;
    [Test] procedure TestMalformedResponseFailsCallLocally;
    [Test] procedure TestMalformedNotificationIsReportedNotAnswered;
    [Test] procedure TestRaisingOnErrorKeepsReaderAlive;
    [Test] procedure TestFreeAfterCloseFromHandlerWaitsForReader;
    [Test] procedure TestBatchOfOneFrameIsReported;
    [Test] procedure TestRaisingRequestHandlerIsAnswered;
    [Test] procedure TestUnparseableFrameIsAnswered;
    [Test] procedure TestPeerBatchRequestsAreAnswered;
    [Test] procedure TestBlankFrameIsIgnored;
    [Test] procedure TestDuplicatePendingIdRaisesClientError;
  end;

implementation

uses
  System.JSON, System.Threading, System.StrUtils;

{ TMemoryMessageTransport }

constructor TMemoryMessageTransport.Create;
begin
  inherited Create;
  FQueue := TThreadedQueue<string>.Create(1024, Cardinal($FFFFFFFF), 100);
  FSent := TStringList.Create;
  FLock := TCriticalSection.Create;
  FClosed := 0;
end;

destructor TMemoryMessageTransport.Destroy;
begin
  FLock.Free;
  FSent.Free;
  FQueue.Free;
  inherited;
end;

function TMemoryMessageTransport.Receive(out AText: string): Boolean;
var
  LText: string;
begin
  while FClosed = 0 do
    if FQueue.PopItem(LText) = wrSignaled then
    begin
      AText := LText;
      Exit(True);
    end;

  AText := '';
  Result := False;
end;

procedure TMemoryMessageTransport.Send(const AText: string);
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

procedure TMemoryMessageTransport.Close;
begin
  TInterlocked.Exchange(FClosed, 1);
end;

procedure TMemoryMessageTransport.Push(const AText: string);
begin
  FQueue.PushItem(AText);
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

{ TJRPCConnectionTest }

procedure TJRPCConnectionTest.Setup;
begin
  FTransport := TMemoryMessageTransport.Create;
  FConnection := TJRPCConnection.Create(FTransport);
  FConnection.Open;
end;

procedure TJRPCConnectionTest.TearDown;
begin
  // The connection holds the transport's interface reference: freeing it
  // releases the last one, so FTransport must not be freed here as well.
  FConnection.Free;
  FTransport := nil;
end;

function TJRPCConnectionTest.NewRequest(const AMethod: string): TJRPCRequest;
begin
  Result := TJRPCRequest.Create;
  Result.Method := AMethod;
end;

class function TJRPCConnectionTest.RequestIdOf(const AText: string): string;
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

function TJRPCConnectionTest.EchoReply(const AText: string): string;
var
  LId: string;
begin
  LId := RequestIdOf(AText);
  Result := Format('{"jsonrpc":"2.0","id":%s,"result":%s}', [LId, LId]);
end;

procedure TJRPCConnectionTest.TestCallCorrelatesResponse;
var
  LRequest: TJRPCRequest;
  LResponse: TJRPCResponse;
begin
  FTransport.OnSend :=
    procedure(const AText: string)
    begin
      FTransport.Push(Format('{"jsonrpc":"2.0","id":%s,"result":42}',
        [RequestIdOf(AText)]));
    end;

  LRequest := NewRequest('math/sum');
  try
    LResponse := FConnection.Call(LRequest, 2000);
    try
      Assert.AreEqual('42', LResponse.Result.ToJSON);
      Assert.AreEqual(LRequest.Id.AsString, LResponse.Id.AsString);
    finally
      LResponse.Free;
    end;
  finally
    LRequest.Free;
  end;
end;

procedure TJRPCConnectionTest.TestCallAssignsAnId;
var
  LRequest: TJRPCRequest;
begin
  FTransport.OnSend :=
    procedure(const AText: string)
    begin
      FTransport.Push(Format('{"jsonrpc":"2.0","id":%s,"result":1}',
        [RequestIdOf(AText)]));
    end;

  LRequest := NewRequest('math/sum');
  try
    Assert.IsTrue(LRequest.Id.IsNull, 'the request starts without an id');
    FConnection.Call(LRequest, 2000).Free;
    Assert.IsFalse(LRequest.Id.IsNull, 'the connection gives the request an id');
    Assert.IsTrue(FTransport.SentText(0).Contains(LRequest.Id.AsString),
      FTransport.SentText(0));
  finally
    LRequest.Free;
  end;
end;

procedure TJRPCConnectionTest.TestRemoteErrorRaises;
var
  LRequest: TJRPCRequest;
begin
  FTransport.OnSend :=
    procedure(const AText: string)
    begin
      FTransport.Push(Format(
        '{"jsonrpc":"2.0","id":%s,"error":{"code":-32602,"message":"bad","data":{"detail":7}}}',
        [RequestIdOf(AText)]));
    end;

  LRequest := NewRequest('math/sum');
  try
    try
      FConnection.Call(LRequest, 2000);
      Assert.Fail('expected EJRPCRemoteError');
    except
      on E: EJRPCRemoteError do
      begin
        Assert.AreEqual(-32602, E.Code);
        Assert.AreEqual('bad', E.Message);
        Assert.AreEqual(7, (E.ErrorData as TJSONObject).GetValue<Integer>('detail'));
      end;
    end;
  finally
    LRequest.Free;
  end;
end;

procedure TJRPCConnectionTest.TestTimeoutRaises;
var
  LRequest: TJRPCRequest;
begin
  // No OnSend: the peer never answers.
  LRequest := NewRequest('math/slim');
  try
    try
      FConnection.Call(LRequest, 150);
      Assert.Fail('expected EJRPCClientError');
    except
      on E: EJRPCClientError do
        Assert.IsTrue(E.Message.Contains('150'), E.Message);
    end;
  finally
    LRequest.Free;
  end;
end;

procedure TJRPCConnectionTest.TestCallAsyncCanBeCancelled;
var
  LRequest: TJRPCRequest;
  LCall: IJRPCCall;
  LError: Exception;
begin
  LRequest := NewRequest('math/slim');
  try
    LCall := FConnection.CallAsync(LRequest);
    LCall.Cancel;

    Assert.IsTrue(LCall.Wait(2000), 'cancelling completes the call');
    Assert.IsTrue(LCall.Completed);
    Assert.IsNull(LCall.TakeResponse);

    LError := LCall.TakeError;
    try
      Assert.IsNotNull(LError);
      Assert.IsTrue(LError is EJRPCClientError);
    finally
      LError.Free;
    end;
  finally
    LRequest.Free;
  end;
end;

procedure TJRPCConnectionTest.TestNotificationDelivered;
var
  LReceived: TEvent;
  LMethod: string;
begin
  LMethod := '';
  LReceived := TEvent.Create(nil, True, False, '');
  try
    FConnection.OnNotification :=
      procedure(const ANotification: TJRPCNotification)
      begin
        LMethod := ANotification.Method;
        LReceived.SetEvent;
      end;

    FTransport.Push('{"jsonrpc":"2.0","method":"notifications/progress","params":{"n":1}}');

    Assert.IsTrue(LReceived.WaitFor(3000) = wrSignaled, 'the notification must arrive');
    Assert.AreEqual('notifications/progress', LMethod);
  finally
    LReceived.Free;
  end;
end;

procedure TJRPCConnectionTest.TestInboundRequestAnswered;
var
  LAnswered: TEvent;
begin
  LAnswered := TEvent.Create(nil, True, False, '');
  try
    FConnection.OnRequest :=
      procedure(const ARequest: TJRPCRequest)
      var
        LResponse: TJRPCResponse;
      begin
        LResponse := TJRPCResponse.Create;
        try
          LResponse.Id := ARequest.Id;
          LResponse.Result := TJSONNumber.Create(7);
          FConnection.Respond(LResponse);
        finally
          LResponse.Free;
        end;
        LAnswered.SetEvent;
      end;

    FTransport.Push('{"jsonrpc":"2.0","id":"srv-1","method":"sampling/createMessage","params":{}}');

    Assert.IsTrue(LAnswered.WaitFor(3000) = wrSignaled, 'the request must arrive');
    Assert.AreEqual(1, FTransport.SentCount);
    Assert.IsTrue(FTransport.SentText(0).Contains('"id":"srv-1"'),
      FTransport.SentText(0));
    Assert.IsTrue(FTransport.SentText(0).Contains('"result":7'),
      FTransport.SentText(0));
  finally
    LAnswered.Free;
  end;
end;

procedure TJRPCConnectionTest.TestUnhandledRequestIsAnswered;
var
  LAnswered: TEvent;
begin
  LAnswered := TEvent.Create(nil, True, False, '');
  try
    // No OnRequest handler: the connection answers Method Not Found itself,
    // rather than leaving the peer waiting.
    FTransport.OnSend :=
      procedure(const AText: string)
      begin
        LAnswered.SetEvent;
      end;

    FTransport.Push('{"jsonrpc":"2.0","id":"srv-2","method":"unknown/method"}');

    Assert.IsTrue(LAnswered.WaitFor(3000) = wrSignaled, 'the request must be answered');
    Assert.AreEqual(1, FTransport.SentCount);
    Assert.IsTrue(FTransport.SentText(0).Contains('-32601'),
      FTransport.SentText(0));
    Assert.IsTrue(FTransport.SentText(0).Contains('"id":"srv-2"'),
      FTransport.SentText(0));
  finally
    LAnswered.Free;
  end;
end;

procedure TJRPCConnectionTest.TestPeerCloseFailsPending;
var
  LRequest: TJRPCRequest;
  LCall: IJRPCCall;
  LError: Exception;
  LClosed: TEvent;
begin
  LClosed := TEvent.Create(nil, True, False, '');
  try
    FConnection.OnClose :=
      procedure
      begin
        LClosed.SetEvent;
      end;

    LRequest := NewRequest('math/slim');
    try
      LCall := FConnection.CallAsync(LRequest);

      // The peer closes its side: the reader sees Receive return False.
      FTransport.Close;

      Assert.IsTrue(LCall.Wait(3000), 'the pending call must fail');
      LError := LCall.TakeError;
      try
        Assert.IsNotNull(LError);
        Assert.IsTrue(LError is EJRPCClientError);
        Assert.IsTrue(LError.Message.Contains('peer closed'), LError.Message);
      finally
        LError.Free;
      end;

      Assert.IsTrue(LClosed.WaitFor(3000) = wrSignaled, 'OnClose must fire');
      Assert.IsTrue(FConnection.Closed);
    finally
      LRequest.Free;
    end;
  finally
    LClosed.Free;
  end;
end;

procedure TJRPCConnectionTest.TestCallAfterCloseRaises;
var
  LRequest: TJRPCRequest;
begin
  FConnection.Close;

  LRequest := NewRequest('math/sum');
  try
    try
      FConnection.Call(LRequest, 1000);
      Assert.Fail('expected EJRPCClientError');
    except
      on E: EJRPCClientError do
        Assert.IsTrue(E.Message.Contains('closed'), E.Message);
    end;
  finally
    LRequest.Free;
  end;
end;

procedure TJRPCConnectionTest.TestNotifySends;
var
  LNotification: TJRPCNotification;
begin
  LNotification := TJRPCNotification.Create;
  try
    LNotification.Method := 'notifications/cancelled';
    FConnection.Notify(LNotification);
  finally
    LNotification.Free;
  end;

  Assert.AreEqual(1, FTransport.SentCount);
  Assert.IsTrue(FTransport.SentText(0).Contains('notifications/cancelled'),
    FTransport.SentText(0));
end;

procedure TJRPCConnectionTest.TestUnknownIdIsDropped;
var
  LRequest: TJRPCRequest;
  LResponse: TJRPCResponse;
begin
  FTransport.OnSend :=
    procedure(const AText: string)
    begin
      FTransport.Push(Format('{"jsonrpc":"2.0","id":%s,"result":1}',
        [RequestIdOf(AText)]));
    end;

  // An answer nobody asked for, then a normal call: the stray one must not
  // corrupt the pending map.
  FTransport.Push('{"jsonrpc":"2.0","id":999999,"result":1}');

  LRequest := NewRequest('math/sum');
  try
    LResponse := FConnection.Call(LRequest, 2000);
    try
      Assert.AreEqual('1', LResponse.Result.ToJSON);
    finally
      LResponse.Free;
    end;
  finally
    LRequest.Free;
  end;
end;

procedure TJRPCConnectionTest.TestTwoConcurrentCalls;
var
  LThread1, LThread2: TThread;
  LId1, LId2, LResult1, LResult2: string;
begin
  LId1 := '';
  LId2 := '';
  LResult1 := '';
  LResult2 := '';

  FTransport.OnSend :=
    procedure(const AText: string)
    begin
      FTransport.Push(EchoReply(AText));
    end;

  LThread1 := TThread.CreateAnonymousThread(
    procedure
    var
      LRequest: TJRPCRequest;
      LResponse: TJRPCResponse;
    begin
      LRequest := NewRequest('echo/one');
      try
        LResponse := FConnection.Call(LRequest, 5000);
        try
          LId1 := LResponse.Id.AsString;
          LResult1 := LResponse.Result.ToJSON;
        finally
          LResponse.Free;
        end;
      finally
        LRequest.Free;
      end;
    end);
  LThread1.FreeOnTerminate := False;

  LThread2 := TThread.CreateAnonymousThread(
    procedure
    var
      LRequest: TJRPCRequest;
      LResponse: TJRPCResponse;
    begin
      LRequest := NewRequest('echo/two');
      try
        LResponse := FConnection.Call(LRequest, 5000);
        try
          LId2 := LResponse.Id.AsString;
          LResult2 := LResponse.Result.ToJSON;
        finally
          LResponse.Free;
        end;
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
  Assert.AreEqual(LId1, LResult1, 'the first call got the other answer');
  Assert.AreEqual(LId2, LResult2, 'the second call got the other answer');
end;

procedure TJRPCConnectionTest.TestMalformedPeerRequestIsAnsweredNotRouted;
var
  LRequest: TJRPCRequest;
  LResponse: TJRPCResponse;
  LId: string;
begin
  // The peer sends a request it got wrong ("jsonrpc":"1.0") under the same id
  // as our pending call - ids collide easily, both sides count from 1. The
  // parser's -32600 is an answer the peer is owed, not an error the peer sent:
  // it must not complete our call, and it must go back to the peer.
  FTransport.OnSend :=
    procedure(const AText: string)
    begin
      // Only our own request triggers the exchange, not the reply we send
      if not AText.Contains('"method"') then
        Exit;

      LId := RequestIdOf(AText);
      FTransport.Push(Format('{"jsonrpc":"1.0","id":%s,"method":"peer/ask"}', [LId]));
      FTransport.Push(EchoReply(AText));
    end;

  LRequest := NewRequest('math/sum');
  try
    LResponse := FConnection.Call(LRequest, 2000);
    try
      Assert.AreEqual(LRequest.Id.AsString, LResponse.Result.ToJSON,
        'the call completes with its real answer');
    finally
      LResponse.Free;
    end;

    // Our request, then the rejection of the peer's
    Assert.AreEqual(2, FTransport.SentCount);
    Assert.IsTrue(FTransport.SentText(1).Contains('-32600'), FTransport.SentText(1));
    Assert.IsTrue(FTransport.SentText(1).Contains('"id":' + LId), FTransport.SentText(1));
  finally
    LRequest.Free;
  end;
end;

procedure TJRPCConnectionTest.TestMalformedResponseFailsCallLocally;
var
  LRequest: TJRPCRequest;
begin
  // A response carrying both "result" and "error" is not a response. The call
  // it names fails - as a client error, since the peer never said -32600.
  FTransport.OnSend :=
    procedure(const AText: string)
    begin
      FTransport.Push(Format(
        '{"jsonrpc":"2.0","id":%s,"result":1,"error":{"code":-1,"message":"m"}}',
        [RequestIdOf(AText)]));
    end;

  LRequest := NewRequest('math/sum');
  try
    try
      FConnection.Call(LRequest, 2000).Free;
      Assert.Fail('expected EJRPCClientError');
    except
      on E: EJRPCRemoteError do
        Assert.Fail('a response the parser rejected was reported as the peer''s error: ' + E.Message);
      on E: EJRPCClientError do
        Assert.IsTrue(E.Message.Contains('could not be read'), E.Message);
    end;

    // A response is never answered
    Assert.AreEqual(1, FTransport.SentCount);
  finally
    LRequest.Free;
  end;
end;

procedure TJRPCConnectionTest.TestMalformedNotificationIsReportedNotAnswered;
var
  LReported: TEvent;
  LMessage: string;
begin
  LReported := TEvent.Create(nil, True, False, '');
  try
    FConnection.OnError :=
      procedure(E: Exception)
      begin
        LMessage := E.Message;
        LReported.SetEvent;
      end;

    FTransport.Push('{"jsonrpc":"1.0","method":"peer/tell"}');

    Assert.IsTrue(LReported.WaitFor(3000) = wrSignaled, 'the rejection must be reported');
    Assert.IsTrue(LMessage.Contains('notification'), LMessage);
    // Notifications are never answered, malformed or not
    Assert.AreEqual(0, FTransport.SentCount);
  finally
    FConnection.OnError := nil;
    LReported.Free;
  end;
end;

procedure TJRPCConnectionTest.TestRaisingOnErrorKeepsReaderAlive;
var
  LRequest: TJRPCRequest;
  LResponse: TJRPCResponse;
begin
  // OnError is called from the reader's own except blocks: an exception it
  // raises used to escape the loop and end the reader silently, leaving every
  // later call to wait for an answer nobody would read.
  FConnection.OnError :=
    procedure(E: Exception)
    begin
      raise Exception.Create('the handler failed too');
    end;
  try
    FTransport.Push('this is not JSON');

    FTransport.OnSend :=
      procedure(const AText: string)
      begin
        FTransport.Push(EchoReply(AText));
      end;

    LRequest := NewRequest('math/sum');
    try
      LResponse := FConnection.Call(LRequest, 2000);
      try
        Assert.AreEqual(LRequest.Id.AsString, LResponse.Result.ToJSON);
      finally
        LResponse.Free;
      end;
    finally
      LRequest.Free;
    end;
  finally
    FConnection.OnError := nil;
  end;
end;

procedure TJRPCConnectionTest.TestFreeAfterCloseFromHandlerWaitsForReader;
var
  LInHandler: TEvent;
  LHandlerDone: Boolean;
begin
  // A handler closes the connection and goes on working; the owner sees it
  // closed and frees it on its own thread. Destroy must wait for the handler
  // to return and the reader to end, not free what the reader still uses.
  LHandlerDone := False;
  LInHandler := TEvent.Create(nil, True, False, '');
  try
    FConnection.OnRequest :=
      procedure(const ARequest: TJRPCRequest)
      begin
        FConnection.Close;
        LInHandler.SetEvent;
        Sleep(300);
        LHandlerDone := True;
      end;

    FTransport.Push('{"jsonrpc":"2.0","id":"srv-9","method":"peer/shutdown"}');
    Assert.IsTrue(LInHandler.WaitFor(3000) = wrSignaled, 'the handler must run');
    Assert.IsTrue(FConnection.Closed);

    FConnection.Free;
    FConnection := nil;

    Assert.IsTrue(LHandlerDone,
      'Destroy returned while the handler that closed the connection was still running');
  finally
    LInHandler.Free;
  end;
end;

procedure TJRPCConnectionTest.TestBatchOfOneFrameIsReported;
var
  LReported: TEvent;
  LClass: string;
  LMessage: string;
begin
  // An error reply wrapped in an array of one: read as a single message it
  // reached the object cast and raised EInvalidCast. It is a batch, which this
  // endpoint reports rather than fans out - and says so.
  LReported := TEvent.Create(nil, True, False, '');
  try
    FConnection.OnError :=
      procedure(E: Exception)
      begin
        LClass := E.ClassName;
        LMessage := E.Message;
        LReported.SetEvent;
      end;

    FTransport.Push('[{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"x"}}]');

    Assert.IsTrue(LReported.WaitFor(3000) = wrSignaled, 'the frame must be reported');
    Assert.AreEqual(EJRPCClientError.ClassName, LClass, LMessage);
    Assert.IsTrue(LMessage.Contains('batch'), LMessage);
    Assert.AreEqual(0, FTransport.SentCount, 'a reply is never answered');
  finally
    FConnection.OnError := nil;
    LReported.Free;
  end;
end;

procedure TJRPCConnectionTest.TestRaisingRequestHandlerIsAnswered;
var
  LAnswered: TEvent;
  LReported: Integer;
  LGeneric, LTyped: string;
  LIndex: Integer;
begin
  // A handler that raises used to leave the peer waiting for an answer that
  // never came. It is answered the way TJRPCServer answers a method that
  // raised: a protocol exception keeps its code and message, anything else is
  // -32603 with the details kept off the wire. Both are still reported.
  LReported := 0;
  LAnswered := TEvent.Create(nil, True, False, '');
  try
    FConnection.OnError :=
      procedure(E: Exception)
      begin
        TInterlocked.Increment(LReported);
      end;

    FConnection.OnRequest :=
      procedure(const ARequest: TJRPCRequest)
      begin
        if ARequest.Method = 'peer/typed' then
          raise EJRPCInvalidParamsError.Create('the x argument is missing');
        raise Exception.Create('secret internal detail');
      end;

    FTransport.OnSend :=
      procedure(const AText: string)
      begin
        if FTransport.SentCount >= 2 then
          LAnswered.SetEvent;
      end;

    FTransport.Push('{"jsonrpc":"2.0","id":"srv-5","method":"peer/generic"}');
    FTransport.Push('{"jsonrpc":"2.0","id":"srv-6","method":"peer/typed"}');

    Assert.IsTrue(LAnswered.WaitFor(3000) = wrSignaled, 'both requests must be answered');

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

    // The answer goes out before the failure is reported: let the second
    // report land.
    LIndex := 0;
    while (LReported < 2) and (LIndex < 100) do
    begin
      Sleep(20);
      Inc(LIndex);
    end;
    Assert.AreEqual(2, LReported, 'both failures are still reported');
  finally
    FConnection.OnError := nil;
    FConnection.OnRequest := nil;
    FTransport.OnSend := nil;
    LAnswered.Free;
  end;
end;

procedure TJRPCConnectionTest.TestUnparseableFrameIsAnswered;
var
  LAnswered: TEvent;
begin
  LAnswered := TEvent.Create(nil, True, False, '');
  try
    FTransport.OnSend :=
      procedure(const AText: string)
      begin
        LAnswered.SetEvent;
      end;

    FTransport.Push('{"jsonrpc":"2.0","id":1,"method":');

    Assert.IsTrue(LAnswered.WaitFor(3000) = wrSignaled, 'a parse error must be answered');
    Assert.IsTrue(FTransport.SentText(0).Contains('-32700'), FTransport.SentText(0));
    Assert.IsTrue(FTransport.SentText(0).Contains('"id":null'), FTransport.SentText(0));
  finally
    FTransport.OnSend := nil;
    LAnswered.Free;
  end;
end;

procedure TJRPCConnectionTest.TestPeerBatchRequestsAreAnswered;
var
  LAnswered: TEvent;
  LHandled: Integer;
  LReply: string;
begin
  // The connection does not fan a batch out, but the requests in it are
  // waiting: each gets a -32600 under its own id, in one array. The
  // notification in it gets nothing, and the handler sees none of them.
  LHandled := 0;
  LAnswered := TEvent.Create(nil, True, False, '');
  try
    FConnection.OnRequest :=
      procedure(const ARequest: TJRPCRequest)
      begin
        TInterlocked.Increment(LHandled);
      end;

    FTransport.OnSend :=
      procedure(const AText: string)
      begin
        LAnswered.SetEvent;
      end;

    FTransport.Push(
      '[{"jsonrpc":"2.0","id":"a","method":"peer/one"},' +
      '{"jsonrpc":"2.0","method":"peer/tell"},' +
      '{"jsonrpc":"2.0","id":"b","method":"peer/two"}]');

    Assert.IsTrue(LAnswered.WaitFor(3000) = wrSignaled, 'the batch must be answered');
    Assert.AreEqual(1, FTransport.SentCount, 'one reply, an array');

    LReply := FTransport.SentText(0);
    Assert.IsTrue(LReply.StartsWith('['), LReply);
    Assert.IsTrue(LReply.Contains('"id":"a"'), LReply);
    Assert.IsTrue(LReply.Contains('"id":"b"'), LReply);
    Assert.IsTrue(LReply.Contains('-32600'), LReply);
    Assert.AreEqual(0, LHandled);
  finally
    FConnection.OnRequest := nil;
    FTransport.OnSend := nil;
    LAnswered.Free;
  end;
end;

procedure TJRPCConnectionTest.TestBlankFrameIsIgnored;
var
  LDelivered: TEvent;
  LReported: Integer;
begin
  // A stray blank line is not a parse error to answer: nothing is sent and
  // nothing reported. The notification after it is the sync point.
  LReported := 0;
  LDelivered := TEvent.Create(nil, True, False, '');
  try
    FConnection.OnError :=
      procedure(E: Exception)
      begin
        TInterlocked.Increment(LReported);
      end;
    FConnection.OnNotification :=
      procedure(const ANotification: TJRPCNotification)
      begin
        LDelivered.SetEvent;
      end;

    FTransport.Push('   ');
    FTransport.Push('{"jsonrpc":"2.0","method":"peer/tell"}');

    Assert.IsTrue(LDelivered.WaitFor(3000) = wrSignaled, 'the notification must arrive');
    Assert.AreEqual(0, FTransport.SentCount);
    Assert.AreEqual(0, LReported);
  finally
    FConnection.OnError := nil;
    FConnection.OnNotification := nil;
    LDelivered.Free;
  end;
end;

procedure TJRPCConnectionTest.TestDuplicatePendingIdRaisesClientError;
var
  LFirst, LSecond, LThird: TJRPCRequest;
  LCall: IJRPCCall;
  LError: TClass;
  LMessage: string;
begin
  LFirst := NewRequest('math/slow');
  LSecond := NewRequest('math/other');
  LThird := NewRequest('math/third');
  try
    // No OnSend: the first call stays pending
    LFirst.Id := 5;
    LCall := FConnection.CallAsync(LFirst);

    // The same id again used to raise EListError from the dictionary - not
    // the EJRPCClientError the connection raises for every other refusal.
    LSecond.Id := 5;
    LError := nil;
    try
      FConnection.CallAsync(LSecond);
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
    FConnection.CallAsync(LThird);
    Assert.AreEqual(2, FTransport.SentCount);

    // The first call is untouched and still gets its answer
    Assert.IsFalse(LCall.Completed);
    FTransport.Push('{"jsonrpc":"2.0","id":5,"result":1}');
    Assert.IsTrue(LCall.Wait(2000), 'the pending call must still be answered');
    Assert.IsNull(LCall.TakeError);
  finally
    LThird.Free;
    LSecond.Free;
    LFirst.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TJRPCConnectionTest);

end.
