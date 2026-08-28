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
unit JRPC.Tests.Core;

interface

uses
  System.SysUtils, System.JSON, System.Rtti, System.Generics.Collections,
  DUnitX.TestFramework,

  Logify,
  Logify.Adapter.Buffer,

  JRPC.Classes,
  JRPC.Core;

type
  [TestFixture]
  TJRPCMessageTest = class
  public
    // TJRPCRequest
    [Test] procedure TestRequestWithNamedParams;
    [Test] procedure TestRequestWithPositionParams;
    [Test] procedure TestRequestWithNullParams;
    [Test] procedure TestRequestSerializeToJson;
    [Test] procedure TestRequestAddNamedParam;
    [Test] procedure TestRequestAddPositionParam;
    [Test] procedure TestRequestIdInteger;
    [Test] procedure TestRequestIdString;
    [Test] procedure TestRequestIdInt64;
    [Test] procedure TestRequestNullId;
    [Test] procedure TestRequestBooleanIdIsInvalid;
    [Test] procedure TestRequestFractionalIdIsInvalid;
    [Test] procedure TestRequestInvalidJsonRpcVersion;
    [Test] procedure TestRequestMissingMethodIsInvalid;
    [Test] procedure TestRequestMethodNotAStringIsInvalid;
    [Test] procedure TestRequestCreateFromJsonRejectsNonStringMethod;
    [Test] procedure TestRequestParamsCount;
    [Test] procedure TestRequestWithoutParamsOmitsTheMember;
    [Test] procedure TestNotificationWithoutParamsOmitsTheMember;
    [Test] procedure TestRequestNullParamsRoundTripsAsAbsent;

    // TJRPCNotification
    [Test] procedure TestNotificationWithParams;
    [Test] procedure TestNotificationSerializeRoundTrip;
    [Test] procedure TestNotificationInvalidJsonRpcVersion;

    // TJRPCResponse
    [Test] procedure TestResponseSerializeResult;
    [Test] procedure TestResponseDeserializeRoundTrip;
    [Test] procedure TestResponseNullIdRoundTrip;

    // TJRPCError
    [Test] procedure TestErrorCreateFromJRPCException;
    [Test] procedure TestErrorCreateFromParseException;
    [Test] procedure TestErrorCreateFromGenericException;
    [Test] procedure TestErrorCreateFromGenericExceptionExposedWhenEnabled;
    [Test] procedure TestErrorProtocolExceptionsKeepTheirMessage;
    [Test] procedure TestErrorCarriesExceptionData;
    [Test] procedure TestJRPCExceptionKeepsAConstructorChosenCode;
    [Test] procedure TestErrorDetailsAreValidFromBirth;
    [Test] procedure TestErrorSerializeNullId;
    [Test] procedure TestErrorClone;

    // TJRPCID
    [Test] procedure TestJRPCIDInteger;
    [Test] procedure TestJRPCIDString;
    [Test] procedure TestJRPCIDIsNull;

    // TJRPCMessages parsing
    [Test] procedure TestMessagesFromSingleRequest;
    [Test] procedure TestMessagesFromBatch;
    [Test] procedure TestMessagesFromEmptyBatchIsInvalid;
    [Test] procedure TestMessagesFromScalarJSONIsInvalid;
    [Test] procedure TestMessagesFromMalformedJSONIsParseError;
    [Test] procedure TestMessagesFromBatchWithInvalidElement;
    [Test] procedure TestMessagesFromResultAndErrorIsInvalid;
    [Test] procedure TestMessagesToJsonSingle;
    [Test] procedure TestMessagesToJsonBatch;
    [Test] procedure TestMessagesToJsonFormatIsConsistent;
    [Test] procedure TestMessagesFromStream;

    // TJRPCRegistry
    [Test] procedure TestRegistryRegisterAndExists;
    [Test] procedure TestRegistryUnregister;
    [Test] procedure TestRegistryGetClassInstance;
    [Test] procedure TestRegistryConstructorFunc;
    [Test] procedure TestRegistryNeonConfig;
    [Test] procedure TestRegistryGetConstructorProxy;
    [Test] procedure TestRegistryFlatMethodProxy;
    [Test] procedure TestRegistryFlatUnregisterRemovesMethods;

    // TGarbageCollector
    [Test] procedure TestGarbageCollectorFreesObjects;
    [Test] procedure TestGarbageCollectorCustomAction;
    [Test] procedure TestGarbageCollectorIgnoresNonObjects;
    [Test] procedure TestGarbageCollectorFreesArrayItems;
    [Test] procedure TestGarbageCollectorAddTwice;

    // TContextManager
    [Test] procedure TestContextAddAndFind;
    [Test] procedure TestContextGetMissingRaises;
    [Test] procedure TestContextInjectClassField;
    [Test] procedure TestContextInjectInterfaceField;

    // TRouteMatcher
    [Test] procedure TestRouteMatcherMatch;
    [Test] procedure TestRouteMatcherParams;
    [Test] procedure TestRouteMatcherUrlDecode;
    [Test] procedure TestRouteMatcherNonMatch;
  end;

  TContextData = class
  public
    Value: Integer;
  end;

  IContextMarker = interface
    ['{B7D45E1A-2C93-4E6F-9B12-3A1F8C4D5E6F}']
    function GetId: Integer;
    property Id: Integer read GetId;
  end;

  TContextMarker = class(TInterfacedObject, IContextMarker)
  private
    FId: Integer;
  public
    constructor Create(AId: Integer);
    function GetId: Integer;
  end;

  [TestFixture]
  TJRPCInstrumentationTest = class
  public
    [Test] procedure TestLoggerRoutesFormattedMessages;
    [Test] procedure TestLoggerRoutesLevels;
    [Test] procedure TestLoggerLevelFiltering;
    [Test] procedure TestLoggerUnregisterStopsOutput;
  end;

  /// <summary>Context injection target for TContextManager tests.</summary>
  TContextTarget = class
  private
    [Context] FData: TContextData;
    [Context] FMarker: IContextMarker;
  public
    property Data: TContextData read FData;
    property Marker: IContextMarker read FMarker;
  end;

implementation

uses
  System.Classes,

  Neon.Core.Utils,

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

{ TJRPCMessageTest }

procedure TJRPCMessageTest.TestRequestWithNamedParams;
var
  LRequest: TJRPCRequest;
begin
  LRequest := TJRPCRequest.CreateFromJson(
    '{"jsonrpc":"2.0","id":1,"method":"math/sum","params":{"a":2,"b":40}}');
  try
    Assert.AreEqual('math/sum', LRequest.Method);
    Assert.AreEqual(1, LRequest.Id.AsInteger);
    Assert.AreEqual(TJRPCParamsType.ByName, LRequest.ParamsType);
    Assert.AreEqual(2, LRequest.ParamsCount);
  finally
    LRequest.Free;
  end;
