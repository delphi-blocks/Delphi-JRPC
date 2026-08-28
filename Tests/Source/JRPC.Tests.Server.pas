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
    [Test] procedure TestProcessRequestMethodNotAStringIsInvalidRequest;
    [Test] procedure TestProcessRequestMethodErrorCarriesNoRTLDetail;
    [Test] procedure TestProcessRequestEmptyMethodIsMethodNotFound;
    [Test] procedure TestProcessRequestParamErrorsCarryTheirReason;
    [Test] procedure TestProcessRequestParamsNotStructuredIsInvalidParams;
    [Test] procedure TestProcessRequestParamsNullIsTreatedAsAbsent;
    [Test] procedure TestProcessRequestNotificationBadParamsNoResponse;
    [Test] procedure TestProcessRequestMalformedNotificationNoResponse;
    [Test] procedure TestProcessRequestUnparsableIdIsNotANotification;
    [Test] procedure TestProcessRequestBatchNotificationErrorsNotAnswered;
    [Test] procedure TestProcessRequestProcedureReturnsNullResult;
    [Test] procedure TestProcessRequestProcedureNotificationNoResponse;
    [Test] procedure TestProcessRequestBatchOfOneStaysArray;
    [Test] procedure TestProcessRequestBatchSingleAnswerStaysArray;
    [Test] procedure TestProcessRequestSingleStaysObject;
    [Test] procedure TestProcessRequestEmptyBatchAnswersObject;
    [Test] procedure TestProcessRequestMethodNotFound;
    [Test] procedure TestProcessRequestInvalidParams;
    [Test] procedure TestProcessRequestMissingParam;
    [Test] procedure TestProcessRequestWholeParamsObject;
    [Test] procedure TestProcessRequestEnumParam;
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
  System.Classes, System.Generics.Collections,
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
    Assert.IsTrue(LResponse.Contains('"id":1'), 'the id is echoed: ' + LResponse);
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

procedure TJRPCServerTest.TestProcessRequestMethodNotAStringIsInvalidRequest;
var
  LServer: TJRPCServer;
