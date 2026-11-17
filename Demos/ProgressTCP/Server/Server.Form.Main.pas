/// <summary>
///   The transport: an Indy TCP server that reads one JSON-RPC message per
///   line, hands it to TJRPCServer.ProcessRequest and writes the answer back.
///   While the request runs, the notifications the method sends go out on the
///   same connection, ahead of the answer (see TJRPCNotifier).
/// </summary>
unit Server.Form.Main;

interface

uses
  System.SysUtils, System.Classes,
  Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, Vcl.ExtCtrls,

  IdBaseComponent, IdComponent, IdCustomTCPServer, IdTCPServer, IdContext,

  JRPC.Server;

const
  /// <summary>Indy's ReadLn gives up past MaxLineLength, 16 KiB by default.</summary>
  MAX_LINE_LENGTH = 1024 * 1024;
  DEFAULT_PORT = 11100;

type
  TServerForm = class(TForm)
    tcpServer: TIdTCPServer;
    pnlTop: TPanel;
    lblPort: TLabel;
    edtPort: TEdit;
    btnStart: TButton;
    btnStop: TButton;
    btnClear: TButton;
    lblStatus: TLabel;
    memoLog: TMemo;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure btnStartClick(Sender: TObject);
    procedure btnStopClick(Sender: TObject);
    procedure btnClearClick(Sender: TObject);
    procedure tcpServerConnect(AContext: TIdContext);
    procedure tcpServerDisconnect(AContext: TIdContext);
    procedure tcpServerExecute(AContext: TIdContext);
  private
    FJRPCServer: TJRPCServer;
    procedure Log(const AText: string);
    procedure StartServer;
    procedure StopServer;
    procedure UpdateUI;
  end;

var
  ServerForm: TServerForm;

implementation

{$R *.dfm}

uses
  IdGlobal;

{ TServerForm }

procedure TServerForm.FormCreate(Sender: TObject);
begin
  // One TJRPCServer serves every connection: it keeps no per-request state.
  FJRPCServer := TJRPCServer.Create(Self);
  edtPort.Text := IntToStr(DEFAULT_PORT);
  UpdateUI;
end;

procedure TServerForm.FormShow(Sender: TObject);
begin
  StartServer;
end;

procedure TServerForm.FormDestroy(Sender: TObject);
begin
  StopServer;
  // The log lines queued by the connection threads, while the form is alive.
  CheckSynchronize;
end;

procedure TServerForm.Log(const AText: string);
var
  LLine: string;
begin
  // Called from the connection threads: Queue, never Synchronize - stopping
  // the server waits for those threads on the main one.
  LLine := FormatDateTime('hh:nn:ss.zzz', Now) + '  ' + AText;
  TThread.Queue(nil,
    procedure
    begin
      memoLog.Lines.Add(LLine);
    end);
end;

procedure TServerForm.StartServer;
begin
  if tcpServer.Active then
    Exit;

  try
    // Indy keeps the bindings of a previous attempt, which would ignore a port
    // changed since: clear them, and DefaultPort is used again.
    tcpServer.Bindings.Clear;
    tcpServer.DefaultPort := StrToIntDef(edtPort.Text, DEFAULT_PORT);
    tcpServer.Active := True;
    Log(Format('listening on port %d', [tcpServer.DefaultPort]));
  except
    on E: Exception do
      Log(Format('cannot listen on port %s: %s', [edtPort.Text, E.Message]));
  end;

  UpdateUI;
end;

procedure TServerForm.StopServer;
begin
  if not tcpServer.Active then
    Exit;

  // Disconnects the clients and waits for their threads: a job still running
  // stops at its next step, when it fails to write its notification.
  tcpServer.Active := False;
  Log('stopped');
  UpdateUI;
end;

procedure TServerForm.UpdateUI;
begin
  btnStart.Enabled := not tcpServer.Active;
  btnStop.Enabled := tcpServer.Active;
  edtPort.Enabled := not tcpServer.Active;

  if tcpServer.Active then
    lblStatus.Caption := Format('listening on %d', [tcpServer.DefaultPort])
  else
    lblStatus.Caption := 'stopped';
end;

procedure TServerForm.btnStartClick(Sender: TObject);
begin
  StartServer;
end;

procedure TServerForm.btnStopClick(Sender: TObject);
begin
  StopServer;
end;

procedure TServerForm.btnClearClick(Sender: TObject);
begin
  memoLog.Clear;
end;

procedure TServerForm.tcpServerConnect(AContext: TIdContext);
begin
  AContext.Connection.IOHandler.MaxLineLength := MAX_LINE_LENGTH;
  Log('connected: ' + AContext.Binding.PeerIP);
end;

procedure TServerForm.tcpServerDisconnect(AContext: TIdContext);
begin
  Log('disconnected: ' + AContext.Binding.PeerIP);
end;

procedure TServerForm.tcpServerExecute(AContext: TIdContext);
var
  LLine: string;
  LResponse: string;
begin
  // Indy runs this on the connection's own thread, once per incoming line.
  LLine := AContext.Connection.IOHandler.ReadLn(IndyTextEncoding_UTF8);
  if LLine.Trim = '' then
    Exit;

  Log('--> ' + LLine);

  // The second argument is how the method's notifications reach this
  // connection: TJRPCServer wraps it in a TJRPCNotifier and injects it into
  // the [Context] FNotifier field of TJobApi. It is called before
  // ProcessRequest returns, so it goes out ahead of the answer.
  LResponse := FJRPCServer.ProcessRequest(LLine,
    procedure (const AText: string)
    begin
      AContext.Connection.IOHandler.WriteLn(AText, IndyTextEncoding_UTF8);
      Log('<-- ' + AText);
    end);

  // '' answers a notification: nothing goes back.
  if LResponse = '' then
    Exit;

  AContext.Connection.IOHandler.WriteLn(LResponse, IndyTextEncoding_UTF8);
  Log('<-- ' + LResponse);
end;

end.
