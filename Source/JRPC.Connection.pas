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
unit JRPC.Connection;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Generics.Collections,

  JRPC.Core;

type
  /// <summary>
  ///   A bidirectional JSON-RPC transport: one ordered stream that carries
  ///   replies, notifications and peer requests.
  /// </summary>
  /// <remarks>
  ///   The transport owns the framing (a line ending, a pipe message, a
  ///   WebSocket frame) and hands over one complete JSON document at a time.
  ///   The connection owns the reader thread, so an implementation only has to
  ///   block in Receive and write in Send.
  ///
  ///   Close must unblock a pending Receive and be idempotent; it is called
  ///   from another thread than the one reading when the connection is closed.
  /// </remarks>
  IJRPCMessageTransport = interface
  ['{E1F2A3B4-C5D6-4E7F-8A9B-0C1D2E3F4A5B}']
    /// <summary>
    ///   Blocks until the next message arrives, storing it in AText and
    ///   returning True. False ends the connection: the peer closed the
    ///   stream, or Close was called.
    /// </summary>
    function Receive(out AText: string): Boolean;

    /// <summary>
    ///   Writes one complete JSON document. Called from any thread; the
    ///   connection serializes the writes.
    /// </summary>
    procedure Send(const AText: string);

    /// <summary>
    ///   Unblocks a pending Receive. Idempotent.
    /// </summary>
    procedure Close;
  end;

  /// <summary>
  ///   Called with a notification that arrived on the connection.
  /// </summary>
  /// <remarks>
  ///   Runs on the reader thread and the object is freed as soon as the
  ///   callback returns: Clone it to keep it, and do not call TJRPCConnection.Call
  ///   from here - the thread that would read the answer is the one waiting.
  /// </remarks>
  TJRPCNotifyProc = reference to procedure(const ANotification: TJRPCNotification);

  /// <summary>
  ///   Called with a request the peer sent, for the application to answer with
  ///   TJRPCConnection.Respond.
  /// </summary>
  /// <remarks>
  ///   Runs on the reader thread; the object is freed when the callback
  ///   returns, so Clone it if the answer is produced later. Never call
  ///   TJRPCConnection.Call from here.
  /// </remarks>
  TJRPCRequestProc = reference to procedure(const ARequest: TJRPCRequest);

  /// <summary>
  ///   Called once when the connection ends, whether it was closed locally or
  ///   by the peer.
  /// </summary>
  TJRPCClosedProc = reference to procedure;

  /// <summary>
  ///   Reports a failure of the connection itself (an unreadable frame, a
  ///   handler that raised, an answer no call was waiting for).
  /// </summary>
  /// <remarks>
  ///   It observes, it does not handle: the connection carries on.
  /// </remarks>
  TJRPCConnectionErrorProc = reference to procedure(E: Exception);

  /// <summary>
  ///   One call in flight on a connection.
  /// </summary>
  /// <remarks>
  ///   The connection holds the call while it is pending, so the handle stays
  ///   valid even if the caller drops it. Wait blocks, Completed does not, and
  ///   Take receives ownership of what the call produced - exactly once.
  /// </remarks>
  IJRPCCall = interface
  ['{F2A3B4C5-D6E7-4F80-9BAC-1D2E3F4A5B6C}']
    /// <summary>
    ///   Waits for the call to complete. False on timeout; the call then
    ///   remains pending until Cancel or the connection closes.
    /// </summary>
    function Wait(ATimeout: Cardinal): Boolean; overload;

    /// <summary>
    ///   Waits for the call to complete, with no timeout.
    /// </summary>
    function Wait: Boolean; overload;

    /// <summary>
    ///   True once the call has completed, for whatever reason.
    /// </summary>
    function Completed: Boolean;

    /// <summary>
    ///   Removes the call from the connection and completes it with an
    ///   EJRPCClientError. Idempotent; a completed call is left alone.
    /// </summary>
    procedure Cancel;

    /// <summary>
    ///   The response, transferred to the caller; nil when the call failed or
    ///   was cancelled. Only the first call returns it.
    /// </summary>
    function TakeResponse: TJRPCResponse;

    /// <summary>
    ///   The failure, transferred to the caller; nil when the call succeeded.
    ///   Raise it, or free it. Only the first call returns it.
    /// </summary>
    function TakeError: Exception;
  end;

  /// <summary>
  ///   The connection's own view of a call: what only it may do to one.
  /// </summary>
  IJRPCOwnedCall = interface(IJRPCCall)
  ['{A3B4C5D6-E7F8-4A91-8CBD-2E3F4A5B6C7D}']
    /// <summary>The key the call is filed under in the pending map.</summary>
    function Key: string;

    /// <summary>
    ///   Completes the call, taking ownership of AResponse and AError. False
    ///   when it was already completed (cancelled), in which case the caller
    ///   still owns both.
    /// </summary>
    function Complete(AResponse: TJRPCResponse; AError: Exception): Boolean;

    /// <summary>
    ///   Forgets the connection, so a handle that outlives it cannot call
    ///   back into a freed object.
    /// </summary>
    procedure Detach;
  end;

  /// <summary>
  ///   A JSON-RPC endpoint over a bidirectional stream: calls by id,
  ///   notifications, and requests the peer sends.
  /// </summary>
  /// <remarks>
  ///   Where TJRPCClient is one request and one answer, the connection keeps a
  ///   map of calls in flight: responses are matched by id as they arrive,
  ///   notifications go to OnNotification and peer requests to OnRequest.
  ///   Reads happen on a thread of the connection's own, writes are
  ///   serialized.
  ///
  ///   Handlers run on the reader thread. A handler that calls Call - or any
  ///   synchronous wait - deadlocks, because the response it waits for is on
  ///   the thread it is blocking; use CallAsync, a queue, or the call handle.
  ///
  ///   One message per frame: a batch answer is reported to OnError rather
  ///   than fanned out, and the calls it answers time out. Send batches one
  ///   call at a time on this endpoint. A batch the peer sends is reported
  ///   too, and each request in it is answered -32600 under its own id.
  ///
  ///   Whatever the peer is owed is answered as TJRPCServer would answer it:
  ///   -32700 with a null id for a frame that is not JSON, -32600 for JSON
  ///   that is no message, and an error under the request's id when OnRequest
  ///   raises (its own code for an EJRPCException, -32603 otherwise). Blank
  ///   frames are skipped.
  /// </remarks>
  TJRPCConnection = class
  private
    FTransport: IJRPCMessageTransport;
    FLock: TCriticalSection;
    FSendLock: TCriticalSection;
    FPending: TDictionary<string, IJRPCOwnedCall>;
    FReader: TThread;
    FOpen: Boolean;
    FClosed: Boolean;
    FCloseNotified: Boolean;
    FOnNotification: TJRPCNotifyProc;
    FOnRequest: TJRPCRequestProc;
    FOnError: TJRPCConnectionErrorProc;
    FOnClose: TJRPCClosedProc;

    procedure CheckOpen;
    procedure ReaderLoop;
    procedure DispatchMessage(const AText: string);
    procedure DispatchNotification(ANotification: TJRPCNotification);
    procedure DispatchRequest(ARequest: TJRPCRequest);
    procedure RejectPeerMessage(AError: TJRPCError);
    procedure RejectPeerBatch(AMessages: TJRPCMessages);
    procedure AnswerPeer(E: Exception; const AId: TJRPCID);
    procedure FailInvalidResponse(AError: TJRPCError);
    procedure CompletePending(const AKey: string; AResponse: TJRPCResponse; AError: Exception);
    procedure FailPending(const AMessage: string);
    procedure ReleaseReader;
    procedure Forget(const AKey: string);
    procedure NotifyClosed;
    procedure CloseTransport;
    procedure SendText(const AText: string);
    procedure ReportError(E: Exception);
    procedure FinalizeReader(AReader: TThread);

    class function KeyOf(const AId: TJRPCID): string; static;
  public
    /// <summary>
    ///   Takes the transport, which must not be nil. Call Open to start
    ///   reading.
    /// </summary>
    constructor Create(const ATransport: IJRPCMessageTransport);
    destructor Destroy; override;

    /// <summary>
    ///   Starts the reader thread. Idempotent; a connection that was closed
    ///   cannot be reopened.
    /// </summary>
    procedure Open;

    /// <summary>
    ///   Ends the connection: pending calls fail with EJRPCClientError, the
    ///   transport is closed and the reader is joined. Idempotent.
    /// </summary>
    /// <remarks>
    ///   Called from a handler, it cannot join the thread it runs on: the
    ///   reader ends once the handler returns, and the connection keeps it
    ///   until Destroy, which waits for it. Freeing the connection on another
    ///   thread right after such a Close is therefore safe.
    /// </remarks>
    procedure Close;

    /// <summary>
    ///   Sends ARequest and waits for its answer.
    /// </summary>
    /// <param name="ATimeout">
    ///   Milliseconds to wait; 0 means no timeout. On timeout the call is
    ///   cancelled and EJRPCClientError is raised.
    /// </param>
    /// <remarks>
    ///   The response belongs to the caller. An error answer raises
    ///   EJRPCRemoteError.
    /// </remarks>
    function Call(ARequest: TJRPCRequest; ATimeout: Cardinal = 0): TJRPCResponse;

    /// <summary>
    ///   Sends ARequest and returns a handle to wait on, without blocking.
    /// </summary>
    /// <remarks>
    ///   A request with no id is given one. An id that is already pending
    ///   raises EJRPCClientError and sends nothing.
    /// </remarks>
    function CallAsync(ARequest: TJRPCRequest): IJRPCCall;

    /// <summary>
    ///   Sends a notification; the peer answers nothing.
    /// </summary>
    procedure Notify(ANotification: TJRPCNotification);

    /// <summary>
    ///   Sends the answer to a request received in OnRequest. The response
    ///   must carry that request's id.
    /// </summary>
    procedure Respond(AResponse: TJRPCResponse);

    /// <summary>
    ///   True once the connection has ended, locally or by the peer.
    /// </summary>
    function Closed: Boolean;

    /// <summary>
    ///   Notifications the peer sends. Runs on the reader thread.
    /// </summary>
    property OnNotification: TJRPCNotifyProc read FOnNotification write FOnNotification;

    /// <summary>
    ///   Requests the peer sends, to be answered with Respond. Runs on the
    ///   reader thread.
    /// </summary>
    property OnRequest: TJRPCRequestProc read FOnRequest write FOnRequest;

    /// <summary>
    ///   A failure of the connection itself - an unreadable frame, a handler
    ///   that raised, an answer no call was waiting for.
    /// </summary>
    /// <remarks>
    ///   An exception this handler raises is logged and dropped: it cannot
    ///   stop the reader or make Close and Destroy raise.
    /// </remarks>
    property OnError: TJRPCConnectionErrorProc read FOnError write FOnError;

    /// <summary>
    ///   Called once when the connection ends.
    /// </summary>
    property OnClose: TJRPCClosedProc read FOnClose write FOnClose;
  end;

