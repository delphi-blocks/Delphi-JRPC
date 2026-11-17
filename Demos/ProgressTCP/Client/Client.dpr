program Client;

uses
  Vcl.Forms,
  // The line-framed persistent TCP transport of the CommandsTCP demo.
  Client.Transport in '..\..\CommandsTCP\Client\Client.Transport.pas',
  Client.Form.Main in 'Client.Form.Main.pas' {ClientForm};

begin
  ReportMemoryLeaksOnShutdown := True;
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TClientForm, ClientForm);
  Application.Run;
end.
