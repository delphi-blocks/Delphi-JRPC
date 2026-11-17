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
///   The client of the demo. One TJRPCClient, three transports to pick from
///   before connecting: a socket that writes a line and reads the next one, a
///   socket kept open and read on a thread of its own, and a TJRPCServer in
///   this very process. Every button works the same over all three; what
///   changes is only how a message gets to the server and back. See README.md.
/// </summary>
unit Client.Form.Main;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs,
  Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, Vcl.ExtCtrls,
  IdBaseComponent, IdComponent, IdTCPConnection, IdTCPClient,

  JRPC.Core,
  JRPC.Server,
  JRPC.Transport,
  JRPC.Client;

type
  {$SCOPEDENUMS ON}

  /// <summary>
  ///   The transports of the demo, in the order of the combo box.
  /// </summary>
  TTransportKind = (
    /// <summary>A socket, one line out and one line back per call.</summary>
    RoundTrip,
    /// <summary>A socket kept open and read by a thread of its own.</summary>
    Persistent,
    /// <summary>A TJRPCServer in this process: no socket at all.</summary>
    InProcess
  );

  {$SCOPEDENUMS OFF}

  /// <summary>
  ///   One entry of a "dir/list" result, declared client-side.
  /// </summary>
  /// <remarks>
  ///   Deliberately a copy of the server's TDirEntry rather than a reference to
  ///   it: a client knows the wire contract, not the server's units. Only the
  ///   members it actually reads need to be here, and Neon ignores the rest.
  /// </remarks>
  TDirEntry = class
  private
    FName: string;
    FSize: Int64;
    FModified: string;
  public
    property Name: string read FName write FName;
    property Size: Int64 read FSize write FSize;
    property Modified: string read FModified write FModified;
  end;

  TClientForm = class(TForm)
    tcpClient: TIdTCPClient;
    tmrLog: TTimer;
    pnlTop: TPanel;
    lblTransport: TLabel;
    cbxTransport: TComboBox;
    btnClear: TButton;
    lblHost: TLabel;
    edtHost: TEdit;
    lblPort: TLabel;
    edtPort: TEdit;
    lblTimeout: TLabel;
    edtTimeout: TEdit;
    btnConnect: TButton;
    btnDisconnect: TButton;
    lblStatus: TLabel;
    pnlLeft: TPanel;
    grpSync: TGroupBox;
    btnPing: TButton;
    btnInfo: TButton;
    btnTime: TButton;
    lblEcho: TLabel;
    edtEcho: TEdit;
    btnEcho: TButton;
    lblPath: TLabel;
    edtPath: TEdit;
    lblMask: TLabel;
    edtMask: TEdit;
    btnDir: TButton;
    grpAsync: TGroupBox;
    lblBurst: TLabel;
    edtBurst: TEdit;
    btnBurst: TButton;
    grpMore: TGroupBox;
    btnBatch: TButton;
    btnNotify: TButton;
    grpRaw: TGroupBox;
    edtRaw: TEdit;
    btnSendRaw: TButton;
    memoLog: TMemo;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure tmrLogTimer(Sender: TObject);
    procedure cbxTransportChange(Sender: TObject);
    procedure edtTimeoutChange(Sender: TObject);
    procedure btnConnectClick(Sender: TObject);
    procedure btnDisconnectClick(Sender: TObject);
    procedure btnPingClick(Sender: TObject);
    procedure btnInfoClick(Sender: TObject);
    procedure btnTimeClick(Sender: TObject);
    procedure btnEchoClick(Sender: TObject);
    procedure btnDirClick(Sender: TObject);
    procedure btnBurstClick(Sender: TObject);
    procedure btnBatchClick(Sender: TObject);
    procedure btnNotifyClick(Sender: TObject);
    procedure btnSendRawClick(Sender: TObject);
    procedure btnClearClick(Sender: TObject);
  private
    FClient: TJRPCClient;
    FKind: TTransportKind;
    FServer: TJRPCServer;
    FSocketLock: TCriticalSection;
    FTimeout: Integer;
    FLogLock: TCriticalSection;
    FPendingLog: TStringList;
    FConnectionEnded: Integer;

    /// <summary>
    ///   Thread-safe: the client's hooks run on the caller, on the reader, on
    ///   the dispatch thread or on a task of the pool, depending on the
    ///   transport. The lines are buffered and tmrLog moves them to the memo,
    ///   in the order they were logged.
    /// </summary>
    procedure Log(const AText: string);
    procedure FlushLog;
    procedure LogError(AError: Exception);
    procedure UpdateUI;

    function SelectedKind: TTransportKind;
    function IsConnected: Boolean;

    /// <summary>
    ///   The timeout typed in the top bar, kept in a field so that the socket
    ///   closures can read it from any thread. 0 means wait forever.
    /// </summary>
    function Timeout: Cardinal;

    /// <summary>
    ///   The same timeout in the terms of an Indy ReadLn.
    /// </summary>
    function SocketTimeout: Integer;

    procedure ConnectSocket;
    function CreateTransport(AKind: TTransportKind): IJRPCTransport;
    function CreateRoundTripTransport: IJRPCTransport;

    /// <summary>
    ///   Asks tmrLog to shut the connection down from the main thread. Callable
    ///   from any thread.
    /// </summary>
    procedure ConnectionEnded;

    /// <summary>
    ///   Closes the client, then the socket - in that order: Close joins the
    ///   reader, so nothing reads the socket any more when it goes away.
    ///   Idempotent.
    /// </summary>
    procedure ShutdownConnection;
  end;

