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
unit JRPC.Transport;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Generics.Collections,

  JRPC.Core,
  JRPC.Server;

const
  /// <summary>
  ///   No timeout: wait for as long as it takes.
  /// </summary>
  JRPC_INFINITE = Cardinal($FFFFFFFF);

type
  /// <summary>
  ///   Who ended a transport.
  /// </summary>
  TJRPCCloseKind = (
    /// <summary>Close was called on this side.</summary>
    Local,
    /// <summary>The peer ended the stream (EOF, a process that exited).</summary>
    Peer,
    /// <summary>The transport failed (a read error, a broken pipe).</summary>
    Error
  );

  /// <summary>
  ///   Why a transport ended: handed to TJRPCClient.OnClose, and quoted in the
  ///   error of every call still waiting when it happened.
  /// </summary>
  TJRPCCloseInfo = record
    Kind: TJRPCCloseKind;
    Reason: string;
    /// <summary>
    ///   Meaningful only for a transport over a child process.
    /// </summary>
    ExitCode: Integer;

    class function Create(AKind: TJRPCCloseKind; const AReason: string;
      AExitCode: Integer = 0): TJRPCCloseInfo; static;
    class function Local: TJRPCCloseInfo; static;
    class function Peer: TJRPCCloseInfo; static;
  end;

  /// <summary>
  ///   What a transport talks to: implemented by TJRPCClient.
  /// </summary>
  IJRPCTransportListener = interface
  ['{6B1C7D2E-3F40-4A51-9B62-7C8D9EAFB0C1}']
    /// <summary>
    ///   One complete JSON document arrived.
    /// </summary>
    /// <param name="AOrigin">
    ///   The id of the request on whose answer stream the message arrived (an
    ///   SSE body), or a null id for a persistent channel, where messages are
    ///   not tied to a request by the transport.
    /// </param>
    procedure MessageReceived(const AText: string; const AOrigin: TJRPCID);

    /// <summary>
    ///   The transport ended. Called once.
    /// </summary>
    procedure TransportClosed(const AInfo: TJRPCCloseInfo);
  end;

  /// <summary>
  ///   A channel to the peer, seen as a sequence of JSON documents.
  /// </summary>
  /// <remarks>
  ///   Two shapes fit this contract, told apart by RoundTrip:
  ///
  ///   - RoundTrip = True: Send returns only once the exchange is over, and
  ///     the messages of the answer are handed to the listener from inside
  ///     Send, on the thread that called it (HTTP, a function over
  ///     TJRPCServer.ProcessRequest). Send may be called by several threads at
  ///     once, and must cope.
  ///   - RoundTrip = False: Send writes and returns; what comes in is read on a
  ///     thread of the transport's own, at any time (stdio, a socket, a pipe).
  ///     TJRPCPullTransport is the base class for these.
  ///
  ///   The library never links a network transport: implement this over
  ///   whatever is at hand.
  /// </remarks>
  IJRPCTransport = interface
  ['{7C2D8E3F-4051-4B62-AC73-8D9EAFB0C1D2}']
    /// <summary>
    ///   Starts the transport. A RoundTrip transport may be reopened after
    ///   Close; one that owns a resource (a process) may refuse.
    /// </summary>
    procedure Open(const AListener: IJRPCTransportListener);

    /// <summary>
    ///   Writes one complete JSON document.
    /// </summary>
    /// <param name="AOrigin">
    ///   The id of the request going out, which a RoundTrip transport passes
    ///   back with every message of its answer. Null for a notification and
    ///   for an answer to the peer: nothing is expected back.
    /// </param>
    procedure Send(const AText: string; const AOrigin: TJRPCID);

    /// <summary>
    ///   Ends the transport and unblocks a pending read. Idempotent;
    ///   TransportClosed reaches the listener once.
    /// </summary>
    procedure Close;

    /// <summary>
    ///   True when Send delivers the answer before returning (see the remark
    ///   above).
    /// </summary>
    function RoundTrip: Boolean;
  end;

  /// <summary>
  ///   A transport that can stop reading the answer to one request.
  /// </summary>
  /// <remarks>
  ///   Optional. TJRPCClient calls it when a call times out or is cancelled,
  ///   so that a RoundTrip transport does not keep reading a stream nobody
  ///   waits for (a long-lived subscription, typically).
  /// </remarks>
  IJRPCAbortableTransport = interface
  ['{8D3E9F40-5162-4C73-BD84-9EAFB0C1D2E3}']
    /// <summary>
    ///   Stops reading the answer of the request with id AOrigin. Safe to call
    ///   from any thread, and for an id that is no longer being read.
    /// </summary>
    procedure Abort(const AOrigin: TJRPCID);
  end;

  /// <summary>
  ///   Base class for a transport over a persistent stream: implement Receive,
  ///   DoSend and DoClose, and the reader thread is provided.
  /// </summary>
  /// <remarks>
  ///   Writes are serialized here, so DoSend never runs twice at once. The
  ///   reader is started by Open and joined by Close, unless Close comes from
  ///   the reader itself (a handler that closes the client), in which case it
  ///   is joined on destruction.
  ///
  ///   A descendant that frees resources in its destructor must not free
  ///   anything DoClose or Receive uses before this class has closed: Close
  ///   runs in BeforeDestruction, ahead of every destructor.
  /// </remarks>
  TJRPCPullTransport = class abstract(TInterfacedObject, IJRPCTransport)
  private type
    TState = (Idle, Open, Closed);
  private
    FLock: TCriticalSection;
    FSendLock: TCriticalSection;
    FListener: IJRPCTransportListener;
    FReader: TThread;
    FState: TState;
    FClosedLocally: Boolean;

    procedure ReaderLoop;
    procedure CloseResource;
  protected
    /// <summary>
    ///   Blocks until the next message arrives. False ends the stream: the peer
    ///   closed it, or DoClose was called. Raising ends it too, as an error.
    /// </summary>
    function Receive(out AText: string): Boolean; virtual; abstract;

    /// <summary>
    ///   Writes one message. Never called twice at once.
    /// </summary>
    procedure DoSend(const AText: string); virtual; abstract;

    /// <summary>
    ///   Unblocks a pending Receive and releases the stream. Called once, from
    ///   Close or after the peer ended the stream; idempotence is not needed.
    /// </summary>
    procedure DoClose; virtual; abstract;

    /// <summary>
    ///   Called by Open before the reader starts.
    /// </summary>
    procedure DoOpen; virtual;

    /// <summary>
    ///   Why the stream ended when Receive returned False on its own. Called
    ///   after DoClose, so a process transport can report its exit code.
    /// </summary>
    function PeerCloseInfo: TJRPCCloseInfo; virtual;
  public
    constructor Create;
    destructor Destroy; override;
    procedure BeforeDestruction; override;

    // IJRPCTransport
    procedure Open(const AListener: IJRPCTransportListener);
    procedure Send(const AText: string; const AOrigin: TJRPCID);
    procedure Close;
    function RoundTrip: Boolean;
  end;

  /// <summary>
  ///   Sends a request and returns the whole answer ('' when there is none).
  /// </summary>
  TJRPCSendAndReceiveFunc = reference to function(const AText: string): string;

  /// <summary>
  ///   Sends a message that expects no answer.
  /// </summary>
  TJRPCSendProc = reference to procedure(const AText: string);

  /// <summary>
  ///   Hands one message of an answer back to the transport.
  /// </summary>
  TJRPCFrameSink = reference to procedure(const AText: string);

  /// <summary>
  ///   Sends a request and hands every message of the answer to AOnFrame, in
  ///   order, before returning: an SSE body, a test script.
  /// </summary>
  TJRPCFramesProc = reference to procedure(const AText: string; const AOnFrame: TJRPCFrameSink);

  /// <summary>
  ///   A RoundTrip transport made of closures: the quickest way to plug in an
  ///   HTTP client, or a TJRPCServer for an in-process loopback.
  /// </summary>
  /// <example>
  ///   <code>
  ///   LClient.Transport := TJRPCFuncTransport.Create(
  ///     function (const AText: string): string
  ///     begin
  ///       Result := FHttp.Post(FUrl, AText);
  ///     end);
  ///   </code>
  /// </example>
  /// <remarks>
  ///   A message with no origin (a notification, an answer to the peer) goes
  ///   to ASend when one was given; otherwise it goes through the answering
  ///   function too, and whatever that returns is delivered. A function over
  ///   TJRPCServer.ProcessRequest is fine without ASend - it returns '' for a
  ///   notification - while one over a socket that would block reading an
  ///   answer that never comes needs it.
  /// </remarks>
  TJRPCFuncTransport = class(TInterfacedObject, IJRPCTransport)
  private
    FLock: TCriticalSection;
    FSendAndReceive: TJRPCSendAndReceiveFunc;
    FFrames: TJRPCFramesProc;
    FSend: TJRPCSendProc;
    FListener: IJRPCTransportListener;
    FOpen: Boolean;

    function CurrentListener: IJRPCTransportListener;
  public
    constructor Create(const ASendAndReceive: TJRPCSendAndReceiveFunc;
      const ASend: TJRPCSendProc = nil);

    /// <summary>
    ///   An answer made of several messages, handed over one at a time.
    /// </summary>
    constructor CreateFramed(const AFrames: TJRPCFramesProc;
      const ASend: TJRPCSendProc = nil);

    destructor Destroy; override;

    // IJRPCTransport
    procedure Open(const AListener: IJRPCTransportListener);
    procedure Send(const AText: string; const AOrigin: TJRPCID);
    procedure Close;
    function RoundTrip: Boolean;
  end;

  /// <summary>
  ///   An asynchronous in-process loopback to a TJRPCServer.
  /// </summary>
  /// <remarks>
  ///   Every message sent is processed by the server on a task of its own, and
  ///   the answers come back through the reader in whatever order the tasks
  ///   finish. That is what makes it useful in tests: calls are correlated
  ///   out of order, exactly as over a real persistent channel. For a
  ///   synchronous loopback use a TJRPCFuncTransport over ProcessRequest.
  ///
  ///   The server is not owned and must outlive the transport.
  /// </remarks>
  TJRPCLoopbackTransport = class(TJRPCPullTransport)
  private
    FServer: TJRPCServer;
    FQueue: TThreadedQueue<string>;
    FTasksLock: TCriticalSection;
    FTasks: Integer;
    FTasksDone: TEvent;
  protected
    function Receive(out AText: string): Boolean; override;
    procedure DoSend(const AText: string); override;
    procedure DoClose; override;
  public
    constructor Create(AServer: TJRPCServer);
    destructor Destroy; override;
  end;

