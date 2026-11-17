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
  System.Classes, System.SysUtils, System.JSON, System.Contnrs, System.SyncObjs,

  JRPC.Classes,
  JRPC.Core,
  JRPC.Invoker;

type
  /// <summary>
  ///   Writes one message to the client the request being processed came
  ///   from. Given by the transport to ProcessRequest.
  /// </summary>
  TJRPCNotifySink = reference to procedure(const AText: string);

  /// <summary>
  ///   Lets a method send notifications to its client while it is still
  ///   running, ahead of its answer: progress, log lines, partial results.
  /// </summary>
  /// <remarks>
  ///   The server puts one in the context of a request when the transport
  ///   passed a sink to ProcessRequest or ProcessMessages, which only a
  ///   transport with a channel back to the client can do (a socket, stdio).
  ///   A method gets it through a [Context] field:
  ///
  ///   - [Context] FNotifier: TJRPCNotifier - the method needs it: without a
  ///     sink the call fails before the method runs.
  ///   - [Context([TContextOption.Optional])] FNotifier: TJRPCNotifier - the
  ///     method can do without: the field is nil when there is no sink.
  ///
  ///   It lives as long as the request (the batch, for a batch): never keep it,
  ///   nor use it from a thread that outlives the method. Send can be called
  ///   from several threads at once while the method runs: calls are
  ///   serialized, so the sink never runs twice at once.
  /// </remarks>
  TJRPCNotifier = class
  private
    FLock: TCriticalSection;
    FSink: TJRPCNotifySink;
  public
    constructor Create(const ASink: TJRPCNotifySink);
    destructor Destroy; override;

    /// <summary>
    ///   Sends ANotification now, before the answer. The caller still owns it.
    /// </summary>
    procedure Send(ANotification: TJRPCNotification); overload;

    /// <summary>
    ///   Sends a notification without params.
    /// </summary>
    procedure Send(const AMethod: string); overload;
  end;

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
    /// <param name="ANotify">
    ///   Where the notifications a method sends while it runs go (see
    ///   TJRPCNotifier). Called before this function returns, on the thread of
    ///   the method that sends. nil: the methods get no notifier.
    /// </param>
    function ProcessRequest(const AJSON: string;
      const ANotify: TJRPCNotifySink = nil): string;

    /// <summary>
    ///   Dispatches an already parsed message list. Responses are appended to
    ///   AResponses, which must be owned by the caller.
    /// </summary>
    /// <param name="ANotify">
    ///   As in ProcessRequest.
    /// </param>
    procedure ProcessMessages(AMessages: TJRPCMessages; AResponses: TJRPCMessages;
      const ANotify: TJRPCNotifySink = nil);
  end;

implementation

uses
  System.Diagnostics,

  Neon.Core.Persistence,
  Neon.Core.Utils,

  Logify;

{ TJRPCNotifier }

constructor TJRPCNotifier.Create(const ASink: TJRPCNotifySink);
begin
  inherited Create;
  if not Assigned(ASink) then
    raise EJRPCException.Create('TJRPCNotifier needs a sink to write to');

  FLock := TCriticalSection.Create;
  FSink := ASink;
end;

destructor TJRPCNotifier.Destroy;
begin
  FLock.Free;
  inherited;
end;

procedure TJRPCNotifier.Send(ANotification: TJRPCNotification);
var
  LText: string;
begin
  LText := ANotification.ToJson;
  FLock.Enter;
  try
    FSink(LText);
  finally
    FLock.Leave;
  end;
end;

procedure TJRPCNotifier.Send(const AMethod: string);
var
  LNotification: TJRPCNotification;
begin
  LNotification := TJRPCNotification.Create;
  try
    LNotification.Method := AMethod;
    Send(LNotification);
  finally
    LNotification.Free;
  end;
end;

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

procedure TJRPCServer.ProcessMessages(AMessages: TJRPCMessages; AResponses: TJRPCMessages;
  const ANotify: TJRPCNotifySink);
var
  LContext: TJRPCContext;
  LGarbage: IGarbageCollector;
  LInstances: TObjectList;
  LNotifier: TJRPCNotifier;
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
  LNotifier := nil;
  try
    LContext.AddContent(LGarbage);
    LContext.AddContent(AResponses);

    // Only with a channel back to the client: a [Context] field asking for it
    // is otherwise left unresolved (an error, or nil when Optional).
    if Assigned(ANotify) then
    begin
      LNotifier := TJRPCNotifier.Create(ANotify);
      LContext.AddContent(LNotifier);
    end;

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
    LNotifier.Free;
  end;
end;

function TJRPCServer.ProcessRequest(const AJSON: string;
  const ANotify: TJRPCNotifySink): string;
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
        ProcessMessages(LRequestList, LResponseList, ANotify);
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