end;

procedure TJRPCMessageTest.TestRequestWithPositionParams;
var
  LRequest: TJRPCRequest;
begin
  LRequest := TJRPCRequest.CreateFromJson(
    '{"jsonrpc":"2.0","id":1,"method":"math/sum","params":[10,32]}');
  try
    Assert.AreEqual(TJRPCParamsType.ByPos, LRequest.ParamsType);
    Assert.AreEqual(2, LRequest.ParamsCount);
  finally
    LRequest.Free;
  end;
end;

procedure TJRPCMessageTest.TestRequestWithNullParams;
var
  LRequest: TJRPCRequest;
begin
  LRequest := TJRPCRequest.CreateFromJson(
    '{"jsonrpc":"2.0","id":1,"method":"math/sum"}');
  try
    Assert.AreEqual(TJRPCParamsType.Null, LRequest.ParamsType);
    Assert.AreEqual(0, LRequest.ParamsCount);
  finally
    LRequest.Free;
  end;
end;

procedure TJRPCMessageTest.TestRequestSerializeToJson;
var
  LRequest, LParsed: TJRPCRequest;
begin
  LRequest := TJRPCRequest.CreateFromJson(
    '{"jsonrpc":"2.0","id":42,"method":"math/sum","params":{"a":1,"b":5}}');
  try
    LParsed := TJRPCRequest.CreateFromJson(LRequest.ToJson);
    try
      Assert.AreEqual(LRequest.Method, LParsed.Method);
      Assert.AreEqual(LRequest.Id.AsInteger, LParsed.Id.AsInteger);
      Assert.AreEqual(TJRPCParamsType.ByName, LParsed.ParamsType);
    finally
      LParsed.Free;
    end;
  finally
    LRequest.Free;
  end;
end;

procedure TJRPCMessageTest.TestRequestAddNamedParam;
var
  LRequest: TJRPCRequest;
begin
  LRequest := TJRPCRequest.Create;
  try
    LRequest.Method := 'math/sum';
    LRequest.Id := 1;
    LRequest.AddNamedParam('a', 2);
    LRequest.AddNamedParam('b', 40);
    Assert.AreEqual(2, LRequest.ParamsCount);
    Assert.AreEqual(TJRPCParamsType.ByName, LRequest.ParamsType);
    Assert.IsTrue(LRequest.ToJson.Contains('"params":{"a":2,"b":40}'));
  finally
    LRequest.Free;
  end;
end;

procedure TJRPCMessageTest.TestRequestAddPositionParam;
var
  LRequest: TJRPCRequest;
begin
  LRequest := TJRPCRequest.Create;
  try
    LRequest.Method := 'math/sum';
    LRequest.Id := 1;
    LRequest.AddPositionParam(10);
    LRequest.AddPositionParam(32);
    Assert.AreEqual(2, LRequest.ParamsCount);
    Assert.AreEqual(TJRPCParamsType.ByPos, LRequest.ParamsType);
    Assert.IsTrue(LRequest.ToJson.Contains('"params":[10,32]'));
  finally
    LRequest.Free;
  end;
end;

procedure TJRPCMessageTest.TestRequestIdInteger;
var
  LRequest: TJRPCRequest;
begin
  LRequest := TJRPCRequest.CreateFromJson(
    '{"jsonrpc":"2.0","id":7,"method":"m"}');
  try
    Assert.IsFalse(LRequest.Id.IsNull);
    Assert.AreEqual(7, LRequest.Id.AsInteger);
    Assert.AreEqual('7', LRequest.Id.AsString);
  finally
    LRequest.Free;
  end;
end;

procedure TJRPCMessageTest.TestRequestIdString;
var
  LRequest: TJRPCRequest;
begin
  LRequest := TJRPCRequest.CreateFromJson(
    '{"jsonrpc":"2.0","id":"abc","method":"m"}');
  try
    Assert.AreEqual('abc', LRequest.Id.AsString);
    Assert.AreEqual(0, LRequest.Id.AsInteger);
  finally
    LRequest.Free;
  end;
end;

procedure TJRPCMessageTest.TestRequestIdInt64;
var
  LRequest: TJRPCRequest;
begin
  LRequest := TJRPCRequest.CreateFromJson(
    '{"jsonrpc":"2.0","id":9223372036854775807,"method":"m"}');
  try
    Assert.IsFalse(LRequest.Id.IsNull);
    Assert.AreEqual('9223372036854775807', LRequest.Id.AsString);
  finally
    LRequest.Free;
  end;
end;

procedure TJRPCMessageTest.TestRequestNullId;
var
  LRequest: TJRPCRequest;
begin
  LRequest := TJRPCRequest.CreateFromJson(
    '{"jsonrpc":"2.0","id":null,"method":"m"}');
  try
    Assert.IsTrue(LRequest.Id.IsNull);
    Assert.IsTrue(LRequest.ToJson.Contains('"id":null'));
  finally
    LRequest.Free;
  end;
end;

procedure TJRPCMessageTest.TestRequestBooleanIdIsInvalid;
begin
  Assert.WillRaise(
    procedure
    begin
      var LRequest := TJRPCRequest.CreateFromJson(
        '{"jsonrpc":"2.0","id":true,"method":"m"}');
      LRequest.Free;
    end,
    EJRPCInvalidRequestError);
end;

procedure TJRPCMessageTest.TestRequestFractionalIdIsInvalid;
begin
  Assert.WillRaise(
    procedure
    begin
      var LRequest := TJRPCRequest.CreateFromJson(
        '{"jsonrpc":"2.0","id":1.5,"method":"m"}');
      LRequest.Free;
    end,
    EJRPCInvalidRequestError);
end;

procedure TJRPCMessageTest.TestRequestInvalidJsonRpcVersion;
begin
  Assert.WillRaise(
    procedure
    begin
      var LRequest := TJRPCRequest.CreateFromJson(
        '{"jsonrpc":"1.0","id":1,"method":"m"}');
      LRequest.Free;
    end,
    EJRPCInvalidRequestError);
end;

procedure TJRPCMessageTest.TestRequestMethodNotAStringIsInvalid;
var
  LMsgs: TJRPCMessages;
begin
  // A non-string "method" is an Invalid Request, not a request for a method
  // that happens not to exist: the number used to be coerced into its text.
  LMsgs := TJRPCMessages.CreateFromJson('{"jsonrpc":"2.0","id":1,"method":123}');
  try
    Assert.AreEqual(1, LMsgs.Count);
    Assert.IsTrue(LMsgs.List[0] is TJRPCError);
    Assert.AreEqual(JRPC_INVALID_REQUEST, Integer((LMsgs.List[0] as TJRPCError).Error.Code));
    Assert.AreEqual(1, (LMsgs.List[0] as TJRPCError).Id.AsInteger, 'the id is still echoed');
  finally
    LMsgs.Free;
  end;