implementation

uses
  System.Threading,

  Logify;

type
  /// <summary>
  ///   The reader of a TJRPCPullTransport.
  /// </summary>
  TJRPCPullReader = class(TThread)
  private
    FTransport: TJRPCPullTransport;
  protected
    procedure Execute; override;
  public
    constructor Create(ATransport: TJRPCPullTransport);
  end;

{ TJRPCCloseInfo }

class function TJRPCCloseInfo.Create(AKind: TJRPCCloseKind;
  const AReason: string; AExitCode: Integer): TJRPCCloseInfo;
begin
  Result.Kind := AKind;
  Result.Reason := AReason;
  Result.ExitCode := AExitCode;
end;

class function TJRPCCloseInfo.Local: TJRPCCloseInfo;
begin
  Result := Create(TJRPCCloseKind.Local, SJRPCCloseLocal);
end;

class function TJRPCCloseInfo.Peer: TJRPCCloseInfo;
begin
  Result := Create(TJRPCCloseKind.Peer, SJRPCClosePeer);
end;

{ TJRPCPullReader }

constructor TJRPCPullReader.Create(ATransport: TJRPCPullTransport);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FTransport := ATransport;
end;

procedure TJRPCPullReader.Execute;
begin
  FTransport.ReaderLoop;
end;