implementation

uses
  System.JSON,

  Logify;

type
  /// <summary>
  ///   The reader: one loop, on a thread of its own, until the transport says
  ///   the stream is over.
  /// </summary>
  TJRPCConnectionReader = class(TThread)
  private
    FConnection: TJRPCConnection;
  protected
    procedure Execute; override;
  public
    constructor Create(AConnection: TJRPCConnection);
  end;

  /// <summary>
  ///   The call object behind an IJRPCCall.
  /// </summary>
  TJRPCConnectionCall = class(TInterfacedObject, IJRPCCall, IJRPCOwnedCall)
  private
    FConnection: TJRPCConnection;
    FKey: string;
    FLock: TCriticalSection;
    FDone: TEvent;
    FCompleted: Boolean;
    FResponse: TJRPCResponse;
    FError: Exception;
  public
    constructor Create(AConnection: TJRPCConnection; const AKey: string);
    destructor Destroy; override;

    // IJRPCCall
    function Wait(ATimeout: Cardinal): Boolean; overload;
    function Wait: Boolean; overload;
    function Completed: Boolean;
    procedure Cancel;
    function TakeResponse: TJRPCResponse;
    function TakeError: Exception;

    // IJRPCOwnedCall
    function Key: string;
    function Complete(AResponse: TJRPCResponse; AError: Exception): Boolean;
    procedure Detach;
  end;