var
  ClientForm: TClientForm;

implementation

uses
  System.IOUtils, System.Diagnostics,

  IdGlobal, IdException,

  Client.Transport;

{$R *.dfm}

const
  MAX_LINE_LENGTH = 1024 * 1024;
  DEFAULT_PORT = 11099;
  DEFAULT_TIMEOUT_MS = 5000;
  DEFAULT_BURST_COUNT = 10;

  TRANSPORT_NAMES: array [TTransportKind] of string = (
    'one line per call',
    'socket kept open',
    'in process');

{ TClientForm }

procedure TClientForm.FormCreate(Sender: TObject);
begin
  FLogLock := TCriticalSection.Create;
  FPendingLog := TStringList.Create;
  FSocketLock := TCriticalSection.Create;
  FClient := nil;
  FKind := TTransportKind.RoundTrip;
  FConnectionEnded := 0;

  // The in-process transport needs a server to talk to. It carries the very
  // commands of Server.exe: the dpr links Server.Protocol.Api, which registers
  // TBasicApi with the global registry every TJRPCServer reads.
  FServer := TJRPCServer.Create(Self);

  edtPath.Text := TPath.GetTempPath;
  edtTimeout.Text := DEFAULT_TIMEOUT_MS.ToString;
  FTimeout := DEFAULT_TIMEOUT_MS;
  edtBurst.Text := DEFAULT_BURST_COUNT.ToString;
  UpdateUI;
end;

procedure TClientForm.FormDestroy(Sender: TObject);
begin
  tmrLog.Enabled := False;
  ShutdownConnection;
  FSocketLock.Free;
  FPendingLog.Free;
  FLogLock.Free;
end;

procedure TClientForm.Log(const AText: string);
begin
  FLogLock.Enter;
  try
    FPendingLog.Add(AText);
  finally
    FLogLock.Leave;
  end;
end;

procedure TClientForm.FlushLog;
var
  LLines: TStringList;
begin
  LLines := TStringList.Create;
  try
    FLogLock.Enter;
    try
      LLines.Assign(FPendingLog);
      FPendingLog.Clear;
    finally
      FLogLock.Leave;
    end;

    if LLines.Count = 0 then
      Exit;

    memoLog.Lines.BeginUpdate;
    try
      memoLog.Lines.AddStrings(LLines);
    finally
      memoLog.Lines.EndUpdate;
    end;
  finally
    LLines.Free;
  end;
