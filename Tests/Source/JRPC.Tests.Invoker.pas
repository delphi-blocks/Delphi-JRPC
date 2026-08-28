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
unit JRPC.Tests.Invoker;

interface

uses
  System.SysUtils, System.JSON,
  DUnitX.TestFramework,

  JRPC.Core;

type
  [TestFixture]
  TJRPCInvokerTest = class
  public
    [Test] procedure TestInvokeNamedParams;
    [Test] procedure TestInvokePositionalParams;
    [Test] procedure TestInvokeStringParams;
    [Test] procedure TestInvokeEnumParam;
    [Test] procedure TestInvokeJRPCParamsObject;
    [Test] procedure TestInvokeObjectResult;
    [Test] procedure TestInvokePerClassNeonConfig;
    [Test] procedure TestInvokeCustomSeparator;
    [Test] procedure TestInvokeNotificationAttribute;
    [Test] procedure TestInvokeProcedureReturnsNullResult;
    [Test] procedure TestInvokeProcedureWithParamsReturnsNullResult;
    [Test] procedure TestInvokeEmptyArrayResultStaysArray;
    [Test] procedure TestInvokeMethodNotFound;
    [Test] procedure TestInvokeInvalidParamType;
    [Test] procedure TestInvokeMissingParam;
    [Test] procedure TestHandleErrorJRPCException;
    [Test] procedure TestHandleErrorParseException;
    [Test] procedure TestHandleErrorGenericException;
    [Test] procedure TestHandleErrorGenericExceptionExposedWhenEnabled;
    [Test] procedure TestHandleErrorAgreesWithCreateFromException;
    [Test] procedure TestHandleErrorLogsSuppressedException;
    [Test] procedure TestInvokeEmitsPerfLogs;
    [Test] procedure TestInvokeArrayResultIsCollected;
  end;

  /// <summary>Array-returning API: the garbage collector must free the items.</summary>
  TArrayItem = class
  public
    class var Destroyed: Boolean;
    destructor Destroy; override;
  end;

  [JRPCPath('items')]
  TItemsApi = class
  public
    [JRPCMethod('list')]
    function List: TArray<TArrayItem>;
  end;

implementation

uses
  System.Generics.Collections,

  System.Classes,
  Neon.Core.Persistence,

  Logify,
  Logify.Adapter.Buffer,

  JRPC.Classes,
  JRPC.Invoker,
  JRPC.Tests.Api;

{ TArrayItem }

destructor TArrayItem.Destroy;
begin
  Destroyed := True;
  inherited;
end;

{ TItemsApi }

function TItemsApi.List: TArray<TArrayItem>;
begin
  Result := [TArrayItem.Create, TArrayItem.Create];
end;

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

function GetIdValue(const AJSON: string): string;
var
  LObj: TJSONObject;
  LId: TJSONValue;
begin
  Result := '';
  LObj := ParseObject(AJSON);
  if Assigned(LObj) then
  try
    LId := LObj.GetValue('id');
    if Assigned(LId) then
      Result := LId.Value;
  finally
    LObj.Free;
  end;
end;

/// <summary>Invokes ARequestJSON against AApi and returns the response JSON.</summary>
function InvokeToJSON(AApi: TObject; const ARequestJSON: string; ANeonConfig: INeonConfiguration = nil): string;
var
  LRequest: TJRPCRequest;
  LResponses: TJRPCMessages;
  LContext: TJRPCInvokerContext;
  LGarbage: IGarbageCollector;
begin
  LRequest := TJRPCRequest.CreateFromJson(ARequestJSON);
  LResponses := TJRPCMessages.Create(True);
  LGarbage := TGarbageCollector.CreateInstance;
  try
    LContext.Request := LRequest;
    LContext.Responses := LResponses;
    LContext.Garbage := LGarbage;
    LContext.ApiInstance := AApi;
    LContext.SelectConfig(ANeonConfig);

    TJRPCInvoker.Invoke(LContext);
    Result := LResponses.ToJson;
  finally
    LRequest.Free;
    LResponses.Free;
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

{ TJRPCInvokerTest }

