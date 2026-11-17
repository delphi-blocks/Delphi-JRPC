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
///   The line-framed TCP socket of the demo as a persistent channel: one JSON
///   message per line, LF terminated, UTF-8, read on a thread of its own.
/// </summary>
unit Client.Transport;

interface

uses
  System.SysUtils,

  IdTCPClient,

  JRPC.Transport;

type
  /// <summary>
  ///   A persistent channel over a connected TIdTCPClient.
  /// </summary>
  /// <remarks>
  ///   The base class owns the reader thread and serializes the writes; this
  ///   class only reads a line, writes a line and stops reading.
  ///
  ///   The contract asks DoClose to unblock a pending Receive. Disconnecting the
  ///   Indy socket from another thread while ReadLn runs on it is a race, so
  ///   Receive reads with a short timeout instead and DoClose only raises a
  ///   flag: the reader notices it within RECEIVE_POLL_MS. The socket itself is
  ///   left to its owner, which disconnects it once TJRPCClient.Close has
  ///   joined the reader.
  ///
  ///   DoSend and Receive run on different threads at the same time (a caller
  ///   and the reader). Indy keeps the input and output buffers apart, so one
  ///   writer and one reader need no lock; the base class already serializes
  ///   the writers.
  /// </remarks>
  TIndyLineTransport = class(TJRPCPullTransport)
  private
    FClient: TIdTCPClient;
    FMaxLineLength: Integer;
    FClosed: Integer;
    function GetClosed: Boolean;
  protected
    function Receive(out AText: string): Boolean; override;
    procedure DoSend(const AText: string); override;
    procedure DoClose; override;
  public
    constructor Create(AClient: TIdTCPClient; AMaxLineLength: Integer);

    property Closed: Boolean read GetClosed;
  end;

implementation

uses
  System.SyncObjs,

  IdGlobal, IdIOHandler, IdException;

const
  /// <summary>
  ///   How long a single ReadLn waits before checking whether Close was called.
  /// </summary>
  RECEIVE_POLL_MS = 200;

{ TIndyLineTransport }

constructor TIndyLineTransport.Create(AClient: TIdTCPClient; AMaxLineLength: Integer);
begin
  inherited Create;
  FClient := AClient;
  FMaxLineLength := AMaxLineLength;
  FClosed := 0;
end;

function TIndyLineTransport.GetClosed: Boolean;
begin
  Result := TInterlocked.CompareExchange(FClosed, 0, 0) <> 0;
end;

function TIndyLineTransport.Receive(out AText: string): Boolean;
var
  LIOHandler: TIdIOHandler;
begin
  AText := '';
  while not Closed do
  begin
    LIOHandler := FClient.IOHandler;
    if not Assigned(LIOHandler) then
      Exit(False);

    try
      AText := LIOHandler.ReadLn(LF, RECEIVE_POLL_MS, FMaxLineLength, IndyTextEncoding_UTF8);
    except
      // The server went away: that is the end of the stream, not an error.
      on E: EIdConnClosedGracefully do
        Exit(False);
      on E: Exception do
      begin
        if Closed then
          Exit(False);
        raise;
      end;
    end;

    // A timeout only means "nothing yet": loop, and look at the flag again.
    if LIOHandler.ReadLnTimedout then
      Continue;

    // An empty line is a keepalive (see README.md, "Framing").
    if AText.Trim = '' then
      Continue;

    Exit(True);
  end;

  Result := False;
end;

procedure TIndyLineTransport.DoSend(const AText: string);
begin
  FClient.IOHandler.WriteLn(AText, IndyTextEncoding_UTF8);
end;

procedure TIndyLineTransport.DoClose;
begin
  TInterlocked.Exchange(FClosed, 1);
end;

end.