end;

procedure TClientForm.tmrLogTimer(Sender: TObject);
begin
  FlushLog;

  // The end of a connection is noticed on another thread (the reader, a task
  // of the pool); the client and the socket are released here, on the main
  // thread.
  if TInterlocked.Exchange(FConnectionEnded, 0) <> 0 then
    ShutdownConnection;
end;

procedure TClientForm.LogError(AError: Exception);
begin
  // The call reached the server and it said no, versus the call never
  // completed (timeout, closed, unreadable answer).
  if AError is EJRPCRemoteError then
    Log(Format('!!! server error %d: %s', [EJRPCRemoteError(AError).Code, AError.Message]))
  else
    Log(Format('!!! %s: %s', [AError.ClassName, AError.Message]));
end;

procedure TClientForm.UpdateUI;
var
  LConnected: Boolean;
  LSocket: Boolean;
begin
  LConnected := IsConnected;
  LSocket := SelectedKind <> TTransportKind.InProcess;

  cbxTransport.Enabled := not LConnected;
  edtHost.Enabled := not LConnected and LSocket;
  edtPort.Enabled := not LConnected and LSocket;
  btnConnect.Enabled := not LConnected;
  btnDisconnect.Enabled := LConnected;
  pnlLeft.Enabled := LConnected;

  // Raw text goes on the socket past the client, which is only safe while
  // nobody else reads it: with a reader thread the answer would be its.
  edtRaw.Enabled := LConnected and (FKind = TTransportKind.RoundTrip);
  btnSendRaw.Enabled := edtRaw.Enabled;

  if not LConnected then
    lblStatus.Caption := 'not connected'
  else if FKind = TTransportKind.InProcess then
    lblStatus.Caption := 'connected in process'
  else
    lblStatus.Caption := Format('connected to %s:%d, %s',
      [tcpClient.Host, tcpClient.Port, TRANSPORT_NAMES[FKind]]);
end;

function TClientForm.SelectedKind: TTransportKind;
begin
  Result := TTransportKind(cbxTransport.ItemIndex);
end;

function TClientForm.IsConnected: Boolean;
begin
  Result := Assigned(FClient) and FClient.Active;
end;

function TClientForm.Timeout: Cardinal;
begin
  Result := TInterlocked.CompareExchange(FTimeout, 0, 0);
  if Result = 0 then
    Result := JRPC_INFINITE;
end;

function TClientForm.SocketTimeout: Integer;
begin
  if Timeout = JRPC_INFINITE then
    Result := IdTimeoutInfinite
  else
    Result := Integer(Timeout);
end;

procedure TClientForm.cbxTransportChange(Sender: TObject);
begin
  UpdateUI;
end;

procedure TClientForm.edtTimeoutChange(Sender: TObject);
begin
  TInterlocked.Exchange(FTimeout, StrToIntDef(edtTimeout.Text, 0));
end;

procedure TClientForm.ConnectSocket;
begin
  tcpClient.Host := edtHost.Text;
  tcpClient.Port := StrToIntDef(edtPort.Text, DEFAULT_PORT);
  tcpClient.Connect;
  tcpClient.IOHandler.MaxLineLength := MAX_LINE_LENGTH;
end;

function TClientForm.CreateTransport(AKind: TTransportKind): IJRPCTransport;
begin
  case AKind of
    TTransportKind.RoundTrip:
      Result := CreateRoundTripTransport;

    // The reader thread reads every line the server writes and the client
    // matches each answer to its call by id: several calls can be in flight.
    TTransportKind.Persistent:
      Result := TIndyLineTransport.Create(tcpClient, MAX_LINE_LENGTH);

    // Each message is processed by FServer on a task of its own, and the
    // answers come back in whatever order the tasks finish.
    TTransportKind.InProcess:
      Result := TJRPCLoopbackTransport.Create(FServer);
  else
    raise EJRPCClientError.Create('unknown transport');
  end;
