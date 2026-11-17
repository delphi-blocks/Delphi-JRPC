/// <summary>
///   The client: starts job/run on the server and shows what comes back while
///   the call runs - the job/progress notifications - and, at the end, the
///   result of the call.
/// </summary>
unit Client.Form.Main;

interface

uses
  System.SysUtils, System.Classes,
  Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ComCtrls,

  IdBaseComponent, IdComponent, IdTCPConnection, IdTCPClient,

  JRPC.Core,
  JRPC.Client;

const
  MAX_LINE_LENGTH = 1024 * 1024;
  DEFAULT_PORT = 11100;

type
  TClientForm = class(TForm)
    tcpClient: TIdTCPClient;
    pnlTop: TPanel;
    lblHost: TLabel;
    edtHost: TEdit;
    lblPort: TLabel;
    edtPort: TEdit;
    btnConnect: TButton;
    btnDisconnect: TButton;
    lblStatus: TLabel;
    pnlJob: TPanel;
    lblSteps: TLabel;
    edtSteps: TEdit;
    lblStepTime: TLabel;
    edtStepTime: TEdit;
    btnRun: TButton;
    pbJob: TProgressBar;
    lblResult: TLabel;
    memoLog: TMemo;
    tmrCall: TTimer;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure btnConnectClick(Sender: TObject);
    procedure btnDisconnectClick(Sender: TObject);
    procedure btnRunClick(Sender: TObject);
    procedure tmrCallTimer(Sender: TObject);
  private
    FClient: TJRPCClient;
    FCall: IJRPCCall<string>;

    /// <summary>
    ///   Adds a line to the log. Safe from any thread.
    /// </summary>
    procedure Log(const AText: string);

    procedure ShowProgress(AStep, ASteps: Integer);
    procedure ShutdownConnection;
    function IsConnected: Boolean;
    procedure UpdateUI;
  end;

var
  ClientForm: TClientForm;

implementation

{$R *.dfm}

uses
  JRPC.Transport,

  Client.Transport;

{ TClientForm }

procedure TClientForm.FormCreate(Sender: TObject);
begin
  edtPort.Text := IntToStr(DEFAULT_PORT);
  UpdateUI;
end;

procedure TClientForm.FormDestroy(Sender: TObject);
begin
  tmrCall.Enabled := False;
  ShutdownConnection;
  // The log lines queued by the client's threads, while the form is alive.
  CheckSynchronize;
end;

procedure TClientForm.Log(const AText: string);
var
  LLine: string;
begin
  LLine := FormatDateTime('hh:nn:ss.zzz', Now) + '  ' + AText;
  TThread.Queue(nil,
    procedure
    begin
      memoLog.Lines.Add(LLine);
    end);
end;

function TClientForm.IsConnected: Boolean;
begin
  Result := Assigned(FClient) and FClient.Active;
end;

procedure TClientForm.UpdateUI;
var
  LConnected: Boolean;
begin
  LConnected := IsConnected;
  edtHost.Enabled := not LConnected;
  edtPort.Enabled := not LConnected;
  btnConnect.Enabled := not LConnected;
  btnDisconnect.Enabled := LConnected;
  btnRun.Enabled := LConnected and not Assigned(FCall);

  if LConnected then
    lblStatus.Caption := Format('connected to %s:%d', [tcpClient.Host, tcpClient.Port])
  else
    lblStatus.Caption := 'not connected';
end;

