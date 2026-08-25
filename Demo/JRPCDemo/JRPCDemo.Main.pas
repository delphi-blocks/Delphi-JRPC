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
unit JRPCDemo.Main;

interface

uses
  System.SysUtils, System.JSON,

  JRPC.Classes,
  JRPC.Core,
  JRPC.Server;

type
  /// <summary>
  ///   Runs a set of JSON-RPC scenarios against TJRPCServer and reports
  ///   PASS/FAIL for every assertion. The process exit code is the number of
  ///   failed assertions (0 = all green).
  /// </summary>
  TJRPCDemoRunner = class
  public
    class function Run: Integer;
  end;

implementation

uses
  Logify,
  Logify.Adapter.Console,

  JRPCDemo.Api;

var
  GPassed: Integer = 0;
  GFailed: Integer = 0;

procedure Check(ACondition: Boolean; const AMessage: string);
begin
  if ACondition then
  begin
    Inc(GPassed);
    Writeln('  PASS: ' + AMessage);
  end
  else
  begin
    Inc(GFailed);
    Writeln('  FAIL: ' + AMessage);
  end;
end;

/// <summary>Runs a raw JSON-RPC request through the server and prints it.</summary>
function Send(AServer: TJRPCServer; const ARequest: string): string;
begin
  Writeln;
  Writeln('>>> ' + ARequest);
  Result := AServer.ProcessRequest(ARequest);
  if Result = '' then
    Writeln('<<< (no response)')
  else
    Writeln('<<< ' + Result);
end;

/// <summary>Returns the response parsed as an object, or nil when it is not one.</summary>
function AsObject(const AResponse: string): TJSONObject;
var
  LValue: TJSONValue;
begin
  Result := nil;
  LValue := TJSONObject.ParseJSONValue(AResponse);
  if Assigned(LValue) and (LValue is TJSONObject) then
    Result := LValue as TJSONObject
  else
    LValue.Free;
end;

/// <summary>Parses a response and returns its "result" member as text ('' if absent).</summary>
function ResultAsString(const AResponse: string): string;
var
  LObj: TJSONObject;
  LRes: TJSONValue;
begin
  Result := '';
  LObj := AsObject(AResponse);
  if Assigned(LObj) then
  try
    LRes := LObj.GetValue('result');
    if Assigned(LRes) then
      Result := LRes.Value;
  finally
    LObj.Free;
  end;
end;

/// <summary>Returns the JSON-RPC error code of a response, or MaxInt when there is none.</summary>
function ErrorCodeOf(const AResponse: string): Integer;
var
  LObj: TJSONObject;
  LErr: TJSONValue;
begin
  Result := MaxInt;
  LObj := AsObject(AResponse);
  if Assigned(LObj) then
  try
    LErr := LObj.GetValue('error');
    if Assigned(LErr) and (LErr is TJSONObject) then
    begin
      LErr := TJSONObject(LErr).GetValue('code');
      if Assigned(LErr) then
        Result := StrToInt(LErr.Value);
    end;
  finally
    LObj.Free;
  end;
end;

/// <summary>Returns the "id" member of a response as text ('' when absent).</summary>
function IdAsString(const AResponse: string): string;
var
  LObj: TJSONObject;
  LId: TJSONValue;
begin
  Result := '';
  LObj := AsObject(AResponse);
  if Assigned(LObj) then
  try
    LId := LObj.GetValue('id');
    if Assigned(LId) then
      Result := LId.Value;
  finally
    LObj.Free;
  end;
end;

/// <summary>True when the response is a JSON array with ACount elements.</summary>
function IsArrayOfSize(const AResponse: string; ACount: Integer): Boolean;
var
  LValue: TJSONValue;
begin
  Result := False;
  LValue := TJSONObject.ParseJSONValue(AResponse);
  try
    if Assigned(LValue) and (LValue is TJSONArray) then
      Result := (LValue as TJSONArray).Count = ACount;
  finally
    LValue.Free;
  end;
end;

/// <summary>True when the response carries an "id": null member.</summary>
function HasNullId(const AResponse: string): Boolean;
var
  LObj: TJSONObject;
  LId: TJSONValue;
begin
  Result := False;
  LObj := AsObject(AResponse);
  if Assigned(LObj) then
  try
    LId := LObj.GetValue('id');
    Result := Assigned(LId) and (LId is TJSONNull);
  finally
    LObj.Free;
  end;
