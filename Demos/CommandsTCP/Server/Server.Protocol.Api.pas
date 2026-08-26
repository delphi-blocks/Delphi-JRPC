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
///   The commands the TCP server exposes. Every command is a plain Delphi
///   method: [JRPCMethod] gives it its JSON-RPC name, [JRPCParam] names its
///   arguments, and the result - a string, an integer, an object, an array of
///   objects - is serialized by Neon. See README.md.
///
///   Every command below runs on an Indy connection thread, concurrently with
///   the other connections: the commands here are pure functions over their
///   parameters, which is what keeps the server lock-free. Before reaching for
///   a dataset, a singleton or a class var, read the thread-safety note in
///   TServerForm.tcpServerExecute.
/// </summary>
unit Server.Protocol.Api;

interface

uses
  System.Classes, System.SysUtils, System.IOUtils, System.DateUtils,

  Neon.Core.Attributes,
  Neon.Core.Persistence,

  JRPC.Core;

type
  /// <summary>Result of "sys/info": a snapshot of the running server.</summary>
  TServerInfo = class
  private
    FHost: string;
    FOS: string;
    FCpuCount: Integer;
    FServerVersion: string;
    FUptimeSec: Int64;
  public
    property Host: string read FHost write FHost;
    [NeonProperty('os')]
    property OS: string read FOS write FOS;
    property CpuCount: Integer read FCpuCount write FCpuCount;
    property ServerVersion: string read FServerVersion write FServerVersion;
    property UptimeSec: Int64 read FUptimeSec write FUptimeSec;
  end;

  /// <summary>One entry of a "dir/list" result.</summary>
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

  TBasicApi = class
  public
    [JRPCMethod('ping')]
    function Ping: string;

    [JRPCMethod('echo')]
    function Echo([JRPCParam('text')] const text: string): string;

    [JRPCMethod('sys/info')]
    function Info: TServerInfo;

    [JRPCMethod('sys/time')]
    function Time: string;

    [JRPCMethod('dir/list')]
    function List([JRPCParam('path')] const path: string;
      [JRPCParam('mask')] const mask: string): TArray<TDirEntry>;
  end;

implementation

var
  GStartedAt: TDateTime;

{ TBasicApi }

function TBasicApi.Ping: string;
begin
  Result := 'pong';
end;

function TBasicApi.Echo(const text: string): string;
begin
  Result := text;
end;

function TBasicApi.Info: TServerInfo;
begin
  // The result is handed to the request garbage collector: it is freed once
  // the response has been serialized, so nothing is freed here.
  Result := TServerInfo.Create;
  Result.Host := GetEnvironmentVariable('COMPUTERNAME');
  Result.OS := TOSVersion.ToString;
  Result.CpuCount := TThread.ProcessorCount;
  Result.ServerVersion := '1.0.0';
  Result.UptimeSec := SecondsBetween(Now, GStartedAt);
end;

function TBasicApi.Time: string;
begin
  Result := DateToISO8601(Now);
end;

function TBasicApi.List(const path: string; const mask: string): TArray<TDirEntry>;
var
  LRec: TSearchRec;
  LEntry: TDirEntry;
begin
  Result := nil;

  // A command reports a failure by raising: EJRPCException carries its message
  // into error.message and maps to -32603. No exception class of our own.
  if not TDirectory.Exists(path) then
    raise EJRPCException.CreateFmt('Path not found: %s', [path]);

  if FindFirst(TPath.Combine(path, mask), faAnyFile, LRec) <> 0 then
    Exit;
  try
    repeat
      if (LRec.Attr and faDirectory) <> 0 then
        Continue;

      LEntry := TDirEntry.Create;
      LEntry.Name := LRec.Name;
      LEntry.Size := LRec.Size;
      LEntry.Modified := DateToISO8601(LRec.TimeStamp);

      // The items are collected too: the garbage collector walks the array.
      Result := Result + [LEntry];
    until FindNext(LRec) <> 0;
  finally
    FindClose(LRec);
  end;
end;

initialization
  GStartedAt := Now;

  TJRPCRegistry.Instance.RegisterClass(TBasicApi, TNeonConfiguration.Camel);

end.