{ TJRPCConnectionReader }

constructor TJRPCConnectionReader.Create(AConnection: TJRPCConnection);
begin
  inherited Create(True);
  FConnection := AConnection;
  FreeOnTerminate := False;
end;

procedure TJRPCConnectionReader.Execute;
begin
  FConnection.ReaderLoop;
end;

{ TJRPCConnectionCall }

constructor TJRPCConnectionCall.Create(AConnection: TJRPCConnection;
  const AKey: string);
begin
  inherited Create;
  FConnection := AConnection;
  FKey := AKey;
  FLock := TCriticalSection.Create;
  FDone := TEvent.Create(nil, True, False, '');
end;

destructor TJRPCConnectionCall.Destroy;
begin
  FResponse.Free;
  FError.Free;
  FDone.Free;
  FLock.Free;
  inherited;
end;

function TJRPCConnectionCall.Wait(ATimeout: Cardinal): Boolean;
begin
  Result := FDone.WaitFor(ATimeout) = wrSignaled;
end;

function TJRPCConnectionCall.Wait: Boolean;
begin
  Result := Wait($FFFFFFFF);
end;

function TJRPCConnectionCall.Completed: Boolean;
begin
  Result := FDone.WaitFor(0) = wrSignaled;
end;

function TJRPCConnectionCall.Complete(AResponse: TJRPCResponse;
  AError: Exception): Boolean;