procedure TJRPCInvokerTest.TestInvokeNamedParams;
var
  LApi: TMathApi;
  LJson: string;
begin
  LApi := TMathApi.Create;
  try
    LJson := InvokeToJSON(LApi,
      '{"jsonrpc":"2.0","id":1,"method":"math/sum","params":{"a":2,"b":40}}');
    Assert.AreEqual('42', GetResultValue(LJson));
    Assert.AreEqual('1', GetIdValue(LJson));
  finally
    LApi.Free;
  end;
end;

procedure TJRPCInvokerTest.TestInvokePositionalParams;
var
  LApi: TMathApi;
  LJson: string;
begin
  LApi := TMathApi.Create;
  try
    LJson := InvokeToJSON(LApi,
      '{"jsonrpc":"2.0","id":"two","method":"math/sum","params":[10,32]}');
    Assert.AreEqual('42', GetResultValue(LJson));
    Assert.AreEqual('two', GetIdValue(LJson));
  finally
    LApi.Free;
  end;
end;

procedure TJRPCInvokerTest.TestInvokeStringParams;
var
  LApi: TMathApi;
  LJson: string;
begin
  LApi := TMathApi.Create;
  try
    LJson := InvokeToJSON(LApi,
      '{"jsonrpc":"2.0","id":1,"method":"math/concat",' +
      '"params":{"left":"JRPC","right":"-Delphi"}}');
    Assert.AreEqual('JRPC-Delphi', GetResultValue(LJson));
  finally
    LApi.Free;
  end;
end;

procedure TJRPCInvokerTest.TestInvokeEnumParam;
var
  LApi: TMathApi;
  LJson: string;
begin
  LApi := TMathApi.Create;
  try
    LJson := InvokeToJSON(LApi,
      '{"jsonrpc":"2.0","id":1,"method":"math/apply",' +
      '"params":{"op":"opMultiply","a":6,"b":7}}');
    Assert.AreEqual('42', GetResultValue(LJson));
  finally
    LApi.Free;
  end;
end;

procedure TJRPCInvokerTest.TestInvokeJRPCParamsObject;
var
  LApi: TGreetApi;
  LJson: string;
begin
  LApi := TGreetApi.Create;
  try
    LJson := InvokeToJSON(LApi,
      '{"jsonrpc":"2.0","id":1,"method":"greet/hello",' +
      '"params":{"Salutation":"Hello","Name":"World"}}');
    Assert.AreEqual('Hello, World!', GetResultValue(LJson));
  finally
    LApi.Free;
  end;
end;

procedure TJRPCInvokerTest.TestInvokeObjectResult;
var
  LApi: TObjectApi;
  LJson: string;
begin
  LApi := TObjectApi.Create;
  try
    LJson := InvokeToJSON(LApi,
      '{"jsonrpc":"2.0","id":1,"method":"object/person"}');
    Assert.IsTrue(LJson.Contains('"Name":"Paolo"'), LJson);
    Assert.IsTrue(LJson.Contains('"Age":42'), LJson);
  finally
    LApi.Free;
  end;
end;

procedure TJRPCInvokerTest.TestInvokePerClassNeonConfig;
var
  LApi: TObjectApi;
  LJson: string;
begin
  LApi := TObjectApi.Create;
  try
    LJson := InvokeToJSON(LApi,
      '{"jsonrpc":"2.0","id":1,"method":"object/person"}',
      TNeonConfiguration.Camel);
    Assert.IsTrue(LJson.Contains('"name":"Paolo"'), LJson);
    Assert.IsTrue(LJson.Contains('"age":42'), LJson);
  finally
    LApi.Free;
  end;
end;

procedure TJRPCInvokerTest.TestInvokeCustomSeparator;
var
  LApi: TCustomSeparatorApi;
  LJson: string;
begin
  LApi := TCustomSeparatorApi.Create;
  try
    LJson := InvokeToJSON(LApi,
      '{"jsonrpc":"2.0","id":1,"method":"custom.hello"}');
    Assert.AreEqual('hello from custom separator', GetResultValue(LJson));
  finally
    LApi.Free;
  end;
