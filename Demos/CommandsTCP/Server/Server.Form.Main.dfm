object ServerForm: TServerForm
  Left = 0
  Top = 0
  Caption = 'JRPC TCP Commands - Server'
  ClientHeight = 441
  ClientWidth = 724
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  OnShow = FormShow
  TextHeight = 15
  object pnlTop: TPanel
    Left = 0
    Top = 0
    Width = 724
    Height = 45
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 0
    object lblPort: TLabel
      Left = 12
      Top = 15
      Width = 25
      Height = 15
      Caption = 'Port:'
    end
    object lblStatus: TLabel
      Left = 360
      Top = 15
      Width = 43
      Height = 15
      Caption = 'stopped'
    end
    object edtPort: TEdit
      Left = 43
      Top = 12
      Width = 61
      Height = 23
      TabOrder = 0
      Text = '11099'
    end
    object btnStart: TButton
      Left = 115
      Top = 11
      Width = 75
      Height = 25
      Caption = 'Start'
      TabOrder = 1
      OnClick = btnStartClick
    end
    object btnStop: TButton
      Left = 196
      Top = 11
      Width = 75
      Height = 25
      Caption = 'Stop'
      TabOrder = 2
      OnClick = btnStopClick
    end
    object btnClear: TButton
      Left = 277
      Top = 11
      Width = 75
      Height = 25
      Caption = 'Clear log'
      TabOrder = 3
      OnClick = btnClearClick
    end
  end
  object memoLog: TMemo
    Left = 0
    Top = 45
    Width = 724
    Height = 396
    Align = alClient
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -12
    Font.Name = 'Consolas'
    Font.Style = []
    ParentFont = False
    ReadOnly = True
    ScrollBars = ssBoth
    TabOrder = 1
    WordWrap = False
  end
  object tcpServer: TIdTCPServer
    Bindings = <>
    DefaultPort = 11099
    OnConnect = tcpServerConnect
    OnDisconnect = tcpServerDisconnect
    OnExecute = tcpServerExecute
    Left = 624
    Top = 80
  end
end