begin
  FLock.Enter;
  try
    Result := not FCompleted;
    if Result then
    begin
      FCompleted := True;
      FResponse := AResponse;
      FError := AError;
    end;
  finally
    FLock.Leave;
  end;

  if Result then
    FDone.SetEvent;
end;

procedure TJRPCConnectionCall.Cancel;
var
  LError: Exception;
  LConnection: TJRPCConnection;
begin
  LError := EJRPCClientError.Create(SJRPCConnectionCallCancelled);
  if not Complete(nil, LError) then
  begin
    LError.Free;
    Exit;
  end;

  // The call is no longer pending; forget the connection under the same lock
  // Detach uses, so a close that already detached it is not called twice.
  // Forget runs under that lock too: a Close racing with this one detaches
  // the call before the connection is freed, and Detach waits here, so the
  // connection cannot go away between reading it and calling it. The order
  // is safe - the connection never holds its own lock while taking a call's.
  FLock.Enter;
  try
    LConnection := FConnection;
    FConnection := nil;

    if Assigned(LConnection) then
      LConnection.Forget(FKey);
  finally
    FLock.Leave;
  end;
end;

function TJRPCConnectionCall.TakeResponse: TJRPCResponse;
begin
  FLock.Enter;
  try
    Result := FResponse;
    FResponse := nil;
  finally
    FLock.Leave;
  end;
end;

function TJRPCConnectionCall.TakeError: Exception;
begin
  FLock.Enter;
  try
    Result := FError;
    FError := nil;
  finally
    FLock.Leave;
  end;
end;

function TJRPCConnectionCall.Key: string;
begin
  Result := FKey;
end;

procedure TJRPCConnectionCall.Detach;
begin
  FLock.Enter;
  try
    FConnection := nil;
  finally
    FLock.Leave;
  end;
end;

{ TJRPCConnection }

constructor TJRPCConnection.Create(const ATransport: IJRPCMessageTransport);
begin
  inherited Create;
  if not Assigned(ATransport) then
    raise EJRPCClientError.Create(SJRPCConnectionNoTransport);

  FTransport := ATransport;
  FLock := TCriticalSection.Create;
  FSendLock := TCriticalSection.Create;
  FPending := TDictionary<string, IJRPCOwnedCall>.Create;
  FOpen := False;
  FClosed := False;
  FCloseNotified := False;
end;

destructor TJRPCConnection.Destroy;
begin
  Close;
  ReleaseReader;
  FPending.Free;
  FSendLock.Free;
  FLock.Free;
  inherited;
end;

procedure TJRPCConnection.CheckOpen;
begin
  if FClosed then
    raise EJRPCClientError.Create(SJRPCConnectionClosed);

  if not FOpen then
    raise EJRPCClientError.Create(SJRPCConnectionNotOpen);
end;

