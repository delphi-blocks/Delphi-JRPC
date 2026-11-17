program Server;

uses
  Vcl.Forms,
  Server.Jobs.Api in 'Server.Jobs.Api.pas',
  Server.Form.Main in 'Server.Form.Main.pas' {ServerForm};

begin
  ReportMemoryLeaksOnShutdown := True;
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TServerForm, ServerForm);
  Application.Run;
end.
