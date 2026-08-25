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
unit JRPC.Tests.Server;

interface

uses
  System.SysUtils, System.JSON,
  DUnitX.TestFramework,

  JRPC.Core;

type
  [TestFixture]
  TJRPCServerTest = class
  public
    [Test] procedure TestProcessRequestNamedParams;
    [Test] procedure TestProcessRequestPositionalParams;
    [Test] procedure TestProcessRequestStringId;
    [Test] procedure TestProcessRequestNotificationNoResponse;
    [Test] procedure TestProcessRequestBatch;
    [Test] procedure TestProcessRequestBatchWithInvalidElement;
    [Test] procedure TestProcessRequestMethodNotFound;
    [Test] procedure TestProcessRequestInvalidParams;
    [Test] procedure TestProcessRequestParseError;
    [Test] procedure TestProcessRequestInvalidRequestScalar;
    [Test] procedure TestProcessRequestNullIdRoundTrip;
    [Test] procedure TestProcessRequestObjectResultPascalCase;
    [Test] procedure TestProcessRequestObjectResultCamelCase;
    [Test] procedure TestProcessRequestContextInjection;
    [Test] procedure TestProcessRequestGarbageCollector;
    [Test] procedure TestProcessRequestCustomSeparator;
    [Test] procedure TestProcessRequestFlatMethod;
    [Test] procedure TestProcessRequestFlatMethodWithParams;
    [Test] procedure TestProcessRequestFlatMethodSingleSegment;
    [Test] procedure TestProcessRequestFlatMethodNotFound;
    [Test] procedure TestProcessRequestFlatCoexistsWithPathClasses;
    [Test] procedure TestProcessRequestNoPathAttribute;
    [Test] procedure TestProcessRequestEmitsPerfLogs;
  end;

implementation

uses
  System.Classes,
  Logify,
  Logify.Adapter.Buffer,

  JRPC.Classes,
  JRPC.Server,
  JRPC.Tests.Api;

{ helpers }

function ParseObject(const AJSON: string): TJSONObject;
var
  LValue: TJSONValue;
begin
  Result := nil;
  LValue := TJSONObject.ParseJSONValue(AJSON);
  if Assigned(LValue) and (LValue is TJSONObject) then
    Result := LValue as TJSONObject
  else
    LValue.Free;
end;

function GetResultValue(const AJSON: string): string;
var
  LObj: TJSONObject;
  LRes: TJSONValue;
begin
  Result := '';
  LObj := ParseObject(AJSON);
  if Assigned(LObj) then
  try
    LRes := LObj.GetValue('result');
    if Assigned(LRes) then
      Result := LRes.Value;
  finally
    LObj.Free;
  end;
end;

function GetBatchResultValue(const AJSON: string; AIndex: Integer): string;
var
  LValue: TJSONValue;
  LArray: TJSONArray;
  LRes: TJSONValue;
begin
  Result := '';
  LValue := TJSONObject.ParseJSONValue(AJSON);
  try
    if not (Assigned(LValue) and (LValue is TJSONArray)) then
      Exit;

    LArray := LValue as TJSONArray;
    if (AIndex < 0) or (AIndex >= LArray.Count) or not (LArray.Items[AIndex] is TJSONObject) then
      Exit;

    LRes := TJSONObject(LArray.Items[AIndex]).GetValue('result');
    if Assigned(LRes) then
      Result := LRes.Value;
  finally
    LValue.Free;
  end;
end;

function ErrorCodeOf(const AJSON: string): Integer;
var
  LObj: TJSONObject;
  LErr: TJSONValue;
begin
  Result := MaxInt;
  LObj := ParseObject(AJSON);
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

function HasNullId(const AJSON: string): Boolean;
var
  LObj: TJSONObject;
  LId: TJSONValue;