end;

procedure TJRPCMessageTest.TestRequestCreateFromJsonRejectsNonStringMethod;
begin
  // The check lives in the serializer, so it also guards the public
  // CreateFromJson entry point, which never goes through GetMessageType.
  Assert.WillRaise(
    procedure
    begin
      TJRPCRequest.CreateFromJson('{"jsonrpc":"2.0","id":1,"method":123}').Free;
    end,
    EJRPCInvalidRequestError);

  Assert.WillRaise(
    procedure
    begin
      TJRPCRequest.CreateFromJson('{"jsonrpc":"2.0","id":1,"method":{"a":1}}').Free;
    end,
    EJRPCInvalidRequestError);
end;

procedure TJRPCMessageTest.TestRequestWithoutParamsOmitsTheMember;
var
  LRequest: TJRPCRequest;
  LObj: TJSONObject;
begin
  // A param-less request used to go out as "params": null, which is neither an
  // Array nor an Object and which a strict peer may answer with -32602.
  LRequest := TJRPCRequest.Create;
  try
    LRequest.Method := 'foo';
    LRequest.Id := 1;
    LObj := ParseObject(LRequest.ToJson);
    try
      Assert.IsNotNull(LObj);
      Assert.IsNull(LObj.GetValue('params'), 'the member is absent, not null');
      Assert.AreEqual('foo', LObj.GetValue('method').Value);
    finally
      LObj.Free;
    end;
  finally
    LRequest.Free;
  end;

  // ...but a request that has parameters still carries them.
  LRequest := TJRPCRequest.Create;
  try
    LRequest.Method := 'foo';
    LRequest.Id := 1;
    LRequest.AddPositionParam(42);
    LObj := ParseObject(LRequest.ToJson);
    try
      Assert.IsNotNull(LObj.GetValue('params'), 'real params are still emitted');
      Assert.IsTrue(LObj.GetValue('params') is TJSONArray);
    finally
      LObj.Free;
    end;
  finally
    LRequest.Free;
  end;
end;

procedure TJRPCMessageTest.TestNotificationWithoutParamsOmitsTheMember;
var
  LNotif: TJRPCNotification;
  LObj: TJSONObject;
begin
  LNotif := TJRPCNotification.Create;
  try
    LNotif.Method := 'notify';
    LObj := ParseObject(LNotif.ToJson);
    try
      Assert.IsNotNull(LObj);
      Assert.IsNull(LObj.GetValue('params'), 'the member is absent, not null');
      Assert.IsNull(LObj.GetValue('id'), 'a notification still carries no id');
    finally
      LObj.Free;
    end;
  finally
    LNotif.Free;
  end;

  LNotif := TJRPCNotification.Create;
  try
    LNotif.Method := 'notify';
    LNotif.AddNamedParam('a', 1);
    LObj := ParseObject(LNotif.ToJson);
    try
      Assert.IsNotNull(LObj.GetValue('params'), 'real params are still emitted');
      Assert.IsTrue(LObj.GetValue('params') is TJSONObject);
    finally
      LObj.Free;
    end;
  finally
    LNotif.Free;
  end;
end;

procedure TJRPCMessageTest.TestRequestNullParamsRoundTripsAsAbsent;
var
  LParsed: TJRPCRequest;
  LObj: TJSONObject;
begin
  // Incoming "params": null is accepted as "no params" (AssignJRPCParams), and
  // re-serializing drops the member rather than echoing the null back out.
  LParsed := TJRPCRequest.CreateFromJson(
    '{"jsonrpc":"2.0","id":1,"method":"foo","params":null}');
  try
    Assert.AreEqual(TJRPCParamsType.Null, LParsed.ParamsType);
    LObj := ParseObject(LParsed.ToJson);
    try
      Assert.IsNull(LObj.GetValue('params'), 'the null is not echoed back');
    finally
      LObj.Free;
    end;
  finally
    LParsed.Free;
  end;
end;

procedure TJRPCMessageTest.TestRequestMissingMethodIsInvalid;
var
  LMsgs: TJRPCMessages;
begin
  // A message that is neither a Request, a Notification nor a Response is
  // turned into an Invalid Request error response while parsing.
  LMsgs := TJRPCMessages.CreateFromJson('{"jsonrpc":"2.0","id":1}');
  try
    Assert.AreEqual(1, LMsgs.Count);
    Assert.IsTrue(LMsgs.List[0] is TJRPCError);
    Assert.AreEqual(JRPC_INVALID_REQUEST, Integer((LMsgs.List[0] as TJRPCError).Error.Code));
    Assert.AreEqual(1, (LMsgs.List[0] as TJRPCError).Id.AsInteger);
  finally
    LMsgs.Free;
  end;
end;

procedure TJRPCMessageTest.TestRequestParamsCount;
var
  LRequest: TJRPCRequest;
begin
  LRequest := TJRPCRequest.CreateFromJson(
    '{"jsonrpc":"2.0","id":1,"method":"m","params":{"a":1,"b":2,"c":3}}');
  try
    Assert.AreEqual(3, LRequest.ParamsCount);
  finally
    LRequest.Free;
  end;
end;

procedure TJRPCMessageTest.TestNotificationWithParams;
var
  LNotif: TJRPCNotification;
begin
  // Regression test: notifications with params used to double-free the params
  // value (RTL TJSONValueSerializer frees the replaced value, SetParams frees
  // it again). This must parse without crashing and keep the params.
  LNotif := TJRPCNotification.Create;
  try
    LNotif.FromJson('{"jsonrpc":"2.0","method":"math/sum","params":{"a":1,"b":2}}');
    Assert.AreEqual('math/sum', LNotif.Method);
    Assert.AreEqual(TJRPCParamsType.ByName, LNotif.ParamsType);
    Assert.AreEqual(2, LNotif.ParamsCount);
  finally
    LNotif.Free;
  end;
end;

procedure TJRPCMessageTest.TestNotificationSerializeRoundTrip;
var
  LNotif, LParsed: TJRPCNotification;
begin
  LNotif := TJRPCNotification.Create;
  try
    LNotif.FromJson('{"jsonrpc":"2.0","method":"math/sum","params":[1,2]}');
    LParsed := TJRPCNotification.Create;
    try
      LParsed.FromJson(LNotif.ToJson);
      Assert.AreEqual(LNotif.Method, LParsed.Method);
      Assert.AreEqual(TJRPCParamsType.ByPos, LParsed.ParamsType);
      Assert.AreEqual(2, LParsed.ParamsCount);
    finally
      LParsed.Free;
    end;
  finally
    LNotif.Free;
  end;