procedure TJRPCConnection.Open;
begin
  FLock.Enter;
  try
    if FOpen then
      Exit;

    if FClosed then
      raise EJRPCClientError.Create(SJRPCConnectionClosed);

    FOpen := True;
    FReader := TJRPCConnectionReader.Create(Self);
    // Started under the lock: a Close racing with Open must never take a
    // thread that was created but never started, or WaitFor would hang on it.
    FReader.Start;
  finally
    FLock.Leave;
  end;
end;

procedure TJRPCConnection.Close;
var
  LReader: TThread;
  LWasOpen: Boolean;
begin
  FLock.Enter;
  try
    LWasOpen := FOpen;
    FOpen := False;
    FClosed := True;

    // Only a Close on another thread can join the reader; it takes the
    // reference so that no second Close joins it again. A Close from a
    // handler, on the reader itself, leaves it where it is: the connection
    // still owns the thread, and Destroy joins it once the handler has
    // returned and the loop has ended.
    LReader := FReader;
    if Assigned(LReader) and (LReader <> TThread.CurrentThread) then
      FReader := nil
    else
      LReader := nil;
  finally
    FLock.Leave;
  end;

  if LWasOpen then
    FailPending(SJRPCConnectionClosed);

  CloseTransport;
  FinalizeReader(LReader);

  if LWasOpen then
    NotifyClosed;
end;

procedure TJRPCConnection.CloseTransport;
begin
  try
    FTransport.Close;
  except
    on E: Exception do
      // The transport is on its way out either way; the failure is reported,
      // not raised, so Close stays safe to call from a destructor.
      ReportError(E);
  end;
end;

procedure TJRPCConnection.FinalizeReader(AReader: TThread);
begin
  if not Assigned(AReader) then
    Exit;

  AReader.WaitFor;
  AReader.Free;
end;

procedure TJRPCConnection.ReleaseReader;
var
  LReader: TThread;
begin
  FLock.Enter;
  try
    LReader := FReader;
    FReader := nil;
  finally
    FLock.Leave;
  end;

  if not Assigned(LReader) then
    Exit;

  if LReader = TThread.CurrentThread then
  begin
    // Destroyed from a handler (OnClose, typically): the thread cannot wait
    // for itself. It ends once the handler returns and frees itself; the
    // handler must not touch the connection after freeing it, and the loop
    // does not either once it has been closed.
    LReader.FreeOnTerminate := True;
    Exit;
  end;

  // Still running only when Close came from a handler: wait for the handler
  // to return and the loop to end, so nothing below frees what it uses.
  FinalizeReader(LReader);
end;

function TJRPCConnection.Closed: Boolean;
begin
  Result := FClosed;
end;

function TJRPCConnection.Call(ARequest: TJRPCRequest; ATimeout: Cardinal): TJRPCResponse;
var
  LCall: IJRPCCall;
  LError: Exception;
begin
  LCall := CallAsync(ARequest);

  if ATimeout = 0 then
    LCall.Wait
  else if not LCall.Wait(ATimeout) then
  begin
    LCall.Cancel;
    raise EJRPCClientError.CreateFmt(SJRPCConnectionTimeout, [ATimeout]);
  end;

  LError := LCall.TakeError;
  if Assigned(LError) then
    raise LError;

  Result := LCall.TakeResponse;
  if not Assigned(Result) then
    raise EJRPCClientError.Create(SJRPCConnectionNoResponse);
end;

function TJRPCConnection.CallAsync(ARequest: TJRPCRequest): IJRPCCall;
var
  LCall: TJRPCConnectionCall;
  LOwned: IJRPCOwnedCall;
  LPayload: string;
begin
  if ARequest.Id.IsNull then
    ARequest.Id := TJRPCID.NewId;

  LCall := TJRPCConnectionCall.Create(Self, KeyOf(ARequest.Id));
  LOwned := LCall;
  LPayload := ARequest.ToJson;

  FLock.Enter;
  try
    if FClosed then
      raise EJRPCClientError.Create(SJRPCConnectionClosed);
    if not FOpen then
      raise EJRPCClientError.Create(SJRPCConnectionNotOpen);

    // An id the caller chose (or a request object sent twice) that is still
    // in flight: the answer could not tell the two calls apart. Refused before
    // anything is sent, as the client error every other refusal here is -
    // and the call already pending is left alone.
    if FPending.ContainsKey(LCall.Key) then
      raise EJRPCClientError.CreateFmt(SJRPCConnectionDuplicateId,
        [ARequest.Id.AsString]);

    FPending.Add(LCall.Key, LOwned);
  finally
    FLock.Leave;
  end;

  try
    SendText(LPayload);
  except
    Forget(LCall.Key);
    raise;
  end;

  Result := LCall;
