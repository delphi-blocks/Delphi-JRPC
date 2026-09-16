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
///   The client half. TJRPCClient builds the request, correlates the answer
///   and turns an "error" member into an exception; this form only has to say
///   how a line gets to the socket and back, which it does once in FormCreate.
///   Calls are synchronous - write, read, done - which is the whole point of
///   this demo. See README.md.
/// </summary>
unit Client.Form.Main;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes,
  System.Rtti, System.JSON, System.IOUtils,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls, Vcl.ExtCtrls,
  IdBaseComponent, IdComponent, IdTCPConnection, IdTCPClient, IdGlobal, IdException,

  JRPC.Core,
  JRPC.Client;

const
  MAX_LINE_LENGTH = 1024 * 1024;
  READ_TIMEOUT_MS = 5000;

type
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
    pnlTop: TPanel;
    lblHost: TLabel;
    edtHost: TEdit;
    lblPort: TLabel;
    edtPort: TEdit;
    btnConnect: TButton;
    btnDisconnect: TButton;
    lblStatus: TLabel;
    pnlLeft: TPanel;
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
    lblRaw: TLabel;
    edtRaw: TEdit;
    btnSendRaw: TButton;
    btnClear: TButton;
    memoLog: TMemo;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure btnConnectClick(Sender: TObject);
    procedure btnDisconnectClick(Sender: TObject);
    procedure btnPingClick(Sender: TObject);
    procedure btnInfoClick(Sender: TObject);
    procedure btnTimeClick(Sender: TObject);
    procedure btnEchoClick(Sender: TObject);
    procedure btnDirClick(Sender: TObject);
    procedure btnSendRawClick(Sender: TObject);
    procedure btnClearClick(Sender: TObject);
  private
    FJRPCClient: TJRPCClient;
    procedure Log(const AText: string);
    procedure UpdateUI;
    /// <summary>Raises unless the socket is up, so no call starts blind.</summary>
    procedure CheckConnected;
    /// <summary>Logs a failure, telling a server error from a local one.</summary>
    procedure LogError(E: Exception);
  end;

var
  ClientForm: TClientForm;

implementation

{$R *.dfm}

{ TClientForm }

procedure TClientForm.FormCreate(Sender: TObject);
begin
  FJRPCClient := TJRPCClient.Create(Self);

  // The Indy pair *is* the transport: one line out, one line back. This is the
  // only place in the form that touches the socket.
  FJRPCClient.OnTransport :=
    function(const ARequest: string): string
    begin
      CheckConnected;
      tcpClient.IOHandler.WriteLn(ARequest, IndyTextEncoding_UTF8);
      Result := tcpClient.IOHandler.ReadLn(IndyTextEncoding_UTF8);

      if tcpClient.IOHandler.ReadLnTimedout then
        raise EJRPCClientError.Create('timed out waiting for the answer');
    end;

  // A notification must not read: per the spec the server answers nothing at
  // all, so a ReadLn here would block until the timeout.
  FJRPCClient.OnNotify :=
    procedure(const ARequest: string)
    begin
      CheckConnected;
      tcpClient.IOHandler.WriteLn(ARequest, IndyTextEncoding_UTF8);
    end;

  FJRPCClient.OnBeforeSend :=
    procedure(const AJSON: string)
    begin
      Log('--> ' + AJSON);
    end;

  FJRPCClient.OnAfterReceive :=
    procedure(const AJSON: string)
    begin
      Log('<-- ' + AJSON);
    end;

  // One place for every failure, so no handler below repeats the logging.
  // OnError only reports: the exception still leaves the call, and reaches the
  // VCL handler when a button click does not catch it.
  FJRPCClient.OnError :=
    procedure(E: Exception)
    begin
      LogError(E);
    end;

  edtPath.Text := TPath.GetTempPath;
  UpdateUI;
end;

procedure TClientForm.FormDestroy(Sender: TObject);
begin
  if tcpClient.Connected then
    tcpClient.Disconnect;
end;

procedure TClientForm.Log(const AText: string);
begin
  memoLog.Lines.Add(AText);
end;

procedure TClientForm.UpdateUI;
var
  LConnected: Boolean;