end;

procedure TJRPCMessageTest.TestNotificationInvalidJsonRpcVersion;
begin
  Assert.WillRaise(
    procedure
    begin
      var LNotif := TJRPCNotification.Create;
      try
        LNotif.FromJson('{"jsonrpc":"1.0","method":"m"}');
      finally
        LNotif.Free;
      end;
    end,
    EJRPCInvalidRequestError);
end;

procedure TJRPCMessageTest.TestResponseSerializeResult;
var
  LResponse: TJRPCResponse;
begin
  LResponse := TJRPCResponse.Create;
  try
    LResponse.Id := 1;
    LResponse.Result := TJSONNumber.Create(42);
    Assert.AreEqual('42', GetResultValue(LResponse.ToJson));
  finally
    LResponse.Free;
  end;
end;

procedure TJRPCMessageTest.TestResponseDeserializeRoundTrip;
var
  LResponse, LParsed: TJRPCResponse;
begin
  LResponse := TJRPCResponse.CreateFromJson(
    '{"jsonrpc":"2.0","id":5,"result":"ok"}');
  try
    Assert.AreEqual('ok', LResponse.Result.Value);
    LParsed := TJRPCResponse.CreateFromJson(LResponse.ToJson);
    try
      Assert.AreEqual('ok', LParsed.Result.Value);
      Assert.AreEqual(5, LParsed.Id.AsInteger);
    finally
      LParsed.Free;
    end;
  finally
    LResponse.Free;
  end;
end;

procedure TJRPCMessageTest.TestResponseNullIdRoundTrip;
var
  LResponse: TJRPCResponse;
begin
  LResponse := TJRPCResponse.Create;
  try
    LResponse.Id := nil;
    LResponse.Result := TJSONNumber.Create(42);
    Assert.IsTrue(LResponse.ToJson.Contains('"id":null'));
  finally
    LResponse.Free;
  end;
end;

procedure TJRPCMessageTest.TestErrorCreateFromJRPCException;
var
  LError: TJRPCError;
begin
  LError := TJRPCError.CreateFromException(
    EJRPCMethodNotFoundError.Create('nope'), 3);
  try
    Assert.AreEqual(JRPC_METHOD_NOT_FOUND, Integer(LError.Error.Code));
    Assert.AreEqual('nope', String(LError.Error.Message));
    Assert.AreEqual(3, LError.Id.AsInteger);
  finally
    LError.Free;
  end;
end;

procedure TJRPCMessageTest.TestErrorCreateFromParseException;
var
  LError: TJRPCError;
begin
  LError := TJRPCError.CreateFromException(
    EJSONParseException.Create('bad json'), TJRPCID(nil));
  try
    Assert.AreEqual(JRPC_PARSE_ERROR, Integer(LError.Error.Code));
    Assert.IsTrue(LError.Id.IsNull);
  finally
    LError.Free;
  end;
end;

procedure TJRPCMessageTest.TestErrorCreateFromGenericException;
var
  LError: TJRPCError;
begin
  // The parse-time counterpart of the invoker's HandleError: the code stays put,
  // but nothing about the exception is described to the client by default.
  LError := TJRPCError.CreateFromException(
    Exception.Create('boom'), 1);
  try
    Assert.AreEqual(JRPC_INTERNAL_ERROR, Integer(LError.Error.Code));
    Assert.IsTrue(LError.Error.Data.IsEmpty, 'no class name in data');
    Assert.AreEqual(SJRPCUnexpectedError, string(LError.Error.Message),
      'a fixed message, not the exception''s own');
  finally
    LError.Free;
  end;
end;

procedure TJRPCMessageTest.TestErrorCreateFromGenericExceptionExposedWhenEnabled;
var
  LError: TJRPCError;
begin
  TJRPCError.ExposeExceptionDetails := True;
  try
    LError := TJRPCError.CreateFromException(Exception.Create('boom'), 1);
    try
      Assert.AreEqual(JRPC_INTERNAL_ERROR, Integer(LError.Error.Code));
      Assert.AreEqual('Exception', LError.Error.Data.AsString);
      Assert.AreEqual('boom', string(LError.Error.Message));
    finally
      LError.Free;
    end;
  finally
    TJRPCError.ExposeExceptionDetails := False;
  end;
end;

procedure TJRPCMessageTest.TestErrorCarriesExceptionData;
var
  LException: EJRPCInvalidParamsError;
  LError: TJRPCError;
begin
  // A JSON-RPC exception can now carry a detail for the "data" member, so a
  // precise reason travels with the stable message instead of replacing it.
  LException := EJRPCInvalidParamsError.Create(SJRPCInvalidMethodParameters);
  try
    LException.Data := 'Parameter "b" not found';
    LError := TJRPCError.CreateFromException(LException, 1);
    try
      Assert.AreEqual(JRPC_INVALID_PARAMS, Integer(LError.Error.Code));
      Assert.AreEqual(SJRPCInvalidMethodParameters, string(LError.Error.Message));
      Assert.AreEqual('Parameter "b" not found', LError.Error.Data.AsString);
    finally
      LError.Free;
    end;
  finally
    LException.Free;
  end;

  // ...and an exception that carries none leaves the member out entirely.
  LException := EJRPCInvalidParamsError.Create(SJRPCInvalidMethodParameters);
  try
    LError := TJRPCError.CreateFromException(LException, 1);
    try
      Assert.IsTrue(LError.Error.Data.IsEmpty, 'no empty data member is emitted');
    finally
      LError.Free;
    end;
  finally
    LException.Free;
  end;
end;

procedure TJRPCMessageTest.TestJRPCExceptionKeepsAConstructorChosenCode;
var
  LException: EJRPCException;
begin
  // EJRPCException.AfterConstruction runs after the constructor body, so it
  // only defaults the code now - a descendant that already chose one keeps it,
  // which is what lets EJRPCInvokerError report the code it was built with.
  LException := EJRPCException.Create('plain');
  try
    Assert.AreEqual(JRPC_INTERNAL_ERROR, LException.Code, 'the default still applies');
  finally
    LException.Free;
  end;

  // The descendants that set their code in their own AfterConstruction are
  // unaffected, since theirs runs after the base one.
  LException := EJRPCParseError.Create('x');
  try
    Assert.AreEqual(JRPC_PARSE_ERROR, LException.Code);
  finally
    LException.Free;
  end;

  LException := EJRPCMethodNotFoundError.Create('x');
  try
    Assert.AreEqual(JRPC_METHOD_NOT_FOUND, LException.Code);
  finally
    LException.Free;
  end;
