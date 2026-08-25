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
program JRPCExample;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,

  JRPCExample.Api in 'JRPCExample.Api.pas',
  JRPCExample.Main in 'JRPCExample.Main.pas';

begin
  // Reports leaked objects on shutdown (Debug builds).
  ReportMemoryLeaksOnShutdown := True;
  TExampleRunner.Run;
end.
