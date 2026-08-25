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
unit JRPCExample.Api;

interface

uses
  System.Classes, System.SysUtils, System.Generics.Collections,

  Neon.Core.Persistence,

  JRPC.Classes,
  JRPC.Core;

type
  /// <summary>Priority of a note, serialized by name as a JSON string.</summary>
  TNotePriority = (Low, Normal, High, Urgent);

  /// <summary>A note: a plain object used both as a parameter and as a result.</summary>
  TNote = class
  private
    FId: Integer;
    FTitle: string;
    FBody: string;
    FTags: TArray<string>;
    FPriority: TNotePriority;
  public
    function Clone: TNote;

    property Id: Integer read FId write FId;
    property Title: string read FTitle write FTitle;
    property Body: string read FBody write FBody;
    property Tags: TArray<string> read FTags write FTags;
    property Priority: TNotePriority read FPriority write FPriority;
  end;

  /// <summary>A profile object, serialized with camelCase keys (see registration).</summary>
  TUserProfile = class
  private
    FName: string;
    FEmail: string;
    FMemberSince: string;
  public
    property Name: string read FName write FName;
    property Email: string read FEmail write FEmail;
    property MemberSince: string read FMemberSince write FMemberSince;
  end;

  /// <summary>
  ///   Notes CRUD API over an in-memory store. The store lives at class level
  ///   because the server creates a fresh API instance per request; methods
  ///   return clones of the stored notes because the request garbage collector
  ///   owns every object result.
  /// </summary>
  [JRPCPath('notes')]
  TNotesApi = class
  private
    class var FStore: TObjectList<TNote>;
    class var FNextId: Integer;
    class function FindNote(const AId: Integer): TNote; static;
  public
    class constructor Create;
    /// <summary>Frees the in-memory store. Called by the demo before exiting
    /// (class destructors run too late for the shutdown leak check).</summary>
    class procedure Shutdown; static;

    [JRPCMethod('create')]
    function CreateNote([JRPCParams] const note: TNote): TNote;

    [JRPCMethod('get')]
    function GetNote([JRPCParam('id')] const id: Integer): TNote;

    [JRPCMethod('list')]
    function ListNotes: TArray<TNote>;

    [JRPCMethod('delete')]
    function DeleteNote([JRPCParam('id')] const id: Integer): string;

    [JRPCMethod('count')]
    function CountNotes: Integer;

    [JRPCMethod('ping')]
    function Ping: string;
  end;

  /// <summary>
  ///   Custom separator section: methods are addressed as "utils.uppercase"
  ///   instead of the default "utils/uppercase".
  /// </summary>
  [JRPCPath('utils', 'separator=.')]
  TUtilsApi = class
  public
    [JRPCMethod('uppercase')]
    function ToUpper([JRPCParam('text')] const text: string): string;

    [JRPCMethod('timestamp')]
    function Timestamp: string;
  end;

  /// <summary>Profile API, registered with a CamelCase Neon configuration.</summary>
  [JRPCPath('profile')]
  TProfileApi = class
  public
    [JRPCMethod('get')]
    function GetProfile: TUserProfile;
  end;

  /// <summary>
  ///   Context injection: [Context]-annotated fields receive the request being
  ///   processed and the garbage collector.
  /// </summary>
  [JRPCPath('session')]
  TSessionApi = class
  private
    [Context] Request: TJRPCRequest;
    [Context] FGC: IGarbageCollector;
  public
    [JRPCMethod('whoami')]
    function WhoAmI: string;
  end;

implementation

{ TNote }

function TNote.Clone: TNote;
begin
  Result := TNote.Create;
  Result.Id := FId;
  Result.Title := FTitle;
  Result.Body := FBody;
  Result.Tags := Copy(FTags);
  Result.Priority := FPriority;
end;

{ TNotesApi }

class constructor TNotesApi.Create;
begin
  FStore := TObjectList<TNote>.Create(True);
  FNextId := 0;
end;

class procedure TNotesApi.Shutdown;
begin
  FreeAndNil(FStore);
end;

function TNotesApi.CreateNote(const note: TNote): TNote;
var
  LStored: TNote;
begin
  Inc(FNextId);
  note.Id := FNextId;
  // The store keeps its own copy: the deserialized param object and the
  // returned clone are both owned by the request garbage collector.
  LStored := note.Clone;
  FStore.Add(LStored);
  Result := LStored.Clone;
end;

function TNotesApi.DeleteNote(const id: Integer): string;
var
  LNote: TNote;
begin
  for LNote in FStore do
    if LNote.Id = id then
    begin
      FStore.Remove(LNote);
      Exit(Format('Note [%d] deleted', [id]));
    end;
  raise EJRPCException.CreateFmt('Note [%d] not found', [id]);
end;

class function TNotesApi.FindNote(const AId: Integer): TNote;
var
  LNote: TNote;
begin
  Result := nil;
  for LNote in FStore do
    if LNote.Id = AId then
      Exit(LNote);
end;

function TNotesApi.GetNote(const id: Integer): TNote;
begin
  Result := FindNote(id);
  if not Assigned(Result) then
    raise EJRPCException.CreateFmt('Note [%d] not found', [id]);
  // Return a clone: the store keeps the original, the garbage collector owns
  // the result.
  Result := Result.Clone;
end;

function TNotesApi.ListNotes: TArray<TNote>;
var
  LNote: TNote;
begin
  Result := nil;
  for LNote in FStore do
  begin
    SetLength(Result, Length(Result) + 1);
    Result[Length(Result) - 1] := LNote.Clone;
  end;
end;

function TNotesApi.Ping: string;
begin
  Result := 'pong';
end;

function TNotesApi.CountNotes: Integer;
begin
  Result := FStore.Count;
end;

{ TUtilsApi }

function TUtilsApi.ToUpper(const text: string): string;
begin
  Result := UpperCase(text);
end;

function TUtilsApi.Timestamp: string;
begin
  Result := FormatDateTime('yyyy-mm-dd hh:nn:ss', Now);
end;

{ TProfileApi }

function TProfileApi.GetProfile: TUserProfile;
begin
  Result := TUserProfile.Create;
  Result.Name := 'Ada Lovelace';
  Result.Email := 'ada@example.com';
  Result.MemberSince := '2024-01-15';
end;

{ TSessionApi }

function TSessionApi.WhoAmI: string;
begin
  // [Context] Request is injected with the request being processed.
  Result := Format('handling method "%s" (id=%s)', [Request.Method, Request.Id.AsString]);

  // [Context] FGC is the request garbage collector: request-scoped objects
  // registered with it are freed automatically when the request completes.
  var LScoped := TStringList.Create;
  FGC.Add(LScoped);
  LScoped.Add('freed with the request');
end;

initialization
  // TNotesApi is registered with a CamelCase Neon configuration: parameters
  // and results use camelCase JSON keys, like a typical HTTP API.
  TJRPCRegistry.Instance.RegisterClass(TNotesApi, TNeonConfiguration.Camel);
  TJRPCRegistry.Instance.RegisterClass(TUtilsApi);
  TJRPCRegistry.Instance.RegisterClass(TProfileApi, TNeonConfiguration.Camel);
  TJRPCRegistry.Instance.RegisterClass(TSessionApi);

end.