end;

procedure TJRPCMessageTest.TestErrorProtocolExceptionsKeepTheirMessage;
var
  LError: TJRPCError;
begin
  // Only the unexpected-exception branch is muted. JSON-RPC exceptions carry
  // messages the library wrote on purpose, and the client still gets them.
  LError := TJRPCError.CreateFromException(
    EJRPCMethodNotFoundError.Create('Method [x] non found'), 1);
  try
    Assert.AreEqual(JRPC_METHOD_NOT_FOUND, Integer(LError.Error.Code));
    Assert.AreEqual('Method [x] non found', string(LError.Error.Message));
    Assert.IsTrue(LError.Error.Data.IsEmpty);
  finally
    LError.Free;
  end;

  LError := TJRPCError.CreateFromException(
    EJRPCParseError.Create(SJRPCInvalidJSONReceived), 1);
  try
    Assert.AreEqual(JRPC_PARSE_ERROR, Integer(LError.Error.Code));
    Assert.AreEqual(SJRPCInvalidJSONReceived, string(LError.Error.Message));
  finally
    LError.Free;
  end;
end;

procedure TJRPCMessageTest.TestErrorDetailsAreValidFromBirth;
var
  LError: TJRPCError;
  LObj, LDetails: TJSONObject;
begin
  // "code" and "message" are REQUIRED members. Both are nullable and Neon omits
  // a nullable that was never assigned, so an error object nobody filled in
  // used to serialize as {"error":{}} - nothing a client can act on.
  LError := TJRPCError.Create;
  try
    LError.Id := 1;
    LObj := ParseObject(LError.ToJson);
    try
      LDetails := LObj.GetValue('error') as TJSONObject;
      Assert.IsNotNull(LDetails.GetValue('code'), 'code is present');
      Assert.IsTrue(LDetails.GetValue('code') is TJSONNumber, 'code is a Number');
      Assert.AreEqual(JRPC_INTERNAL_ERROR, StrToInt(LDetails.GetValue('code').Value));
      Assert.IsNotNull(LDetails.GetValue('message'), 'message is present');
      Assert.IsTrue(LDetails.GetValue('message') is TJSONString, 'message is a String');
    finally
      LObj.Free;
    end;
  finally
    LError.Free;
  end;

  // Setting only one of the two still leaves the other valid.
  LError := TJRPCError.Create;
  try
    LError.Id := 1;
    LError.Error.Code := -32001;
    LObj := ParseObject(LError.ToJson);
    try
      LDetails := LObj.GetValue('error') as TJSONObject;
      Assert.AreEqual(-32001, StrToInt(LDetails.GetValue('code').Value), 'the set code wins');
      Assert.IsNotNull(LDetails.GetValue('message'), 'message keeps its default');
    finally
      LObj.Free;
    end;
  finally
    LError.Free;
  end;

  // A malformed error object received from a peer is normalized rather than
  // passed on with a member missing.
  var LMsgs := TJRPCMessages.CreateFromJson('{"jsonrpc":"2.0","error":{},"id":1}');
  try
    LObj := ParseObject((LMsgs.List[0] as TJRPCError).ToJson);
    try
      LDetails := LObj.GetValue('error') as TJSONObject;
      Assert.IsNotNull(LDetails.GetValue('code'));
      Assert.IsNotNull(LDetails.GetValue('message'));
    finally
      LObj.Free;
    end;
  finally
    LMsgs.Free;
  end;
end;

procedure TJRPCMessageTest.TestErrorSerializeNullId;
var
  LError: TJRPCError;
begin
  LError := TJRPCError.CreateFromException(
    Exception.Create('boom'), TJRPCID(nil));
  try
    Assert.IsTrue(LError.ToJson.Contains('"id":null'));
  finally
    LError.Free;
  end;
end;

procedure TJRPCMessageTest.TestErrorClone;
var
  LError, LClone: TJRPCError;
begin
  LError := TJRPCError.CreateFromException(
    EJRPCMethodNotFoundError.Create('nope'), 7);
  try
    LClone := LError.Clone;
    try
      Assert.AreEqual(LError.Error.Code, LClone.Error.Code);
      Assert.AreEqual(LError.Error.Message, LClone.Error.Message);
      Assert.AreEqual(LError.Id.AsInteger, LClone.Id.AsInteger);
    finally
      LClone.Free;
    end;
  finally
    LError.Free;
  end;
end;

procedure TJRPCMessageTest.TestJRPCIDInteger;
begin
  Assert.AreEqual(5, TJRPCID(5).AsInteger);
  Assert.AreEqual('5', TJRPCID(5).AsString);
end;

procedure TJRPCMessageTest.TestJRPCIDString;
begin
  Assert.AreEqual('abc', TJRPCID('abc').AsString);
end;

procedure TJRPCMessageTest.TestJRPCIDIsNull;
begin
  Assert.IsTrue(TJRPCID(nil).IsNull);
end;

procedure TJRPCMessageTest.TestMessagesFromSingleRequest;
var
  LMsgs: TJRPCMessages;
begin
  LMsgs := TJRPCMessages.CreateFromJson(
    '{"jsonrpc":"2.0","id":1,"method":"math/sum","params":{"a":1,"b":2}}');
  try
    Assert.AreEqual(1, LMsgs.Count);
    Assert.IsTrue(LMsgs.Single);
    Assert.IsTrue(LMsgs.List[0] is TJRPCRequest);
  finally
    LMsgs.Free;
  end;
end;

procedure TJRPCMessageTest.TestMessagesFromBatch;
var
  LMsgs: TJRPCMessages;
begin
  LMsgs := TJRPCMessages.CreateFromJson(
    '[' +
    '{"jsonrpc":"2.0","id":1,"method":"a"},' +
    '{"jsonrpc":"2.0","method":"b"},' +
    '{"jsonrpc":"2.0","id":2,"method":"c"}' +
    ']');
  try
    Assert.AreEqual(3, LMsgs.Count);
    Assert.IsFalse(LMsgs.Single);
    Assert.IsTrue(LMsgs.List[0] is TJRPCRequest);
    Assert.IsTrue(LMsgs.List[1] is TJRPCNotification);
    Assert.IsTrue(LMsgs.List[2] is TJRPCRequest);
  finally
    LMsgs.Free;
  end;
end;

procedure TJRPCMessageTest.TestMessagesFromEmptyBatchIsInvalid;
begin
  Assert.WillRaise(
    procedure
    begin
      var LMsgs := TJRPCMessages.CreateFromJson('[]');
      LMsgs.Free;
    end,
    EJRPCInvalidRequestError);
end;

