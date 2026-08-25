object ClientForm: TClientForm
  Left = 0
  Top = 0
  Caption = 'JRPC TCP Commands - Client'
  ClientHeight = 561
  ClientWidth = 904
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
    Width = 904
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
      Left = 172
      Top = 15
      Width = 25
      Height = 15
      Caption = 'Port:'
    end
    object lblStatus: TLabel
      Left = 472
      Top = 15
      Width = 77
      Height = 15
      Caption = 'not connected'
    end
    object edtHost: TEdit
      Left = 47
      Top = 12
      Width = 111
      Height = 23
      TabOrder = 0
      Text = '127.0.0.1'
    end
    object edtPort: TEdit
      Left = 202
      Top = 12
      Width = 61
      Height = 23
      TabOrder = 1
      Text = '11099'
    end
    object btnConnect: TButton
      Left = 277
      Top = 11
      Width = 85
      Height = 25
      Caption = 'Connect'
      TabOrder = 2
      OnClick = btnConnectClick
    end
    object btnDisconnect: TButton
      Left = 368
      Top = 11
      Width = 90
      Height = 25
      Caption = 'Disconnect'
      TabOrder = 3
      OnClick = btnDisconnectClick
    end
  end
  object pnlLeft: TPanel
    Left = 0
    Top = 45
    Width = 250
    Height = 516
    Align = alLeft
    BevelOuter = bvNone
    TabOrder = 1
    object lblEcho: TLabel
      Left = 12
      Top = 116
      Width = 51
      Height = 15
      Caption = 'echo text:'
    end
    object lblPath: TLabel
      Left = 12
      Top = 200
      Width = 64
      Height = 15
      Caption = 'dir/list path:'
    end
    object lblMask: TLabel
      Left = 12
      Top = 247
      Width = 31
      Height = 15
      Caption = 'mask:'
    end
    object lblRaw: TLabel
      Left = 12
      Top = 331
      Width = 95
      Height = 15
      Caption = 'raw JSON to send:'
    end
    object btnPing: TButton
      Left = 12
      Top = 12
      Width = 110
      Height = 25
      Caption = 'ping'
      TabOrder = 0
      OnClick = btnPingClick
    end
    object btnInfo: TButton
      Left = 12
      Top = 43
      Width = 110
      Height = 25
      Caption = 'sys/info'
      TabOrder = 1
      OnClick = btnInfoClick
    end
    object btnTime: TButton
      Left = 12
      Top = 74
      Width = 110
      Height = 25
      Caption = 'sys/time'
      TabOrder = 2
      OnClick = btnTimeClick
    end
    object edtEcho: TEdit
      Left = 12
      Top = 134
      Width = 222
      Height = 23
      TabOrder = 3
      Text = 'hello JRPC'
    end
    object btnEcho: TButton
      Left = 12
      Top = 163
      Width = 110
      Height = 25
      Caption = 'echo'
      TabOrder = 4
      OnClick = btnEchoClick
    end
    object edtPath: TEdit
      Left = 12
      Top = 218
      Width = 222
      Height = 23
      TabOrder = 5
      Text = 'C:\Temp'
    end
    object edtMask: TEdit
      Left = 12
      Top = 265
      Width = 222
      Height = 23
      TabOrder = 6
      Text = '*.*'
    end
    object btnDir: TButton
      Left = 12
      Top = 294
      Width = 110
      Height = 25
      Caption = 'dir/list'
      TabOrder = 7
      OnClick = btnDirClick
    end
    object edtRaw: TEdit
      Left = 12
      Top = 349
      Width = 222
      Height = 23
      TabOrder = 8
      Text = '{"jsonrpc":"2.0","id":99,"method":"nope"}'
    end
    object btnSendRaw: TButton
      Left = 12
      Top = 378
      Width = 110
      Height = 25
      Caption = 'send raw'
      TabOrder = 9
      OnClick = btnSendRawClick
    end
    object btnClear: TButton
      Left = 12
      Top = 424
      Width = 110
      Height = 25
      Caption = 'Clear log'
      TabOrder = 10
      OnClick = btnClearClick
    end
  end
  object memoLog: TMemo
    Left = 250
    Top = 45
    Width = 654
    Height = 516
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
    Host = '127.0.0.1'
    Port = 8090
    ReadTimeout = 5000
    Left = 800
    Top = 96
  end
end