begin
  LServer := TJRPCServer.Create(nil);
  try
    // "method" MUST be a String. A number used to be coerced into its text and
    // answered with a misleading -32601 "Method [123] non found", as if the
    // client had asked for a method that merely happened not to exist.
    Assert.AreEqual(JRPC_INVALID_REQUEST, ErrorCodeOf(LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":1,"method":123}')), 'a number method is rejected');
    Assert.AreEqual(JRPC_INVALID_REQUEST, ErrorCodeOf(LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":2,"method":true}')), 'a boolean method is rejected');
    Assert.AreEqual(JRPC_INVALID_REQUEST, ErrorCodeOf(LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":3,"method":{"a":1}}')), 'an object method is rejected');
    Assert.AreEqual(JRPC_INVALID_REQUEST, ErrorCodeOf(LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":4,"method":["a"]}')), 'an array method is rejected');
    Assert.AreEqual(JRPC_INVALID_REQUEST, ErrorCodeOf(LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":5,"method":null}')), 'a null method is rejected');

    // And a notification with a bad method is still never answered.
    Assert.AreEqual('', LServer.ProcessRequest('{"jsonrpc":"2.0","method":123}'));
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestMethodErrorCarriesNoRTLDetail;
var
  LServer: TJRPCServer;
  LResponse: string;
  LObj: TJSONObject;
  LErr: TJSONValue;
begin
  LServer := TJRPCServer.Create(nil);
  try
    // An object method used to reach TJSONValue.GetValue<string> and escape as
    // a raw RTL conversion message quoted verbatim to the client, carrying an
    // instance address and "data":"EJSONException".
    LResponse := LServer.ProcessRequest('{"jsonrpc":"2.0","id":1,"method":{"a":1}}');
    LObj := ParseObject(LResponse);
    try
      Assert.IsNotNull(LObj);
      LErr := LObj.GetValue('error');
      Assert.IsTrue(Assigned(LErr) and (LErr is TJSONObject));
      Assert.IsNull(TJSONObject(LErr).GetValue('data'),
        'no exception class name is leaked in data');
      Assert.AreEqual(SJRPCInvalidMethodMember,
        TJSONObject(LErr).GetValue('message').Value,
        'the message is ours, not the RTL conversion text');
    finally
      LObj.Free;
    end;
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestEmptyMethodIsMethodNotFound;
var
  LServer: TJRPCServer;
begin
  LServer := TJRPCServer.Create(nil);
  try
    // An empty string is still a String, so it is a well-formed Request asking
    // for a method that does not exist - not an Invalid Request.
    Assert.AreEqual(JRPC_METHOD_NOT_FOUND, ErrorCodeOf(LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":1,"method":""}')));
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestParamErrorsCarryTheirReason;

  function ErrorDataOf(const AJSON: string): string;
  var
    LObj: TJSONObject;
    LErr: TJSONValue;
  begin
    Result := '';
    LObj := ParseObject(AJSON);
    if Assigned(LObj) then
    try
      LErr := LObj.GetValue('error');
      if Assigned(LErr) and (LErr is TJSONObject) then
      begin
        LErr := TJSONObject(LErr).GetValue('data');
        if Assigned(LErr) then
          Result := LErr.Value;
      end;
    finally
      LObj.Free;
    end;
  end;

  function ErrorMessageOf(const AJSON: string): string;
  var
    LObj: TJSONObject;
    LErr: TJSONValue;
  begin
    Result := '';
    LObj := ParseObject(AJSON);
    if Assigned(LObj) then
    try
      LErr := LObj.GetValue('error');
      if Assigned(LErr) and (LErr is TJSONObject) then
        Result := TJSONObject(LErr).GetValue('message').Value;
    finally
      LObj.Free;
    end;
  end;

var
  LServer: TJRPCServer;
  LResponse: string;
begin
  LServer := TJRPCServer.Create(nil);
  try
    // The invoker works out exactly which parameter was wrong; that reason used
    // to be replaced wholesale by the flat "Invalid method parameters.", so the
    // caller was told the parameters were bad but never which or why. It now
    // travels in "data", where the spec puts additional information, while
    // "message" stays the one-liner clients can group on.

    // a named parameter the request never sent
    LResponse := LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":1,"method":"math/sum","params":{"a":5}}');
    Assert.AreEqual(JRPC_INVALID_PARAMS, ErrorCodeOf(LResponse));
    Assert.AreEqual(SJRPCInvalidMethodParameters, ErrorMessageOf(LResponse),
      'the message stays stable');
    Assert.AreEqual(Format(SJRPCParamNotFound, ['b']), ErrorDataOf(LResponse),
      'data names the missing parameter');

    // too few positional parameters
    LResponse := LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":2,"method":"math/sum","params":[1]}');
    Assert.AreEqual(JRPC_INVALID_PARAMS, ErrorCodeOf(LResponse));
    Assert.AreEqual(Format(SJRPCParamIndexNotFound, [1, 1]), ErrorDataOf(LResponse),
      'data reports the index and the count');

    // a parameter of the wrong JSON type
    LResponse := LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":3,"method":"math/sum","params":{"a":"x","b":1}}');
    Assert.AreEqual(JRPC_INVALID_PARAMS, ErrorCodeOf(LResponse));
    Assert.AreEqual(Format(SJRPCInvalidParamForString, ['a']), ErrorDataOf(LResponse),
      'data names the parameter and the offending type');

    // the method takes parameters and none were sent: Invalid params, and the
    // reason is the truth rather than the old internal "Unknown params type"
    LResponse := LServer.ProcessRequest('{"jsonrpc":"2.0","id":4,"method":"math/sum"}');
    Assert.AreEqual(JRPC_INVALID_PARAMS, ErrorCodeOf(LResponse));
    Assert.AreEqual(Format(SJRPCParamsRequired, ['a']), ErrorDataOf(LResponse));

    // a call that is fine still carries no error at all
    LResponse := LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":5,"method":"math/sum","params":{"a":1,"b":1}}');
    Assert.AreEqual('2', GetResultValue(LResponse));
    Assert.AreEqual('', ErrorDataOf(LResponse));
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestParamsNotStructuredIsInvalidParams;
var
  LServer: TJRPCServer;
begin
  LServer := TJRPCServer.Create(nil);
  try
    // "params" must be an Array or an Object. A scalar used to be discarded in
    // silence, so a method taking no arguments answered with a plausible result
    // instead of reporting that the call was malformed.
    Assert.AreEqual(JRPC_INVALID_PARAMS, ErrorCodeOf(LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":1,"method":"math/sum","params":"bogus"}')),
      'a string params is rejected');
    Assert.AreEqual(JRPC_INVALID_PARAMS, ErrorCodeOf(LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":2,"method":"math/sum","params":7}')),
      'a number params is rejected');
    Assert.AreEqual(JRPC_INVALID_PARAMS, ErrorCodeOf(LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":3,"method":"math/sum","params":true}')),
      'a boolean params is rejected');
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestParamsNullIsTreatedAsAbsent;
var
  LServer: TJRPCServer;
  LResponse: string;
begin
  LServer := TJRPCServer.Create(nil);
  try
    // A JSON null carries no parameters to misread and is what a great many
    // clients emit for a call that takes none, so it is accepted as "no params"
    // rather than rejected alongside the scalars above.
    LResponse := LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":1,"method":"math/reset","params":null}');
    Assert.AreNotEqual(JRPC_INVALID_PARAMS, ErrorCodeOf(LResponse),
      'a null params is tolerated');
    LResponse := LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":2,"method":"math/sum","params":{"a":1,"b":1}}');
    Assert.AreEqual('2', GetResultValue(LResponse), 'valid params still work');
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestNotificationBadParamsNoResponse;
var
  LServer: TJRPCServer;
begin
  LServer := TJRPCServer.Create(nil);
  try
    // Rejecting the params must not turn a notification into something the
    // server answers: notifications are not confirmable, malformed or not.
    Assert.AreEqual('', LServer.ProcessRequest(
      '{"jsonrpc":"2.0","method":"math/sum","params":"bogus"}'));
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestMalformedNotificationNoResponse;
var
  LServer: TJRPCServer;
begin
  LServer := TJRPCServer.Create(nil);
  try
    // Same rule for every other way a notification can fail to parse.
    Assert.AreEqual('', LServer.ProcessRequest(
      '{"jsonrpc":"1.0","method":"math/sum","params":[1,2]}'),
      'a notification with a bad version is not answered');
    Assert.AreEqual('', LServer.ProcessRequest(
      '{"jsonrpc":"2.0","method":{"a":1}}'),
      'a notification with a non-string method is not answered');
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestUnparsableIdIsNotANotification;
var
  LServer: TJRPCServer;
  LResponse: string;
begin
  LServer := TJRPCServer.Create(nil);
  try
    // An id that is present but unusable does not make the message a
    // notification: the client is waiting, and gets an answer with a null id.
    LResponse := LServer.ProcessRequest(
      '{"jsonrpc":"2.0","method":"math/sum","params":"bogus","id":true}');
    Assert.AreNotEqual('', LResponse, 'a request with a bad id is still answered');
    Assert.AreEqual(JRPC_INVALID_REQUEST, ErrorCodeOf(LResponse));

    // And a message with no method was never identifiable as a notification.
    Assert.AreNotEqual('', LServer.ProcessRequest('{}'),
      'an unidentifiable message is still answered');
    Assert.AreNotEqual('', LServer.ProcessRequest('{"jsonrpc":"2.0"}'),
      'an unidentifiable message is still answered');
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestBatchNotificationErrorsNotAnswered;
var
  LServer: TJRPCServer;
  LResponse: string;
begin
  LServer := TJRPCServer.Create(nil);
  try
    // In a batch, only the request is answered - the rejected notification
    // contributes nothing, and the reply stays an array.
    LResponse := LServer.ProcessRequest(
      '[' +
      '{"jsonrpc":"2.0","id":1,"method":"math/sum","params":"bogus"},' +
      '{"jsonrpc":"2.0","method":"math/sum","params":"bogus"}' +
      ']');
    Assert.IsTrue(IsArrayOfSize(LResponse, 1), 'only the request is answered');

    // A batch of only rejected notifications produces no reply at all.
    Assert.AreEqual('', LServer.ProcessRequest(
      '[{"jsonrpc":"2.0","method":"math/sum","params":"bogus"}]'));
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestProcedureReturnsNullResult;
var
  LServer: TJRPCServer;
  LResponse: string;
  LObj: TJSONObject;
  LRes: TJSONValue;
begin
  LServer := TJRPCServer.Create(nil);
  try
    // End to end: a void API method used to answer with an access violation
    // wrapped in -32603 (leaking a code address to the client).
    LResponse := LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":3,"method":"math/store","params":{"value":42}}');
    LObj := ParseObject(LResponse);
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
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestProcedureNotificationNoResponse;
var
  LServer: TJRPCServer;
begin
  LServer := TJRPCServer.Create(nil);
  try
    // The same void method called without an id is a notification: still no
    // answer at all, and still no exception on the way there.
    Assert.AreEqual('', LServer.ProcessRequest(
      '{"jsonrpc":"2.0","method":"math/store","params":{"value":42}}'));
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestBatchOfOneStaysArray;
var
  LServer: TJRPCServer;
  LResponse: string;
begin
  LServer := TJRPCServer.Create(nil);
  try
    // A batch is answered with an Array even when it holds a single request:
    // the reply mirrors the shape of the payload, not the message count.
    LResponse := LServer.ProcessRequest(
      '[{"jsonrpc":"2.0","id":1,"method":"math/sum","params":{"a":1,"b":1}}]');
    Assert.IsTrue(IsArrayOfSize(LResponse, 1), 'a batch of one still answers with an array');
    Assert.AreEqual('2', GetBatchResultValue(LResponse, 0));
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestBatchSingleAnswerStaysArray;
var
  LServer: TJRPCServer;
  LResponse: string;
begin
  LServer := TJRPCServer.Create(nil);
  try
    // Same rule when the batch is larger but only one element is answerable:
    // the notifications produce nothing, the single Response stays wrapped.
    LResponse := LServer.ProcessRequest(
      '[' +
      '{"jsonrpc":"2.0","id":1,"method":"math/sum","params":{"a":1,"b":1}},' +
      '{"jsonrpc":"2.0","method":"math/sum","params":{"a":9,"b":9}},' +
      '{"jsonrpc":"2.0","method":"math/sum","params":{"a":3,"b":4}}' +
      ']');
    Assert.IsTrue(IsArrayOfSize(LResponse, 1), 'one answer in a batch is still an array');
    Assert.AreEqual('2', GetBatchResultValue(LResponse, 0));
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestSingleStaysObject;
var
  LServer: TJRPCServer;
  LResponse: string;
begin
  LServer := TJRPCServer.Create(nil);
  try
    // The converse: a bare Request object must never be answered with an array.
    LResponse := LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":1,"method":"math/sum","params":{"a":1,"b":1}}');
    Assert.IsFalse(IsArrayOfSize(LResponse, 1), 'a single request is not answered with an array');
    Assert.AreEqual('2', GetResultValue(LResponse));
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestEmptyBatchAnswersObject;
var
  LServer: TJRPCServer;
  LResponse: string;
begin
  LServer := TJRPCServer.Create(nil);
  try
    // An empty array never became a batch, so its Invalid Request is reported
    // as a bare Response object - the spec is explicit about this one.
    LResponse := LServer.ProcessRequest('[]');
    Assert.IsFalse(IsArrayOfSize(LResponse, 1), 'an empty batch answers with an object');
    Assert.AreEqual(JRPC_INVALID_REQUEST, ErrorCodeOf(LResponse));
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

procedure TJRPCServerTest.TestProcessRequestMissingParam;
var
  LServer: TJRPCServer;
  LResponse: string;
begin
  // "b" is not supplied at all: invalid params, like a wrongly typed one.
  LServer := TJRPCServer.Create(nil);
  try
    LResponse := LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":10,"method":"math/sum","params":{"a":5}}');
    Assert.AreEqual(JRPC_INVALID_PARAMS, ErrorCodeOf(LResponse));
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestWholeParamsObject;
var
  LServer: TJRPCServer;
  LResponse: string;
begin
  // [JRPCParams]: the whole params object is deserialized into one argument.
  LServer := TJRPCServer.Create(nil);
  try
    LResponse := LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":13,"method":"greet/hello",' +
      '"params":{"Salutation":"Hello","Name":"World"}}');
    Assert.AreEqual('Hello, World!', GetResultValue(LResponse));
  finally
    LServer.Free;
  end;
end;

procedure TJRPCServerTest.TestProcessRequestEnumParam;
var
  LServer: TJRPCServer;
  LResponse: string;
begin
  // Enums travel by name.
  LServer := TJRPCServer.Create(nil);
  try
    LResponse := LServer.ProcessRequest(
      '{"jsonrpc":"2.0","id":14,"method":"math/apply",' +
      '"params":{"op":"opMultiply","a":6,"b":7}}');
    Assert.AreEqual('42', GetResultValue(LResponse));
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
