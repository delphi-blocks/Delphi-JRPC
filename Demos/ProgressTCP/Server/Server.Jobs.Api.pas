/// <summary>
///   The command the server exposes: a long job that reports its progress
///   while it runs.
/// </summary>
unit Server.Jobs.Api;

interface

uses
  System.SysUtils, System.Classes, System.Diagnostics,

  Neon.Core.Persistence,

  JRPC.Classes,
  JRPC.Core,
  JRPC.Server;

type
  TJobApi = class
  private
    /// <summary>
    ///   Put here by TJRPCServer for every request, because the transport
    ///   passed ProcessRequest a way to write to the client.
    /// </summary>
    [Context] FNotifier: TJRPCNotifier;
  public
    /// <summary>
    ///   Runs a job of ASteps steps, AStepTime milliseconds each. After every
    ///   step it sends a job/progress notification; the answer, with a
    ///   summary, comes once the last step is done.
    /// </summary>
    [JRPCMethod('job/run')]
    function Run([JRPCParam('steps')] ASteps: Integer;
      [JRPCParam('stepTime')] AStepTime: Integer): string;
  end;

implementation

{ TJobApi }

function TJobApi.Run(ASteps: Integer; AStepTime: Integer): string;
var
  LWatch: TStopwatch;
  LStep: Integer;
  LProgress: TJRPCNotification;
begin
  if (ASteps < 1) or (ASteps > 100) then
    raise EJRPCInvalidParamsError.Create('steps must be between 1 and 100');
  if (AStepTime < 0) or (AStepTime > 10000) then
    raise EJRPCInvalidParamsError.Create('stepTime must be between 0 and 10000 ms');

  LWatch := TStopwatch.StartNew;
  for LStep := 1 to ASteps do
  begin
    // The work of one step.
    Sleep(AStepTime);

    // Out now, while the call is still running: the client sees it long
    // before the answer below.
    LProgress := TJRPCNotification.Create;
    try
      LProgress.Method := 'job/progress';
      LProgress.AddNamedParam('step', LStep);
      LProgress.AddNamedParam('of', ASteps);
      FNotifier.Send(LProgress);
    finally
      LProgress.Free;
    end;
  end;

  // The answer: TJRPCServer serializes it and the transport writes it last.
  Result := Format('%d steps done in %d ms', [ASteps, LWatch.ElapsedMilliseconds]);
end;

initialization
  TJRPCRegistry.Instance.RegisterClass(TJobApi, TNeonConfiguration.Camel);

end.
