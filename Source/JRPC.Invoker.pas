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
unit JRPC.Invoker;

interface

uses
  System.SysUtils, System.Rtti, System.Classes, System.Generics.Collections,
  System.TypInfo, System.JSON,

  Neon.Core.Utils,
  Neon.Core.Types,
  Neon.Core.Nullables,
  Neon.Core.Attributes,
  Neon.Core.Persistence,
  Neon.Core.Persistence.JSON,

  JRPC.Classes,
  JRPC.Core;


type
  /// <summary>
  ///   This exception is raised when an error occurs during the invocation of a JRPC method. 
  ///   It provides the standard information required by the JSON-RPC specification.
  /// </summary>
  EJRPCInvokerError = class(Exception)
  private
    FCode: Integer;
    FData: string;
  public
    property Code: Integer read FCode;
    property Data: string read FData;

    constructor Create(ACode: Integer; const AMessage: string; const AData: string = '');
  end;

  TJRPCInvokerContext = record
    Garbage: IGarbageCollector;
    Request: TJRPCRequest;
    Responses: TJRPCMessages;

    ApiInstance: TObject;
    NeonConfig: INeonConfiguration;

    procedure SelectConfig(AApiConfig: INeonConfiguration);
  end;

  /// <summary>
  ///   This class Invokes a specific method on a given instance.
  ///   The method to be invoked is reached through RTTI
  ///   using the JRPC specific attributes.
  /// </summary>
  TJRPCInvoker = class
  private
    FRttiType: TRttiType;
    FContext: TJRPCInvokerContext;
    FNeonConfig: INeonConfiguration;
    FSeparator: string;
    /// <summary>
    ///   True when the API class contributes no path prefix ([JRPCPath('')] or
    ///   no attribute at all): its methods carry the full JSON-RPC method name,
    ///   so the request method is matched as-is instead of being stripped.
    /// </summary>
    FFlatMode: Boolean;

    function FindMethod(ARequest: TJRPCRequest): TRttiMethod;
    function GetRequestMethodName(ARequest: TJRPCRequest): string;
    function RetrieveNeonConfig(ANeonConfig: INeonConfiguration): INeonConfiguration;
    function GetParamName(LParam: TRttiParameter): string;
    function RequestToRttiParams(AMethod: TRttiMethod): TArray<TValue>;
    procedure InternalInvoke;
  public

    constructor Create(AContext: TJRPCInvokerContext);
  public
    class function HandleError(E: Exception; AId: TJRPCID): TJRPCError; static;
    class procedure Invoke(AContext: TJRPCInvokerContext);
  end;

implementation

uses
  System.Diagnostics,

  Logify;

// Checks the compatibility of the JSONValue with the function parameters.
// Enums and records (including Nullable types) are handled natively by Neon
// from multiple JSON representations, so they skip the check.
procedure CheckCompatibility(AParam: TRttiParameter; AValue: TJSONValue);
begin
  if AParam.ParamType.TypeKind in [tkEnumeration, tkRecord] then
    Exit;

  if AValue is TJSONNumber then
  begin
    if not (AParam.ParamType.TypeKind in [tkInteger, tkFloat, tkInt64]) then
      raise EJRPCInvokerError.Create(JRPC_INVALID_PARAMS, Format(SJRPCInvalidParamForNumber, [AParam.Name]));
  end
  else if AValue is TJSONString then
  begin
    if not (AParam.ParamType.TypeKind in [tkString, tkWChar, tkLString, tkWString, tkUString]) then
      raise EJRPCInvokerError.Create(JRPC_INVALID_PARAMS, Format(SJRPCInvalidParamForString, [AParam.Name]));
  end
  else if AValue is TJSONObject then
  begin
    if not (AParam.ParamType.TypeKind in [tkClass, tkRecord, tkInterface]) then
      raise EJRPCInvokerError.Create(JRPC_INVALID_PARAMS, Format(SJRPCInvalidParamForObject, [AParam.Name]));
  end
  else if AValue is TJSONArray then
  begin
    if not (AParam.ParamType.TypeKind in [tkArray, tkDynArray]) then
      raise EJRPCInvokerError.Create(JRPC_INVALID_PARAMS, Format(SJRPCInvalidParamForArray, [AParam.Name]));
  end
  else
    raise EJRPCInvokerError.Create(JRPC_INVALID_PARAMS, Format(SJRPCInvalidParam, [AParam.Name]));
end;