{ TJRPCPullTransport }

constructor TJRPCPullTransport.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FSendLock := TCriticalSection.Create;
  FState := TState.Idle;
end;

procedure TJRPCPullTransport.BeforeDestruction;
begin
  // Ahead of every destructor in the hierarchy: DoClose and Receive are
  // virtual, and must still find the descendant's fields alive.
  Close;
  inherited;
end;

destructor TJRPCPullTransport.Destroy;
var
  LReader: TThread;
begin
  LReader := FReader;
  FReader := nil;

  if Assigned(LReader) then
  begin
    if LReader = TThread.CurrentThread then
      // Freed from a handler running on the reader: it cannot wait for
      // itself. It ends once the handler returns, and frees itself.
      LReader.FreeOnTerminate := True
    else
    begin
      LReader.WaitFor;
      LReader.Free;
    end;
  end;

  FSendLock.Free;
  FLock.Free;
  inherited;
end;

procedure TJRPCPullTransport.DoOpen;
begin
end;

function TJRPCPullTransport.PeerCloseInfo: TJRPCCloseInfo;
begin
  Result := TJRPCCloseInfo.Peer;
end;

procedure TJRPCPullTransport.Open(const AListener: IJRPCTransportListener);
begin
  FLock.Enter;
  try
    case FState of
      TState.Open: raise EJRPCClientError.Create(SJRPCTransportAlreadyOpen);
      TState.Closed: raise EJRPCClientError.Create(SJRPCTransportClosed);
    end;

    DoOpen;

    FListener := AListener;
    FState := TState.Open;
    FReader := TJRPCPullReader.Create(Self);
    // Started under the lock: a Close racing with Open must never find a
    // thread that was created but never started, or WaitFor would hang on it.
    FReader.Start;
  finally
    FLock.Leave;
  end;