begin
  LConnected := tcpClient.Connected;

  btnConnect.Enabled := not LConnected;
  btnDisconnect.Enabled := LConnected;
  edtHost.Enabled := not LConnected;
  edtPort.Enabled := not LConnected;
  pnlLeft.Enabled := LConnected;

  if LConnected then
    lblStatus.Caption := Format('connected to %s:%d', [tcpClient.Host, tcpClient.Port])
  else
    lblStatus.Caption := 'not connected';
end;

procedure TClientForm.CheckConnected;
begin
  if not tcpClient.Connected then
    raise EJRPCClientError.Create('not connected');
end;

procedure TClientForm.LogError(E: Exception);
begin
  // The distinction the old SendLine could not make: the call reached the
  // server and it said no, versus the call never completed.
  if E is EJRPCRemoteError then
    Log(Format('!!! server error %d: %s', [EJRPCRemoteError(E).Code, E.Message]))
  else
    Log(Format('!!! %s: %s', [E.ClassName, E.Message]));

  if not tcpClient.Connected then
    UpdateUI;
end;

procedure TClientForm.btnConnectClick(Sender: TObject);
begin
  try
    tcpClient.Host := edtHost.Text;
    tcpClient.Port := StrToIntDef(edtPort.Text, 8090);
    tcpClient.ReadTimeout := READ_TIMEOUT_MS;
    tcpClient.Connect;
    tcpClient.IOHandler.MaxLineLength := MAX_LINE_LENGTH;
    Log(Format('*** connected to %s:%d', [tcpClient.Host, tcpClient.Port]));
  except
    on E: Exception do
      Log(Format('!!! cannot connect: %s', [E.Message]));
  end;

  UpdateUI;
end;

procedure TClientForm.btnDisconnectClick(Sender: TObject);
begin
  if tcpClient.Connected then
    tcpClient.Disconnect;
  Log('*** disconnected');
  UpdateUI;
end;

procedure TClientForm.btnPingClick(Sender: TObject);
begin
  var LRequest := TJRPCRequestBuilder.New
    .SetMethod('ping');

  Log('    = ' + FJRPCClient.ExecuteAs<string>(LRequest));
end;

procedure TClientForm.btnInfoClick(Sender: TObject);
begin
  var LRequest := TJRPCRequestBuilder.New
    .SetMethod('sys/info');

  Log('    = ' + FJRPCClient.ExecuteAs<string>(LRequest));
end;

procedure TClientForm.btnTimeClick(Sender: TObject);
begin
  var LRequest := TJRPCRequestBuilder.New
    .SetMethod('sys/time');

  Log('    = ' + FJRPCClient.ExecuteAs<string>(LRequest));
end;

procedure TClientForm.btnEchoClick(Sender: TObject);
begin
  var LRequest := TJRPCRequestBuilder.New
    .SetMethod('echo')
    .AddNamedParam('text', edtEcho.Text);

  Log('    = ' + FJRPCClient.ExecuteAs<string>(LRequest));
end;

procedure TClientForm.btnDirClick(Sender: TObject);
var
  LEntries: TArray<TDirEntry>;
  LEntry: TDirEntry;
begin
  var LRequest := TJRPCRequest.Create;
  try
    LRequest.Method := 'dir/list';
    LRequest.AddNamedParam('path', edtPath.Text);
    LRequest.AddNamedParam('mask', edtMask.Text);
    // Every parameter is required: a missing one is -32602, not a default.
    LEntries := FJRPCClient.ExecuteAs<TArray<TDirEntry>>(LRequest);
    try
      for LEntry in LEntries do
        Log(Format('    %-30s %10d  %s', [LEntry.Name, LEntry.Size, LEntry.Modified]));

      if Length(LEntries) = 0 then
        Log('    (no matching file)');
    finally
      for LEntry in LEntries do
        LEntry.Free;
    end;
  finally
    LRequest.Free;
  end;
end;

procedure TClientForm.btnSendRawClick(Sender: TObject);
begin
  // Anything typed here goes out untouched: handy for provoking -32700,
  // -32600 and -32601 by hand. ExecuteRaw skips the building, the parsing and
  // the id check for exactly that reason - so the error comes back as a logged
  // reply rather than through OnError.
  if Trim(edtRaw.Text) = '' then
    Exit;

  FJRPCClient.ExecuteRaw(edtRaw.Text);
end;

procedure TClientForm.btnClearClick(Sender: TObject);
begin
  memoLog.Clear;
end;

end.