end;

procedure TJRPCConnection.Notify(ANotification: TJRPCNotification);
begin
  CheckOpen;
  SendText(ANotification.ToJson);
end;

procedure TJRPCConnection.Respond(AResponse: TJRPCResponse);
begin
  CheckOpen;
  SendText(AResponse.ToJson);
end;

procedure TJRPCConnection.SendText(const AText: string);
begin
  FSendLock.Enter;
  try
    FTransport.Send(AText);
  finally
    FSendLock.Leave;
  end;
end;

procedure TJRPCConnection.ReaderLoop;
var
  LText: string;
begin
  while True do
  begin
    try
      if not FTransport.Receive(LText) then
        Break;
    except
      on E: Exception do
      begin
        ReportError(E);
        Break;
      end;
    end;

    try
      DispatchMessage(LText);
    except
      on E: Exception do
        ReportError(E);
    end;
  end;

  // The peer closed the stream, or the transport failed. If Close already ran,
  // it owns the cleanup.
  FLock.Enter;
  try
    if FClosed then
      Exit;

    FClosed := True;
    FOpen := False;
  finally
    FLock.Leave;
  end;

  FailPending(SJRPCConnectionClosedByPeer);
  NotifyClosed;
end;

procedure TJRPCConnection.DispatchMessage(const AText: string);
var
  LDocument: TJSONValue;
  LMessages: TJRPCMessages;
  LMessage: TJRPCMessage;
  LId: TJRPCID;
  LRemote: EJRPCRemoteError;
var
  LParseError: EJRPCParseError;
begin
  // A blank frame (a stray line break between messages) carries nothing to
  // read or to answer.
  if AText.Trim = '' then
    Exit;

  LDocument := TJSONObject.ParseJSONValue(AText);
  if not Assigned(LDocument) then
  begin
    // What a server answers to what it cannot parse: -32700 with a null id.
    // The peer may be waiting for it; the failure is still reported.
    LParseError := EJRPCParseError.Create(SJRPCInvalidJSONReceived);
    try
      AnswerPeer(LParseError, nil);
    except
      LParseError.Free;
      raise;
    end;
    raise LParseError;
  end;

  try
    try
      LMessages := TJRPCMessages.CreateFromJson(LDocument);
    except
      on E: EJRPCException do
      begin
        // JSON, but no message at all - an empty array, a bare value: the
        // -32600 a server owes it, with a null id. Then reported.
        AnswerPeer(E, nil);
        raise;
      end;
    end;

    try
      // One object per frame. A batch of one is still a batch: let through,
      // it would reach the object casts below, and an error reply inside it
      // would raise EInvalidCast instead of being reported.
      if not LMessages.Single or (LMessages.Count <> 1) then
      begin
        RejectPeerBatch(LMessages);
        raise EJRPCClientError.CreateFmt(SJRPCConnectionNotSingle,
          [LMessages.Count]);
      end;

      LMessage := LMessages.List[0];

      if LMessage is TJRPCResponse then
      begin
        LId := (LMessage as TJRPCResponse).Id;
        CompletePending(KeyOf(LId), (LMessage as TJRPCResponse).Clone, nil);
      end
      else if (LMessage is TJRPCError) and
        Assigned((LDocument as TJSONObject).GetValue('method')) then
        // Not an error the peer sent: a request or a notification of the peer
        // that this side could not read, and the error is the parser's
        RejectPeerMessage(LMessage as TJRPCError)
      else if (LMessage is TJRPCError) and not (LMessage as TJRPCError).Request then
        // A response this side could not read. The parser marks every error
        // it really read from the peer with Request; one it built itself from
        // a message with no "method" never has it. Completing the call with it
        // would put words in the peer's mouth.
        FailInvalidResponse(LMessage as TJRPCError)
      else if LMessage is TJRPCError then
      begin
        LId := (LMessage as TJRPCError).Id;
        LRemote := EJRPCRemoteError.FromError(LMessage as TJRPCError,
          LDocument as TJSONObject);

        if LId.IsNull then
        begin
          // The peer could not read the id. There is nothing to correlate it
          // with, so the error is reported and dropped.
          try
            Logger.LogWarning(SJRPCConnectionNullId, [LRemote.Message]);
            ReportError(LRemote);
          finally
            LRemote.Free;
          end;
          Exit;
        end;

        CompletePending(KeyOf(LId), nil, LRemote);
      end
      else if LMessage is TJRPCNotification then
        DispatchNotification(LMessage as TJRPCNotification)
      else if LMessage is TJRPCRequest then
        DispatchRequest(LMessage as TJRPCRequest)
      else
        raise EJRPCClientError.CreateFmt(SJRPCConnectionUnexpected,
          [LMessage.ClassName]);
    finally
      LMessages.Free;
    end;
  finally
    LDocument.Free;
  end;