end;

procedure TJRPCPullTransport.Send(const AText: string; const AOrigin: TJRPCID);
begin
  if FState <> TState.Open then
    raise EJRPCClientError.Create(SJRPCTransportNotOpen);

  FSendLock.Enter;
  try
    DoSend(AText);
  finally
    FSendLock.Leave;
  end;
end;

procedure TJRPCPullTransport.Close;
var
  LReader: TThread;
  LWasOpen: Boolean;
begin
  FLock.Enter;
  try
    LWasOpen := FState = TState.Open;
    FState := TState.Closed;
    if LWasOpen then
      FClosedLocally := True;

    // Only a Close on another thread can join the reader. One from a handler,
    // on the reader itself, leaves the thread to the destructor.
    LReader := FReader;
    if Assigned(LReader) and (LReader <> TThread.CurrentThread) then
      FReader := nil
    else
      LReader := nil;
  finally
    FLock.Leave;
  end;

  if LWasOpen then
    CloseResource;

  // The reader notices that the stream is over, tells the listener and ends.
  if Assigned(LReader) then
  begin
    LReader.WaitFor;
    LReader.Free;
  end;
end;

procedure TJRPCPullTransport.CloseResource;
begin
  try
    DoClose;
  except
    on E: Exception do
      Logger.LogWarning(E, 'The transport failed while closing');
  end;
end;

function TJRPCPullTransport.RoundTrip: Boolean;
begin
  Result := False;
end;

procedure TJRPCPullTransport.ReaderLoop;
var
  LText: string;
  LInfo: TJRPCCloseInfo;
  LFailed: Boolean;
  LFailure: string;
  LLocal: Boolean;
  LListener: IJRPCTransportListener;
begin
  LFailed := False;
  LListener := FListener;

  while True do
  begin
    try
      if not Receive(LText) then
        Break;
    except
      on E: Exception do
      begin
        LFailed := True;
        LFailure := E.Message;
        Break;
      end;
    end;

    try
      LListener.MessageReceived(LText, TJRPCID.Null);
    except
      on E: Exception do
        // The listener reports its own failures; one that escapes must not end
        // the reader and leave every pending call waiting forever.
        Logger.LogWarning(E, 'The transport listener raised');
    end;
  end;

  FLock.Enter;
  try
    LLocal := FClosedLocally;
    FState := TState.Closed;
  finally
    FLock.Leave;
  end;

  if LLocal then
    LInfo := TJRPCCloseInfo.Local
  else
  begin
    // The peer ended the stream, or it broke: release what DoClose releases,
    // then ask what happened (a process has exited by then).
    CloseResource;
    if LFailed then
      LInfo := TJRPCCloseInfo.Create(TJRPCCloseKind.Error,
        Format(SJRPCCloseError, [LFailure]))
    else
      LInfo := PeerCloseInfo;
  end;

  try
    LListener.TransportClosed(LInfo);
  except
    on E: Exception do
      Logger.LogWarning(E, 'The transport listener raised on close');
  end;

  FListener := nil;
end;

{ TJRPCFuncTransport }

constructor TJRPCFuncTransport.Create(
  const ASendAndReceive: TJRPCSendAndReceiveFunc; const ASend: TJRPCSendProc);
begin
  inherited Create;
  if not Assigned(ASendAndReceive) then
    raise EJRPCClientError.Create(SJRPCTransportNoFunc);

  FLock := TCriticalSection.Create;
  FSendAndReceive := ASendAndReceive;
  FSend := ASend;
end;

constructor TJRPCFuncTransport.CreateFramed(const AFrames: TJRPCFramesProc;
  const ASend: TJRPCSendProc);