procedure TJRPCMessageTest.TestMessagesFromScalarJSONIsInvalid;
begin
  Assert.WillRaise(
    procedure
    begin
      var LMsgs := TJRPCMessages.CreateFromJson('42');
      LMsgs.Free;
    end,
    EJRPCInvalidRequestError);
end;

procedure TJRPCMessageTest.TestMessagesFromMalformedJSONIsParseError;
begin
  Assert.WillRaise(
    procedure
    begin
      var LMsgs := TJRPCMessages.CreateFromJson('this is not json');
      LMsgs.Free;
    end,
    EJRPCParseError);
end;

procedure TJRPCMessageTest.TestMessagesFromBatchWithInvalidElement;
var
  LMsgs: TJRPCMessages;
begin
  LMsgs := TJRPCMessages.CreateFromJson(
    '[' +
    '{"jsonrpc":"2.0","id":1,"method":"a"},' +
    '42,' +
    '{"jsonrpc":"2.0","id":2,"method":"b"}' +
    ']');
  try
    Assert.AreEqual(3, LMsgs.Count);
    Assert.IsTrue(LMsgs.List[0] is TJRPCRequest);
    Assert.IsTrue(LMsgs.List[1] is TJRPCError);
    Assert.AreEqual(JRPC_INVALID_REQUEST, Integer((LMsgs.List[1] as TJRPCError).Error.Code));
    Assert.IsTrue((LMsgs.List[1] as TJRPCError).Id.IsNull);
    Assert.IsTrue(LMsgs.List[2] is TJRPCRequest);
  finally
    LMsgs.Free;
  end;
end;

procedure TJRPCMessageTest.TestMessagesFromResultAndErrorIsInvalid;
var
  LMsgs: TJRPCMessages;
begin
  // A Response carrying both "result" and "error" is invalid and is converted
  // into an Invalid Request error response while parsing.
  LMsgs := TJRPCMessages.CreateFromJson(
    '{"jsonrpc":"2.0","id":1,"result":1,"error":{"code":-1,"message":"x"}}');
  try
    Assert.AreEqual(1, LMsgs.Count);
    Assert.IsTrue(LMsgs.List[0] is TJRPCError);
    Assert.AreEqual(JRPC_INVALID_REQUEST, Integer((LMsgs.List[0] as TJRPCError).Error.Code));
  finally
    LMsgs.Free;
  end;
end;

procedure TJRPCMessageTest.TestMessagesToJsonSingle;
var
  LMsgs: TJRPCMessages;
begin
  LMsgs := TJRPCMessages.CreateFromJson(
    '{"jsonrpc":"2.0","id":1,"method":"math/sum","params":{"a":1,"b":2}}');
  try
    Assert.IsTrue(not LMsgs.ToJson.StartsWith('['), 'single message serializes as an object');
  finally
    LMsgs.Free;
  end;
end;

procedure TJRPCMessageTest.TestMessagesToJsonFormatIsConsistent;
var
  LMsgs: TJRPCMessages;
begin
  // A batch used to be pretty-printed while a single message was compact, so
  // one endpoint answered in two wire formats depending on what was asked of
  // it. Both now take their formatting from the Neon configuration, which does
  // not enable pretty-printing.
  LMsgs := TJRPCMessages.CreateFromJson(
    '{"jsonrpc":"2.0","id":1,"method":"math/sum","params":{"a":1,"b":2}}');
  try
    Assert.DoesNotContain(LMsgs.ToJson, sLineBreak, 'a single message is compact');
  finally
    LMsgs.Free;
  end;

  LMsgs := TJRPCMessages.CreateFromJson(
    '[' +
    '{"jsonrpc":"2.0","id":1,"method":"a"},' +
    '{"jsonrpc":"2.0","id":2,"method":"b"}' +
    ']');
  try
    Assert.DoesNotContain(LMsgs.ToJson, sLineBreak, 'a batch is compact too');
    // ...and is still parseable as the array it must be.
    Assert.IsTrue(LMsgs.ToJson.StartsWith('['));
  finally
    LMsgs.Free;
  end;
end;

procedure TJRPCMessageTest.TestMessagesToJsonBatch;
var
  LMsgs: TJRPCMessages;
begin
  LMsgs := TJRPCMessages.CreateFromJson(
    '[' +
    '{"jsonrpc":"2.0","id":1,"method":"a"},' +
    '{"jsonrpc":"2.0","id":2,"method":"b"}' +
    ']');
  try
    Assert.IsTrue(LMsgs.ToJson.StartsWith('['), 'batch serializes as an array');
  finally
    LMsgs.Free;
  end;
end;

procedure TJRPCMessageTest.TestMessagesFromStream;
var
  LMsgs: TJRPCMessages;
  LStream: TStringStream;
begin
  LStream := TStringStream.Create(
    '{"jsonrpc":"2.0","id":1,"method":"math/sum","params":{"a":1,"b":2}}');
  try
    LMsgs := TJRPCMessages.Create(True);
    try
      LMsgs.FromJson(LStream);
      Assert.AreEqual(1, LMsgs.Count);
      Assert.IsTrue(LMsgs.List[0] is TJRPCRequest);
    finally
      LMsgs.Free;
    end;
  finally
    LStream.Free;
  end;
end;

procedure TJRPCMessageTest.TestRegistryRegisterAndExists;
begin
  Assert.IsTrue(TJRPCRegistry.Instance.ClassExists(TMathApi));
  Assert.IsTrue(TJRPCRegistry.Instance.ClassExists<TMathApi>);
end;

procedure TJRPCMessageTest.TestRegistryUnregister;
var
  LRegistered: Boolean;
begin
  LRegistered := TJRPCRegistry.Instance.ClassExists(TGreetApi);
  TJRPCRegistry.Instance.UnregisterClass(TGreetApi);
  try
    Assert.IsFalse(TJRPCRegistry.Instance.ClassExists(TGreetApi));
  finally
    if LRegistered then
      TJRPCRegistry.Instance.RegisterClass(TGreetApi);
  end;
end;

procedure TJRPCMessageTest.TestRegistryGetClassInstance;
var
  LInstance: TObject;
begin
  Assert.IsTrue(TJRPCRegistry.Instance.GetClassInstance('math', LInstance));
  try
    Assert.IsNotNull(LInstance);
    Assert.IsTrue(LInstance is TMathApi);
  finally
    LInstance.Free;
  end;
end;

procedure TJRPCMessageTest.TestRegistryConstructorFunc;
var
  LCount: Integer;
  LInstance: TObject;
