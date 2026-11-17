object ClientForm: TClientForm
  Left = 0
  Top = 0
  Caption = 'JRPC Progress over TCP - Client'
  ClientHeight = 480
  ClientWidth = 860
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  TextHeight = 15
  object pnlTop: TPanel
    Left = 0
    Top = 0
    Width = 860
    Height = 45
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 0
    object lblHost: TLabel
      Left = 12
      Top = 15
      Width = 28
      Height = 15
      Caption = 'Host:'
    end
    object lblPort: TLabel
      Left = 176
      Top = 15
      Width = 25
      Height = 15
      Caption = 'Port:'
    end
    object lblStatus: TLabel
      Left = 448
      Top = 15
      Width = 77
      Height = 15
      Caption = 'not connected'
    end
    object edtHost: TEdit
      Left = 46
      Top = 12
      Width = 120
      Height = 23
      TabOrder = 0
      Text = '127.0.0.1'
    end
    object edtPort: TEdit
      Left = 207
      Top = 12
      Width = 61
      Height = 23
      TabOrder = 1
    end
    object btnConnect: TButton
      Left = 280
      Top = 11
      Width = 75
      Height = 25
      Caption = 'Connect'
      TabOrder = 2
      OnClick = btnConnectClick
    end
    object btnDisconnect: TButton
      Left = 361
      Top = 11
      Width = 75
      Height = 25
      Caption = 'Disconnect'
      TabOrder = 3
      OnClick = btnDisconnectClick
    end
  end
  object pnlJob: TPanel
    Left = 0
    Top = 45
    Width = 860
    Height = 80
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 1
    object lblSteps: TLabel
      Left = 12
      Top = 11
      Width = 31
      Height = 15
      Caption = 'Steps:'
    end
    object lblStepTime: TLabel
      Left = 112
      Top = 11
      Width = 82
      Height = 15
      Caption = 'Step time (ms):'
    end
    object lblResult: TLabel
      Left = 386
      Top = 46
      Width = 3
      Height = 15
    end
    object edtSteps: TEdit
      Left = 49
      Top = 8
      Width = 50
      Height = 23
      TabOrder = 0
      Text = '10'
    end
    object edtStepTime: TEdit
      Left = 200
      Top = 8
      Width = 60
      Height = 23
      TabOrder = 1
      Text = '500'
    end
    object btnRun: TButton
      Left = 280
      Top = 7
      Width = 156
      Height = 25
      Caption = 'Run job/run'
      TabOrder = 2
      OnClick = btnRunClick
    end
    object pbJob: TProgressBar
      Left = 12
      Top = 44
      Width = 360
      Height = 20
      TabOrder = 3
    end
  end
  object memoLog: TMemo
    Left = 0
    Top = 125
    Width = 860
    Height = 355
    Align = alClient
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -12
    Font.Name = 'Consolas'
    Font.Style = []
    ParentFont = False
    ReadOnly = True
    ScrollBars = ssBoth
    TabOrder = 2
    WordWrap = False
  end
  object tcpClient: TIdTCPClient
    ConnectTimeout = 5000
    Port = 0
    ReadTimeout = -1
    Left = 744
    Top = 160
  end
  object tmrCall: TTimer
    Enabled = False
    Interval = 50
    OnTimer = tmrCallTimer
    Left = 744
    Top = 216
  end
end