begin
  Result := False;
  LObj := ParseObject(AJSON);
  if Assigned(LObj) then
  try
    LId := LObj.GetValue('id');
    Result := Assigned(LId) and (LId is TJSONNull);
  finally
    LObj.Free;
  end;
end;

function IsArrayOfSize(const AJSON: string; ACount: Integer): Boolean;
var
  LValue: TJSONValue;
begin
  Result := False;
  LValue := TJSONObject.ParseJSONValue(AJSON);
  try
    if Assigned(LValue) and (LValue is TJSONArray) then
      Result := (LValue as TJSONArray).Count = ACount;
  finally
    LValue.Free;
  end;
end;

{ TJRPCServerTest }

procedure TJRPCServerTest.TestProcessRequestNamedParams;
var
  LServer: TJRPCServer;
  LResponse: string;
begin
  LServer := TJRPCServer.Create(nil);
  try
    LResponse := LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":1,"method":"math/sum","params":{"a":2,"b":40}}');
    Assert.AreEqual('42', GetResultValue(LResponse));
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestPositionalParams;
var
  LServer: TJRPCServer;
  LResponse: string;
begin
  LServer := TJRPCServer.Create(nil);
  try
    LResponse := LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":1,"method":"math/sum","params":[10,32]}');
    Assert.AreEqual('42', GetResultValue(LResponse));
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestStringId;
var
  LServer: TJRPCServer;
  LResponse: string;
begin
  LServer := TJRPCServer.Create(nil);
  try
    LResponse := LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":"req-1","method":"math/concat",' +
      '"params":{"left":"a","right":"b"}}');
    Assert.AreEqual('ab', GetResultValue(LResponse));
    Assert.IsTrue(LResponse.Contains('"id":"req-1"'), LResponse);
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestNotificationNoResponse;
var
  LServer: TJRPCServer;
begin
  LServer := TJRPCServer.Create(nil);
  try
    // A notification (no id) must never be answered.
    Assert.AreEqual('', LServer.ProcessRequest(
      '{"jsonrpc":"2.0","method":"math/sum","params":{"a":1,"b":1}}'));
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestBatch;
var
  LServer: TJRPCServer;
  LResponse: string;
begin
  LServer := TJRPCServer.Create(nil);
  try
    LResponse := LServer.ProcessRequest(
      '[' +
      '{"jsonrpc":"2.0","id":1,"method":"math/sum","params":{"a":1,"b":1}},' +
      '{"jsonrpc":"2.0","method":"math/sum","params":{"a":9,"b":9}},' +
      '{"jsonrpc":"2.0","id":2,"method":"math/sum","params":{"a":3,"b":4}}' +
      ']');
    Assert.IsTrue(IsArrayOfSize(LResponse, 2), 'batch answers only the requests');
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestBatchWithInvalidElement;
var
  LServer: TJRPCServer;
  LResponse: string;
  LValue: TJSONValue;
  LArr: TJSONArray;
  LErr: TJSONValue;
  LErrObj: TJSONObject;
begin
  LServer := TJRPCServer.Create(nil);
  try
    LResponse := LServer.ProcessRequest(
      '[' +
      '{"jsonrpc":"2.0","id":1,"method":"math/sum","params":[1,2]},' +
      '42,' +
      '{"jsonrpc":"2.0","id":2,"method":"math/sum","params":[3,4]}' +
      ']');
    Assert.IsTrue(IsArrayOfSize(LResponse, 3), 'each element gets an answer');
    LValue := TJSONObject.ParseJSONValue(LResponse);
    try
      LArr := LValue as TJSONArray;
      LErr := LArr.Items[1];
      Assert.IsTrue(LErr is TJSONObject);
      LErrObj := LErr as TJSONObject;
      LErr := LErrObj.GetValue('error');
      Assert.IsTrue(Assigned(LErr) and (LErr is TJSONObject));
      Assert.AreEqual(JRPC_INVALID_REQUEST,
        StrToInt(TJSONObject(LErr).GetValue('code').Value));
    finally
      LValue.Free;
    end;
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestMethodNotFound;
var
  LServer: TJRPCServer;
  LResponse: string;
