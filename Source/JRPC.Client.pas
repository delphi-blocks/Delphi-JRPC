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
unit JRPC.Client;

{$SCOPEDENUMS ON}

interface

uses
  System.Classes, System.SysUtils, System.Rtti, System.JSON, System.SyncObjs,
  System.Generics.Collections,

  Neon.Core.Persistence,

  JRPC.Core,
  JRPC.Server,
  JRPC.Transport;

type
  /// <summary>
  ///   A failure of the call itself: the call never completed.
  /// </summary>
  /// <remarks>
  ///   Declared in JRPC.Core, next to EJRPCRemoteError. This alias keeps the
  ///   name where a client's users have always found it.
  /// </remarks>
  EJRPCClientError = JRPC.Core.EJRPCClientError;

  /// <summary>
  ///   The "error" member the peer sent back, raised as a Delphi exception.
  /// </summary>
  EJRPCRemoteError = JRPC.Core.EJRPCRemoteError;

  /// <summary>
  ///   Builds a Request in one expression:
  ///   TJRPCRequestBuilder.New.SetMethod('dir/list').AddNamedParam('path', APath)
  /// </summary>
  /// <remarks>
  ///   Interfaced, so the request it is building is freed with the builder and
  ///   no call site needs a try/finally. Build only lends the request out - the
  ///   builder keeps ownership - so the interface must stay in scope for as
  ///   long as the request is in use. Passing the builder straight to ExecuteAs
  ///   does exactly that.
  ///
  ///   Named and positional params never mix in one message: JSON-RPC 2.0 has
  ///   no shape for that, and TJRPCMethod raises if they are combined.
  ///
  ///   IJRPCNotificationBuilder is the twin of this one, and the two share no
  ///   ancestor interface on purpose: Delphi has no covariant return types, so
  ///   an inherited SetMethod could only hand back the base interface, and the
  ///   chain would lose its type halfway through. What the two do share is the
  ///   implementation, in TJRPCMethodBuilder.
  /// </remarks>
  IJRPCRequestBuilder = interface
    ['{04F411DA-409A-4917-995D-046C1C683B55}']
    function SetMethod(const AName: string): IJRPCRequestBuilder;

    function AddPositionParam(const AValue: TValue): IJRPCRequestBuilder;
    function AddNamedParam(const AName: string; const AValue: TValue): IJRPCRequestBuilder;

    /// <summary>
    ///   The request built so far, still owned by the builder.
    /// </summary>
    function Build: TJRPCRequest;
  end;

  /// <summary>
  ///   Builds a Notification in one expression:
  ///   TJRPCNotificationBuilder.New.SetMethod('log/write').AddNamedParam('text', AText)
  /// </summary>
  /// <remarks>
  ///   The same shape and the same ownership rule as IJRPCRequestBuilder, minus
  ///   the id: a notification carries none, and the peer answers nothing.
  /// </remarks>
  IJRPCNotificationBuilder = interface
    ['{0E86228E-44D6-4CDB-A94E-5A22D6D06138}']
    function SetMethod(const AName: string): IJRPCNotificationBuilder;

    function AddPositionParam(const AValue: TValue): IJRPCNotificationBuilder;
    function AddNamedParam(const AName: string; const AValue: TValue): IJRPCNotificationBuilder;

    /// <summary>
    ///   The notification built so far, still owned by the builder.
    /// </summary>
    function Build: TJRPCNotification;
  end;

  TJRPCMethodClass = class of TJRPCMethod;

  /// <summary>
  ///   What the two builders have in common: the message being filled in and
  ///   its lifetime.
  /// </summary>
  TJRPCMethodBuilder = class abstract(TInterfacedObject)
  protected
    FMethod: TJRPCMethod;

    /// <summary>
    ///   Creates the message AMethodClass names; the builder owns it.
    /// </summary>
    constructor Create(AMethodClass: TJRPCMethodClass);
  public
    destructor Destroy; override;
  end;

  TJRPCRequestBuilder = class(TJRPCMethodBuilder, IJRPCRequestBuilder)
  public
    /// <summary>The way in: returns the interface, so nothing is freed by hand.</summary>
    class function New: IJRPCRequestBuilder;

    constructor Create;

    function SetMethod(const AName: string): IJRPCRequestBuilder;

    function AddPositionParam(const AValue: TValue): IJRPCRequestBuilder;
    function AddNamedParam(const AName: string; const AValue: TValue): IJRPCRequestBuilder;

    function Build: TJRPCRequest;
  end;

  TJRPCNotificationBuilder = class(TJRPCMethodBuilder, IJRPCNotificationBuilder)
  public
    /// <summary>The way in: returns the interface, so nothing is freed by hand.</summary>
    class function New: IJRPCNotificationBuilder;

    constructor Create;

    function SetMethod(const AName: string): IJRPCNotificationBuilder;

    function AddPositionParam(const AValue: TValue): IJRPCNotificationBuilder;
    function AddNamedParam(const AName: string; const AValue: TValue): IJRPCNotificationBuilder;

    function Build: TJRPCNotification;
  end;

  TJRPCClient = class;

  /// <summary>
  ///   Why a call ended before its answer: what OnCallEnded reports.
  /// </summary>
  TJRPCCallEnd = (
    /// <summary>The call did not complete within its timeout.</summary>
    Timeout,
    /// <summary>Cancel was called on the call handle.</summary>
    Cancelled
  );

  /// <summary>
  ///   One call in flight.
  /// </summary>
  /// <remarks>
  ///   The client holds the call while it is pending, so the handle stays
  ///   valid even if the caller drops it, and outlives the client safely.
  /// </remarks>
  IJRPCCall = interface
  ['{2E4F6A81-93B5-4C7D-8E0F-1A2B3C4D5E6F}']
    /// <summary>
    ///   The id the request went out with.
    /// </summary>
    function Id: TJRPCID;

    /// <summary>
    ///   Waits for the call to complete. False on timeout; the call then stays
    ///   pending until Cancel, an answer, or the client closing.
    /// </summary>
    function Wait(ATimeout: Cardinal = JRPC_INFINITE): Boolean;

    /// <summary>
    ///   True once the call has completed, for whatever reason.
    /// </summary>
    function Completed: Boolean;

    /// <summary>
    ///   Stops waiting: the call completes with an EJRPCClientError, a
    ///   transport that implements IJRPCAbortableTransport stops reading its
    ///   answer, and OnCallEnded fires. Idempotent; a completed call is left
    ///   alone.
    /// </summary>
    procedure Cancel;
  end;

  /// <summary>
  ///   A call whose result is deserialized into T.
  /// </summary>
  IJRPCCall<T> = interface(IJRPCCall)
    /// <summary>
    ///   Waits for the call and returns its result, deserialized as ExecuteAs
    ///   would. Raises EJRPCRemoteError for an error answer and
    ///   EJRPCClientError (or the transport's own exception) for a failure.
    /// </summary>
    /// <remarks>
    ///   When T is a class, every call creates a new instance that belongs to
    ///   the caller. A failure is raised as the exception the call failed
    ///   with the first time, and as an EJRPCClientError quoting it after
    ///   that - unless OnError chose Abort (EAbort is raised) or Ignore
    ///   (Default(T) is returned).
    /// </remarks>
    function Value: T;
  end;

  /// <summary>
  ///   The answer to a request the peer sent.
  /// </summary>
  /// <remarks>
  ///   Answer exactly once, from any thread, even after the handler returned:
  ///   keep the interface (capture it in a task) to answer later. A reply
  ///   released without an answer answers -32603 on its own, so the peer is
  ///   never left waiting.
  /// </remarks>
  IJRPCReply = interface
  ['{3F5A7B92-A4C6-4D8E-9F01-2B3C4D5E6F70}']
    /// <summary>
    ///   Answers with AValue as the "result", taking ownership of it. nil
    ///   answers null.
    /// </summary>
    procedure Result(AValue: TJSONValue); overload;

    /// <summary>
    ///   Answers with AValue serialized through the client's NeonConfig.
    /// </summary>
    procedure Result(const AValue: TValue); overload;

    /// <summary>
    ///   Answers with an error; AData, which may be nil, becomes "data" and is
    ///   owned by the reply.
    /// </summary>
    procedure Error(ACode: Integer; const AMessage: string; AData: TJSONValue = nil);

    /// <summary>
    ///   True once an answer was given.
    /// </summary>
    function Answered: Boolean;
  end;

  /// <summary>
  ///   Called with a notification of the peer.
  /// </summary>
  /// <remarks>
  ///   The object belongs to the client and is freed when the handler returns:
  ///   Clone it to keep it.
  /// </remarks>
  TJRPCNotificationProc = reference to procedure(const ANotification: TJRPCNotification);

  /// <summary>
  ///   Called with a request of the peer, to be answered through AReply.
  /// </summary>
  /// <remarks>
  ///   ARequest is freed when the handler returns: Clone what the answer needs
  ///   if it is produced later.
  /// </remarks>
  TJRPCRequestHandler = reference to procedure(const ARequest: TJRPCRequest; const AReply: IJRPCReply);

  /// <summary>
  ///   Called once when the client's transport ends.
  /// </summary>
  TJRPCCloseProc = reference to procedure(const AInfo: TJRPCCloseInfo);

  /// <summary>
  ///   Called when a call stops waiting before its answer: the place to tell
  ///   the peer (notifications/cancelled, in MCP).
  /// </summary>
  TJRPCCallEndedProc = reference to procedure(const AId: TJRPCID; AReason: TJRPCCallEnd);

  /// <summary>
  ///   Called with the exact text going out or coming in. Meant for logging and
  ///   for tests; it cannot alter the payload.
  /// </summary>
  TJRPCTraceProc = reference to procedure(const AJSON: string);

  /// <summary>
  ///   What the caller of a failed call gets, as chosen by OnError.
  /// </summary>
  TJRPCErrorAction = (
    /// <summary>The failure is raised to the caller. The default.</summary>
    &Raise,
    /// <summary>
    ///   An EAbort is raised instead: the caller's flow stops, silently.
    /// </summary>
    Abort,
    /// <summary>
    ///   Nothing is raised: the call returns an empty result - Default(T),
    ///   nil, '' or an empty list.
    /// </summary>
    Ignore
  );

  /// <summary>
  ///   Called with a failure, on its way out. AAction arrives as Raise; set it
  ///   to choose what the caller gets instead.
  /// </summary>
  /// <remarks>
  ///   AAction matters only for a failure that has a caller to reach: a call
  ///   (ExecuteAs, Execute, ExecuteAsJSONValue, ExecuteAsJsonString, the Value
  ///   of an ExecuteAsync), Notify, or the sending of a batch. For a failure
  ///   of the channel itself (an unreadable message, an answer nobody waits
  ///   for, a handler that raised) there is nobody to raise to, and it is
  ///   ignored. The handler may run on any thread; the choice is applied on
  ///   the caller's, when it collects the outcome.
  /// </remarks>
  TJRPCErrorProc = reference to procedure(E: Exception; var AAction: TJRPCErrorAction);

  /// <summary>
  ///   Where the handlers of what the peer sends on its own run.
  /// </summary>
  TJRPCDispatchMode = (
    /// <summary>
    ///   On a dispatch thread of the client's own, one at a time, in arrival
    ///   order. A handler can call the client synchronously, and a slow one
    ///   delays only the other handlers, never the answers.
    /// </summary>
    Queue,
    /// <summary>
    ///   On the thread that received the message: the transport's reader, or
    ///   the thread of a RoundTrip Send. Simpler, but a handler that waits for
    ///   an answer from the same peer over a persistent channel deadlocks.
    /// </summary>
    Direct
  );

  /// <summary>
  ///   A call in flight, as the client sees it. Internal: use IJRPCCall.
  /// </summary>
  /// <remarks>
  ///   Declared in the interface section only because the generic
  ///   TJRPCCall&lt;T&gt; reaches it, and generic code cannot use symbols that
  ///   are local to the implementation.
  /// </remarks>
  TJRPCPendingCall = class(TInterfacedObject, IJRPCCall)
  private
    FClient: TJRPCClient;
    FId: TJRPCID;
    FKey: string;
    FLock: TCriticalSection;
    FDone: TEvent;
    FCompleted: Boolean;
    FReply: TJRPCMessage;
    FRaw: TJSONObject;
    FError: Exception;
    FErrorMessage: string;
    FErrorAction: TJRPCErrorAction;
    FOnNotification: TJRPCNotificationProc;
  public
    constructor Create(AClient: TJRPCClient; const AId: TJRPCID;
      const AOnNotification: TJRPCNotificationProc);
    destructor Destroy; override;

    // IJRPCCall
    function Id: TJRPCID;
    function Wait(ATimeout: Cardinal = JRPC_INFINITE): Boolean;
    function Completed: Boolean;
    procedure Cancel;

    /// <summary>
    ///   Completes the call, taking ownership of what it is given. False when
    ///   it was already completed, in which case the caller still owns it all.
    /// </summary>
    /// <param name="AAction">
    ///   What OnError chose for the failure, if this is one.
    /// </param>
    function Complete(AReply: TJRPCMessage; ARaw: TJSONObject; AError: Exception;
      AAction: TJRPCErrorAction = TJRPCErrorAction.Raise): Boolean;

    /// <summary>
    ///   Records what OnError chose for a failure reported after the call
    ///   completed (a timeout).
    /// </summary>
    procedure SetErrorAction(AAction: TJRPCErrorAction);

    /// <summary>
    ///   Forgets the client, so a handle that outlives it cannot call back.
    /// </summary>
    procedure Detach;

    /// <summary>
    ///   Completes the call with an EJRPCClientError and tells the client why.
    /// </summary>
    procedure CancelWith(AReason: TJRPCCallEnd; const AMessage: string);

    /// <summary>
    ///   The "result" of the answer, as a clone the caller owns; for a failure,
    ///   raises it, raises EAbort, or returns nil, as OnError chose.
    /// </summary>
    function TakeResult: TJSONValue;

    /// <summary>
    ///   The answer as a message the caller owns: the response or error the
    ///   peer sent, or an error built from the local failure.
    /// </summary>
    function TakeMessage: TJRPCMessage;

    property Key: string read FKey;
    property OnNotification: TJRPCNotificationProc read FOnNotification;
  end;

  /// <summary>
  ///   The typed handle ExecuteAsync returns. Internal: use IJRPCCall&lt;T&gt;.
  /// </summary>
  TJRPCCall<T> = class(TInterfacedObject, IJRPCCall, IJRPCCall<T>)
  private
    FCall: IJRPCCall;
    FPending: TJRPCPendingCall;
    FNeonConfig: INeonConfiguration;
  public
    constructor Create(const ACall: IJRPCCall; const ANeonConfig: INeonConfiguration);

    function Id: TJRPCID;
    function Wait(ATimeout: Cardinal = JRPC_INFINITE): Boolean;
    function Completed: Boolean;
    procedure Cancel;
    function Value: T;
  end;

  /// <summary>
  ///   JSON-RPC 2.0 client over any channel: the mirror image of TJRPCServer,
  ///   and the endpoint that answers what the peer asks in return.
  /// </summary>
  /// <remarks>
  ///   One API whatever the transport. The client keeps a map of the calls in
  ///   flight and correlates the answers by id as they arrive, so calls can run
  ///   concurrently and be answered in any order. Notifications go to
  ///   OnNotification (or to the handler of the call they belong to) and the
  ///   peer's requests to OnRequest or Server.
  ///
  ///   The transport decides where things run (see IJRPCTransport.RoundTrip):
  ///   over HTTP the answer arrives inside Send, on the calling thread, and no
  ///   thread is created; over stdio or a socket a reader thread of the
  ///   transport delivers everything. ExecuteAsync over a RoundTrip transport
  ///   runs Send on a task of the thread pool, so that calls overlap.
  ///
  ///   The transport is opened on the first call, or by Open. Close ends it:
  ///   the calls still waiting fail with EJRPCClientError quoting the reason,
  ///   and the client cannot be reopened until a new Transport is assigned.
  ///
  ///   OnError sees every failure once: a call that failed (an error answer, a
  ///   timeout, a transport that raised) and a failure of the channel itself
  ///   (an unreadable message, an answer nobody waits for, a handler that
  ///   raised). A call cancelled through its handle, or failed by Close, is
  ///   not reported. For a failure that reaches a caller, OnError also
  ///   chooses what the caller gets (see TJRPCErrorAction).
  /// </remarks>
  TJRPCClient = class(TComponent, IJRPCTransportListener)
  private type
    TState = (Idle, Open, Closed);
  private
    FLock: TCriticalSection;
    FTransport: IJRPCTransport;
    FState: TState;
    FCloseInfo: TJRPCCloseInfo;
    FHasCloseInfo: Boolean;
    FCloseNotified: Boolean;
    FPending: TDictionary<string, IJRPCCall>;
    FDispatcher: TThread;
    FReplyChannel: IInterface;
    FInFlight: Integer;

    FNeonConfig: INeonConfiguration;
    FCompactPayload: Boolean;
    FDefaultTimeout: Cardinal;
    FDispatchMode: TJRPCDispatchMode;
    FServer: TJRPCServer;
    FOnBeforeSend: TJRPCTraceProc;
    FOnAfterReceive: TJRPCTraceProc;
    FOnError: TJRPCErrorProc;
    FOnNotification: TJRPCNotificationProc;
    FOnRequest: TJRPCRequestHandler;
    FOnClose: TJRPCCloseProc;
    FOnCallEnded: TJRPCCallEndedProc;

    procedure SetTransport(const AValue: IJRPCTransport);
    procedure SetServer(AValue: TJRPCServer);
    function GetActive: Boolean;

    procedure EnsureOpen;
    function CloseReason: string;
    function StartCall(ARequest: TJRPCRequest;
      const AOnNotification: TJRPCNotificationProc; AAsync: Boolean): IJRPCCall;
    procedure AddPending(const ACall: IJRPCCall);
    procedure StartAsyncSend(const AText: string; const AOrigin: TJRPCID;
      const AKeys: TArray<string>);
    procedure FinishRoundTrip(const AKeys: TArray<string>);
    procedure FailKeys(const AKeys: TArray<string>; E: Exception);
    procedure AwaitCall(ACall: TJRPCPendingCall; ATimeout: Cardinal);
    function DoExecute(ARequest: TJRPCRequest; ATimeout: Cardinal): TJSONValue;
    function PreparePayload(const AJSON: string): string;
    procedure Transmit(const AJSON: string; const AOrigin: TJRPCID);
    procedure SendText(const AText: string; const AOrigin: TJRPCID);

    function FailedCall(const AId: TJRPCID; AError: Exception;
      AAction: TJRPCErrorAction): IJRPCCall;
    procedure CompletePending(const AId: TJRPCID; AReply: TJRPCMessage;
      ARaw: TJSONObject; AError: Exception);
    procedure CallAbandoned(ACall: TJRPCPendingCall; AReason: TJRPCCallEnd;
      const AMessage: string);
    function IsPending(const AId: TJRPCID): Boolean;
    function AnyPending(const AKeys: TArray<string>): Boolean;
    procedure Forget(const AKey: string);
    procedure FailPending(const AMessage: string);

    procedure HandleFrame(const AText: string; const AOrigin: TJRPCID);
    procedure HandleMessage(AMessage: TJRPCMessage; ARaw: TJSONObject;
      const AOrigin: TJRPCID; ARejections: TStrings);
    procedure RejectFrame(AError: Exception; const AOrigin: TJRPCID);
    procedure RejectPeerMessage(AError: TJRPCError; ARejections: TStrings);
    procedure FailInvalidResponse(AError: TJRPCError; const AOrigin: TJRPCID);
    procedure RouteNotification(ANotification: TJRPCNotification; const AOrigin: TJRPCID);
    procedure Enqueue(AMessage: TJRPCMessage);
    procedure RunMessage(AMessage: TJRPCMessage);
    procedure RunRequest(ARequest: TJRPCRequest);
    procedure AnswerPeer(E: Exception; const AId: TJRPCID);

    function ReportError(E: Exception): TJRPCErrorAction;
    function ReportText(const AText: string): TJRPCErrorAction;
    procedure NotifyClosed(const AInfo: TJRPCCloseInfo);
    procedure StopDispatcher(AWait: Boolean);
    procedure ReleaseDispatcher;
    procedure WaitInFlight;

    class function KeyOf(const AId: TJRPCID): string; static;
    class function MessageId(AMessage: TJRPCMessage; out AId: TJRPCID): Boolean; static;

    // IJRPCTransportListener
    procedure MessageReceived(const AText: string; const AOrigin: TJRPCID);
    procedure TransportClosed(const AInfo: TJRPCCloseInfo);
  protected
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    /// <summary>
    ///   A fresh request id, unique across every client in the process.
    /// </summary>
    class function NewId: TJRPCID; static;

    /// <summary>
    ///   Deserializes a "result" into T: a class through TNeon.JSONToObject
    ///   (the instance belongs to the caller), anything else through
    ///   TNeon.JSONToValue.
    /// </summary>
    class function FromJSON<T>(AValue: TJSONValue; const ANeonConfig: INeonConfiguration): T; static;

    /// <summary>
    ///   The message in AMessages carrying AId, or nil. The way to line up a
    ///   batch answer with what was sent.
    /// </summary>
    class function FindById(AMessages: TJRPCMessages; const AId: TJRPCID): TJRPCMessage; static;

    /// <summary>
    ///   Opens the transport. Optional: the first call does it. Raises when
    ///   the client was closed and no new Transport has been assigned since.
    /// </summary>
    procedure Open;

    /// <summary>
    ///   Ends the transport: the calls still waiting fail, OnClose fires.
    ///   Idempotent, and safe from a handler.
    /// </summary>
    procedure Close;

    /// <summary>
    ///   Sends ARequest, waits for the answer and deserializes the "result"
    ///   into T. Raises EJRPCRemoteError when the peer answered with an error.
    /// </summary>
    /// <param name="ATimeout">
    ///   Milliseconds; 0 uses DefaultTimeout, JRPC_INFINITE waits forever. On
    ///   timeout the call is cancelled and EJRPCClientError is raised. Over a
    ///   RoundTrip transport the wait is the transport's own: Send returns
    ///   with the answer.
    /// </param>
    /// <remarks>
    ///   A request with no id is given one; an id the caller set is kept, and
    ///   one already pending is refused with EJRPCClientError.
    /// </remarks>
    function ExecuteAs<T>(ARequest: TJRPCRequest; ATimeout: Cardinal = 0): T; overload;
    function ExecuteAs<T>(const ARequest: IJRPCRequestBuilder; ATimeout: Cardinal = 0): T; overload;

    /// <summary>
    ///   Same call, but the "result" comes back as JSON, a clone the caller
    ///   owns. A "result" of null arrives as a TJSONNull: nil means only a
    ///   failure OnError chose to Ignore.
    /// </summary>
    function ExecuteAsJSONValue(ARequest: TJRPCRequest; ATimeout: Cardinal = 0): TJSONValue; overload;
    function ExecuteAsJSONValue(const ARequest: IJRPCRequestBuilder; ATimeout: Cardinal = 0): TJSONValue; overload;

    /// <summary>
    ///   Same call, with the "result" rendered as compact JSON text.
    /// </summary>
    function ExecuteAsJsonString(ARequest: TJRPCRequest; ATimeout: Cardinal = 0): string; overload;
    function ExecuteAsJsonString(const ARequest: IJRPCRequestBuilder; ATimeout: Cardinal = 0): string; overload;

    /// <summary>
    ///   Sends a Request and checks the answer, discarding the result.
    /// </summary>
    procedure Execute(ARequest: TJRPCRequest; ATimeout: Cardinal = 0); overload;
    procedure Execute(const ARequest: IJRPCRequestBuilder; ATimeout: Cardinal = 0); overload;

    /// <summary>
    ///   Sends ARequest and returns at once, with a handle to wait on.
    /// </summary>
    /// <param name="AOnNotification">
    ///   Receives the notifications that arrive on the answer stream of this
    ///   call (an SSE body), on the thread that reads that stream. A persistent
    ///   channel does not tie notifications to a call: there they go to
    ///   OnNotification.
    /// </param>
    /// <remarks>
    ///   Over a RoundTrip transport Send runs on a task of the thread pool, so
    ///   several calls overlap; over a persistent channel the message is
    ///   written before ExecuteAsync returns. A failure is never raised here:
    ///   it is what Value raises.
    /// </remarks>
    function ExecuteAsync<T>(ARequest: TJRPCRequest;
      const AOnNotification: TJRPCNotificationProc = nil): IJRPCCall<T>; overload;
    function ExecuteAsync<T>(const ARequest: IJRPCRequestBuilder;
      const AOnNotification: TJRPCNotificationProc = nil): IJRPCCall<T>; overload;

    /// <summary>
    ///   Sends a Notification. Nothing is read back.
    /// </summary>
    procedure Notify(ANotification: TJRPCNotification); overload;
    procedure Notify(const ANotification: IJRPCNotificationBuilder); overload;

    /// <summary>
    ///   Sends a batch and returns the answers, which the caller owns.
    /// </summary>
    /// <remarks>
    ///   Requests with no id are given one, and the payload always goes out as
    ///   a JSON array. An error is returned, not raised, so that the answers to
    ///   the elements that succeeded are not lost with it; a request that got
    ///   no answer comes back as an error built from its local failure. Pair
    ///   the answers with FindById: the peer may answer in any order. A batch
    ///   made only of notifications returns an empty list.
    /// </remarks>
    function ExecuteBatch(AMessages: TJRPCMessages; ATimeout: Cardinal = 0): TJRPCMessages;

    /// <summary>
    ///   The channel to the peer. Assigning it closes the current one and lets
    ///   the client open again.
    /// </summary>
    property Transport: IJRPCTransport read FTransport write SetTransport;

    /// <summary>
    ///   True while the transport is open.
    /// </summary>
    property Active: Boolean read GetActive;

    /// <summary>
    ///   The timeout of a synchronous call that passes 0. 0, the default,
    ///   waits forever.
    /// </summary>
    property DefaultTimeout: Cardinal read FDefaultTimeout write FDefaultTimeout default 0;

    /// <summary>
    ///   Where OnNotification, OnRequest and Server run. Takes effect when the
    ///   client opens.
    /// </summary>
    property DispatchMode: TJRPCDispatchMode read FDispatchMode write FDispatchMode default TJRPCDispatchMode.Queue;

    /// <summary>
    ///   The Neon configuration used to deserialize a "result" and to
    ///   serialize an IJRPCReply.Result. It must not be nil.
    /// </summary>
    property NeonConfig: INeonConfiguration read FNeonConfig write FNeonConfig;

    /// <summary>
    ///   Collapses an outgoing payload onto a single line when it contains a
    ///   line break. True by default: a line-framed transport would read a
    ///   pretty-printed payload as several truncated messages.
    /// </summary>
    property CompactPayload: Boolean read FCompactPayload write FCompactPayload default True;

    /// <summary>
    ///   Answers the peer's requests when OnRequest is not assigned: methods,
    ///   attributes and [Context] work as on the server side. Not owned.
    /// </summary>
    property Server: TJRPCServer read FServer write SetServer;

    /// <summary>
    ///   Called with the payload about to go out, after compaction.
    /// </summary>
    property OnBeforeSend: TJRPCTraceProc read FOnBeforeSend write FOnBeforeSend;

    /// <summary>
    ///   Called with every message as it arrived, before it is parsed - so it
    ///   sees even the ones that turn out to be unreadable.
    /// </summary>
    property OnAfterReceive: TJRPCTraceProc read FOnAfterReceive write FOnAfterReceive;

    /// <summary>
    ///   One place to log failures (see the remark on the class), and to
    ///   choose through AAction whether the caller gets them raised, an
    ///   EAbort, or an empty result. An exception it raises is logged and
    ///   dropped, and the failure is raised as usual.
    /// </summary>
    property OnError: TJRPCErrorProc read FOnError write FOnError;

    /// <summary>
    ///   The notifications of the peer that belong to no call.
    /// </summary>
    property OnNotification: TJRPCNotificationProc read FOnNotification write FOnNotification;

    /// <summary>
    ///   The requests of the peer. Without it they go to Server, and without a
    ///   server they are answered -32601.
    /// </summary>
    /// <remarks>
    ///   A handler that raises answers the peer the way TJRPCServer answers a
    ///   method that raised; the failure is reported to OnError as well.
    /// </remarks>
    property OnRequest: TJRPCRequestHandler read FOnRequest write FOnRequest;

    /// <summary>
    ///   Called once when the transport ends, with the reason.
    /// </summary>
    property OnClose: TJRPCCloseProc read FOnClose write FOnClose;

    /// <summary>
    ///   Called when a call times out or is cancelled.
    /// </summary>
    property OnCallEnded: TJRPCCallEndedProc read FOnCallEnded write FOnCallEnded;
  end;