begin
  LCount := 0;
  // The class is already registered by JRPC.Tests.Api: replace the entry with
  // a custom constructor function, then restore the default registration.
  TJRPCRegistry.Instance.UnregisterClass(TMathApi);
  TJRPCRegistry.Instance.RegisterClass<TMathApi>(
    function: TObject
    begin
      Inc(LCount);
      Result := TMathApi.Create;
    end);
  try
    Assert.IsTrue(TJRPCRegistry.Instance.GetClassInstance('math', LInstance));
    try
      Assert.AreEqual(1, LCount);
      Assert.IsTrue(LInstance is TMathApi);
    finally
      LInstance.Free;
    end;
  finally
    TJRPCRegistry.Instance.UnregisterClass(TMathApi);
    TJRPCRegistry.Instance.RegisterClass(TMathApi);
  end;
end;

procedure TJRPCMessageTest.TestRegistryNeonConfig;
var
  LProxy: TJRPCConstructorProxy;
begin
  Assert.IsTrue(TJRPCRegistry.Instance.GetConstructorProxy('camel', LProxy));
  Assert.IsNotNull(LProxy);
  Assert.IsNotNull(LProxy.NeonConfig);
end;

procedure TJRPCMessageTest.TestRegistryGetConstructorProxy;
var
  LProxy: TJRPCConstructorProxy;
begin
  Assert.IsTrue(TJRPCRegistry.Instance.GetConstructorProxy('math/sum', LProxy));
  Assert.IsNotNull(LProxy);
  Assert.AreEqual(TMathApi, LProxy.TypeTClass);

  // Custom separator class resolves through its own separator
  Assert.IsTrue(TJRPCRegistry.Instance.GetConstructorProxy('custom.hello', LProxy));
  Assert.AreEqual(TCustomSeparatorApi, LProxy.TypeTClass);
end;

procedure TJRPCMessageTest.TestRegistryFlatMethodProxy;
var
  LProxy: TJRPCConstructorProxy;
begin
  // A flat class ([JRPCPath('')]) is reached through its fully qualified
  // method names, with or without a separator in them.
  Assert.IsTrue(TJRPCRegistry.Instance.GetConstructorProxy('tools/call', LProxy));
  Assert.AreEqual(TFlatApi, LProxy.TypeTClass);

  Assert.IsTrue(TJRPCRegistry.Instance.GetConstructorProxy('ping', LProxy));
  Assert.AreEqual(TFlatApi, LProxy.TypeTClass);

  // It is keyed by its qualified class name, so the "tools" prefix alone
  // resolves to nothing.
  Assert.IsTrue(TJRPCRegistry.Instance.ClassExists(TFlatApi));
  Assert.IsFalse(TJRPCRegistry.Instance.GetConstructorProxy('tools', LProxy));
end;

procedure TJRPCMessageTest.TestRegistryFlatUnregisterRemovesMethods;
var
  LProxy: TJRPCConstructorProxy;
begin
  TJRPCRegistry.Instance.UnregisterClass(TFlatApi);
  try
    Assert.IsFalse(TJRPCRegistry.Instance.ClassExists(TFlatApi));
    Assert.IsFalse(TJRPCRegistry.Instance.GetConstructorProxy('tools/call', LProxy));
  finally
    // Re-registering must not raise SJRPCDuplicateFlatMethod: the flat index
    // is cleaned up together with the class.
    TJRPCRegistry.Instance.RegisterClass(TFlatApi);
  end;
  Assert.IsTrue(TJRPCRegistry.Instance.GetConstructorProxy('tools/call', LProxy));
end;

procedure TJRPCMessageTest.TestGarbageCollectorFreesObjects;
var
  LGarbage: IGarbageCollector;
  LObj: TObject;
begin
  LGarbage := TGarbageCollector.CreateInstance;
  LObj := TObject.Create;
  LGarbage.Add(LObj);
  LGarbage := nil; // release -> collects
  // If the object were leaked, FastMM would report it at shutdown.
end;

procedure TJRPCMessageTest.TestGarbageCollectorCustomAction;
var
  LGarbage: IGarbageCollector;
  LObj: TObject;
  LActionRan: Boolean;
begin
  LActionRan := False;
  LGarbage := TGarbageCollector.CreateInstance;
  LObj := TObject.Create;
  LGarbage.Add(LObj,
    procedure
    begin
      LActionRan := True;
      LObj.Free;
    end);
  LGarbage := nil;
  Assert.IsTrue(LActionRan);
end;

procedure TJRPCMessageTest.TestGarbageCollectorIgnoresNonObjects;
var
  LGarbage: IGarbageCollector;
begin
  LGarbage := TGarbageCollector.CreateInstance;
  // Must not raise on non-object values
  LGarbage.Add(TValue.From<Integer>(42));
  LGarbage.Add(TValue.From<string>('x'));
  LGarbage := nil;
end;

procedure TJRPCMessageTest.TestGarbageCollectorFreesArrayItems;
var
  LGarbage: IGarbageCollector;
  LItems: TArray<TObject>;
begin
  LGarbage := TGarbageCollector.CreateInstance;
  LItems := [TObject.Create, TObject.Create];
  LGarbage.Add(TValue.From<TArray<TObject>>(LItems));
  LGarbage := nil;
end;

procedure TJRPCMessageTest.TestGarbageCollectorAddTwice;
var
  LGarbage: IGarbageCollector;
  LObj: TObject;
begin
  LGarbage := TGarbageCollector.CreateInstance;
  LObj := TObject.Create;
  LGarbage.Add(LObj);
  LGarbage.Add(LObj); // duplicate must be ignored, no double free later
  LGarbage := nil;
end;

procedure TJRPCMessageTest.TestContextAddAndFind;
var
  LContext: TContextManager;
  LData: TContextData;
begin
  LContext := TContextManager.Create;
  try
    LData := TContextData.Create;
    LData.Value := 42;
    try
      LContext.AddContent(LData);
      Assert.AreEqual(42, LContext.FindContextDataAs<TContextData>.Value);
      Assert.IsTrue(LContext.GetContextDataAs(TContextData) = LData);
    finally
      LData.Free;
    end;
  finally
    LContext.Free;
  end;
end;

procedure TJRPCMessageTest.TestContextGetMissingRaises;
var
  LContext: TContextManager;
begin
  LContext := TContextManager.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        LContext.GetContextDataAs(TContextData);
      end,
      ECtxException);
  finally
    LContext.Free;
  end;
end;

procedure TJRPCMessageTest.TestContextInjectClassField;
var
  LContext: TContextManager;
  LTarget: TContextTarget;
  LData: TContextData;
  LMarker: IContextMarker;
begin
  LContext := TContextManager.Create;
  LTarget := TContextTarget.Create;
  LData := TContextData.Create;
  LMarker := TContextMarker.Create(1);
  try
    LData.Value := 7;
    LContext.AddContent(LData);
    LContext.AddContent(LMarker);
    LContext.Inject(LTarget);
    Assert.IsNotNull(LTarget.Data);
    Assert.AreEqual(7, LTarget.Data.Value);
  finally
    LMarker := nil;
    LData.Free;
    LTarget.Free;
    LContext.Free;
  end;