begin
  LServer := TJRPCServer.Create(nil);
  try
    LResponse := LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":8,"method":"math/nope","params":{}}');
    Assert.AreEqual(JRPC_METHOD_NOT_FOUND, ErrorCodeOf(LResponse));
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestInvalidParams;
var
  LServer: TJRPCServer;
  LResponse: string;
begin
  LServer := TJRPCServer.Create(nil);
  try
    LResponse := LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":9,"method":"math/sum","params":{"a":"x","b":1}}');
    Assert.AreEqual(JRPC_INVALID_PARAMS, ErrorCodeOf(LResponse));
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestParseError;
var
  LServer: TJRPCServer;
  LResponse: string;
begin
  LServer := TJRPCServer.Create(nil);
  try
    LResponse := LServer.ProcessRequest('this is not json');
    Assert.AreEqual(JRPC_PARSE_ERROR, ErrorCodeOf(LResponse));
    Assert.IsTrue(HasNullId(LResponse), 'parse error carries a null id');
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestInvalidRequestScalar;
var
  LServer: TJRPCServer;
  LResponse: string;
begin
  LServer := TJRPCServer.Create(nil);
  try
    LResponse := LServer.ProcessRequest('42');
    Assert.AreEqual(JRPC_INVALID_REQUEST, ErrorCodeOf(LResponse));
    Assert.IsTrue(HasNullId(LResponse), 'invalid request carries a null id');
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestNullIdRoundTrip;
var
  LServer: TJRPCServer;
  LResponse: string;
begin
  LServer := TJRPCServer.Create(nil);
  try
    LResponse := LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":null,"method":"math/sum","params":[20,22]}');
    Assert.AreEqual('42', GetResultValue(LResponse));
    Assert.IsTrue(HasNullId(LResponse), 'response echoes "id": null');
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestObjectResultPascalCase;
var
  LServer: TJRPCServer;
  LResponse: string;
begin
  LServer := TJRPCServer.Create(nil);
  try
    LResponse := LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":1,"method":"object/person"}');
    Assert.IsTrue(LResponse.Contains('"Name":"Paolo"'), LResponse);
    Assert.IsTrue(LResponse.Contains('"Age":42'), LResponse);
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestObjectResultCamelCase;
var
  LServer: TJRPCServer;
  LResponse: string;
begin
  LServer := TJRPCServer.Create(nil);
  try
    // TCamelApi is registered with a CamelCase Neon configuration: same class
    // shape, different JSON keys.
    LResponse := LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":1,"method":"camel/person"}');
    Assert.IsTrue(LResponse.Contains('"name":"Paolo"'), LResponse);
    Assert.IsTrue(LResponse.Contains('"age":42'), LResponse);
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestContextInjection;
var
  LServer: TJRPCServer;
  LResponse: string;
begin
  LServer := TJRPCServer.Create(nil);
  try
    LResponse := LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":1,"method":"ctx/method"}');
    Assert.AreEqual('request=ctx/method', GetResultValue(LResponse));
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestGarbageCollector;
var
  LServer: TJRPCServer;
begin
  LServer := TJRPCServer.Create(nil);
  try
    TContextApi.Destroyed := False;
    LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":1,"method":"ctx/method"}');
    Assert.IsTrue(TContextApi.Destroyed,
      'the API instance must be freed when the request completes');
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestCustomSeparator;
var
  LServer: TJRPCServer;
  LResponse: string;
begin
  LServer := TJRPCServer.Create(nil);
  try
    LResponse := LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":1,"method":"custom.hello"}');
    Assert.AreEqual('hello from custom separator', GetResultValue(LResponse));
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestFlatMethod;
var
  LServer: TJRPCServer;
  LResponse: string;