end;

procedure TJRPCInvokerTest.TestInvokeNotificationAttribute;
var
  LApi: TMathApi;
  LObj: TJSONObject;
  LRes: TJSONValue;
  LJson: string;
begin
  LApi := TMathApi.Create;
  try
    LJson := InvokeToJSON(LApi,
      '{"jsonrpc":"2.0","id":1,"method":"math/notif","params":{"a":1,"b":2}}');
    LObj := ParseObject(LJson);
    try
      Assert.IsNotNull(LObj);
      LRes := LObj.GetValue('result');
      Assert.IsNotNull(LRes, 'response must carry a result member');
      Assert.IsTrue(LRes is TJSONNull, 'notification-annotated method returns a null result');
    finally
      LObj.Free;
    end;
  finally
    LApi.Free;
  end;
end;

procedure TJRPCInvokerTest.TestInvokeProcedureReturnsNullResult;
var
  LApi: TMathApi;
  LObj: TJSONObject;
  LRes: TJSONValue;
  LJson: string;
begin
  LApi := TMathApi.Create;
  try
    // A procedure has no return type: Invoke hands back an empty TValue, which
    // used to reach TNeon.ValueToJSON and raise an access violation reported to
    // the client as -32603. The Response must carry "result": null instead.
    LJson := InvokeToJSON(LApi, '{"jsonrpc":"2.0","id":1,"method":"math/reset"}');
    LObj := ParseObject(LJson);
    try
      Assert.IsNotNull(LObj, 'a procedure must still produce a response object');
      Assert.IsNull(LObj.GetValue('error'), 'a procedure is not an error');
      LRes := LObj.GetValue('result');
      Assert.IsNotNull(LRes, 'response must carry a result member');
      Assert.IsTrue(LRes is TJSONNull, 'a procedure returns a null result');
    finally
      LObj.Free;
    end;
  finally
    LApi.Free;
  end;
end;

procedure TJRPCInvokerTest.TestInvokeProcedureWithParamsReturnsNullResult;
var
  LApi: TMathApi;
  LObj: TJSONObject;
  LRes: TJSONValue;
  LJson: string;
begin
  LApi := TMathApi.Create;
  try
    // Same, but the parameters still have to be marshaled and the id echoed.
    LJson := InvokeToJSON(LApi,
      '{"jsonrpc":"2.0","id":7,"method":"math/store","params":{"value":42}}');
    LObj := ParseObject(LJson);
    try
      Assert.IsNotNull(LObj);
      Assert.IsNull(LObj.GetValue('error'), 'a procedure with params is not an error');
      LRes := LObj.GetValue('result');
      Assert.IsNotNull(LRes, 'response must carry a result member');
      Assert.IsTrue(LRes is TJSONNull, 'a procedure returns a null result');
    finally
      LObj.Free;
    end;
    Assert.AreEqual('7', GetIdValue(LJson), 'the id is still echoed');
  finally
    LApi.Free;
  end;
end;

procedure TJRPCInvokerTest.TestInvokeEmptyArrayResultStaysArray;
var
  LApi: TMathApi;
  LObj: TJSONObject;
  LRes: TJSONValue;
  LJson: string;
begin
  LApi := TMathApi.Create;
  try
    // Guards the predicate used to detect "no result": TValue.IsEmpty is also
    // True for an empty dynamic array, so testing the value instead of the
    // method's ReturnType would collapse [] into null.
    LJson := InvokeToJSON(LApi, '{"jsonrpc":"2.0","id":1,"method":"math/emptylist"}');
    LObj := ParseObject(LJson);
    try
      Assert.IsNotNull(LObj);
      LRes := LObj.GetValue('result');
      Assert.IsNotNull(LRes, 'response must carry a result member');
      Assert.IsTrue(LRes is TJSONArray, 'an empty array result stays an array');
      Assert.AreEqual(0, (LRes as TJSONArray).Count);
    finally
      LObj.Free;
    end;
  finally
    LApi.Free;
  end;
end;

procedure TJRPCInvokerTest.TestInvokeMethodNotFound;
var
  LApi: TMathApi;