end;

function TClientForm.CreateRoundTripTransport: IJRPCTransport;
begin
  // The Indy pair *is* the transport: one line out, one line back.
  //
  // ExecuteAsync runs these closures on tasks of the thread pool, so several
  // can run at once; one socket only takes one exchange at a time, hence the
  // lock. A call that times out leaves its answer on the socket, where the
  // next call would read it as its own: the connection is dropped instead.
  Result := TJRPCFuncTransport.Create(
    function (const ARequest: string): string
    begin
      FSocketLock.Enter;
      try
        try
          tcpClient.IOHandler.WriteLn(ARequest, IndyTextEncoding_UTF8);
          Result := tcpClient.IOHandler.ReadLn(LF, SocketTimeout, MAX_LINE_LENGTH,
            IndyTextEncoding_UTF8);
        except
          on E: EIdException do
          begin
            ConnectionEnded;
            raise;
          end;
        end;

        if tcpClient.IOHandler.ReadLnTimedout then
        begin
          ConnectionEnded;
          raise EJRPCClientError.Create('timed out waiting for the answer; the socket is out of step, so it is closed');
        end;
      finally
        FSocketLock.Leave;
      end;
    end,
    // A notification must not read: per the spec the server answers nothing
    // at all, so a ReadLn here would block until the timeout.
    procedure (const ARequest: string)
    begin
      FSocketLock.Enter;
      try
        tcpClient.IOHandler.WriteLn(ARequest, IndyTextEncoding_UTF8);
      finally
        FSocketLock.Leave;
      end;
    end);
end;

procedure TClientForm.ConnectionEnded;
begin
  TInterlocked.Exchange(FConnectionEnded, 1);
end;

procedure TClientForm.btnConnectClick(Sender: TObject);
begin
  FKind := SelectedKind;
  try
    if FKind <> TTransportKind.InProcess then
      ConnectSocket;

    // A closed client cannot be reopened on the same transport, so every
    // Connect makes a new one.
    FClient := TJRPCClient.Create(nil);
    FClient.Transport := CreateTransport(FKind);

    // The trace hooks see every payload exactly as it goes out and comes in,
    // whatever the transport.
    FClient.OnBeforeSend :=
      procedure (const AJSON: string)
      begin
        Log('--> ' + AJSON);
      end;

    FClient.OnAfterReceive :=
      procedure (const AJSON: string)
      begin
        Log('<-- ' + AJSON);
      end;

    // One place for every failure, so no button repeats the logging: an error
    // answer, a timeout, an unreadable line, an answer nobody waits for. Once
    // logged, a failed call raises EAbort instead: it stops the button's code,
    // and the VCL drops it without a dialog, so no button needs an except.
    FClient.OnError :=
      procedure (AError: Exception; var AAction: TJRPCErrorAction)
      begin
        LogError(AError);
        AAction := TJRPCErrorAction.Abort;
      end;

    FClient.OnCallEnded :=
      procedure (const AId: TJRPCID; AReason: TJRPCCallEnd)
      var
        LId: string;
      begin
        LId := AId;
        case AReason of
          TJRPCCallEnd.Timeout: Log(Format('    (call %s: no answer in time)', [LId]));
          TJRPCCallEnd.Cancelled: Log(Format('    (call %s: cancelled)', [LId]));
        end;
      end;

    // This server never pushes anything; a server that does would land here,
    // on the client's dispatch thread. With no OnRequest and no Server, a
    // request from the server is answered -32601 by the client itself.
    FClient.OnNotification :=
      procedure (const ANotification: TJRPCNotification)
      begin
        Log(Format('<<< notification %s', [ANotification.Method]));
      end;

    FClient.OnClose :=
      procedure (const AInfo: TJRPCCloseInfo)
      begin
        Log('*** connection closed: ' + AInfo.Reason);
        if AInfo.Kind <> TJRPCCloseKind.Local then
          ConnectionEnded;
      end;

    FClient.Open;
    if FKind = TTransportKind.InProcess then
      Log('*** connected in process')
    else
      Log(Format('*** connected to %s:%d, %s', [tcpClient.Host, tcpClient.Port, TRANSPORT_NAMES[FKind]]));
  except
    on E: Exception do
    begin
      Log(Format('!!! cannot connect: %s', [E.Message]));
      ShutdownConnection;
    end;
  end;

  UpdateUI;
