; Phoenicx SSH - Windows installer (Inno Setup 6)
; Built by GitHub Actions: iscc /DAppVersion=1.2.3 /DSourceDir=... /DOutDir=... installer.iss

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef OutName
  #define OutName "PhoenicxSSH-" + AppVersion + "-Windows-Setup"
#endif

[Setup]
AppId={{6C1E7B2A-4F3D-4E8B-9A57-2D1F0E5C8B31}
AppName=Phoenicx SSH
AppVersion={#AppVersion}
AppVerName=Phoenicx SSH {#AppVersion}
AppPublisher=Phoenicx
AppPublisherURL=https://phoenicx.org
AppSupportURL=https://phoenicx.org
DefaultDirName={autopf}\Phoenicx SSH
DefaultGroupName=Phoenicx SSH
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutDir}
OutputBaseFilename={#OutName}
SetupIconFile={#SourcePath}\app_icon.ico
UninstallDisplayIcon={app}\PhoenicxSSH.exe
UninstallDisplayName=Phoenicx SSH
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Phoenicx SSH"; Filename: "{app}\PhoenicxSSH.exe"
Name: "{autodesktop}\Phoenicx SSH"; Filename: "{app}\PhoenicxSSH.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\PhoenicxSSH.exe"; Description: "Start Phoenicx SSH"; Flags: nowait postinstall skipifsilent
