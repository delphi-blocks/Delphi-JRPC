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
program JRPCDemo;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,

  JRPCDemo.Api in 'JRPCDemo.Api.pas',
  JRPCDemo.Main in 'JRPCDemo.Main.pas';

begin
  // Reports leaked objects on shutdown (Debug builds) - the demo exercises the
  // garbage collector, so any leak here is a real bug in the library.
  ReportMemoryLeaksOnShutdown := True;
  ExitCode := TJRPCDemoRunner.Run;
  Readln;
end.