begin
  LApi := TMathApi.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        InvokeToJSON(LApi,
          '{"jsonrpc":"2.0","id":1,"method":"math/nope","params":{}}');
      end,
      EJRPCMethodNotFoundError);
  finally
    LApi.Free;
  end;
end;

procedure TJRPCInvokerTest.TestInvokeInvalidParamType;
var
  LApi: TMathApi;
begin
  LApi := TMathApi.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        InvokeToJSON(LApi,
          '{"jsonrpc":"2.0","id":1,"method":"math/sum","params":{"a":"x","b":1}}');
      end,
      EJRPCInvalidParamsError);
  finally
    LApi.Free;
  end;
end;

procedure TJRPCInvokerTest.TestInvokeMissingParam;
var
  LApi: TMathApi;
begin
  LApi := TMathApi.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        InvokeToJSON(LApi,
          '{"jsonrpc":"2.0","id":1,"method":"math/sum","params":{"a":5}}');
      end,
      EJRPCInvalidParamsError);
  finally
    LApi.Free;
  end;
end;

procedure TJRPCInvokerTest.TestHandleErrorJRPCException;
var
  LError: TJRPCError;
  E: EJRPCException;
begin
  E := EJRPCMethodNotFoundError.CreateFmt('Method [%s] not found', ['math/nope']);
  try
    LError := TJRPCInvoker.HandleError(E, 8);
    try
      Assert.AreEqual(JRPC_METHOD_NOT_FOUND, Integer(LError.Error.Code));
      Assert.AreEqual(8, LError.Id.AsInteger);
    finally
      LError.Free;
    end;
  finally
    E.Free;
  end;
end;

procedure TJRPCInvokerTest.TestHandleErrorParseException;
var
  LError: TJRPCError;
  E: EJSONParseException;
begin
  E := EJSONParseException.Create('bad json');
  try
    LError := TJRPCInvoker.HandleError(E, TJRPCID(nil));
    try
      Assert.AreEqual(JRPC_PARSE_ERROR, Integer(LError.Error.Code));
      Assert.IsTrue(LError.Id.IsNull);
    finally
      LError.Free;
    end;
  finally
    E.Free;
  end;
end;

procedure TJRPCInvokerTest.TestHandleErrorGenericException;
var
  LError: TJRPCError;
begin
  // An exception that is not part of the protocol is still an internal error,
  // but nothing about it reaches the client by default: RTL messages carry
  // instance addresses and module offsets, and the class name describes the
  // server's internals.
  LError := TJRPCInvoker.HandleError(EInvalidCast.Create('cast'), 1);
  try
    Assert.AreEqual(JRPC_INTERNAL_ERROR, Integer(LError.Error.Code));
    Assert.IsTrue(LError.Error.Data.IsEmpty, 'no class name in data');
    Assert.AreEqual(SJRPCUnexpectedError, string(LError.Error.Message),
      'a fixed message, not the exception''s own');
  finally
    LError.Free;
  end;
end;

procedure TJRPCInvokerTest.TestHandleErrorGenericExceptionExposedWhenEnabled;
var
  LError: TJRPCError;
begin
  // Opting in restores the old, chatty behaviour for development.
  TJRPCError.ExposeExceptionDetails := True;
  try
    LError := TJRPCInvoker.HandleError(EInvalidCast.Create('cast'), 1);
    try
      Assert.AreEqual(JRPC_INTERNAL_ERROR, Integer(LError.Error.Code));
      Assert.AreEqual('EInvalidCast', LError.Error.Data.AsString);
      Assert.AreEqual('cast', string(LError.Error.Message));
    finally
      LError.Free;
    end;
  finally
    TJRPCError.ExposeExceptionDetails := False;
  end;
end;

