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
unit JRPC.Tests.Api;

interface

uses
  System.Classes, System.SysUtils,

  Neon.Core.Persistence,

  JRPC.Classes,
  JRPC.Core;

type
  /// <summary>An operation selector, serialized by name as a JSON string.</summary>
  TOperation = (opAdd, opMultiply);

  /// <summary>A plain object returned as a JSON object result.</summary>
  TPerson = class
  private
    FName: string;
    FAge: Integer;
  public
    property Name: string read FName write FName;
    property Age: Integer read FAge write FAge;
  end;

  /// <summary>An object passed whole to a method through [JRPCParams].</summary>
  TGreeting = class
  private
    FSalutation: string;
    FName: string;
  public
    property Salutation: string read FSalutation write FSalutation;
    property Name: string read FName write FName;
  end;

  /// <summary>Arithmetic and string helpers under the "math" path.</summary>
  [JRPCPath('math')]
  TMathApi = class
  public
    [JRPCMethod('sum')]
    function Sum([JRPCParam('a')] const a: Integer; [JRPCParam('b')] const b: Integer): Integer;

    [JRPCMethod('concat')]
    function Concat([JRPCParam('left')] const left: string;
      [JRPCParam('right')] const right: string): string;

    [JRPCMethod('apply')]
    function Apply([JRPCParam('op')] const op: TOperation;
      [JRPCParam('a')] const a: Integer; [JRPCParam('b')] const b: Integer): Integer;

    [JRPCMethod('notif'), JRPCNotificationAttribute]
    function Notif([JRPCParam('a')] const a: Integer; [JRPCParam('b')] const b: Integer): Integer;
  end;

  /// <summary>Object results under the "object" path (default Neon casing).</summary>
  [JRPCPath('object')]
  TObjectApi = class
  public
    [JRPCMethod('person')]
    function GetPerson: TPerson;
  end;

  /// <summary>Same API registered with a CamelCase Neon configuration.</summary>
  [JRPCPath('camel')]
  TCamelApi = class
  public
    [JRPCMethod('person')]
    function GetPerson: TPerson;
  end;

  /// <summary>Whole-params object under the "greet" path.</summary>
  [JRPCPath('greet')]
  TGreetApi = class
  public
    [JRPCMethod('hello')]
    function Hello([JRPCParams] const greeting: TGreeting): string;
  end;

  /// <summary>
  ///   Context injection: [Context] fields receive the request and the
  ///   garbage collector; the instance is owned by the server.
  /// </summary>
  [JRPCPath('ctx')]
  TContextApi = class
  private
    [Context] FGC: IGarbageCollector;
    [Context] Request: TJRPCRequest;
  public
    class var Destroyed: Boolean;

    destructor Destroy; override;

    [JRPCMethod('method')]
    function GetRequestMethod: string;
  end;

  /// <summary>
  ///   Flat class: the empty path means the methods declare the full JSON-RPC
  ///   method name themselves ("tools/list", "tools/call", "ping").
  /// </summary>
  [JRPCPath('')]
  TFlatApi = class
  public
    [JRPCMethod('tools/list')]
    function ToolsList: string;

    [JRPCMethod('tools/call')]
    function ToolsCall([JRPCParam('name')] const name: string): string;

    [JRPCMethod('ping')]
    function Ping: string;
  end;

  /// <summary>
  ///   No attribute at all: same as a flat class, since the class carries no
  ///   path prefix. Registration is explicit, so nothing has to be declared.
  /// </summary>
  TBareApi = class
  public
    [JRPCMethod('status/get')]
    function StatusGet: string;

    [JRPCMethod('version')]
    function Version: string;
  end;

  /// <summary>Custom separator demo: methods are addressed as "custom.hello".</summary>
  [JRPCPath('custom', 'separator=.')]
  TCustomSeparatorApi = class
  public
    [JRPCMethod('hello')]
    function Hello: string;
  end;

implementation

{ TMathApi }

function TMathApi.Apply(const op: TOperation; const a, b: Integer): Integer;
begin
  case op of
    opAdd:      Result := a + b;
    opMultiply: Result := a * b;
  else
    Result := 0;
  end;
end;

function TMathApi.Concat(const left, right: string): string;
begin
  Result := left + right;
end;

function TMathApi.Notif(const a, b: Integer): Integer;
begin
  Result := a + b;
end;

function TMathApi.Sum(const a, b: Integer): Integer;
begin
  Result := a + b;
end;

{ TObjectApi }

function TObjectApi.GetPerson: TPerson;
begin
  Result := TPerson.Create;
  Result.Name := 'Paolo';
  Result.Age := 42;
end;

{ TCamelApi }

function TCamelApi.GetPerson: TPerson;
begin
  Result := TPerson.Create;
  Result.Name := 'Paolo';
  Result.Age := 42;
end;

{ TGreetApi }

function TGreetApi.Hello(const greeting: TGreeting): string;
begin
  Result := greeting.Salutation + ', ' + greeting.Name + '!';
end;

{ TContextApi }

destructor TContextApi.Destroy;
begin
  Destroyed := True;
  inherited;
end;

function TContextApi.GetRequestMethod: string;
begin
  Result := 'request=' + Request.Method;

  var LScoped := TStringList.Create;
  FGC.Add(LScoped);
  LScoped.Add('freed automatically with the request');
end;

{ TFlatApi }

function TFlatApi.Ping: string;
begin
  Result := 'pong';
end;

function TFlatApi.ToolsCall(const name: string): string;
begin
  Result := 'called ' + name;
end;

function TFlatApi.ToolsList: string;
begin
  Result := 'tools: list, call';
end;

{ TBareApi }

function TBareApi.StatusGet: string;
begin
  Result := 'status: ok';
end;

function TBareApi.Version: string;
begin
  Result := '1.0.0';
end;

{ TCustomSeparatorApi }

function TCustomSeparatorApi.Hello: string;
begin
  Result := 'hello from custom separator';
end;

initialization
  TJRPCRegistry.Instance.RegisterClass(TMathApi);
  TJRPCRegistry.Instance.RegisterClass(TObjectApi);
  TJRPCRegistry.Instance.RegisterClass(TCamelApi, TNeonConfiguration.Camel);
  TJRPCRegistry.Instance.RegisterClass(TGreetApi);
  TJRPCRegistry.Instance.RegisterClass(TContextApi);
  TJRPCRegistry.Instance.RegisterClass(TCustomSeparatorApi);
  TJRPCRegistry.Instance.RegisterClass(TFlatApi);
  TJRPCRegistry.Instance.RegisterClass(TBareApi);

end.