end;

class function TJRPCDemoRunner.Run: Integer;
var
  LServer: TJRPCServer;
  LResponse: string;
  LMatcher: TRouteMatcher;
begin
  Writeln('============================================');
  Writeln('  JRPC Demo');
  Writeln('  JSON-RPC 2.0 standalone server');
  Writeln('============================================');

  // Hook the [PERF] TStopwatch instrumentation into the console. The library
  // logs at Debug level through Logify; without a registered adapter nothing
  // is shown, so the demo installs a console adapter to display the timing
  // lines between the request/response pairs.
  TLoggerAdapterRegistry.Instance.RegisterFactory(
    TLogifyAdapterConsoleFactory.CreateAdapterFactory('JRPC Demo', TLogLevel.Debug));

  LServer := TJRPCServer.Create(nil);
  try
    { 1. Named parameters }
    Writeln;
    Writeln('[1] Named parameters');
    LResponse := Send(LServer,
      '{"jsonrpc":"2.0","id":1,"method":"math/sum","params":{"a":2,"b":40}}');
    Check(ResultAsString(LResponse) = '42', 'sum(2, 40) = 42');
    Check(IdAsString(LResponse) = '1', 'id echoed as 1');

    { 2. Positional parameters + string id }
    Writeln;
    Writeln('[2] Positional parameters, string id');
    LResponse := Send(LServer,
      '{"jsonrpc":"2.0","id":"two","method":"math/sum","params":[10,32]}');
    Check(ResultAsString(LResponse) = '42', 'sum(10, 32) = 42');
    Check(IdAsString(LResponse) = 'two', 'string id echoed');

    { 3. String parameters }
    Writeln;
    Writeln('[3] String parameters');
    LResponse := Send(LServer,
      '{"jsonrpc":"2.0","id":3,"method":"math/concat",' +
      '"params":{"left":"JRPC","right":"-Delphi"}}');
    Check(ResultAsString(LResponse) = 'JRPC-Delphi', 'concat works');

    { 4. Notification: no response at all }
    Writeln;
    Writeln('[4] Notification (no response)');
    LResponse := Send(LServer,
      '{"jsonrpc":"2.0","method":"math/sum","params":{"a":1,"b":1}}');
    Check(LResponse = '', 'notification produces no response');

    { 5. Batch of requests and notifications }
    Writeln;
    Writeln('[5] Batch (request + notification + request)');
    LResponse := Send(LServer,
      '[' +
      '{"jsonrpc":"2.0","id":4,"method":"math/sum","params":{"a":1,"b":1}},' +
      '{"jsonrpc":"2.0","method":"math/sum","params":{"a":9,"b":9}},' +
      '{"jsonrpc":"2.0","id":5,"method":"math/concat",' +
      '  "params":{"left":"foo","right":"bar"}}' +
      ']');
    Check(IsArrayOfSize(LResponse, 2), 'batch answered with 2 responses');
    Check(ResultAsString(LResponse) = '', 'batch array has no scalar result member');

    { 6. Batch containing an invalid element }
    Writeln;
    Writeln('[6] Batch with an invalid element');
    LResponse := Send(LServer,
      '[' +
      '{"jsonrpc":"2.0","id":6,"method":"math/sum","params":[1,2]},' +
      '42,' +
      '{"jsonrpc":"2.0","id":7,"method":"math/sum","params":[3,4]}' +
      ']');
    Check(IsArrayOfSize(LResponse, 3), 'invalid element gets its own response');

    { 7. Method not found }
    Writeln;
    Writeln('[7] Method not found');
    LResponse := Send(LServer,
      '{"jsonrpc":"2.0","id":8,"method":"math/nope","params":{}}');
    Check(ErrorCodeOf(LResponse) = JRPC_METHOD_NOT_FOUND, 'error code -32601');

    { 8. Invalid parameter type }
    Writeln;
    Writeln('[8] Invalid parameter type');
    LResponse := Send(LServer,
      '{"jsonrpc":"2.0","id":9,"method":"math/sum","params":{"a":"x","b":1}}');
    Check(ErrorCodeOf(LResponse) = JRPC_INVALID_PARAMS, 'error code -32602');

    { 9. Missing parameter }
    Writeln;
    Writeln('[9] Missing parameter');
    LResponse := Send(LServer,
      '{"jsonrpc":"2.0","id":10,"method":"math/sum","params":{"a":5}}');
    Check(ErrorCodeOf(LResponse) = JRPC_INVALID_PARAMS, 'error code -32602');

    { 10. Parse error: malformed JSON }
    Writeln;
    Writeln('[10] Parse error (malformed JSON)');
    LResponse := Send(LServer, 'this is not json');
    Check(ErrorCodeOf(LResponse) = JRPC_PARSE_ERROR, 'error code -32700');
    Check(HasNullId(LResponse), 'parse error carries a null id');

    { 11. Invalid request: valid JSON that is not a Request }
    Writeln;
    Writeln('[11] Invalid request (scalar JSON)');
    LResponse := Send(LServer, '42');
    Check(ErrorCodeOf(LResponse) = JRPC_INVALID_REQUEST, 'error code -32600');
    Check(HasNullId(LResponse), 'invalid request carries a null id');

    { 12. Object result }
    Writeln;
    Writeln('[12] Object result (default Neon casing)');
    LResponse := Send(LServer,
      '{"jsonrpc":"2.0","id":11,"method":"object/person"}');
    Check(Pos('"Name":"Paolo"', LResponse) > 0, 'object serialized with PascalCase keys');

    { 13. Object result with a per-class CamelCase Neon config }
    Writeln;
    Writeln('[13] Object result (per-class CamelCase Neon config)');
    LResponse := Send(LServer,
      '{"jsonrpc":"2.0","id":12,"method":"camel/person"}');
    Check(Pos('"name":"Paolo"', LResponse) > 0, 'object serialized with camelCase keys');

    { 14. Whole-params object ([JRPCParams]) }
    Writeln;
    Writeln('[14] Whole-params object ([JRPCParams])');
    LResponse := Send(LServer,
      '{"jsonrpc":"2.0","id":13,"method":"greet/hello",' +
      '"params":{"Salutation":"Hello","Name":"World"}}');
    Check(ResultAsString(LResponse) = 'Hello, World!', 'greeting object deserialized');

    { 15. Enum parameter (by name) }
    Writeln;
    Writeln('[15] Enum parameter');
    LResponse := Send(LServer,
      '{"jsonrpc":"2.0","id":14,"method":"math/apply",' +
      '"params":{"op":"opMultiply","a":6,"b":7}}');
    Check(ResultAsString(LResponse) = '42', 'enum parsed by name, 6 * 7 = 42');

    { 16. Null id round-trip }
    Writeln;
    Writeln('[16] Null id round-trip');
    LResponse := Send(LServer,
      '{"jsonrpc":"2.0","id":null,"method":"math/sum","params":[20,22]}');
    Check(ResultAsString(LResponse) = '42', 'result computed for null-id request');
    Check(HasNullId(LResponse), 'response echoes "id": null');

    { 17. Context injection + garbage collector }
    Writeln;
    Writeln('[17] Context injection and garbage collection');
    TContextApi.Destroyed := False;
    LResponse := Send(LServer,
      '{"jsonrpc":"2.0","id":15,"method":"ctx/method"}');
    Check(ResultAsString(LResponse) = 'request=ctx/method', 'request injected via [Context]');
    Check(TContextApi.Destroyed, 'API instance freed by the request garbage collector');

    { 18. Custom separator tag }
    Writeln;
    Writeln('[18] Custom separator (separator=.)');
    LResponse := Send(LServer,
      '{"jsonrpc":"2.0","id":16,"method":"custom.hello"}');
    Check(ResultAsString(LResponse) = 'hello from custom separator', 'custom.hello dispatched');

    { 19. TRouteMatcher utility }
    Writeln;
    Writeln('[19] TRouteMatcher');
    LMatcher := TRouteMatcher.Create;
    try
      Check(LMatcher.Match('/users/{id}', '/users/42'), 'template matched');
      Check(LMatcher.Params['id'] = '42', 'parameter extracted and URL-decoded');
      Check(not LMatcher.Match('/users/{id}', '/orders/42'), 'non-matching route rejected');
    finally
      LMatcher.Free;
    end;
  finally
    LServer.Free;
  end;

  Writeln;
  Writeln('============================================');
  Writeln(Format('  Results: %d passed, %d failed', [GPassed, GFailed]));
  Writeln('============================================');
  Result := GFailed;
end;

end.
