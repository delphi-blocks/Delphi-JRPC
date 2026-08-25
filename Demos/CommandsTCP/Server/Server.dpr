program Server;

uses
  Vcl.Forms,
  Server.Protocol.Api in 'Server.Protocol.Api.pas',
  Server.Form.Main in 'Server.Form.Main.pas' {ServerForm};

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TServerForm, ServerForm);
  Application.Run;
end.