constructor TJRPCInvoker.Create(AContext: TJRPCInvokerContext);
begin
  inherited Create;
  FSeparator := '/';
  FContext := AContext;
  FRttiType := TRttiUtils.GetType(AContext.ApiInstance);

  FNeonConfig := RetrieveNeonConfig(AContext.NeonConfig);

  // A class without a path attribute contributes no prefix: flat by default,
  // unless the attribute below declares a path.
  FFlatMode := True;
  TRttiUtils.HasAttribute<JRPCAttribute>(FRttiType,
    procedure (LAttrib: JRPCAttribute)
    begin
      if LAttrib.Tags.Exists('separator') then
        FSeparator := LAttrib.Tags.GetValueAs<string>('separator');
      FFlatMode := LAttrib.Name.IsEmpty;
    end
  );
end;

function TJRPCInvoker.FindMethod(ARequest: TJRPCRequest): TRttiMethod;
var
  LMethod: TRttiMethod;
  LJRPCAttrib: JRPCAttribute;
  LMethodName: string;
  LRequestMethodName: string;
begin
  Result := nil;
  LRequestMethodName := GetRequestMethodName(ARequest);
  for LMethod in FRttiType.GetMethods do
  begin
    LJRPCAttrib := TRttiUtils.FindAttribute<JRPCAttribute>(LMethod);
    if Assigned(LJRPCAttrib) then
      LMethodName := LJRPCAttrib.Name
    else
      LMethodName := LMethod.Name;

    if LRequestMethodName = LMethodName then
      Exit(LMethod);
  end;
end;

procedure TJRPCInvoker.InternalInvoke;
var
  LMethod: TRttiMethod;
  LResponse: TJRPCResponse;
  LArgs: TArray<TValue>;
  LResult: TValue;
  LStopwatch: TStopwatch;
begin
  LStopwatch := TStopwatch.StartNew;
  LMethod := FindMethod(FContext.Request);
  if not Assigned(LMethod) then
    raise EJRPCMethodNotFoundError.CreateFmt(SJRPCMethodNonFound, [FContext.Request.Method]);
  Logger.LogDebug('[PERF] JRPC [%s] FindMethod: %d ms', [FContext.Request.Method, LStopwatch.ElapsedMilliseconds]);

  LStopwatch := TStopwatch.StartNew;
  try
    LArgs := RequestToRttiParams(LMethod);
    FContext.Garbage.Add(LArgs);
  except
    Exception.RaiseOuterException(EJRPCInvalidParamsError.Create(SJRPCInvalidMethodParameters));
  end;
  Logger.LogDebug('[PERF] JRPC [%s] RequestToRttiParams: %d ms', [FContext.Request.Method, LStopwatch.ElapsedMilliseconds]);

  LStopwatch := TStopwatch.StartNew;
  try
    LResult := LMethod.Invoke(FContext.ApiInstance, LArgs);
    FContext.Garbage.Add(LResult);
    LResponse := TJRPCResponse.Create;
  except
    on E: EJRPCException do
      raise;
    on E: Exception do
      raise EJRPCException.CreateFmt(SJRPCErrorCallingApiMethod,
        [FContext.ApiInstance.ClassName, FContext.Request.Method]);
  end;
  Logger.LogDebug('[PERF] JRPC [%s] Method.Invoke: %d ms', [FContext.Request.Method, LStopwatch.ElapsedMilliseconds]);

  LResponse.Id := FContext.Request.Id;

  LStopwatch := TStopwatch.StartNew;
  try
    // A procedure has no return type, so Invoke hands back an empty TValue with
    // no TypeInfo and TNeon.ValueToJSON would dereference it. The Response still
    // MUST carry a "result" member, so it becomes null - same as a method marked
    // [JRPCNotification], which deliberately answers without a payload.
    // The test is on the method's ReturnType, never on the value: TValue.IsEmpty
    // is also True for an empty dynamic array and for a nil instance, and those
    // have to keep serializing as [] and null respectively.
    if (LMethod.ReturnType = nil) or TRttiUtils.HasAttribute<JRPCNotificationAttribute>(LMethod) then
      LResponse.Result := nil
    else
      LResponse.Result := TNeon.ValueToJSON(LResult, FNeonConfig);
  except
    // The response object must not leak when serializing the result fails.
    LResponse.Free;
    raise;
  end;
  Logger.LogDebug('[PERF] JRPC [%s] ValueToJSON: %d ms', [FContext.Request.Method, LStopwatch.ElapsedMilliseconds]);

  FContext.Responses.AddMessage(LResponse);
end;

function TJRPCInvoker.GetParamName(LParam: TRttiParameter): string;
var
  LParamAttrib: JRPCAttribute;
begin
  LParamAttrib := TRttiUtils.FindAttribute<JRPCAttribute>(LParam);
  if Assigned(LParamAttrib) then
    Result := LParamAttrib.Name
  else
    Result := LParam.Name;
end;

function TJRPCInvoker.GetRequestMethodName(ARequest: TJRPCRequest): string;
var
  LSeparatorIndex: Integer;