procedure TClientForm.btnConnectClick(Sender: TObject);
begin
  try
    tcpClient.Host := edtHost.Text;
    tcpClient.Port := StrToIntDef(edtPort.Text, DEFAULT_PORT);
    tcpClient.Connect;
    tcpClient.IOHandler.MaxLineLength := MAX_LINE_LENGTH;

    FClient := TJRPCClient.Create(nil);

    // A persistent channel: a reader thread reads every line the server
    // writes - the notifications and the answers alike - and the client sorts
    // them out: an answer completes the call with its id, a notification goes
    // to OnNotification.
    FClient.Transport := TIndyLineTransport.Create(tcpClient, MAX_LINE_LENGTH);

    // The handlers run on the reader, in the order the lines arrive: a
    // notification is handled before the answer that follows it is read. Fine
    // here, since no handler calls the server back and waits.
    FClient.DispatchMode := TJRPCDispatchMode.Direct;

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

    // What the server sends while job/run is still running. The notification
    // is freed when the handler returns: read it here, leave the UI to the
    // main thread.
    FClient.OnNotification :=
      procedure (const ANotification: TJRPCNotification)
      var
        LStep: Integer;
        LSteps: Integer;
      begin
        if ANotification.Method <> 'job/progress' then
          Exit;

        LStep := ANotification.Params.GetValue<Integer>('step');
        LSteps := ANotification.Params.GetValue<Integer>('of');
        TThread.Queue(nil,
          procedure
          begin
            ShowProgress(LStep, LSteps);
          end);
      end;

    FClient.OnError :=
      procedure (AError: Exception; var AAction: TJRPCErrorAction)
      begin
        Log('!!! ' + AError.Message);
      end;

    // The server went away: tidy up on the main thread.
    FClient.OnClose :=
      procedure (const AInfo: TJRPCCloseInfo)
      var
        LReason: string;
      begin
        if AInfo.Kind = TJRPCCloseKind.Local then
          Exit;

        LReason := AInfo.Reason;
        TThread.Queue(nil,
          procedure
          begin
            Log('*** connection closed: ' + LReason);
            ShutdownConnection;
          end);
      end;

    FClient.Open;
    Log(Format('*** connected to %s:%d', [tcpClient.Host, tcpClient.Port]));
  except
    on E: Exception do
    begin
      Log('!!! cannot connect: ' + E.Message);
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
    // Fails the call still waiting, if any, and joins the reader.
    FClient.Close;
    FreeAndNil(FClient);
  end;

  try
    if tcpClient.Connected then
      tcpClient.Disconnect;
  except
    // The server may have dropped the socket already.
    on E: Exception do
      Log('!!! disconnect: ' + E.Message);
  end;

  UpdateUI;
end;

procedure TClientForm.btnRunClick(Sender: TObject);
var
  LSteps: Integer;
begin
  LSteps := StrToIntDef(edtSteps.Text, 10);
  pbJob.Max := LSteps;
  pbJob.Position := 0;
  lblResult.Caption := 'running...';

  // Sends the request and returns at once with a handle to the call: the UI
  // stays free while the server works, and the notifications move the bar.
  // The timer picks up the result once the call completes.
  FCall := FClient.ExecuteAsync<string>(TJRPCRequestBuilder.New
    .SetMethod('job/run')
    .AddNamedParam('steps', LSteps)
    .AddNamedParam('stepTime', StrToIntDef(edtStepTime.Text, 500)));
  tmrCall.Enabled := True;

  UpdateUI;
end;

procedure TClientForm.ShowProgress(AStep, ASteps: Integer);
begin
  pbJob.Max := ASteps;
  pbJob.Position := AStep;
  lblResult.Caption := Format('step %d of %d', [AStep, ASteps]);
end;

procedure TClientForm.tmrCallTimer(Sender: TObject);
var
  LText: string;
begin
  if not Assigned(FCall) or not FCall.Completed then
    Exit;

  tmrCall.Enabled := False;

  // The progress queued by the notifications that came before the answer,
  // shown first: the bar reaches its end, then the result appears.
  CheckSynchronize;

  try
    LText := FCall.Value;
    Log('=== result: ' + LText);
  except
    // An error answer, or a connection that closed before the answer came.
    on E: Exception do
    begin
      LText := 'failed: ' + E.Message;
      Log('=== ' + LText);
    end;
  end;
  FCall := nil;

  lblResult.Caption := LText;
  UpdateUI;
end;

end.