implementation

uses
  System.TypInfo, System.Threading,

  Logify,
  Neon.Core.Utils,
  Neon.Core.Persistence.JSON;

type
  /// <summary>
  ///   The dispatch thread: runs the handlers of what the peer sends on its
  ///   own, one at a time, in arrival order.
  /// </summary>
  TJRPCDispatcher = class(TThread)
  private
    FClient: TJRPCClient;
    FLock: TCriticalSection;
    FQueue: TObjectQueue<TJRPCMessage>;
    FSignal: TEvent;
    FStopped: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AClient: TJRPCClient);
    destructor Destroy; override;

    /// <summary>
    ///   Queues AMessage, taking ownership of it.
    /// </summary>
    procedure Push(AMessage: TJRPCMessage);

    /// <summary>
    ///   Ends the loop after the handler running now, if any. What is still
    ///   queued is dropped.
    /// </summary>
    procedure Stop;
  end;

  /// <summary>
  ///   What a reply sends through: shared by the client and every reply, and
  ///   cut off when the client goes away, so a reply that outlives it fails
  ///   cleanly instead of touching a freed object.
  /// </summary>
  TJRPCReplyChannel = class(TInterfacedObject)
  private
    FLock: TCriticalSection;
    FClient: TJRPCClient;
  public
    constructor Create(AClient: TJRPCClient);
    destructor Destroy; override;

    procedure Detach;
    procedure Send(const AText: string);
  end;

  TJRPCReply = class(TInterfacedObject, IJRPCReply)
  private
    FChannel: IInterface;
    FId: TJRPCID;
    FNeonConfig: INeonConfiguration;
    FAnswered: Integer;

    function Claim: Boolean;
    procedure SendText(const AText: string);
    function IdToJSON: TJSONValue;
  public
    constructor Create(const AChannel: IInterface; const AId: TJRPCID;
      const ANeonConfig: INeonConfiguration);
    destructor Destroy; override;

    // IJRPCReply
    procedure Result(AValue: TJSONValue); overload;
    procedure Result(const AValue: TValue); overload;
    procedure Error(ACode: Integer; const AMessage: string; AData: TJSONValue = nil);
    function Answered: Boolean;

    /// <summary>
    ///   Answers with a complete message already built (the server's).
    /// </summary>
    procedure Raw(const AText: string);

    /// <summary>
    ///   Answers with the error E stands for, unless an answer was given.
    /// </summary>
    procedure Fail(E: Exception);
  end;