end;

procedure TClientForm.btnDisconnectClick(Sender: TObject);
begin
  ShutdownConnection;
end;

procedure TClientForm.ShutdownConnection;
begin
  if Assigned(FClient) then
  begin
    // Fails the pending calls, closes the transport and joins the reader.
    FClient.Close;
    FreeAndNil(FClient);
  end;

  try
    if tcpClient.Connected then
      tcpClient.Disconnect;
  except
    // The server may already have dropped the socket.
    on E: Exception do
      Log(Format('!!! disconnect: %s', [E.Message]));
  end;

  UpdateUI;
end;

procedure TClientForm.btnPingClick(Sender: TObject);
begin
  Log('    = ' + FClient.ExecuteAs<string>(TJRPCRequestBuilder.New.SetMethod('ping'), Timeout));
end;

procedure TClientForm.btnInfoClick(Sender: TObject);
begin
  // The result is an object: ExecuteAsJsonString hands it back as text, with
  // no class to declare on this side.
  Log('    = ' + FClient.ExecuteAsJsonString(TJRPCRequestBuilder.New.SetMethod('sys/info'), Timeout));
end;

procedure TClientForm.btnTimeClick(Sender: TObject);
begin
  Log('    = ' + FClient.ExecuteAs<string>(TJRPCRequestBuilder.New.SetMethod('sys/time'), Timeout));
end;

procedure TClientForm.btnEchoClick(Sender: TObject);
begin
  Log('    = ' + FClient.ExecuteAs<string>(
    TJRPCRequestBuilder.New.SetMethod('echo').AddNamedParam('text', edtEcho.Text),
    Timeout));
end;

procedure TClientForm.btnDirClick(Sender: TObject);
var
  LEntries: TArray<TDirEntry>;
  LEntry: TDirEntry;
begin
  // Every parameter is required: a missing one is -32602, not a default.
  LEntries := FClient.ExecuteAs<TArray<TDirEntry>>(
    TJRPCRequestBuilder.New
      .SetMethod('dir/list')
      .AddNamedParam('path', edtPath.Text)
      .AddNamedParam('mask', edtMask.Text),
    Timeout);
  try
    for LEntry in LEntries do
      Log(Format('    %-30s %10d  %s', [LEntry.Name, LEntry.Size, LEntry.Modified]));

    if Length(LEntries) = 0 then
      Log('    (no matching file)');
  finally
    for LEntry in LEntries do
      LEntry.Free;
  end;
end;

procedure TClientForm.btnBurstClick(Sender: TObject);
var
  LCount: Integer;
  LIndex: Integer;
  LCalls: TArray<IJRPCCall<string>>;
  LWatch: TStopwatch;
begin
  LCount := StrToIntDef(edtBurst.Text, DEFAULT_BURST_COUNT);
  if LCount < 1 then
    LCount := DEFAULT_BURST_COUNT;
  SetLength(LCalls, LCount);
  LWatch := TStopwatch.StartNew;

  // Every request goes out before any answer is read. Over a persistent
  // channel the ids keep the answers apart, whatever order they come back in;
  // over a round-trip socket the calls run on the pool and queue on the
  // socket, one exchange at a time.
  for LIndex := 0 to LCount - 1 do
    LCalls[LIndex] := FClient.ExecuteAsync<string>(
      TJRPCRequestBuilder.New
        .SetMethod('echo')
        .AddNamedParam('text', Format('burst #%d', [LIndex + 1])));

  for LIndex := 0 to LCount - 1 do
  begin
    if not LCalls[LIndex].Wait(Timeout) then
    begin
      LCalls[LIndex].Cancel;
      Continue;
    end;

    try
      Log(Format('    #%d = %s', [LIndex + 1, LCalls[LIndex].Value]));
    except
      // Already logged through OnError, which turned it into an EAbort:
      // caught here only so that one failed call does not end the burst.
      on E: EAbort do
        ;
    end;
  end;

  Log(Format('    %d calls in %d ms', [LCount, LWatch.ElapsedMilliseconds]));
