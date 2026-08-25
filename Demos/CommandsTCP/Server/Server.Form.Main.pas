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
///   The transport: an Indy TCP server that reads one JSON-RPC message per
///   line, hands it to TJRPCServer.ProcessRequest and writes the answer back.
///   That is the whole server - the commands live in Server.Api.Commands.
/// </summary>
unit Server.Form.Main;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes,
  System.JSON,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls, Vcl.ExtCtrls,
  IdBaseComponent, IdComponent, IdCustomTCPServer, IdTCPServer, IdContext,
  IdGlobal, IdException,

  JRPC.Server;

const
  /// <summary>PROTOCOL.md: max message size. Indy defaults to 16 KiB.</summary>
  MAX_LINE_LENGTH = 1024 * 1024;
  DEFAULT_PORT = 11099;

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
    procedure Log(const AText: string); overload;
    procedure Log(const AFormat: string; const AArgs: array of const); overload;
    procedure StartServer;
    procedure StopServer;
    procedure UpdateUI;
  end;

var
  ServerForm: TServerForm;

implementation

{$R *.dfm}

uses
  Server.Protocol.Api;

/// <summary>
///   Collapses a response onto a single line.
///
///   TJRPCMessages.ToJson serializes a single response compactly, but a batch
///   goes through TNeon.Print(..., True) and comes back pretty-printed - and a
///   response carrying raw line breaks would break the one-message-per-line
///   framing. Only batches ever pay for the re-parse.
/// </summary>
function CompactJson(const AJSON: string): string;
var
  LValue: TJSONValue;
begin
  if Pos(#10, AJSON) = 0 then
    Exit(AJSON);

  LValue := TJSONObject.ParseJSONValue(AJSON);
  if not Assigned(LValue) then
    Exit(AJSON);
  try
    Result := LValue.ToJSON;
  finally
    LValue.Free;
  end;
end;

{ TServerForm }

procedure TServerForm.FormCreate(Sender: TObject);
begin
  // One TJRPCServer serves every connection: it keeps no per-request state.
  FJRPCServer := TJRPCServer.Create(Self);

  // "Server.exe 9100" overrides the port, which makes the demo scriptable.
  if (ParamCount > 0) and (StrToIntDef(ParamStr(1), 0) > 0) then
    edtPort.Text := ParamStr(1);

  UpdateUI;
end;

procedure TServerForm.FormShow(Sender: TObject);
begin
  StartServer;
end;

procedure TServerForm.FormDestroy(Sender: TObject);
begin
  StopServer;
  // Drain the log entries queued by connection threads while the form is still
  // alive: they would otherwise run against a freed form.
  CheckSynchronize;
end;

procedure TServerForm.Log(const AText: string);
begin
  // Called from the connection threads: Queue, never Synchronize. Stopping the
  // server blocks the main thread until the threads end, and a thread waiting
  // inside Synchronize would deadlock against it.
  TThread.Queue(nil,
    procedure
    begin
      memoLog.Lines.Add(FormatDateTime('hh:nn:ss.zzz', Now) + '  ' + AText);
    end);
end;

procedure TServerForm.Log(const AFormat: string; const AArgs: array of const);
begin
  Log(Format(AFormat, AArgs));
end;

procedure TServerForm.StartServer;
begin
  if tcpServer.Active then
    Exit;

  try
    tcpServer.DefaultPort := StrToIntDef(edtPort.Text, DEFAULT_PORT);
    tcpServer.Active := True;
    Log('listening on port %d', [tcpServer.DefaultPort]);
  except
    on E: Exception do
      Log('cannot listen on port %s: %s', [edtPort.Text, E.Message]);
  end;

  UpdateUI;
end;

procedure TServerForm.StopServer;
begin
  if not tcpServer.Active then
    Exit;

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
  // Indy's ReadLn gives up past MaxLineLength, which defaults to 16 KiB.
  AContext.Connection.IOHandler.MaxLineLength := MAX_LINE_LENGTH;
  Log('connected: %s', [AContext.Binding.PeerIP]);
end;

procedure TServerForm.tcpServerDisconnect(AContext: TIdContext);
begin
  Log('disconnected: %s', [AContext.Binding.PeerIP]);
end;

procedure TServerForm.tcpServerExecute(AContext: TIdContext);
var
  LLine: string;
  LResponse: string;
begin
  LLine := AContext.Connection.IOHandler.ReadLn(IndyTextEncoding_UTF8);

  if LLine.Trim = '' then
    Exit;                                   // empty line: keepalive

  Log('--> %s', [LLine]);

  LResponse := FJRPCServer.ProcessRequest(LLine);

  if LResponse = '' then                    // '' means it was a notification
  begin
    Log('<-- (notification: no response)');
    Exit;
  end;

  LResponse := CompactJson(LResponse);      // a batch answer arrives pretty-printed

  AContext.Connection.IOHandler.WriteLn(LResponse, IndyTextEncoding_UTF8);
  Log('<-- %s', [LResponse]);
end;

end.