threadvar
  /// <summary>
  ///   True on a task running an asynchronous Send: Close from there cannot
  ///   wait for the tasks to end, since one of them is its own.
  /// </summary>
  GInAsyncSend: Boolean;

{ TJRPCDispatcher }

constructor TJRPCDispatcher.Create(AClient: TJRPCClient);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FClient := AClient;
  FLock := TCriticalSection.Create;
  FQueue := TObjectQueue<TJRPCMessage>.Create(True);
  FSignal := TEvent.Create(nil, False, False, '');
end;

destructor TJRPCDispatcher.Destroy;
begin
  // A thread freed before it ran would hang a WaitFor: make sure it can end.
  Stop;
  inherited;
  FSignal.Free;
  FQueue.Free;
  FLock.Free;
end;

procedure TJRPCDispatcher.Push(AMessage: TJRPCMessage);
begin
  FLock.Enter;
  try
    if FStopped then
    begin
      AMessage.Free;
      Exit;
    end;
    FQueue.Enqueue(AMessage);
  finally
    FLock.Leave;
  end;
  FSignal.SetEvent;
end;

procedure TJRPCDispatcher.Stop;
begin
  FLock.Enter;
  try
    FStopped := True;
  finally
    FLock.Leave;
  end;
  FSignal.SetEvent;
