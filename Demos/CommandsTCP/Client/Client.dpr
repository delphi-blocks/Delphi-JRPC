program Client;

uses
  Vcl.Forms,
  Client.Form.Main in 'Client.Form.Main.pas' {ClientForm},
  Client.Transport in 'Client.Transport.pas',
  // The commands of Server.exe, linked for the in-process transport: the
  // unit registers TBasicApi with the global registry when it initializes.
  Server.Protocol.Api in '..\Server\Server.Protocol.Api.pas';

{$R *.res}

begin
  ReportMemoryLeaksOnShutdown := True;
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TClientForm, ClientForm);
  Application.Run;
end.