end;

procedure TJRPCMessageTest.TestContextInjectInterfaceField;
var
  LContext: TContextManager;
  LTarget: TContextTarget;
  LData: TContextData;
  LMarker: IContextMarker;
begin
  LContext := TContextManager.Create;
  LTarget := TContextTarget.Create;
  LData := TContextData.Create;
  LMarker := TContextMarker.Create(9);
  try
    LContext.AddContent(LData);
    LContext.AddContent(LMarker);
    LContext.Inject(LTarget);
    Assert.IsNotNull(LTarget.Marker);
    Assert.AreEqual(9, LTarget.Marker.Id);
  finally
    LMarker := nil;
    LData.Free;
    LTarget.Free;
    LContext.Free;
  end;
end;

procedure TJRPCMessageTest.TestRouteMatcherMatch;
var
  LMatcher: TRouteMatcher;
begin
  LMatcher := TRouteMatcher.Create;
  try
    Assert.IsTrue(LMatcher.Match('/users/{id}', '/users/42'));
    Assert.IsTrue(LMatcher.Match('/a/{x}/b/{y}', '/a/1/b/2'));
  finally
    LMatcher.Free;
  end;
end;

procedure TJRPCMessageTest.TestRouteMatcherParams;
var
  LMatcher: TRouteMatcher;
begin
  LMatcher := TRouteMatcher.Create;
  try
    Assert.IsTrue(LMatcher.Match('/users/{id}', '/users/42'));
    Assert.AreEqual('42', LMatcher.Params['id']);
  finally
    LMatcher.Free;
  end;
end;

procedure TJRPCMessageTest.TestRouteMatcherUrlDecode;
var
  LMatcher: TRouteMatcher;
begin
  LMatcher := TRouteMatcher.Create;
  try
    Assert.IsTrue(LMatcher.Match('/files/{name}', '/files/my%20file.txt'));
    Assert.AreEqual('my file.txt', LMatcher.Params['name']);
  finally
    LMatcher.Free;
  end;
end;

procedure TJRPCMessageTest.TestRouteMatcherNonMatch;
var
  LMatcher: TRouteMatcher;
begin
  LMatcher := TRouteMatcher.Create;
  try
    Assert.IsFalse(LMatcher.Match('/users/{id}', '/orders/42'));
  finally
    LMatcher.Free;
  end;
end;

{ TJRPCInstrumentationTest }

// Registers a Logify buffer adapter (default category) that collects the
// formatted log lines into ATarget. Returns the unique factory name so the
// test can unregister it in the finally block.
function RegisterBufferAdapter(const AName: string; ALevel: TLogLevel; ATarget: TStrings): string;
var
  LFactory: ILoggerAdapterFactory;
begin
  Result := AName;
  LFactory := TLogifyAdapterBufferFactory.CreateAdapterFactory(AName, ALevel, ATarget);
  TLoggerAdapterRegistry.Instance.RegisterFactory(LFactory);
end;

procedure TJRPCInstrumentationTest.TestLoggerRoutesFormattedMessages;
var
  LTarget: TStringList;
begin
  LTarget := TStringList.Create;
  try
    RegisterBufferAdapter('JRPC.Tests.Buffered', TLogLevel.Debug, LTarget);
    try
      Logger.LogDebug('[PERF] %s took %d ms', ['math/sum', 42]);
      Assert.AreEqual(1, LTarget.Count);
      Assert.Contains(LTarget.Text, '[PERF] math/sum took 42 ms');
    finally
      TLoggerAdapterRegistry.Instance.UnregisterFactory('JRPC.Tests.Buffered');
    end;
  finally
    LTarget.Free;
  end;
end;

procedure TJRPCInstrumentationTest.TestLoggerRoutesLevels;
var
  LTarget: TStringList;
begin
  LTarget := TStringList.Create;
  try
    RegisterBufferAdapter('JRPC.Tests.Levels', TLogLevel.Debug, LTarget);
    try
      Logger.LogDebug('debug-msg');
      Logger.LogInfo('info-msg');
      Logger.LogWarning('warn-msg');
      Logger.LogError('error-msg');
      Assert.AreEqual(4, LTarget.Count);
      Assert.Contains(LTarget.Text, 'debug-msg');
      Assert.Contains(LTarget.Text, 'info-msg');
      Assert.Contains(LTarget.Text, 'warn-msg');
      Assert.Contains(LTarget.Text, 'error-msg');
    finally
      TLoggerAdapterRegistry.Instance.UnregisterFactory('JRPC.Tests.Levels');
    end;
  finally
    LTarget.Free;
  end;
end;

procedure TJRPCInstrumentationTest.TestLoggerLevelFiltering;
var
  LTarget: TStringList;
begin
  LTarget := TStringList.Create;
  try
    // A Warning-level adapter drops Debug and Info messages.
    RegisterBufferAdapter('JRPC.Tests.Filtered', TLogLevel.Warning, LTarget);
    try
      Logger.LogDebug('dropped-debug');
      Logger.LogInfo('dropped-info');
      Logger.LogWarning('kept-warning');
      Logger.LogError('kept-error');
      Assert.AreEqual(2, LTarget.Count);
      Assert.Contains(LTarget.Text, 'kept-warning');
      Assert.Contains(LTarget.Text, 'kept-error');
    finally
      TLoggerAdapterRegistry.Instance.UnregisterFactory('JRPC.Tests.Filtered');
    end;
  finally
    LTarget.Free;
  end;
end;

procedure TJRPCInstrumentationTest.TestLoggerUnregisterStopsOutput;
var
  LTarget: TStringList;
begin
  LTarget := TStringList.Create;
  try
    RegisterBufferAdapter('JRPC.Tests.Once', TLogLevel.Debug, LTarget);
    Logger.LogDebug('first');
    TLoggerAdapterRegistry.Instance.UnregisterFactory('JRPC.Tests.Once');
    Logger.LogDebug('second');
    Assert.AreEqual(1, LTarget.Count);
    Assert.Contains(LTarget.Text, 'first');
  finally
    LTarget.Free;
  end;
end;

{ TContextMarker }

constructor TContextMarker.Create(AId: Integer);
begin
  inherited Create;
  FId := AId;
end;

function TContextMarker.GetId: Integer;
begin
  Result := FId;
end;

initialization
  TDUnitX.RegisterTestFixture(TJRPCMessageTest);
  TDUnitX.RegisterTestFixture(TJRPCInstrumentationTest);

end.