end;

procedure TJRPCDispatcher.Execute;
var
  LMessage: TJRPCMessage;
begin
  while True do
  begin
    LMessage := nil;
    FLock.Enter;
    try
      if FStopped then
        Break;
      if FQueue.Count > 0 then
        LMessage := FQueue.Extract;
    finally
      FLock.Leave;
    end;

    if not Assigned(LMessage) then
    begin
      FSignal.WaitFor(JRPC_INFINITE);
      Continue;
    end;

    try
      try
        FClient.RunMessage(LMessage);
      except
        on E: Exception do
          Logger.LogWarning(E, 'A JSON-RPC handler raised on the dispatch thread');
      end;
    finally
      LMessage.Free;
    end;
  end;
end;

{ TJRPCReplyChannel }

constructor TJRPCReplyChannel.Create(AClient: TJRPCClient);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FClient := AClient;
end;

destructor TJRPCReplyChannel.Destroy;
begin
  FLock.Free;
  inherited;
end;

procedure TJRPCReplyChannel.Detach;
begin
  FLock.Enter;
  try
    FClient := nil;
  finally
    FLock.Leave;
  end;
end;

procedure TJRPCReplyChannel.Send(const AText: string);
begin
  FLock.Enter;
  try
    if not Assigned(FClient) then
      raise EJRPCClientError.CreateFmt(SJRPCClientClosed, [SJRPCCloseLocal]);
    FClient.Transmit(AText, TJRPCID.Null);
  finally
    FLock.Leave;
  end;
end;

{ TJRPCReply }

constructor TJRPCReply.Create(const AChannel: IInterface; const AId: TJRPCID;
  const ANeonConfig: INeonConfiguration);
begin
  inherited Create;
  FChannel := AChannel;
  FId := AId;
  FNeonConfig := ANeonConfig;
end;

destructor TJRPCReply.Destroy;
begin
  // Nobody answered: the peer would wait forever for this id.
  if FAnswered = 0 then
    try
      Error(JRPC_INTERNAL_ERROR, SJRPCClientNoReply);
    except
      on E: Exception do
        Logger.LogWarning(E, 'Could not answer a request nobody replied to');
    end;
  inherited;
end;

function TJRPCReply.Claim: Boolean;
begin
  Result := TInterlocked.Exchange(FAnswered, 1) = 0;
end;

procedure TJRPCReply.SendText(const AText: string);
begin
  (FChannel as TJRPCReplyChannel).Send(AText);
end;

function TJRPCReply.IdToJSON: TJSONValue;
begin
  if FId.IsNull then
    Result := TJSONNull.Create
  else if FId.IsString then
    Result := TJSONString.Create(FId.AsString)
  else
    Result := TJSONNumber.Create(FId.AsInteger);
end;

function TJRPCReply.Answered: Boolean;
begin
  Result := FAnswered <> 0;
end;

procedure TJRPCReply.Result(AValue: TJSONValue);
var
  LResponse: TJRPCResponse;
begin
  if not Claim then
  begin
    AValue.Free;
    raise EJRPCClientError.CreateFmt(SJRPCClientAlreadyAnswered, [FId.AsString]);
  end;

  if not Assigned(AValue) then
    AValue := TJSONNull.Create;

  LResponse := TJRPCResponse.Create;
  try
    LResponse.Id := FId;
    LResponse.Result := AValue;
    SendText(LResponse.ToJson);
  finally
    LResponse.Free;
  end;
end;

procedure TJRPCReply.Result(const AValue: TValue);
begin
  Result(TNeon.ValueToJSON(AValue, FNeonConfig));
end;

procedure TJRPCReply.Error(ACode: Integer; const AMessage: string; AData: TJSONValue);
var
  LMessage: TJSONObject;
  LError: TJSONObject;
begin
  if not Claim then
  begin
    AData.Free;
    raise EJRPCClientError.CreateFmt(SJRPCClientAlreadyAnswered, [FId.AsString]);
  end;

  LMessage := TJSONObject.Create;
  try
    LError := TJSONObject.Create;
    LError.AddPair('code', TJSONNumber.Create(ACode));
    LError.AddPair('message', AMessage);
    if Assigned(AData) then
      LError.AddPair('data', AData);

    LMessage.AddPair('jsonrpc', TJRPCMessage.JSONRPC_VERSION);
    LMessage.AddPair('id', IdToJSON);
    LMessage.AddPair('error', LError);
    SendText(LMessage.ToJSON);
  finally
    LMessage.Free;
  end;
end;

procedure TJRPCReply.Raw(const AText: string);
begin
  if AText.Trim = '' then
    Exit;

  if not Claim then
    raise EJRPCClientError.CreateFmt(SJRPCClientAlreadyAnswered, [FId.AsString]);
  SendText(AText);
end;

procedure TJRPCReply.Fail(E: Exception);
var
  LError: TJRPCError;
begin
  if not Claim then
    Exit;

  LError := TJRPCError.CreateFromException(E, FId);
  try
    SendText(LError.ToJson);
  finally
    LError.Free;
  end;
end;

{ TJRPCPendingCall }

constructor TJRPCPendingCall.Create(AClient: TJRPCClient; const AId: TJRPCID;
  const AOnNotification: TJRPCNotificationProc);
begin
  inherited Create;
  FClient := AClient;
  FId := AId;
  FKey := TJRPCClient.KeyOf(AId);
  FOnNotification := AOnNotification;
  FLock := TCriticalSection.Create;
  FDone := TEvent.Create(nil, True, False, '');
end;

destructor TJRPCPendingCall.Destroy;
begin
  FReply.Free;
  FRaw.Free;
  FError.Free;
  FDone.Free;
  FLock.Free;
  inherited;
end;

function TJRPCPendingCall.Id: TJRPCID;
begin
  Result := FId;
end;

function TJRPCPendingCall.Wait(ATimeout: Cardinal): Boolean;
begin
  Result := FDone.WaitFor(ATimeout) = wrSignaled;
end;

function TJRPCPendingCall.Completed: Boolean;
begin
  Result := FDone.WaitFor(0) = wrSignaled;
end;

procedure TJRPCPendingCall.Cancel;
begin
  CancelWith(TJRPCCallEnd.Cancelled, SJRPCClientCallCancelled);
end;

procedure TJRPCPendingCall.CancelWith(AReason: TJRPCCallEnd; const AMessage: string);
var
  LError: Exception;
  LClient: TJRPCClient;
begin
  // The call lock is held while the client is told: Detach takes the same
  // lock, so a client that is going away waits here instead of being freed
  // under the notification. The client never holds its own lock while taking
  // a call's, so the order is safe.
  FLock.Enter;
  try
    LError := EJRPCClientError.Create(AMessage);
    if not Complete(nil, nil, LError) then
    begin
      LError.Free;
      Exit;
    end;

    LClient := FClient;
    FClient := nil;
    if Assigned(LClient) then
      LClient.CallAbandoned(Self, AReason, AMessage);
  finally
    FLock.Leave;
  end;
end;

function TJRPCPendingCall.Complete(AReply: TJRPCMessage; ARaw: TJSONObject;
  AError: Exception; AAction: TJRPCErrorAction): Boolean;
begin
  FLock.Enter;
  try
    Result := not FCompleted;
    if Result then
    begin
      FCompleted := True;
      FReply := AReply;
      FRaw := ARaw;
      FError := AError;
      FErrorAction := AAction;
      if Assigned(AError) then
        FErrorMessage := AError.Message;
      // Nothing more will be delivered to it. A handler that captures its own
      // call (to Cancel it from inside) would otherwise keep both alive.
      FOnNotification := nil;
    end;
  finally
    FLock.Leave;
  end;

  if Result then
    FDone.SetEvent;
end;

procedure TJRPCPendingCall.Detach;
begin
  FLock.Enter;
  try
    FClient := nil;
  finally
    FLock.Leave;
  end;
end;

procedure TJRPCPendingCall.SetErrorAction(AAction: TJRPCErrorAction);
begin
  FLock.Enter;
  try
    FErrorAction := AAction;
  finally
    FLock.Leave;
  end;
end;

function TJRPCPendingCall.TakeResult: TJSONValue;
var
  LRaise: Exception;
  LAction: TJRPCErrorAction;
begin
  Result := nil;
  LRaise := nil;

  FLock.Enter;
  try
    LAction := FErrorAction;
    if not FCompleted then
      LRaise := EJRPCClientError.Create(SJRPCClientNoResponse)
    else if FReply is TJRPCResponse then
      // Result is never nil - the constructor installs a TJSONNull - so a
      // "result" of null comes back as a live value, not as nil.
      Result := (FReply as TJRPCResponse).Result.Clone as TJSONValue
    else if LAction <> TJRPCErrorAction.Raise then
      // OnError chose not to raise the failure: nothing to build. FError
      // stays, for TakeMessage.
    else if FReply is TJRPCError then
      LRaise := EJRPCRemoteError.FromError(FReply as TJRPCError, FRaw)
    else if Assigned(FError) then
    begin
      LRaise := FError;
      FError := nil;
    end
    else
      LRaise := EJRPCClientError.CreateFmt(SJRPCClientOutcomeTaken, [FErrorMessage]);
  finally
    FLock.Leave;
  end;

  if Assigned(Result) then
    Exit;

  case LAction of
    TJRPCErrorAction.Abort:
      System.SysUtils.Abort;
    TJRPCErrorAction.Ignore:
      Exit;
  end;

  raise LRaise;
end;

function TJRPCPendingCall.TakeMessage: TJRPCMessage;
var
  LError: TJRPCError;
