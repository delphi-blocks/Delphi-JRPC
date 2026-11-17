object ClientForm: TClientForm
  Left = 0
  Top = 0
  Caption = 'JRPC TCP Commands - Client'
  ClientHeight = 681
  ClientWidth = 1004
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
    Width = 1004
    Height = 80
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 0
    object lblTransport: TLabel
      Left = 12
      Top = 15
      Width = 56
      Height = 15
      Caption = 'Transport:'
    end
    object lblHost: TLabel
      Left = 12
      Top = 49
      Width = 28
      Height = 15
      Caption = 'Host:'
    end
    object lblPort: TLabel
      Left = 172
      Top = 49
      Width = 25
      Height = 15
      Caption = 'Port:'
    end
    object lblTimeout: TLabel
      Left = 277
      Top = 49
      Width = 74
      Height = 15
      Caption = 'Timeout (ms):'
    end
    object lblStatus: TLabel
      Left = 627
      Top = 49
      Width = 77
      Height = 15
      Caption = 'not connected'
    end
    object cbxTransport: TComboBox
      Left = 80
      Top = 12
      Width = 340
      Height = 23
      Style = csDropDownList
      ItemIndex = 0
      TabOrder = 0
      Text = 'Socket, one line per call (TJRPCFuncTransport)'
      OnChange = cbxTransportChange
      Items.Strings = (
        'Socket, one line per call (TJRPCFuncTransport)'
        'Socket kept open (TJRPCPullTransport)'
        'In process, no server (TJRPCLoopbackTransport)')
    end
    object btnClear: TButton
      Left = 432
      Top = 11
      Width = 85
      Height = 25
      Caption = 'Clear log'
      TabOrder = 1
      OnClick = btnClearClick
    end
    object edtHost: TEdit
      Left = 47
      Top = 46
      Width = 111
      Height = 23
      TabOrder = 2
      Text = '127.0.0.1'
    end
    object edtPort: TEdit
      Left = 202
      Top = 46
      Width = 61
      Height = 23
      TabOrder = 3
      Text = '11099'
    end
    object edtTimeout: TEdit
      Left = 357
      Top = 46
      Width = 61
      Height = 23
      TabOrder = 4
      OnChange = edtTimeoutChange
    end
    object btnConnect: TButton
      Left = 432
      Top = 45
      Width = 85
      Height = 25
      Caption = 'Connect'
      TabOrder = 5
      OnClick = btnConnectClick
    end
    object btnDisconnect: TButton
      Left = 523
      Top = 45
      Width = 90
      Height = 25
      Caption = 'Disconnect'
      TabOrder = 6
      OnClick = btnDisconnectClick
    end
  end
  object pnlLeft: TPanel
    Left = 0
    Top = 80
    Width = 270
    Height = 601
    Align = alLeft
    BevelOuter = bvNone
    TabOrder = 1
    object grpSync: TGroupBox
      Left = 8
      Top = 4
      Width = 254
      Height = 330
      Caption = ' Synchronous: ExecuteAs<T> '
      TabOrder = 0
      object lblEcho: TLabel
        Left = 12
        Top = 120
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
        Top = 246
        Width = 31
        Height = 15
        Caption = 'mask:'
      end
      object btnPing: TButton
        Left = 12
        Top = 24
        Width = 110
        Height = 25
        Caption = 'ping'
        TabOrder = 0
        OnClick = btnPingClick
      end
      object btnInfo: TButton
        Left = 12
        Top = 55
        Width = 110
        Height = 25
        Caption = 'sys/info'
        TabOrder = 1
        OnClick = btnInfoClick
      end
      object btnTime: TButton
        Left = 12
        Top = 86
        Width = 110
        Height = 25
        Caption = 'sys/time'
        TabOrder = 2
        OnClick = btnTimeClick
      end
      object edtEcho: TEdit
        Left = 12
        Top = 138
        Width = 228
        Height = 23
        TabOrder = 3
        Text = 'hello JRPC'
      end
      object btnEcho: TButton
        Left = 12
        Top = 166
        Width = 110
        Height = 25
        Caption = 'echo'
        TabOrder = 4
        OnClick = btnEchoClick
      end
      object edtPath: TEdit
        Left = 12
        Top = 218
        Width = 228
        Height = 23
        TabOrder = 5
        Text = 'C:\Temp'
      end
      object edtMask: TEdit
        Left = 12
        Top = 264
        Width = 228
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
    end
    object grpAsync: TGroupBox
      Left = 8
      Top = 342
      Width = 254
      Height = 62
      Caption = ' Asynchronous: ExecuteAsync<T> '
      TabOrder = 1
      object lblBurst: TLabel
        Left = 12
        Top = 28
        Width = 31
        Height = 15
        Caption = 'calls:'
      end
      object edtBurst: TEdit
        Left = 52
        Top = 25
        Width = 50
        Height = 23
        TabOrder = 0
      end
      object btnBurst: TButton
        Left = 130
        Top = 24
        Width = 110
        Height = 25
        Caption = 'burst'
        TabOrder = 1
        OnClick = btnBurstClick
      end
    end
    object grpMore: TGroupBox
      Left = 8
      Top = 412
      Width = 254
      Height = 62
      Caption = ' ExecuteBatch and Notify '
      TabOrder = 2
      object btnBatch: TButton
        Left = 12
        Top = 24
        Width = 110
        Height = 25
        Caption = 'batch'
        TabOrder = 0
        OnClick = btnBatchClick
      end
      object btnNotify: TButton
        Left = 130
        Top = 24
        Width = 110
        Height = 25
        Caption = 'notify ping'
        TabOrder = 1
        OnClick = btnNotifyClick
      end
    end
    object grpRaw: TGroupBox
      Left = 8
      Top = 482
      Width = 254
      Height = 92
      Caption = ' Raw, past the client (one line per call) '
      TabOrder = 3
      object edtRaw: TEdit
        Left = 12
        Top = 24
        Width = 228
        Height = 23
        TabOrder = 0
        Text = '{"jsonrpc":"2.0","id":99,"method":"nope"}'
      end
      object btnSendRaw: TButton
        Left = 12
        Top = 54
        Width = 110
        Height = 25
        Caption = 'send raw'
        TabOrder = 1
        OnClick = btnSendRawClick
      end
    end
  end
  object memoLog: TMemo
    Left = 270
    Top = 80
    Width = 734
    Height = 601
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
    Port = 11099
    ReadTimeout = -1
    Left = 800
    Top = 136
  end
  object tmrLog: TTimer
    Interval = 100
    OnTimer = tmrLogTimer
    Left = 880
    Top = 136
  end
end