end;

procedure TClientForm.btnBatchClick(Sender: TObject);
var
  LBatch: TJRPCMessages;
  LAnswers: TJRPCMessages;
  LRequest: TJRPCRequest;
  LNotification: TJRPCNotification;
  LMessage: TJRPCMessage;
  LAnswer: TJRPCMessage;
begin
  LBatch := TJRPCMessages.Create(True);
  try
    // The batch owns its messages, so they are created here: Build would only
    // lend out a request its builder frees.
    LRequest := TJRPCRequest.Create;
    LRequest.Method := 'ping';
    LBatch.AddMessage(LRequest);

    LRequest := TJRPCRequest.Create;
    LRequest.Method := 'echo';
    LRequest.AddNamedParam('text', edtEcho.Text);
    LBatch.AddMessage(LRequest);

    LRequest := TJRPCRequest.Create;
    LRequest.Method := 'no/such/method';
    LBatch.AddMessage(LRequest);

    // A notification in a batch gets no answer, not even an empty one.
    LNotification := TJRPCNotification.Create;
    LNotification.Method := 'ping';
    LBatch.AddMessage(LNotification);

    // An error inside a batch is returned, never raised: the answers to the
    // other requests are not lost with it.
    LAnswers := FClient.ExecuteBatch(LBatch, Timeout);
    try
      for LMessage in LBatch.List do
      begin
        if not (LMessage is TJRPCRequest) then
          Continue;
        LRequest := TJRPCRequest(LMessage);
        LAnswer := TJRPCClient.FindById(LAnswers, LRequest.Id);
        if Assigned(LAnswer) then
          Log(Format('    %s = %s', [LRequest.Method, LAnswer.ToJson]))
        else
          Log(Format('    %s = (no answer)', [LRequest.Method]));
      end;
    finally
      LAnswers.Free;
    end;
  finally
    LBatch.Free;
  end;
end;

procedure TClientForm.btnNotifyClick(Sender: TObject);
begin
  FClient.Notify(TJRPCNotificationBuilder.New.SetMethod('ping'));
  Log('    (a notification gets no answer)');
end;

procedure TClientForm.btnSendRawClick(Sender: TObject);
var
  LText: string;
  LReply: string;
begin
  // Anything typed here goes out untouched, straight on the socket and past
  // the client: handy for provoking -32700, -32600 and -32601 by hand. The
  // error comes back as a logged reply rather than through OnError.
  LText := Trim(edtRaw.Text);
  if (LText = '') or not IsConnected or (FKind <> TTransportKind.RoundTrip) then
    Exit;

  Log('--> ' + LText);
  FSocketLock.Enter;
  try
    try
      tcpClient.IOHandler.WriteLn(LText, IndyTextEncoding_UTF8);
      LReply := tcpClient.IOHandler.ReadLn(LF, SocketTimeout, MAX_LINE_LENGTH,
        IndyTextEncoding_UTF8);
      if tcpClient.IOHandler.ReadLnTimedout then
        Log('    (no answer: a notification, or a server that did not reply)')
      else
        Log('<-- ' + LReply);
    except
      on E: Exception do
      begin
        LogError(E);
        ConnectionEnded;
      end;
    end;
  finally
    FSocketLock.Leave;
  end;
end;

procedure TClientForm.btnClearClick(Sender: TObject);
begin
  FlushLog;
  memoLog.Clear;
end;

end.