begin
  // [JRPCPath('')] + [JRPCMethod('tools/list')]: the whole name is matched
  // against the method attribute, nothing is stripped.
  LServer := TJRPCServer.Create(nil);
  try
    LResponse := LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":1,"method":"tools/list"}');
    Assert.AreEqual('tools: list, call', GetResultValue(LResponse));
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestFlatMethodWithParams;
var
  LServer: TJRPCServer;
  LResponse: string;
begin
  LServer := TJRPCServer.Create(nil);
  try
    LResponse := LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"weather"}}');
    Assert.AreEqual('called weather', GetResultValue(LResponse));
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestFlatMethodSingleSegment;
var
  LServer: TJRPCServer;
  LResponse: string;
begin
  // A flat method needs no separator at all: "ping" resolves to TFlatApi.Ping.
  LServer := TJRPCServer.Create(nil);
  try
    LResponse := LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":1,"method":"ping"}');
    Assert.AreEqual('pong', GetResultValue(LResponse));
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestFlatMethodNotFound;
var
  LServer: TJRPCServer;
  LResponse: string;
begin
  LServer := TJRPCServer.Create(nil);
  try
    LResponse := LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":1,"method":"tools/missing"}');
    Assert.AreEqual(JRPC_METHOD_NOT_FOUND, ErrorCodeOf(LResponse));
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestFlatCoexistsWithPathClasses;
var
  LServer: TJRPCServer;
  LResponse: string;
begin
  // Flat classes must not disturb the path + separator + method resolution.
  LServer := TJRPCServer.Create(nil);
  try
    LResponse := LServer.ProcessRequest(
      '[{"jsonrpc":"2.0","id":1,"method":"math/sum","params":{"a":2,"b":3}},' +
      '{"jsonrpc":"2.0","id":2,"method":"tools/list"},' +
      '{"jsonrpc":"2.0","id":3,"method":"custom.hello"}]');
    Assert.IsTrue(IsArrayOfSize(LResponse, 3));
    Assert.AreEqual('5', GetBatchResultValue(LResponse, 0), 'math/sum still resolves');
    Assert.AreEqual('tools: list, call', GetBatchResultValue(LResponse, 1),
      'flat method resolves');
    Assert.AreEqual('hello from custom separator', GetBatchResultValue(LResponse, 2),
      'custom separator still resolves');
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestNoPathAttribute;
var
  LServer: TJRPCServer;
  LResponse: string;
begin
  // TBareApi declares no class attribute at all: registering it is enough, and
  // its [JRPCMethod] names are the full JSON-RPC method names.
  LServer := TJRPCServer.Create(nil);
  try
    LResponse := LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":1,"method":"status/get"}');
    Assert.AreEqual('status: ok', GetResultValue(LResponse));

    LResponse := LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":2,"method":"version"}');
    Assert.AreEqual('1.0.0', GetResultValue(LResponse));
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestEmitsPerfLogs;
var
  LServer: TJRPCServer;
  LTarget: TStringList;
begin
  // The server must emit the [PERF] ProcessRequest timing log and reach a
  // registered Logify adapter.
  LTarget := TStringList.Create;
  try
    TLoggerAdapterRegistry.Instance.RegisterFactory(
      TLogifyAdapterBufferFactory.CreateAdapterFactory(
        'JRPC.Tests.ServerPerf', TLogLevel.Debug, LTarget));
    try
      LServer := TJRPCServer.Create(nil);
      try
        LServer.ProcessRequest(
          '{"jsonrpc":"2.0","id":1,"method":"math/sum","params":{"a":1,"b":2}}');
      finally
        LServer.Free;
      end;
      Assert.Contains(LTarget.Text, '[PERF] JRPC ProcessRequest');
    finally
      TLoggerAdapterRegistry.Instance.UnregisterFactory('JRPC.Tests.ServerPerf');
    end;
  finally
    LTarget.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TJRPCServerTest);

end.