begin
  FLock.Enter;
  try
    if Assigned(FReply) then
    begin
      Result := FReply;
      FReply := nil;
      Exit;
    end;

    if Assigned(FError) then
      LError := TJRPCError.CreateFromException(FError, FId)
    else
    begin
      LError := TJRPCError.Create;
      LError.Id := FId;
      LError.Error.Code := JRPC_INTERNAL_ERROR;
      if FErrorMessage <> '' then
        LError.Error.Message := FErrorMessage
      else
        LError.Error.Message := SJRPCClientNoResponse;
    end;
    Result := LError;
  finally
    FLock.Leave;
  end;
end;

{ TJRPCCall<T> }

constructor TJRPCCall<T>.Create(const ACall: IJRPCCall; const ANeonConfig: INeonConfiguration);
begin
  inherited Create;
  FCall := ACall;
  FPending := ACall as TJRPCPendingCall;
  FNeonConfig := ANeonConfig;
end;

function TJRPCCall<T>.Id: TJRPCID;
begin
  Result := FCall.Id;
end;

function TJRPCCall<T>.Wait(ATimeout: Cardinal): Boolean;
begin
  Result := FCall.Wait(ATimeout);
end;

function TJRPCCall<T>.Completed: Boolean;
begin
  Result := FCall.Completed;
end;

procedure TJRPCCall<T>.Cancel;
begin
  FCall.Cancel;
end;

function TJRPCCall<T>.Value: T;
var
  LValue: TJSONValue;
begin
  FCall.Wait;
  LValue := FPending.TakeResult;
  // A failure OnError chose to Ignore.
  if not Assigned(LValue) then
    Exit(Default(T));

  try
    Result := TJRPCClient.FromJSON<T>(LValue, FNeonConfig);
  finally
    LValue.Free;
  end;
end;

{ TJRPCClient }

constructor TJRPCClient.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FLock := TCriticalSection.Create;
  FPending := TDictionary<string, IJRPCCall>.Create;
  FReplyChannel := TJRPCReplyChannel.Create(Self);
  FState := TState.Idle;
  FCompactPayload := True;
  FDispatchMode := TJRPCDispatchMode.Queue;

  // Once per instance: JRPCNeonConfig builds a fresh configuration, registering
  // six serializers, on every call.
  FNeonConfig := JRPCNeonConfig;
end;

destructor TJRPCClient.Destroy;
begin
  Close;
  WaitInFlight;
  ReleaseDispatcher;
  (FReplyChannel as TJRPCReplyChannel).Detach;
  FReplyChannel := nil;
  // Released here, not with the fields: a pull transport joins its reader on
  // destruction, and the reader may still be in a handler that uses us.
  FTransport := nil;
  FPending.Free;
  FLock.Free;
  inherited;
end;

procedure TJRPCClient.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited;
  if (Operation = opRemove) and (AComponent = FServer) then
    FServer := nil;
end;

procedure TJRPCClient.SetServer(AValue: TJRPCServer);
begin
  if FServer = AValue then
    Exit;

  if Assigned(FServer) then
    FServer.RemoveFreeNotification(Self);
  FServer := AValue;
  if Assigned(FServer) then
    FServer.FreeNotification(Self);
end;

class function TJRPCClient.NewId: TJRPCID;
begin
  // The counter lives in JRPC.Core: one for the whole process.
  Result := TJRPCID.NewId;
end;

class function TJRPCClient.KeyOf(const AId: TJRPCID): string;
begin
  // The kind is part of the key: the number 7 and the string "7" are
  // different ids on the wire.
  if AId.IsNull then
    Result := 'n'
  else if AId.IsString then
    Result := 's:' + AId.AsString
  else
    Result := 'i:' + AId.AsString;
end;

class function TJRPCClient.MessageId(AMessage: TJRPCMessage; out AId: TJRPCID): Boolean;
begin
  Result := True;

  if AMessage is TJRPCRequest then
    AId := (AMessage as TJRPCRequest).Id
  else if AMessage is TJRPCResponse then
    AId := (AMessage as TJRPCResponse).Id
  else if AMessage is TJRPCError then
    AId := (AMessage as TJRPCError).Id
  else
    // A Notification carries no id at all, by definition.
    Result := False;
end;

class function TJRPCClient.FindById(AMessages: TJRPCMessages; const AId: TJRPCID): TJRPCMessage;
var
  LMessage: TJRPCMessage;
  LId: TJRPCID;
begin
  for LMessage in AMessages.List do
    if MessageId(LMessage, LId) and (LId = AId) then
      Exit(LMessage);

  Result := nil;
end;

class function TJRPCClient.FromJSON<T>(AValue: TJSONValue; const ANeonConfig: INeonConfiguration): T;
var
  LType: TRttiType;
  LObject: TObject;
  LResult: TValue;
begin
  LType := TRttiUtils.Context.GetType(TypeInfo(T));
  if not Assigned(LType) then
    raise EJRPCClientError.Create(SJRPCClientUnknownResultType);

  // The same split the server's invoker uses to bind a parameter, run the
  // other way round.
  if LType.IsInstance then
  begin
    LObject := TNeon.JSONToObject(LType, AValue, ANeonConfig);
    TValue.Make(@LObject, LType.Handle, LResult);
    Result := LResult.AsType<T>;
  end
  else
    Result := TNeon.JSONToValue<T>(AValue, ANeonConfig);
end;

function TJRPCClient.GetActive: Boolean;
begin
  Result := FState = TState.Open;
end;

function TJRPCClient.CloseReason: string;
begin
  if FHasCloseInfo then
    Result := FCloseInfo.Reason
  else
    Result := SJRPCCloseLocal;
end;

procedure TJRPCClient.SetTransport(const AValue: IJRPCTransport);
begin
  Close;
  WaitInFlight;
  ReleaseDispatcher;

  FLock.Enter;
  try
    FTransport := AValue;
    FState := TState.Idle;
    FHasCloseInfo := False;
    FCloseNotified := False;
  finally
    FLock.Leave;
  end;
end;

procedure TJRPCClient.Open;
begin
  EnsureOpen;
end;

procedure TJRPCClient.EnsureOpen;
begin
  FLock.Enter;
  try
    case FState of
      TState.Open:
        Exit;
      TState.Closed:
        raise EJRPCClientError.CreateFmt(SJRPCClientClosed, [CloseReason]);
    end;

    if not Assigned(FTransport) then
      raise EJRPCClientError.Create(SJRPCClientNoTransport);

    FState := TState.Open;
    FHasCloseInfo := False;
    FCloseNotified := False;

    // The dispatcher first: the transport may deliver a message as soon as it
    // is open.
    if FDispatchMode = TJRPCDispatchMode.Queue then
    begin
      FDispatcher := TJRPCDispatcher.Create(Self);
      FDispatcher.Start;
    end;

    try
      FTransport.Open(Self);
    except
      FState := TState.Idle;
      StopDispatcher(True);
      raise;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TJRPCClient.Close;
var
  LTransport: IJRPCTransport;
  LInfo: TJRPCCloseInfo;
begin
  FLock.Enter;
  try
    if FState <> TState.Open then
      Exit;

    FState := TState.Closed;
    LTransport := FTransport;
  finally
    FLock.Leave;
  end;

  FailPending(Format(SJRPCClientClosed, [SJRPCCloseLocal]));

  try
    LTransport.Close;
  except
    on E: Exception do
      ReportError(E);
  end;

  WaitInFlight;
  StopDispatcher(True);

  FLock.Enter;
  try
    // A transport that says why it ended (a process with its exit code) has
    // reported it by now, from inside Close.
    if FHasCloseInfo then
      LInfo := FCloseInfo
    else
      LInfo := TJRPCCloseInfo.Local;
  finally
    FLock.Leave;
  end;

  NotifyClosed(LInfo);
end;

procedure TJRPCClient.TransportClosed(const AInfo: TJRPCCloseInfo);
var
  LWasOpen: Boolean;
begin
  FLock.Enter;
  try
    LWasOpen := FState = TState.Open;
    if not FHasCloseInfo then
    begin
      FCloseInfo := AInfo;
      FHasCloseInfo := True;
    end;
    FState := TState.Closed;
  finally
    FLock.Leave;
  end;

  // Closed from this side: Close is running and owns the cleanup.
  if not LWasOpen then
    Exit;

  FailPending(Format(SJRPCClientClosed, [AInfo.Reason]));
  // Signalled, not joined: a handler on the dispatcher may be closing the
  // client right now, waiting for this very thread to end.
  StopDispatcher(False);
  NotifyClosed(AInfo);
end;

procedure TJRPCClient.StopDispatcher(AWait: Boolean);
var
  LDispatcher: TJRPCDispatcher;
begin
  FLock.Enter;
  try
    LDispatcher := TJRPCDispatcher(FDispatcher);
    if not Assigned(LDispatcher) then
      Exit;

    LDispatcher.Stop;

    // From a handler on the dispatcher itself it cannot wait for itself: it
    // ends once the handler returns, and ReleaseDispatcher (Destroy, a new
    // Transport) joins it.
    if not AWait or (LDispatcher = TThread.CurrentThread) then
      Exit;

    FDispatcher := nil;
  finally
    FLock.Leave;
  end;

  LDispatcher.WaitFor;
  LDispatcher.Free;
end;

procedure TJRPCClient.ReleaseDispatcher;
var
  LDispatcher: TThread;
begin
  FLock.Enter;
  try
    LDispatcher := FDispatcher;
    FDispatcher := nil;
  finally
    FLock.Leave;
  end;

  if not Assigned(LDispatcher) then
    Exit;

  TJRPCDispatcher(LDispatcher).Stop;
  if LDispatcher = TThread.CurrentThread then
  begin
    // Freed from its own handler: the thread frees itself once the handler
    // returns. It touches nothing of the client after that.
    LDispatcher.FreeOnTerminate := True;
    Exit;
  end;

  LDispatcher.WaitFor;
  LDispatcher.Free;
end;

procedure TJRPCClient.WaitInFlight;
begin
  // A task cannot wait for itself: Close from a handler running inside an
  // asynchronous Send returns without waiting for the others either.
  if GInAsyncSend then
    Exit;

  while TInterlocked.CompareExchange(FInFlight, 0, 0) > 0 do
    TThread.Sleep(5);
end;

procedure TJRPCClient.NotifyClosed(const AInfo: TJRPCCloseInfo);
var
  LProc: TJRPCCloseProc;
begin
  FLock.Enter;
  try
    if FCloseNotified then
      Exit;
    FCloseNotified := True;
    LProc := FOnClose;
  finally
    FLock.Leave;
  end;

  if Assigned(LProc) then
    try
      LProc(AInfo);
    except
      on E: Exception do
        ReportError(E);
    end;