begin
  inherited Create;
  if not Assigned(AFrames) then
    raise EJRPCClientError.Create(SJRPCTransportNoFunc);

  FLock := TCriticalSection.Create;
  FFrames := AFrames;
  FSend := ASend;
end;

destructor TJRPCFuncTransport.Destroy;
begin
  FLock.Free;
  inherited;
end;

function TJRPCFuncTransport.CurrentListener: IJRPCTransportListener;
begin
  FLock.Enter;
  try
    if not FOpen then
      raise EJRPCClientError.Create(SJRPCTransportNotOpen);
    Result := FListener;
  finally
    FLock.Leave;
  end;
end;

procedure TJRPCFuncTransport.Open(const AListener: IJRPCTransportListener);
begin
  FLock.Enter;
  try
    if FOpen then
      raise EJRPCClientError.Create(SJRPCTransportAlreadyOpen);

    FListener := AListener;
    FOpen := True;
  finally
    FLock.Leave;
  end;
end;

procedure TJRPCFuncTransport.Send(const AText: string; const AOrigin: TJRPCID);
var
  LListener: IJRPCTransportListener;
  LAnswer: string;
begin
  LListener := CurrentListener;

  if AOrigin.IsNull and Assigned(FSend) then
  begin
    FSend(AText);
    Exit;
  end;

  if Assigned(FFrames) then
  begin
    FFrames(AText,
      procedure (const AFrame: string)
      begin
        LListener.MessageReceived(AFrame, AOrigin);
      end);
    Exit;
  end;

  LAnswer := FSendAndReceive(AText);
  if LAnswer.Trim <> '' then
    LListener.MessageReceived(LAnswer, AOrigin);
end;

procedure TJRPCFuncTransport.Close;
var
  LListener: IJRPCTransportListener;
begin
  FLock.Enter;
  try
    if not FOpen then
      Exit;

    FOpen := False;
    LListener := FListener;
    FListener := nil;
  finally
    FLock.Leave;
  end;

  LListener.TransportClosed(TJRPCCloseInfo.Local);
end;

function TJRPCFuncTransport.RoundTrip: Boolean;
begin
  Result := True;
end;

{ TJRPCLoopbackTransport }

constructor TJRPCLoopbackTransport.Create(AServer: TJRPCServer);
begin
  inherited Create;
  if not Assigned(AServer) then
    raise EJRPCClientError.Create(SJRPCTransportNoServer);

  FServer := AServer;
  FQueue := TThreadedQueue<string>.Create(1024, JRPC_INFINITE, JRPC_INFINITE);
  FTasksLock := TCriticalSection.Create;
  FTasksDone := TEvent.Create(nil, True, True, '');
end;

destructor TJRPCLoopbackTransport.Destroy;
begin
  inherited;
  // After the inherited destructor: the reader has been joined by then, so
  // nothing pops from the queue any more.
  FTasksDone.Free;
  FTasksLock.Free;
  FQueue.Free;
end;

function TJRPCLoopbackTransport.Receive(out AText: string): Boolean;
var
  LText: string;
begin
  // After DoShutDown PopItem still answers wrSignaled, with an empty item:
  // the queue itself says whether it is over.
  Result := (FQueue.PopItem(LText) = wrSignaled) and not FQueue.ShutDown;
  AText := LText;
end;

procedure TJRPCLoopbackTransport.DoSend(const AText: string);
begin
  FTasksLock.Enter;
  try
    Inc(FTasks);
    FTasksDone.ResetEvent;
  finally
    FTasksLock.Leave;
  end;

  TTask.Run(
    procedure
    var
      LAnswer: string;
    begin
      try
        try
          LAnswer := FServer.ProcessRequest(AText);
          if LAnswer.Trim <> '' then
            FQueue.PushItem(LAnswer);
        except
          on E: Exception do
            Logger.LogWarning(E, 'The loopback server raised');
        end;
      finally
        FTasksLock.Enter;
        try
          Dec(FTasks);
          if FTasks = 0 then
            FTasksDone.SetEvent;
        finally
          FTasksLock.Leave;
        end;
      end;
    end);
end;

procedure TJRPCLoopbackTransport.DoClose;
begin
  // The tasks still running push into a queue that is shutting down, which
  // drops what they push; waiting for them keeps the server in use only while
  // the transport is.
  FTasksDone.WaitFor(JRPC_INFINITE);
  FQueue.DoShutDown;
end;

end.
