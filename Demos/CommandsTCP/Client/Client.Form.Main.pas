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
///   The client half: builds a JSON-RPC request with TJRPCRequest, writes it
///   as one line, reads one line back. Calls are synchronous - write, read,
///   done - which is the whole point of this demo. See README.md.
/// </summary>
unit Client.Form.Main;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes,
  System.Rtti, System.JSON, System.IOUtils,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls, Vcl.ExtCtrls,
  IdBaseComponent, IdComponent, IdTCPConnection, IdTCPClient, IdGlobal, IdException,

  JRPC.Core;

const
  MAX_LINE_LENGTH = 1024 * 1024;
  READ_TIMEOUT_MS = 5000;

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
    FLastId: Integer;
    procedure Log(const AText: string);
    procedure UpdateUI;
    /// <summary>Writes one line, reads one line, logs both.</summary>
    function SendLine(const AJSON: string): string;
    /// <summary>Builds a request with no parameters and sends it.</summary>
    procedure CallSimple(const AMethod: string);
  end;

var
  ClientForm: TClientForm;

implementation

{$R *.dfm}

{ TClientForm }

procedure TClientForm.FormCreate(Sender: TObject);
begin
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

function TClientForm.SendLine(const AJSON: string): string;
begin
  Result := '';
  if not tcpClient.Connected then
  begin
    Log('!!! not connected');
    Exit;
  end;

  Log('--> ' + AJSON);
  try
    tcpClient.IOHandler.WriteLn(AJSON, IndyTextEncoding_UTF8);
    Result := tcpClient.IOHandler.ReadLn(IndyTextEncoding_UTF8);

    if tcpClient.IOHandler.ReadLnTimedout then
      Log('!!! timed out waiting for the answer')
    else
      Log('<-- ' + Result);
  except
    on E: Exception do
    begin
      Log(Format('!!! %s: %s', [E.ClassName, E.Message]));
      if not tcpClient.Connected then
        UpdateUI;
    end;
  end;
end;

procedure TClientForm.CallSimple(const AMethod: string);
var
  LRequest: TJRPCRequest;
begin
  LRequest := TJRPCRequest.Create;
  try
    Inc(FLastId);
    LRequest.Id := FLastId;
    LRequest.Method := AMethod;
    SendLine(LRequest.ToJson);
  finally
    LRequest.Free;
  end;
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
  CallSimple('ping');
end;

procedure TClientForm.btnInfoClick(Sender: TObject);
begin
  CallSimple('sys/info');
end;

procedure TClientForm.btnTimeClick(Sender: TObject);
begin
  CallSimple('sys/time');
end;

procedure TClientForm.btnEchoClick(Sender: TObject);
var
  LRequest: TJRPCRequest;
begin
  LRequest := TJRPCRequest.Create;
  try
    Inc(FLastId);
    LRequest.Id := FLastId;
    LRequest.Method := 'echo';
    // AddNamedParam builds the "params" object for us.
    LRequest.AddNamedParam('text', edtEcho.Text);
    SendLine(LRequest.ToJson);
  finally
    LRequest.Free;
  end;
end;

procedure TClientForm.btnDirClick(Sender: TObject);
var
  LRequest: TJRPCRequest;
begin
  LRequest := TJRPCRequest.Create;
  try
    Inc(FLastId);
    LRequest.Id := FLastId;
    LRequest.Method := 'dir/list';
    // Every parameter is required: a missing one is -32602, not a default.
    LRequest.AddNamedParam('path', edtPath.Text);
    LRequest.AddNamedParam('mask', edtMask.Text);
    SendLine(LRequest.ToJson);
  finally
    LRequest.Free;
  end;
end;

procedure TClientForm.btnSendRawClick(Sender: TObject);
begin
  // Anything typed here goes out untouched: handy for provoking -32700,
  // -32600 and -32601 by hand.
  if Trim(edtRaw.Text) <> '' then
    SendLine(edtRaw.Text);
end;

procedure TClientForm.btnClearClick(Sender: TObject);
begin
  memoLog.Clear;
end;

end.
