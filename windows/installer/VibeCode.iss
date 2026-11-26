; VibeCode Context Menu Windows 安装向导脚本（Inno Setup 6）
; 由 windows\pack.ps1 -InnoSetup 自动调用

#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif
#ifndef MyAppArch
  #define MyAppArch "x64"
#endif
#ifndef MySourceExe
  #define MySourceExe "..\VibeCodeApp\bin\Release\net8.0-windows\win-x64\publish\VibeCode.exe"
#endif
#ifndef MyIconFile
  #define MyIconFile "..\..\ico\vibecode.ico"
#endif
#ifndef MyOutputDir
  #define MyOutputDir "..\..\dist"
#endif
#ifndef MyOutputBaseFilename
  #define MyOutputBaseFilename "VibeCode-v1.0.0-win-x64-Setup"
#endif

[Setup]
AppId={{8E9B35C2-4D7E-4A9F-B9A1-2C6D8E5A7F11}
AppName=VibeCode Context Menu
AppVersion={#MyAppVersion}
AppVerName=VibeCode Context Menu v{#MyAppVersion}
AppPublisher=清风惹尘丶
AppPublisherURL=https://github.com/myucxy/VibeCodeContextMenu
AppSupportURL=https://github.com/myucxy/VibeCodeContextMenu
AppUpdatesURL=https://github.com/myucxy/VibeCodeContextMenu/releases
DefaultDirName={localappdata}\VibeCode
DefaultGroupName=VibeCode
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible arm64
ArchitecturesInstallIn64BitMode=x64compatible arm64
SetupIconFile={#MyIconFile}
UninstallDisplayIcon={app}\VibeCode.exe
OutputDir={#MyOutputDir}
OutputBaseFilename={#MyOutputBaseFilename}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "autostart"; Description: "开机自动启动 VibeCode（静默驻留系统托盘）"; GroupDescription: "附加选项:"

[Files]
Source: "{#MySourceExe}"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\VibeCode"; Filename: "{app}\VibeCode.exe"

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "VibeCode"; ValueData: """{app}\VibeCode.exe"" --tray"; Tasks: autostart; Flags: uninsdeletevalue

[Run]
Filename: "{app}\VibeCode.exe"; Description: "立即启动 VibeCode"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; 卸载前自动清理 HKCU 资源管理器右键菜单
Filename: "{app}\VibeCode.exe"; Parameters: "--uninstall"; Flags: runhidden; RunOnceId: "CleanVibeCodeContextMenu"
