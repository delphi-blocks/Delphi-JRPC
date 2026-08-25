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
unit JRPCExample.Main;

interface

uses
  System.SysUtils,

  JRPC.Server;

type
  /// <summary>
  ///   Runs a guided showcase of an example JSON-RPC API, then drops into an
  ///   interactive mode where any request can be typed and answered.
  /// </summary>
  TExampleRunner = class
  public
    class procedure Run;
  end;

implementation

uses
  JRPC.Classes,
  JRPC.Core,

  JRPCExample.Api;

procedure Showcase(AServer: TJRPCServer);

  procedure Example(const AComment, ARequest: string);
  var
    LResponse: string;
  begin
    Writeln;
    Writeln('-- ' + AComment);
    Writeln('>>> ' + ARequest);
    LResponse := AServer.ProcessRequest(ARequest);
    if LResponse = '' then
      Writeln('<<< (no response)')
    else
      Writeln('<<< ' + LResponse);
  end;

begin
  Writeln('== Guided showcase =====================================');

  Example('create a note (whole object via [JRPCParams], camelCase keys)',
    '{"jsonrpc":"2.0","id":1,"method":"notes/create",' +
    '"params":{"title":"Buy milk","body":"Also eggs",' +
    '"tags":["errands","home"],"priority":"High"}}');

  Example('create a second note',
    '{"jsonrpc":"2.0","id":2,"method":"notes/create",' +
    '"params":{"title":"Read the JRPC docs","body":"Chapter 1",' +
    '"tags":["learning"],"priority":"Normal"}}');

  Example('list all notes (array result)',
    '{"jsonrpc":"2.0","id":3,"method":"notes/list"}');

  Example('get a note by id (named parameter)',
    '{"jsonrpc":"2.0","id":4,"method":"notes/get","params":{"id":1}}');

  Example('get a missing note (application error, mapped to -32603)',
    '{"jsonrpc":"2.0","id":5,"method":"notes/get","params":{"id":999}}');

  Example('missing parameter (invalid params, -32602)',
    '{"jsonrpc":"2.0","id":6,"method":"notes/get","params":{}}');

  Example('delete a note (string result)',
    '{"jsonrpc":"2.0","id":7,"method":"notes/delete","params":{"id":2}}');

  Example('count notes',
    '{"jsonrpc":"2.0","id":8,"method":"notes/count"}');

  Example('a notification: the server never answers it',
    '{"jsonrpc":"2.0","method":"notes/ping"}');

  Example('custom separator section: utils.uppercase (dot instead of slash)',
    '{"jsonrpc":"2.0","id":9,"method":"utils.uppercase",' +
    '"params":{"text":"hello JRPC"}}');

  Example('custom separator section: utils.timestamp',
    '{"jsonrpc":"2.0","id":10,"method":"utils.timestamp"}');

  Example('object result with a per-class CamelCase Neon config',
    '{"jsonrpc":"2.0","id":11,"method":"profile/get"}');

  Example('context injection: session/whoami sees the current request',
    '{"jsonrpc":"2.0","id":12,"method":"session/whoami"}');

  Example('unknown method (method not found, -32601)',
    '{"jsonrpc":"2.0","id":13,"method":"notes/nope"}');
end;

procedure Interactive(AServer: TJRPCServer);
var
  LRequest: string;
  LResponse: string;
begin
  Writeln;
  Writeln('== Interactive mode =====================================');
  Writeln('Type a JSON-RPC request and press Enter (empty line to quit).');
  Writeln;
  while True do
  begin
    Write('>>> ');
    Readln(LRequest);
    if LRequest.Trim = '' then
      Break;
    LResponse := AServer.ProcessRequest(LRequest);
    if LResponse = '' then
      Writeln('<<< (no response)')
    else
      Writeln('<<< ' + LResponse);
  end;
end;

class procedure TExampleRunner.Run;
var
  LServer: TJRPCServer;
begin
  Writeln('============================================');
  Writeln('  JRPC Example - a JSON-RPC 2.0 API');
  Writeln('============================================');

  LServer := TJRPCServer.Create(nil);
  try
    Showcase(LServer);
    Interactive(LServer);
  finally
    LServer.Free;
    // Release the example store before the shutdown leak check runs.
    TNotesApi.Shutdown;
  end;

  Writeln;
  Writeln('Bye.');
end;

end.
