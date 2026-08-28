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
unit JRPC.Server;

interface

uses
  System.Classes, System.SysUtils, System.JSON, System.Contnrs,

  JRPC.Classes,
  JRPC.Core,
  JRPC.Invoker;

type
  /// <summary>
  ///   Standalone JSON-RPC 2.0 server.
  ///
  ///   Transport-agnostic entry point: give it a JSON-RPC request (a single
  ///   request/notification or a batch) and it produces the JSON-RPC response.
  ///   Registered API classes are resolved through TJRPCRegistry.Instance and
  ///   dispatched with TJRPCInvoker; per-request context and garbage collection
  ///   are managed internally, so a request never leaks its API instances.
  /// </summary>
  /// <remarks>
  ///   A transport (HTTP, WebSockets, STDIO, named pipes...) is expected to feed
  ///   the raw payload to ProcessRequest and send the returned JSON back to the
  ///   client. Notifications are accepted and never answered, per the
  ///   JSON-RPC 2.0 specification.
  /// </remarks>
  TJRPCServer = class(TComponent)
  private
    procedure DispatchMessage(AMessage: TJRPCMessage; AResponses: TJRPCMessages;
      AContext: TJRPCContext; AGarbage: IGarbageCollector; AInstances: TObjectList);
  public
    constructor Create(AOwner: TComponent); override;

    /// <summary>
    ///   Parses and dispatches a JSON-RPC request and returns the response JSON.
    ///   A single request yields a single Response object, a batch yields an
    ///   array of Response objects, and a request that needs no answer
    ///   (notifications) yields an empty string.
    /// </summary>
    function ProcessRequest(const AJSON: string): string;

    /// <summary>
    ///   Dispatches an already parsed message list. Responses are appended to
    ///   AResponses, which must be owned by the caller.
    /// </summary>
    procedure ProcessMessages(AMessages: TJRPCMessages; AResponses: TJRPCMessages);
  end;

implementation

uses
  System.Diagnostics,

  Neon.Core.Persistence,
  Neon.Core.Utils,

  Logify;

{ TJRPCServer }

constructor TJRPCServer.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
end;

procedure TJRPCServer.DispatchMessage(AMessage: TJRPCMessage; AResponses: TJRPCMessages;
  AContext: TJRPCContext; AGarbage: IGarbageCollector; AInstances: TObjectList);
var
  LConstructorProxy: TJRPCConstructorProxy;
  LInstance: TObject;
  LInvokerCtx: TJRPCInvokerContext;
begin
  if AMessage is TJRPCError then
  begin
    // An error produced while parsing the batch (e.g. a batch element that is
    // not a valid Request object) is already a complete JSON-RPC error
    // response and is forwarded as-is. Errors the client sent us (Request =
    // True) are ignored: a server has nothing to do with them.
    if not (AMessage as TJRPCError).Request then
      AResponses.AddMessage((AMessage as TJRPCError).Clone);
    Exit;
  end;

  // Notifications and Responses sent by the client need no action: per the
  // JSON-RPC 2.0 spec a server never answers a notification.
  if not (AMessage is TJRPCRequest) then
    Exit;

  var LRequest := AMessage as TJRPCRequest;
  try
    AContext.AddContent(LRequest);

    if not TJRPCRegistry.Instance.GetConstructorProxy(LRequest.Method, LConstructorProxy) then
      raise EJRPCMethodNotFoundError.CreateFmt(SJRPCMethodNotFound, [LRequest.Method]);

    LInstance := LConstructorProxy.ConstructorFunc();
    // The server owns the API instance and frees it explicitly once the batch
    // is processed (see ProcessMessages). It is deliberately NOT tracked by the
    // garbage collector: the injected [Context] FGC reference the instance
    // holds would otherwise keep the collector alive forever (the collector
    // owns the instance, the instance owns the collector), leaking everything.
    AInstances.Add(LInstance);

    // Injects the context (garbage collector, request, responses, ...) into the
    // [Context]-annotated fields of the API instance.
    AContext.Inject(LInstance);

    LInvokerCtx.Garbage := AGarbage;
    LInvokerCtx.Request := LRequest;
    LInvokerCtx.Responses := AResponses;
    LInvokerCtx.ApiInstance := LInstance;
    LInvokerCtx.SelectConfig(LConstructorProxy.NeonConfig);

    TJRPCInvoker.Invoke(LInvokerCtx);
  except
    on E: Exception do
      AResponses.AddMessage(TJRPCInvoker.HandleError(E, LRequest.Id));
  end;
end;

procedure TJRPCServer.ProcessMessages(AMessages: TJRPCMessages; AResponses: TJRPCMessages);
var
  LContext: TJRPCContext;
  LGarbage: IGarbageCollector;
  LInstances: TObjectList;
  LMessage: TJRPCMessage;
begin
  // One context, one garbage collector and one instance list per batch: they
  // outlive the API instances they reference and are released as soon as the
  // responses have been produced, so no request leaks objects or stale context
  // data.

  // The reply must have the same shape as the payload: an object answers an
  // object, an array answers an array. Carrying Single over is what tells
  // AResponses.ToJson which one to emit when the batch produced exactly one
  // Response (see TJRPCMessages.ToJson).
  AResponses.Single := AMessages.Single;

  LContext := TJRPCContext.Create;
  LGarbage := TGarbageCollector.CreateInstance;
  LInstances := TObjectList.Create(True);
  try
    LContext.AddContent(LGarbage);
    LContext.AddContent(AResponses);

    for LMessage in AMessages.List do
      DispatchMessage(LMessage, AResponses, LContext, LGarbage, LInstances);
  finally
    // Free the API instances first: each one releases its injected [Context]
    // FGC reference, which drops the last reference to the garbage collector;
    // its destruction then collects the request-scoped objects (method
    // results, tracked temporaries). Freeing the instances after the collector
    // died would double-free them, since the collector tracks nothing but the
    // instances it was given - and the instances are not given to it.
    LInstances.Free;
    LContext.Free;
  end;
end;

function TJRPCServer.ProcessRequest(const AJSON: string): string;
var
  LRequestList: TJRPCMessages;
  LResponseList: TJRPCMessages;
  LStopwatch: TStopwatch;
  LFragment: TStopwatch;
begin
  LStopwatch := TStopwatch.StartNew;
  try
    LResponseList := TJRPCMessages.Create(True);
    try
      LFragment := TStopwatch.StartNew;
      try
        LRequestList := TJRPCMessages.CreateFromJson(AJSON);
      except
        on E: EJRPCException do
        begin
          // Malformed JSON (parse error), an empty batch, or a top-level value
          // that is neither a Request nor a batch: answer with a single JSON-RPC
          // error response carrying a null id - never an empty body.
          // Single is set explicitly: the spec answers all three of these with a
          // bare Response object, never with an array - including "[]", whose
          // brackets never produced a batch we could reply to element by element.
          var LErrorId: TJRPCID;
          LRequestList := TJRPCMessages.Create(True);
          LRequestList.Single := True;
          LRequestList.AddMessage(TJRPCError.CreateFromException(E, LErrorId));
        end;
      end;
      Logger.LogDebug('[PERF] JRPC CreateFromJson: %d ms', [LFragment.ElapsedMilliseconds]);

      try
        ProcessMessages(LRequestList, LResponseList);
        Result := LResponseList.ToJson;
      finally
        LRequestList.Free;
      end;
    finally
      LResponseList.Free;
    end;
  finally
    Logger.LogDebug('[PERF] JRPC ProcessRequest total: %d ms', [LStopwatch.ElapsedMilliseconds]);
  end;
end;

end.