begin
  // Flat class: the [JRPCMethod] attributes hold the whole name ("tools/call"),
  // there is no path prefix to strip.
  if FFlatMode then
    Exit(ARequest.Method);

  LSeparatorIndex := Pos(FSeparator, ARequest.Method);
  if LSeparatorIndex > 0 then
    Result := Copy(ARequest.Method, LSeparatorIndex + 1, Length(ARequest.Method))
  else
    Result := '';
end;

class function TJRPCInvoker.HandleError(E: Exception; AId: TJRPCID): TJRPCError;
begin
  Result := TJRPCError.Create;
  if E is EJRPCException then
  begin
    Result.Id := AId;
    Result.Error.Code := EJRPCException(E).Code;
    Result.Error.Message := E.Message;
  end
  else if E is EJSONParseException then
  begin
    Result.Id := AId;
    Result.Error.Code := JRPC_PARSE_ERROR;
    Result.Error.Message := E.Message;
  end
  else
  begin
    Result.Id := AId;
    // Same treatment as the parse-time path, but keeping this branch's own code:
    // a failure during dispatch is an Internal error, not an Invalid Request.
    TJRPCError.SetUnexpectedDetails(Result.Error, JRPC_INTERNAL_ERROR, E);
  end;
end;

class procedure TJRPCInvoker.Invoke(AContext: TJRPCInvokerContext);
var
  LInvoker: TJRPCInvoker;
begin
  LInvoker := TJRPCInvoker.Create(AContext);
  try
    LInvoker.InternalInvoke();
  finally
    LInvoker.Free;
  end;
end;

function TJRPCInvoker.RequestToRttiParams(AMethod: TRttiMethod): TArray<TValue>;

  function CastJSONValue(AParam: TRttiParameter; AValue: TJSONValue): TValue;
  begin
    if not Assigned(AValue) then
    begin
      Result := CreateNewValue(AParam.ParamType);
      Exit;
    end;

    CheckCompatibility(AParam, AValue);
    if AParam.ParamType.IsInstance then
      Result := TNeon.JSONToObject(AParam.ParamType, AValue, FNeonConfig)
    else
      Result := TNeon.JSONToValue(AParam.ParamType, AValue, FNeonConfig);
  end;

var
  LParam: TRttiParameter;
  LParamIndex: Integer;
  LParamJSON: TJSONValue;
  LRttiParams: TArray<TRttiParameter>;
begin
  Result := [];

  LParamIndex := 0;
  LRttiParams := AMethod.GetParameters;

  if (Length(LRttiParams) = 1) and (TRttiUtils.HasAttribute<JRPCParamsAttribute>(LRttiParams[0])) then
  begin
    Result := [TNeon.JSONToObject(LRttiParams[0].ParamType, FContext.Request.Params, FNeonConfig) ];
  end
  else
  begin
    for LParam in LRttiParams do
    begin
      case FContext.Request.ParamsType of
        TJRPCParamsType.ByPos:
        begin
          if LParamIndex >= (FContext.Request.Params as TJSONArray).Count then
            raise EJRPCInvokerError.CreateFmt(SJRPCParamIndexNotFound, [LParamIndex, (FContext.Request.Params as TJSONArray).Count]);

          LParamJSON := (FContext.Request.Params as TJSONArray).Items[LParamIndex];
        end;

        TJRPCParamsType.ByName:
        begin
          if not (FContext.Request.Params as TJSONObject).TryGetValue(GetParamName(LParam), LParamJSON) then
            raise EJRPCInvokerError.CreateFmt(SJRPCParamNotFound, [GetParamName(LParam)]);
        end;
      else
        raise EJRPCInvokerError.Create(JRPC_INTERNAL_ERROR, SJRPCUnknownParamsType);
      end;

      Result := Result + [CastJSONValue(LParam, LParamJSON)];
      Inc(LParamIndex);
    end;
  end;
end;

function TJRPCInvoker.RetrieveNeonConfig(ANeonConfig: INeonConfiguration): INeonConfiguration;
begin
  Result := ANeonConfig;
  if not Assigned(Result) then
    Result := TNeonConfiguration.Default;
end;

{ EJRPCInvokerError }

constructor EJRPCInvokerError.Create(ACode: Integer; const AMessage, AData: string);
begin
  inherited Create(AMessage);
  FCode := ACode;
  FData := AData;
end;

{ TJRPCInvokerContext }

procedure TJRPCInvokerContext.SelectConfig(AApiConfig: INeonConfiguration);
begin
  NeonConfig := AApiConfig;

  if not Assigned(NeonConfig) then
    NeonConfig := TNeonConfiguration.Default;
end;

end.
