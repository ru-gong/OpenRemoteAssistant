; SPDX-License-Identifier: GPL-3.0-only
; Inno Setup script for OpenRemoteAssistant Windows port.

#define MyAppName "遥控器助手"
#define MyAppNameEn "OpenRemoteAssistant"
#define MyAppVersion "0.3.0"
#define MyAppPublisher "OpenRemoteAssistant contributors"
#define MyAppURL "https://github.com/ru-gong/OpenRemoteAssistant"
#define MyAppExeName "OpenRemoteAssistantWin.exe"

[Setup]
AppId={{7A3C1D9E-4F2B-4E8A-9C6D-1B5A0E8F3D42}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
VersionInfoVersion={#MyAppVersion}.18
AppVerName={#MyAppName} {#MyAppVersion}（Windows 版）
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
DefaultDirName={localappdata}\{#MyAppNameEn}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
LicenseFile=..\dist\LICENSE
OutputDir=installer
OutputBaseFilename=OpenRemoteAssistant-{#MyAppVersion}-setup
SetupIconFile=icon.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
UninstallDisplayIcon={app}\{#MyAppExeName}
; Chinese + English UI
ShowLanguageDialog=no

[Languages]
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
chinesesimplified.LaunchApp=安装完成后运行 %1
english.LaunchApp=Run %1 after installation

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "autostart"; Description: "开机自动启动"; GroupDescription: "其他任务："; Flags: unchecked

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "OpenRemoteAssistant"; ValueData: """{app}\{#MyAppExeName}"""; Flags: uninsdeletevalue; Tasks: autostart

[Files]
Source: "..\dist\OpenRemoteAssistantWin.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\dist\wwwroot\*"; DestDir: "{app}\wwwroot"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\dist\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\dist\COPYRIGHT"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\dist\THIRD_PARTY_NOTICES.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\dist\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\dist\licenses\*"; DestDir: "{app}\licenses"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\dist\docs\*"; DestDir: "{app}\docs"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\卸载 {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchApp,{#MyAppName}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Keep user data (bindings, recordings) — only remove app files.
Type: filesandordirs; Name: "{app}\wwwroot"