end;

function TJRPCClient.ReportError(E: Exception): TJRPCErrorAction;
begin
  Result := TJRPCErrorAction.Raise;
  if not Assigned(FOnError) then
    Exit;

  // Called from the reader, the dispatcher and Close: a handler that raises
  // must not end a thread, nor make a destructor raise.
  try
    FOnError(E, Result);
  except
    on EHandler: Exception do
    begin
      Result := TJRPCErrorAction.Raise;
      Logger.LogWarning(EHandler, 'OnError raised while reporting: ' + E.Message);
    end;
  end;
end;

function TJRPCClient.ReportText(const AText: string): TJRPCErrorAction;
var
  LError: EJRPCClientError;
begin
  Logger.LogWarning(AText);
  LError := EJRPCClientError.Create(AText);
  try
    Result := ReportError(LError);
  finally
    LError.Free;
  end;
end;

function CompactJSON(const AJSON: string): string;
var
  LValue: TJSONValue;
begin
  if Pos(#10, AJSON) = 0 then
    Exit(AJSON);

  LValue := TJSONObject.ParseJSONValue(AJSON);
  if not Assigned(LValue) then
    // Deliberately malformed text goes out untouched: compaction is a framing
    // aid, never a validation step.
    Exit(AJSON);

  try
    Result := LValue.ToJSON;
  finally
    LValue.Free;
  end;
end;

function TJRPCClient.PreparePayload(const AJSON: string): string;
begin
  Result := AJSON;
  if FCompactPayload then
    Result := CompactJSON(Result);
end;

procedure TJRPCClient.SendText(const AText: string; const AOrigin: TJRPCID);
var
  LTransport: IJRPCTransport;
begin
  LTransport := FTransport;
  if not Assigned(LTransport) then
    raise EJRPCClientError.Create(SJRPCClientNoTransport);

  if Assigned(FOnBeforeSend) then
    FOnBeforeSend(AText);

  LTransport.Send(AText, AOrigin);
end;

procedure TJRPCClient.Transmit(const AJSON: string; const AOrigin: TJRPCID);
begin
  SendText(PreparePayload(AJSON), AOrigin);
end;

procedure TJRPCClient.AddPending(const ACall: IJRPCCall);
var
  LPending: TJRPCPendingCall;
begin
  LPending := ACall as TJRPCPendingCall;

  FLock.Enter;
  try
    if FState <> TState.Open then
      raise EJRPCClientError.CreateFmt(SJRPCClientClosed, [CloseReason]);

    // An id the caller chose (or a request sent twice) that is still in
    // flight: the answer could not tell the two calls apart.
    if FPending.ContainsKey(LPending.Key) then
      raise EJRPCClientError.CreateFmt(SJRPCClientDuplicateId, [LPending.Id.AsString]);

    FPending.Add(LPending.Key, ACall);
  finally
    FLock.Leave;
  end;
end;

function TJRPCClient.FailedCall(const AId: TJRPCID; AError: Exception;
  AAction: TJRPCErrorAction): IJRPCCall;
var
  LPending: TJRPCPendingCall;
begin
  // Never registered: no answer can reach it, and Cancel has nobody to tell.
  LPending := TJRPCPendingCall.Create(nil, AId, nil);
  Result := LPending;
  LPending.Complete(nil, nil, AError, AAction);
end;

function TJRPCClient.StartCall(ARequest: TJRPCRequest;
  const AOnNotification: TJRPCNotificationProc; AAsync: Boolean): IJRPCCall;
var
  LPending: TJRPCPendingCall;
  LText: string;
  LRoundTrip: Boolean;
begin
  // Every failure below leaves through the except: the compiler cannot tell.
  LPending := nil;
  try
    EnsureOpen;

    // A request the caller built by hand may carry no id: give it one, so
    // the answer can be correlated at all.
    if ARequest.Id.IsNull then
      ARequest.Id := NewId;

    LPending := TJRPCPendingCall.Create(Self, ARequest.Id, AOnNotification);
    Result := LPending;
    LText := PreparePayload(ARequest.ToJson);
    AddPending(Result);
  except
    on E: Exception do
      case ReportError(E) of
        TJRPCErrorAction.Raise:
          raise;
        TJRPCErrorAction.Abort:
          System.SysUtils.Abort;
        TJRPCErrorAction.Ignore:
          // A call that has already failed, so that the caller collects an
          // empty result the way it would for any other ignored failure.
          Exit(FailedCall(ARequest.Id, Exception(AcquireExceptionObject),
            TJRPCErrorAction.Ignore));
      end;
  end;

  LRoundTrip := FTransport.RoundTrip;

  if AAsync and LRoundTrip then
  begin
    StartAsyncSend(LText, ARequest.Id, [LPending.Key]);
    Exit;
  end;

  try
    SendText(LText, ARequest.Id);
  except
    on E: Exception do
      FailKeys([LPending.Key], E);
  end;

  if LRoundTrip then
    FinishRoundTrip([LPending.Key]);
end;

procedure TJRPCClient.FailKeys(const AKeys: TArray<string>; E: Exception);
var
  LKey: string;
  LCall: IJRPCCall;
  LFirst: Boolean;
  LError: Exception;
begin
  // Called from an except block with E: a transport that failed after it had
  // delivered the answer leaves the call completed, and the answer wins. The
  // first call still waiting gets E itself, so its class survives.
  LFirst := True;
  for LKey in AKeys do
  begin
    FLock.Enter;
    try
      if not FPending.TryGetValue(LKey, LCall) then
        LCall := nil;
    finally
      FLock.Leave;
    end;

    if not Assigned(LCall) then
      Continue;

    if LFirst then
    begin
      LError := Exception(AcquireExceptionObject);
      LFirst := False;
    end
    else
      LError := EJRPCClientError.Create(E.Message);

    CompletePending(LCall.Id, nil, nil, LError);
  end;

  if LFirst then
    Logger.LogDebug('The transport failed after the answer arrived: ' + E.Message);
end;

procedure TJRPCClient.FinishRoundTrip(const AKeys: TArray<string>);
var
  LKey: string;
  LCall: IJRPCCall;
begin
  // Send has returned: whatever the answer was going to be has been
  // delivered. A call still waiting will never be answered.
  for LKey in AKeys do
  begin
    FLock.Enter;
    try
      if not FPending.TryGetValue(LKey, LCall) then
        LCall := nil;
    finally
      FLock.Leave;
    end;

    if Assigned(LCall) then
      CompletePending(LCall.Id, nil, nil, EJRPCClientError.Create(SJRPCClientNoResponse));
  end;
end;

procedure TJRPCClient.StartAsyncSend(const AText: string; const AOrigin: TJRPCID;
  const AKeys: TArray<string>);
begin
  TInterlocked.Increment(FInFlight);
  try
    TTask.Run(
      procedure
      begin
        GInAsyncSend := True;
        try
          // Cancelled before this task got going: nothing is sent at all. An
          // Abort that came first would be lost on a transport that clears its
          // abort state as a read starts, and the read would wait on a peer
          // that may never send anything.
          if not AnyPending(AKeys) then
            Exit;

          try
            SendText(AText, AOrigin);
          except
            on E: Exception do
              FailKeys(AKeys, E);
          end;
          FinishRoundTrip(AKeys);
        finally
          GInAsyncSend := False;
          TInterlocked.Decrement(FInFlight);
        end;
      end);
  except
    TInterlocked.Decrement(FInFlight);
    raise;
  end;
end;

procedure TJRPCClient.AwaitCall(ACall: TJRPCPendingCall; ATimeout: Cardinal);
begin
  if ATimeout = 0 then
    ATimeout := FDefaultTimeout;

  if (ATimeout = 0) or (ATimeout = JRPC_INFINITE) then
    ACall.Wait
  else if not ACall.Wait(ATimeout) then
    // A no-op when the answer lands between the wait and the cancel: the
    // answer is then what the caller gets.
    ACall.CancelWith(TJRPCCallEnd.Timeout, Format(SJRPCClientTimeout, [ATimeout]));
end;

function TJRPCClient.DoExecute(ARequest: TJRPCRequest; ATimeout: Cardinal): TJSONValue;
var
  LCall: IJRPCCall;
  LPending: TJRPCPendingCall;
begin
  LCall := StartCall(ARequest, nil, False);
  LPending := LCall as TJRPCPendingCall;
  AwaitCall(LPending, ATimeout);
  Result := LPending.TakeResult;
end;

function TJRPCClient.ExecuteAs<T>(ARequest: TJRPCRequest; ATimeout: Cardinal): T;
var
  LValue: TJSONValue;
begin
  LValue := DoExecute(ARequest, ATimeout);
  // A failure OnError chose to Ignore.
  if not Assigned(LValue) then
    Exit(Default(T));

  // What an ignored failure returns.
  Result := Default(T);
  try
    try
      Result := FromJSON<T>(LValue, FNeonConfig);
    except
      on E: Exception do
        case ReportError(E) of
          TJRPCErrorAction.Raise:
            raise;
          TJRPCErrorAction.Abort:
            System.SysUtils.Abort;
        end;
    end;
  finally
    LValue.Free;
  end;
end;

function TJRPCClient.ExecuteAs<T>(const ARequest: IJRPCRequestBuilder; ATimeout: Cardinal): T;
begin
  Result := ExecuteAs<T>(ARequest.Build, ATimeout);
end;

function TJRPCClient.ExecuteAsJSONValue(ARequest: TJRPCRequest; ATimeout: Cardinal): TJSONValue;
begin
  Result := DoExecute(ARequest, ATimeout);
end;

function TJRPCClient.ExecuteAsJSONValue(const ARequest: IJRPCRequestBuilder;
  ATimeout: Cardinal): TJSONValue;
begin
  Result := DoExecute(ARequest.Build, ATimeout);
end;

function TJRPCClient.ExecuteAsJsonString(ARequest: TJRPCRequest; ATimeout: Cardinal): string;
var
  LValue: TJSONValue;
begin
  LValue := DoExecute(ARequest, ATimeout);
  // A failure OnError chose to Ignore.
  if not Assigned(LValue) then
    Exit('');

  try
    Result := LValue.ToJSON;
  finally
    LValue.Free;
  end;
end;

function TJRPCClient.ExecuteAsJsonString(const ARequest: IJRPCRequestBuilder;
  ATimeout: Cardinal): string;
begin
  Result := ExecuteAsJsonString(ARequest.Build, ATimeout);
end;

procedure TJRPCClient.Execute(ARequest: TJRPCRequest; ATimeout: Cardinal);
begin
  DoExecute(ARequest, ATimeout).Free;
end;

procedure TJRPCClient.Execute(const ARequest: IJRPCRequestBuilder; ATimeout: Cardinal);
begin
  Execute(ARequest.Build, ATimeout);
end;

function TJRPCClient.ExecuteAsync<T>(ARequest: TJRPCRequest;
  const AOnNotification: TJRPCNotificationProc): IJRPCCall<T>;
begin
  Result := TJRPCCall<T>.Create(StartCall(ARequest, AOnNotification, True), FNeonConfig);
end;

function TJRPCClient.ExecuteAsync<T>(const ARequest: IJRPCRequestBuilder;
  const AOnNotification: TJRPCNotificationProc): IJRPCCall<T>;
begin
  Result := ExecuteAsync<T>(ARequest.Build, AOnNotification);
end;

procedure TJRPCClient.Notify(ANotification: TJRPCNotification);
begin
  try
    EnsureOpen;
    Transmit(ANotification.ToJson, TJRPCID.Null);
  except
    on E: Exception do
      case ReportError(E) of
        TJRPCErrorAction.Raise:
          raise;
        TJRPCErrorAction.Abort:
          System.SysUtils.Abort;
      end;
  end;
end;

procedure TJRPCClient.Notify(const ANotification: IJRPCNotificationBuilder);
begin
  Notify(ANotification.Build);
end;

function TJRPCClient.ExecuteBatch(AMessages: TJRPCMessages; ATimeout: Cardinal): TJRPCMessages;
var
  LCalls: TList<IJRPCCall>;
  LKeys: TArray<string>;
  LMessage: TJRPCMessage;
  LRequest: TJRPCRequest;
  LCall: IJRPCCall;
  LOrigin: TJRPCID;
  LText: string;
  LDeadline: UInt64;
  LNow: UInt64;
  LRemaining: Cardinal;
begin
  LCalls := TList<IJRPCCall>.Create;
  try
    try
      if AMessages.IsEmpty then
        raise EJRPCClientError.Create(SJRPCClientEmptyBatch);

      EnsureOpen;

      // A batch always goes out as an array, whatever it holds: Single would
      // make ToJson emit a bare object for a batch of one.
      AMessages.Single := False;

      LOrigin := TJRPCID.Null;
      for LMessage in AMessages.List do
      begin
        if not (LMessage is TJRPCRequest) then
          Continue;

        LRequest := LMessage as TJRPCRequest;
        if LRequest.Id.IsNull then
          LRequest.Id := NewId;

        LCall := TJRPCPendingCall.Create(Self, LRequest.Id, nil);
        AddPending(LCall);
        LCalls.Add(LCall);
        LKeys := LKeys + [(LCall as TJRPCPendingCall).Key];
        if LOrigin.IsNull then
          LOrigin := LRequest.Id;
      end;

      LText := PreparePayload(AMessages.ToJson);
      SendText(LText, LOrigin);
    except
      on E: Exception do
      begin
        for LCall in LCalls do
        begin
          Forget((LCall as TJRPCPendingCall).Key);
          (LCall as TJRPCPendingCall).Detach;
        end;
        case ReportError(E) of
          TJRPCErrorAction.Raise:
            raise;
          TJRPCErrorAction.Abort:
            System.SysUtils.Abort;
          TJRPCErrorAction.Ignore:
            Exit(TJRPCMessages.Create(True));
        end;
      end;
    end;

    Result := TJRPCMessages.Create(True);
    if LCalls.Count = 0 then
      Exit;

    if FTransport.RoundTrip then
      FinishRoundTrip(LKeys);

    // One deadline for the whole batch.
    if ATimeout = 0 then
      ATimeout := FDefaultTimeout;
    LDeadline := 0;
    if (ATimeout <> 0) and (ATimeout <> JRPC_INFINITE) then
      LDeadline := TThread.GetTickCount64 + ATimeout;

    for LCall in LCalls do
    begin
      if LDeadline = 0 then
        LCall.Wait
      else
      begin
        LNow := TThread.GetTickCount64;
        if LNow >= LDeadline then
          LRemaining := 0
        else
          LRemaining := LDeadline - LNow;

        if not LCall.Wait(LRemaining) then
          (LCall as TJRPCPendingCall).CancelWith(TJRPCCallEnd.Timeout,
            Format(SJRPCClientTimeout, [ATimeout]));
      end;

      Result.AddMessage((LCall as TJRPCPendingCall).TakeMessage);
    end;
  finally
    LCalls.Free;
  end;
end;

function TJRPCClient.IsPending(const AId: TJRPCID): Boolean;
begin
  FLock.Enter;
  try
    Result := FPending.ContainsKey(KeyOf(AId));
  finally
    FLock.Leave;
  end;
end;

function TJRPCClient.AnyPending(const AKeys: TArray<string>): Boolean;
var
  LKey: string;
begin
  FLock.Enter;
  try
    for LKey in AKeys do
      if FPending.ContainsKey(LKey) then
        Exit(True);
    Result := False;
  finally
    FLock.Leave;
  end;
end;

procedure TJRPCClient.Forget(const AKey: string);
begin
  FLock.Enter;
  try
    FPending.Remove(AKey);
  finally
    FLock.Leave;
  end;
end;

procedure TJRPCClient.CompletePending(const AId: TJRPCID; AReply: TJRPCMessage;
  ARaw: TJSONObject; AError: Exception);
var
  LKey: string;
  LCall: IJRPCCall;
  LPending: TJRPCPendingCall;
  LRemote: EJRPCRemoteError;
  LAction: TJRPCErrorAction;
begin
  LKey := KeyOf(AId);

  FLock.Enter;
  try
    if FPending.TryGetValue(LKey, LCall) then
      FPending.Remove(LKey)
    else
      LCall := nil;
  finally
    FLock.Leave;
  end;

  if not Assigned(LCall) then
  begin
    // An answer nobody waits for: a call that timed out or was cancelled, or
    // a peer out of sync. A failure of a call already completed (a transport
    // that broke after delivering) is reported as it is.
    try
      if Assigned(AError) then
        ReportError(AError)
      else
        ReportText(Format(SJRPCClientUnknownId, [AId.AsString]));
    finally
      AReply.Free;
      ARaw.Free;
      AError.Free;
    end;
    Exit;
  end;

  LPending := LCall as TJRPCPendingCall;
  LPending.Detach;

  // Reported before the call completes, so the caller that wakes up finds it
  // reported already, with the action OnError chose.
  LAction := TJRPCErrorAction.Raise;
  if Assigned(AError) then
    LAction := ReportError(AError)
  else if AReply is TJRPCError then
  begin
    LRemote := EJRPCRemoteError.FromError(AReply as TJRPCError, ARaw);
    try
      LAction := ReportError(LRemote);
    finally
      LRemote.Free;
    end;
  end;

  if not LPending.Complete(AReply, ARaw, AError, LAction) then
  begin
    AReply.Free;
    ARaw.Free;
    AError.Free;
  end;
end;

procedure TJRPCClient.CallAbandoned(ACall: TJRPCPendingCall; AReason: TJRPCCallEnd;
  const AMessage: string);
var
  LAbort: IJRPCAbortableTransport;
begin
  Forget(ACall.Key);

  if Supports(FTransport, IJRPCAbortableTransport, LAbort) then
    try
      LAbort.Abort(ACall.Id);
    except
      on E: Exception do
        ReportError(E);
    end;

  // A timeout is a failure; a Cancel is what the caller asked for. The call
  // has completed already: the caller, the thread running this, collects it
  // next, with the action OnError chose.
  if AReason = TJRPCCallEnd.Timeout then
    ACall.SetErrorAction(ReportText(AMessage));

  if Assigned(FOnCallEnded) then
    try
      FOnCallEnded(ACall.Id, AReason);
    except
      on E: Exception do
        ReportError(E);
    end;
end;

procedure TJRPCClient.FailPending(const AMessage: string);
var
  LPending: TArray<IJRPCCall>;
  LCall: IJRPCCall;
  LError: Exception;
begin
  FLock.Enter;
  try
    LPending := FPending.Values.ToArray;
    FPending.Clear;
  finally
    FLock.Leave;
  end;

  for LCall in LPending do
  begin
    (LCall as TJRPCPendingCall).Detach;
    LError := EJRPCClientError.Create(AMessage);
    if not (LCall as TJRPCPendingCall).Complete(nil, nil, LError) then
      LError.Free;
  end;
end;

procedure TJRPCClient.MessageReceived(const AText: string; const AOrigin: TJRPCID);
begin
  try
    if Assigned(FOnAfterReceive) then
      FOnAfterReceive(AText);

    HandleFrame(AText, AOrigin);
  except
    on E: Exception do
      ReportError(E);
  end;
end;

procedure TJRPCClient.HandleFrame(const AText: string; const AOrigin: TJRPCID);
var
  LDocument: TJSONValue;
  LMessages: TJRPCMessages;
  LRejections: TStringList;
  LIndex: Integer;
  LRaw: TJSONObject;
begin
  // A blank frame (a stray line break between messages) carries nothing to
  // read or to answer.
  if AText.Trim = '' then
    Exit;

  LDocument := TJSONObject.ParseJSONValue(AText);
  if not Assigned(LDocument) then
  begin
    RejectFrame(EJRPCParseError.Create(SJRPCInvalidJSONReceived), AOrigin);
    Exit;
  end;

  try
    try
      LMessages := TJRPCMessages.CreateFromJson(LDocument);
    except
      on E: EJRPCException do
      begin
        // JSON, but no message at all - an empty array, a bare value.
        RejectFrame(Exception(AcquireExceptionObject), AOrigin);
        Exit;
      end;
    end;

    try
      if LMessages.Single then
      begin
        HandleMessage(LMessages.List[0], LDocument as TJSONObject, AOrigin, nil);
        Exit;
      end;

      // A batch: the answers in it are matched one by one; the requests in it
      // are refused together, in one array, as a batch reply must be.
      LRejections := TStringList.Create;
      try
        for LIndex := 0 to LMessages.Count - 1 do
        begin
          LRaw := nil;
          if (LDocument is TJSONArray) and
            ((LDocument as TJSONArray).Items[LIndex] is TJSONObject) then
            LRaw := (LDocument as TJSONArray).Items[LIndex] as TJSONObject;

          try
            HandleMessage(LMessages.List[LIndex], LRaw, AOrigin, LRejections);
          except
            on E: Exception do
              ReportError(E);
          end;
        end;

        if LRejections.Count > 0 then
          Transmit('[' + string.Join(',', LRejections.ToStringArray) + ']', TJRPCID.Null);
      finally
        LRejections.Free;
      end;
    finally
      LMessages.Free;
    end;
  finally
    LDocument.Free;
  end;
end;

procedure TJRPCClient.RejectFrame(AError: Exception; const AOrigin: TJRPCID);
begin
  // On the answer stream of a call: that call failed to get its answer.
  if not AOrigin.IsNull and IsPending(AOrigin) then
  begin
    CompletePending(AOrigin, nil, nil, AError);
    Exit;
  end;

  try
    // What a server answers to what it cannot read, with a null id: on a
    // persistent channel the peer may be waiting for it.
    if AOrigin.IsNull then
      try
        AnswerPeer(AError, TJRPCID.Null);
      except
        on E: Exception do
          ReportError(E);
      end;

    ReportError(AError);
  finally
    AError.Free;
  end;
end;

procedure TJRPCClient.HandleMessage(AMessage: TJRPCMessage; ARaw: TJSONObject;
  const AOrigin: TJRPCID; ARejections: TStrings);
var
  LError: TJRPCError;
  LRequest: TJRPCRequest;
  LRemote: EJRPCRemoteError;
  LRawClone: TJSONObject;
begin
  if AMessage is TJRPCResponse then
  begin
    CompletePending((AMessage as TJRPCResponse).Id, (AMessage as TJRPCResponse).Clone, nil, nil);
    Exit;
  end;

  if AMessage is TJRPCNotification then
  begin
    RouteNotification(AMessage as TJRPCNotification, AOrigin);
    Exit;
  end;

  if AMessage is TJRPCRequest then
  begin
    LRequest := AMessage as TJRPCRequest;
    if Assigned(ARejections) then
    begin
      LError := TJRPCError.Create;
      try
        LError.Id := LRequest.Id;
        LError.Error.Code := JRPC_INVALID_REQUEST;
        LError.Error.Message := SJRPCClientBatchRequest;
        ARejections.Add(LError.ToJson);
      finally
        LError.Free;
      end;
    end
    else
      Enqueue(LRequest.Clone);
    Exit;
  end;

  if not (AMessage is TJRPCError) then
    raise EJRPCClientError.CreateFmt(SJRPCClientUnexpected, [AMessage.ClassName]);

  LError := AMessage as TJRPCError;

  if Assigned(ARaw) and Assigned(ARaw.GetValue('method')) then
  begin
    // Not an error the peer sent: a request or a notification of the peer
    // that this side could not read, and the error is the parser's.
    RejectPeerMessage(LError, ARejections);
    Exit;
  end;

  if not LError.Request then
  begin
    // A response this side could not read. The parser marks every error it
    // really read from the peer with Request; one it built itself never has
    // it. Completing the call with it would put words in the peer's mouth.
    FailInvalidResponse(LError, AOrigin);
    Exit;
  end;

  LRawClone := nil;
  if Assigned(ARaw) then
    LRawClone := ARaw.Clone as TJSONObject;

  if not LError.Id.IsNull then
  begin
    CompletePending(LError.Id, LError.Clone, LRawClone, nil);
    Exit;
  end;

  // A null id is what a peer answers when it could not read the id. On the
  // answer stream of a call, it is that call's answer.
  if not AOrigin.IsNull and IsPending(AOrigin) then
  begin
    CompletePending(AOrigin, LError.Clone, LRawClone, nil);
    Exit;
  end;

  // Nothing to correlate it with: reported and dropped.
  try
    LRemote := EJRPCRemoteError.FromError(LError, ARaw);
    try
      Logger.LogWarning(SJRPCClientNullId, [LRemote.Message]);
      ReportError(LRemote);
    finally
      LRemote.Free;
    end;
  finally
    LRawClone.Free;
  end;
end;

procedure TJRPCClient.RejectPeerMessage(AError: TJRPCError; ARejections: TStrings);
begin
  if AError.Request then
  begin
    // A notification: never answered, however malformed. The peer is not
    // waiting for anything, so the rejection is only reported.
    ReportText(Format(SJRPCClientInvalidNotification, [AError.Error.Message.Value]));
    Exit;
  end;

  // A request: the peer is waiting, and the error the parser built is the
  // answer a server owes it (-32600, -32602 ...) with the request's id.
  if Assigned(ARejections) then
    ARejections.Add(AError.ToJson)
  else
    Transmit(AError.ToJson, TJRPCID.Null);
end;

procedure TJRPCClient.FailInvalidResponse(AError: TJRPCError; const AOrigin: TJRPCID);
var
  LText: string;
  LId: TJRPCID;
begin
  LText := Format(SJRPCClientInvalidResponse, [AError.Error.Message.Value]);

  // A response is never answered. The call it was meant for fails - locally,
  // as a client error, not as a remote one.
  LId := AError.Id;
  if LId.IsNull then
    LId := AOrigin;

  if not LId.IsNull and IsPending(LId) then
  begin
    CompletePending(LId, nil, nil, EJRPCClientError.Create(LText));
    Exit;
  end;

  ReportText(LText);
end;

procedure TJRPCClient.RouteNotification(ANotification: TJRPCNotification;
  const AOrigin: TJRPCID);
var
  LCall: IJRPCCall;
  LProc: TJRPCNotificationProc;
begin
  // On the answer stream of a call that asked for its notifications: that
  // handler, right here, before the answer that follows.
  if not AOrigin.IsNull then
  begin
    LProc := nil;
    FLock.Enter;
    try
      if FPending.TryGetValue(KeyOf(AOrigin), LCall) then
        LProc := (LCall as TJRPCPendingCall).OnNotification;
    finally
      FLock.Leave;
    end;

    if Assigned(LProc) then
    begin
      try
        LProc(ANotification);
      except
        on E: Exception do
          ReportError(E);
      end;
      Exit;
    end;
  end;

  Enqueue(ANotification.Clone);
end;

procedure TJRPCClient.Enqueue(AMessage: TJRPCMessage);
var
  LDispatcher: TJRPCDispatcher;
begin
  LDispatcher := nil;
  if FDispatchMode = TJRPCDispatchMode.Queue then
  begin
    FLock.Enter;
    try
      LDispatcher := TJRPCDispatcher(FDispatcher);
    finally
      FLock.Leave;
    end;
  end;

  if Assigned(LDispatcher) then
  begin
    LDispatcher.Push(AMessage);
    Exit;
  end;

  try
    RunMessage(AMessage);
  finally
    AMessage.Free;
  end;
end;

procedure TJRPCClient.RunMessage(AMessage: TJRPCMessage);
begin
  if AMessage is TJRPCNotification then
  begin
    if Assigned(FOnNotification) then
      try
        FOnNotification(AMessage as TJRPCNotification);
      except
        on E: Exception do
          ReportError(E);
      end;
  end
  else if AMessage is TJRPCRequest then
    RunRequest(AMessage as TJRPCRequest);
end;

procedure TJRPCClient.RunRequest(ARequest: TJRPCRequest);
var
  LReply: IJRPCReply;
  LReplyObject: TJRPCReply;
begin
  LReplyObject := TJRPCReply.Create(FReplyChannel, ARequest.Id, FNeonConfig);
  LReply := LReplyObject;
  try
    if Assigned(FOnRequest) then
      FOnRequest(ARequest, LReply)
    else if Assigned(FServer) then
      LReplyObject.Raw(FServer.ProcessRequest(ARequest.ToJson))
    else
      // Nobody is listening: Method Not Found rather than a peer left waiting.
      LReply.Error(JRPC_METHOD_NOT_FOUND, Format(SJRPCMethodNotFound, [ARequest.Method]));
  except
    on E: Exception do
    begin
      // Answered the way TJRPCServer answers a method that raised: an
      // EJRPCException with its own code, anything else as -32603 with the
      // details kept off the wire. Then reported.
      try
        LReplyObject.Fail(E);
      except
        on ESend: Exception do
          ReportError(ESend);
      end;
      ReportError(E);
    end;
  end;
  // Released here: a reply nobody kept and nobody answered answers -32603.
end;

procedure TJRPCClient.AnswerPeer(E: Exception; const AId: TJRPCID);
var
  LError: TJRPCError;
begin
  LError := TJRPCError.CreateFromException(E, AId);
  try
    Transmit(LError.ToJson, TJRPCID.Null);
  finally
    LError.Free;
  end;
end;

{ TJRPCMethodBuilder }

constructor TJRPCMethodBuilder.Create(AMethodClass: TJRPCMethodClass);
begin
  inherited Create;
  FMethod := AMethodClass.Create;
end;

destructor TJRPCMethodBuilder.Destroy;
begin
  FMethod.Free;
  inherited;
end;

{ TJRPCRequestBuilder }

class function TJRPCRequestBuilder.New: IJRPCRequestBuilder;
begin
  Result := TJRPCRequestBuilder.Create;
end;

constructor TJRPCRequestBuilder.Create;
begin
  inherited Create(TJRPCRequest);
end;

function TJRPCRequestBuilder.SetMethod(const AName: string): IJRPCRequestBuilder;
begin
  FMethod.Method := AName;
  Result := Self;
end;

function TJRPCRequestBuilder.AddPositionParam(const AValue: TValue): IJRPCRequestBuilder;
begin
  FMethod.AddPositionParam(AValue);
  Result := Self;
end;

function TJRPCRequestBuilder.AddNamedParam(const AName: string;
  const AValue: TValue): IJRPCRequestBuilder;
begin
  FMethod.AddNamedParam(AName, AValue);
  Result := Self;
end;

function TJRPCRequestBuilder.Build: TJRPCRequest;
begin
  Result := FMethod as TJRPCRequest;
end;

{ TJRPCNotificationBuilder }

class function TJRPCNotificationBuilder.New: IJRPCNotificationBuilder;
begin
  Result := TJRPCNotificationBuilder.Create;
end;

constructor TJRPCNotificationBuilder.Create;
begin
  inherited Create(TJRPCNotification);
end;

function TJRPCNotificationBuilder.SetMethod(const AName: string): IJRPCNotificationBuilder;
begin
  FMethod.Method := AName;
  Result := Self;
end;

function TJRPCNotificationBuilder.AddPositionParam(const AValue: TValue): IJRPCNotificationBuilder;
begin
  FMethod.AddPositionParam(AValue);
  Result := Self;
end;

function TJRPCNotificationBuilder.AddNamedParam(const AName: string;
  const AValue: TValue): IJRPCNotificationBuilder;
begin
  FMethod.AddNamedParam(AName, AValue);
  Result := Self;
end;

function TJRPCNotificationBuilder.Build: TJRPCNotification;
begin
  Result := FMethod as TJRPCNotification;
end;

end.