end;

procedure TJRPCConnection.DispatchNotification(ANotification: TJRPCNotification);
begin
  if Assigned(FOnNotification) then
    FOnNotification(ANotification);
end;

procedure TJRPCConnection.RejectPeerMessage(AError: TJRPCError);
var
  LReport: EJRPCClientError;
begin
  if AError.Request then
  begin
    // A notification: never answered, however malformed. The peer is not
    // waiting for anything, so the rejection is only reported.
    LReport := EJRPCClientError.CreateFmt(SJRPCConnectionInvalidNotification,
      [AError.Error.Message.Value]);
    try
      Logger.LogWarning(LReport.Message);
      ReportError(LReport);
    finally
      LReport.Free;
    end;
    Exit;
  end;

  // A request: the peer is waiting, and the error the parser built is the
  // answer a server owes it (-32600, -32602 ...) with the request's id, or a
  // null id when the id itself could not be read.
  SendText(AError.ToJson);
end;

procedure TJRPCConnection.AnswerPeer(E: Exception; const AId: TJRPCID);
var
  LError: TJRPCError;
begin
  LError := TJRPCError.CreateFromException(E, AId);
  try
    SendText(LError.ToJson);
  finally
    LError.Free;
  end;
end;

procedure TJRPCConnection.RejectPeerBatch(AMessages: TJRPCMessages);
var
  LIndex: Integer;
  LMessage: TJRPCMessage;
  LError: TJRPCError;
  LReplies: TArray<string>;
begin
  // This endpoint does not fan a batch out, but a request inside one is still
  // waiting for an answer: each gets a -32600 under its own id, together in
  // an array as a batch reply must be. Notifications are never answered, and
  // responses are reported with the batch by the caller.
  LReplies := [];
  for LIndex := 0 to AMessages.Count - 1 do
  begin
    LMessage := AMessages.List[LIndex];
    if not (LMessage is TJRPCRequest) then
      Continue;

    LError := TJRPCError.Create;
    try
      LError.Id := (LMessage as TJRPCRequest).Id;
      LError.Error.Code := JRPC_INVALID_REQUEST;
      LError.Error.Message := SJRPCConnectionBatchRequest;
      LReplies := LReplies + [LError.ToJson];
    finally
      LError.Free;
    end;
  end;

  if Length(LReplies) > 0 then
    SendText('[' + string.Join(',', LReplies) + ']');
end;

procedure TJRPCConnection.FailInvalidResponse(AError: TJRPCError);
var
  LText: string;
  LReport: EJRPCClientError;
begin
  LText := Format(SJRPCConnectionInvalidResponse, [AError.Error.Message.Value]);

  // A response is never answered. With an id to correlate it, the call it was
  // meant for fails - locally, as a client error, not as a remote one.
  if not AError.Id.IsNull then
  begin
    CompletePending(KeyOf(AError.Id), nil, EJRPCClientError.Create(LText));
    Exit;
  end;

  LReport := EJRPCClientError.Create(LText);
  try
    Logger.LogWarning(LText);
    ReportError(LReport);
  finally
    LReport.Free;
  end;
