; Mayor Street installer: installs for the current user only (no admin rights), adds Desktop and
; Start menu shortcuts, an entry in Apps & features and an uninstaller. Saved games under
; %APPDATA%\Godot are left alone on uninstall.
; Build with tools/installer/build.sh, which passes EXE, VERSION, SIZE_KB and OUTFILE.

; 64-bit like the game itself, so the 64-bit Wine on Linux can test the exact installer.
Target amd64-unicode
SetCompressor /SOLID lzma
SetCompressorDictSize 64

!ifndef EXE
  !error "Pass -DEXE=path/to/MayorStreet.exe (tools/installer/build.sh does)"
!endif
!ifndef VERSION
  !define VERSION "0.0.0"
!endif
!ifndef SIZE_KB
  !define SIZE_KB 0
!endif
!ifndef OUTFILE
  !define OUTFILE "MayorStreet-Setup.exe"
!endif

!define APP "Mayor Street"
!define APPKEY "MayorStreet"
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPKEY}"

Name "${APP}"
OutFile "${OUTFILE}"
RequestExecutionLevel user
InstallDir "$LOCALAPPDATA\Programs\${APPKEY}"
InstallDirRegKey HKCU "Software\${APPKEY}" "InstallDir"
BrandingText "${APP} ${VERSION}"
ManifestDPIAware true

VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "${APP}"
VIAddVersionKey "CompanyName" "${APP}"
VIAddVersionKey "FileDescription" "${APP} installer"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" ""

!include "MUI2.nsh"
!include "WinMessages.nsh"

!define MUI_ICON "../../assets/icon/icon.ico"
!define MUI_UNICON "../../assets/icon/icon.ico"
!define MUI_WELCOMEFINISHPAGE_BITMAP "welcome.bmp"
!define MUI_UNWELCOMEFINISHPAGE_BITMAP "welcome.bmp"
!define MUI_ABORTWARNING

!define MUI_WELCOMEPAGE_TITLE "${APP}"
!define MUI_WELCOMEPAGE_TEXT "Build a city as its mayor, then drop to street level to walk and drive through it.$\r$\n$\r$\nThis installs the game for you only, with no admin rights needed, and puts a shortcut on your desktop and in the Start menu.$\r$\n$\r$\nClick Install to start."
!define MUI_FINISHPAGE_TITLE "${APP} is installed"
!define MUI_FINISHPAGE_TEXT "Open it any time from the ${APP} icon on your desktop."
!define MUI_FINISHPAGE_RUN "$INSTDIR\MayorStreet.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Play ${APP} now"

; The welcome page's button installs straight away: no folder or options pages.
!define MUI_PAGE_CUSTOMFUNCTION_SHOW WelcomeShow
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

Function WelcomeShow
  GetDlgItem $0 $HWNDPARENT 1
  SendMessage $0 ${WM_SETTEXT} 0 "STR:&Install"
FunctionEnd

Section "Install"
  SetShellVarContext current
  SetOutPath "$INSTDIR"
  File "/oname=MayorStreet.exe" "${EXE}"
  WriteUninstaller "$INSTDIR\Uninstall.exe"

  CreateShortcut "$DESKTOP\${APP}.lnk" "$INSTDIR\MayorStreet.exe" "" "$INSTDIR\MayorStreet.exe" 0
  CreateDirectory "$SMPROGRAMS\${APP}"
  CreateShortcut "$SMPROGRAMS\${APP}\${APP}.lnk" "$INSTDIR\MayorStreet.exe" "" "$INSTDIR\MayorStreet.exe" 0
  CreateShortcut "$SMPROGRAMS\${APP}\Uninstall ${APP}.lnk" "$INSTDIR\Uninstall.exe"

  WriteRegStr HKCU "Software\${APPKEY}" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayName" "${APP}"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINST_KEY}" "Publisher" "${APP}"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayIcon" "$INSTDIR\MayorStreet.exe,0"
  WriteRegStr HKCU "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINST_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "${UNINST_KEY}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKCU "${UNINST_KEY}" "EstimatedSize" ${SIZE_KB}
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  SetShellVarContext current
  Delete "$DESKTOP\${APP}.lnk"
  Delete "$SMPROGRAMS\${APP}\${APP}.lnk"
  Delete "$SMPROGRAMS\${APP}\Uninstall ${APP}.lnk"
  RMDir "$SMPROGRAMS\${APP}"
  Delete "$INSTDIR\MayorStreet.exe"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  DeleteRegKey HKCU "${UNINST_KEY}"
  DeleteRegKey HKCU "Software\${APPKEY}"
SectionEnd
