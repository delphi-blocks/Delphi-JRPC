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
unit JRPCDemo.Api;

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
  end;

  /// <summary>Object results under the "object" path (default Neon casing).</summary>
  [JRPCPath('object')]
  TObjectApi = class
  public
    [JRPCMethod('person')]
    function GetPerson: TPerson;
  end;

  /// <summary>
  ///   Same API, registered with a CamelCase Neon configuration: the same class
  ///   shape is serialized with different JSON keys (see the demo runner).
  /// </summary>
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
  ///   Context injection demo: [Context]-annotated fields receive per-request
  ///   data - the request being processed and the garbage collector, which
  ///   owns every request-scoped object (including this instance itself).
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
  ///   Custom separator demo: methods are addressed as "custom.hello" instead
  ///   of the default "custom/hello".
  /// </summary>
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
  // [Context] Request is injected with the request being processed.
  Result := 'request=' + Request.Method;

  // [Context] FGC is the garbage collector for request-scoped objects: the
  // list below is registered with it and freed automatically when the request
  // is done, without any manual Free here.
  var LScoped := TStringList.Create;
  FGC.Add(LScoped);
  LScoped.Add('this list is freed automatically after the request');
end;

{ TCustomSeparatorApi }

function TCustomSeparatorApi.Hello: string;
begin
  Result := 'hello from custom separator';
end;

initialization
  // TObjectApi and TCamelApi share the same implementation but are registered
  // with different Neon configurations to show per-class serialization.
  TJRPCRegistry.Instance.RegisterClass(TMathApi);
  TJRPCRegistry.Instance.RegisterClass(TObjectApi);
  TJRPCRegistry.Instance.RegisterClass(TCamelApi, TNeonConfiguration.Camel);
  TJRPCRegistry.Instance.RegisterClass(TGreetApi);
  TJRPCRegistry.Instance.RegisterClass(TContextApi);
  TJRPCRegistry.Instance.RegisterClass(TCustomSeparatorApi);

end.