end;

procedure TJRPCConnection.DispatchRequest(ARequest: TJRPCRequest);
var
  LError: TJRPCError;
begin
  if Assigned(FOnRequest) then
  begin
    try
      FOnRequest(ARequest);
    except
      on E: Exception do
      begin
        // The peer is waiting for this id. Answered the way TJRPCServer
        // answers a method that raised: an EJRPCException with its own code,
        // anything else as -32603 with the details logged rather than sent.
        // Still raised, so the reader reports it to OnError.
        try
          AnswerPeer(E, ARequest.Id);
        except
          on ESend: Exception do
            ReportError(ESend);
        end;
        raise;
      end;
    end;
    Exit;
  end;

  // Nobody is listening: answer Method Not Found rather than leave the peer
  // waiting for a response that will never come.
  LError := TJRPCError.Create;
  try
    LError.Id := ARequest.Id;
    LError.Error.Code := JRPC_METHOD_NOT_FOUND;
    LError.Error.Message := Format(SJRPCMethodNotFound, [ARequest.Method]);
    SendText(LError.ToJson);
  finally
    LError.Free;
  end;
end;

procedure TJRPCConnection.CompletePending(const AKey: string; AResponse: TJRPCResponse; AError: Exception);
var
  LCall: IJRPCOwnedCall;
begin
  LCall := nil;
  FLock.Enter;
  try
    if FPending.TryGetValue(AKey, LCall) then
      FPending.Remove(AKey);
  finally
    FLock.Leave;
  end;

  if not Assigned(LCall) then
  begin
    AResponse.Free;
    AError.Free;
    Logger.LogDebug(SJRPCConnectionUnknownId, [AKey]);
    Exit;
  end;

  // The connection is done with it: a handle that outlives us must not call
  // back. Complete still owns what it is given until it accepts it.
  LCall.Detach;
  if not LCall.Complete(AResponse, AError) then
  begin
    AResponse.Free;
    AError.Free;
  end;
end;

procedure TJRPCConnection.FailPending(const AMessage: string);
var
  LPending: TArray<IJRPCOwnedCall>;
  LPair: TPair<string, IJRPCOwnedCall>;
  LIndex: Integer;
  LError: Exception;
begin
  FLock.Enter;
  try
    SetLength(LPending, FPending.Count);
    LIndex := 0;
    for LPair in FPending do
    begin
      LPending[LIndex] := LPair.Value;
      Inc(LIndex);
    end;
    FPending.Clear;
  finally
    FLock.Leave;
  end;

  for LIndex := 0 to High(LPending) do
  begin
    LPending[LIndex].Detach;
    LError := EJRPCClientError.Create(AMessage);
    if not LPending[LIndex].Complete(nil, LError) then
      LError.Free;
  end;
end;

procedure TJRPCConnection.Forget(const AKey: string);
begin
  FLock.Enter;
  try
    FPending.Remove(AKey);
  finally
    FLock.Leave;
  end;
end;

procedure TJRPCConnection.NotifyClosed;
var
  LProc: TJRPCClosedProc;
begin
  FLock.Enter;
  try
    if FCloseNotified then
      Exit;

    FCloseNotified := True;
    LProc := FOnClose;
  finally
    FLock.Leave;
  end;

  if Assigned(LProc) then
    try
      LProc;
    except
      on E: Exception do
        ReportError(E);
    end;
end;

procedure TJRPCConnection.ReportError(E: Exception);
begin
  if not Assigned(FOnError) then
    Exit;

  // Called from the reader's except blocks and from Close: a handler that
  // raises must not end the reader (leaving every pending call waiting
  // forever, and OnClose never fired) nor make a destructor raise.
  try
    FOnError(E);
  except
    on EHandler: Exception do
      Logger.LogWarning(EHandler, 'OnError raised while reporting: ' + E.Message);
  end;
end;

class function TJRPCConnection.KeyOf(const AId: TJRPCID): string;
begin
  // The kind is part of the key: the number 7 and the string "7" are
  // different ids on the wire.
  if AId.IsNull then
    Result := 'n'
  else if AId.IsString then
    Result := 's:' + AId.AsString
  else
    Result := 'i:' + AId.AsString;
end;

end.
