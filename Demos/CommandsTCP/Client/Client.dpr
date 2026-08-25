program Client;

uses
  Vcl.Forms,
  Client.Form.Main in 'Client.Form.Main.pas' {ClientForm};

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TClientForm, ClientForm);
  Application.Run;
end.