procedure TJRPCInvokerTest.TestHandleErrorAgreesWithCreateFromException;

  procedure AssertSame(E: Exception; const AWhat: string);
  var
    LFromInvoker, LFromCore: TJRPCError;
  begin
    LFromInvoker := TJRPCInvoker.HandleError(E, 1);
    try
      LFromCore := TJRPCError.CreateFromException(E, 1);
      try
        Assert.AreEqual(LFromCore.ToJson, LFromInvoker.ToJson,
          'the two paths must describe ' + AWhat + ' identically');
      finally
        LFromCore.Free;
      end;
    finally
      LFromInvoker.Free;
      E.Free;
    end;
  end;

begin
  // The same failure must be described the same way whether it surfaced while
  // parsing or while dispatching. These were two hand-maintained copies of the
  // same mapping and had drifted: an unanticipated exception was -32603 in the
  // invoker and -32600 in the core, so the client was told its request was
  // malformed or that the server had failed depending only on where it broke.
  AssertSame(Exception.Create('boom'), 'an unexpected exception');
  AssertSame(EInvalidCast.Create('cast'), 'an RTL exception');
  AssertSame(EJRPCMethodNotFoundError.Create('Method [x] not found'),
    'a method-not-found error');
  AssertSame(EJRPCInvalidParamsError.Create('Invalid method parameters.'),
    'an invalid-params error');
  AssertSame(EJRPCParseError.Create('bad json'), 'a parse error');
end;

procedure TJRPCInvokerTest.TestHandleErrorLogsSuppressedException;
var
  LError: TJRPCError;
  LTarget: TStringList;
begin
  // Keeping the details off the wire must not keep them from whoever has to
  // diagnose the failure: the exception goes to the logger either way.
  LTarget := TStringList.Create;
  try
    TLoggerAdapterRegistry.Instance.RegisterFactory(
      TLogifyAdapterBufferFactory.CreateAdapterFactory(
        'JRPC.Tests.InvokerError', TLogLevel.Debug, LTarget));
    try
      LError := TJRPCInvoker.HandleError(EInvalidCast.Create('cast'), 1);
      try
        Assert.IsTrue(LError.Error.Data.IsEmpty, 'still nothing on the wire');
      finally
        LError.Free;
      end;
      Assert.Contains(LTarget.Text, 'EInvalidCast',
        'the exception class reaches the log');
      Assert.Contains(LTarget.Text, 'cast',
        'the exception message reaches the log');
    finally
      TLoggerAdapterRegistry.Instance.UnregisterFactory('JRPC.Tests.InvokerError');
    end;
  finally
    LTarget.Free;
  end;
end;

procedure TJRPCInvokerTest.TestInvokeEmitsPerfLogs;
var
  LApi: TMathApi;
  LTarget: TStringList;
begin
  // The [PERF] TStopwatch instrumentation must fire while dispatching and
  // reach a registered Logify adapter.
  LTarget := TStringList.Create;
  try
    TLoggerAdapterRegistry.Instance.RegisterFactory(
      TLogifyAdapterBufferFactory.CreateAdapterFactory(
        'JRPC.Tests.InvokerPerf', TLogLevel.Debug, LTarget));
    try
      LApi := TMathApi.Create;
      try
        InvokeToJSON(LApi,
          '{"jsonrpc":"2.0","id":1,"method":"math/sum","params":{"a":1,"b":2}}');
      finally
        LApi.Free;
      end;
      Assert.Contains(LTarget.Text, '[PERF] JRPC [math/sum]');
    finally
      TLoggerAdapterRegistry.Instance.UnregisterFactory('JRPC.Tests.InvokerPerf');
    end;
  finally
    LTarget.Free;
  end;
end;

procedure TJRPCInvokerTest.TestInvokeArrayResultIsCollected;
var
  LApi: TItemsApi;
begin
  // An array of objects returned by a method must be collected by the request
  // garbage collector (regression: plain TValue arrays are not IsObject).
  TArrayItem.Destroyed := False;
  LApi := TItemsApi.Create;
  try
    InvokeToJSON(LApi,
      '{"jsonrpc":"2.0","id":1,"method":"items/list"}');
  finally
    LApi.Free;
  end;
  Assert.IsTrue(TArrayItem.Destroyed,
    'the garbage collector must free the items of an array result');
end;

initialization
  TDUnitX.RegisterTestFixture(TJRPCInvokerTest);

end.
