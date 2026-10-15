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

!ifndef EXENAME
  !define EXENAME "MayorStreet.exe"
!endif
!ifndef APP
  !define APP "Mayor Street"
!endif
!ifndef APPKEY
  !define APPKEY "MayorStreet"
!endif
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

!define MUI_ICON "../../assets/icon/icon.ico"
!define MUI_UNICON "../../assets/icon/icon.ico"
!define MUI_WELCOMEFINISHPAGE_BITMAP "welcome.bmp"
!define MUI_UNWELCOMEFINISHPAGE_BITMAP "welcome.bmp"
!define MUI_ABORTWARNING

; One click: double-clicking the installer goes straight to the progress bar, installs over any
; earlier version, then starts the game and closes itself. No welcome, folder or finish pages.
!define MUI_INSTFILESPAGE_FINISHHEADER_TEXT "Starting ${APP}"
!insertmacro MUI_PAGE_INSTFILES

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

AutoCloseWindow true

; A running copy locks ${EXENAME} on Windows, so offer to close it before copying the new one.
Function CloseRunningGame
  IfFileExists "$INSTDIR\${EXENAME}" 0 done
  ClearErrors
  FileOpen $0 "$INSTDIR\${EXENAME}" a
  IfErrors locked
  FileClose $0
  Goto done
  locked:
  MessageBox MB_OKCANCEL|MB_ICONQUESTION "${APP} is open. Close it and update now?$\r$\n$\r$\nAnything since the last autosave is lost." /SD IDOK IDOK kill
  Abort
  kill:
  nsExec::Exec 'taskkill /IM ${EXENAME} /F'
  Sleep 1500
  done:
FunctionEnd

Function .onInstSuccess
  Exec '"$INSTDIR\${EXENAME}"'
FunctionEnd

Section "Install"
  SetShellVarContext current
  Call CloseRunningGame
  SetOutPath "$INSTDIR"
  File "/oname=${EXENAME}" "${EXE}"
  WriteUninstaller "$INSTDIR\Uninstall.exe"

  CreateShortcut "$DESKTOP\${APP}.lnk" "$INSTDIR\${EXENAME}" "" "$INSTDIR\${EXENAME}" 0
  CreateDirectory "$SMPROGRAMS\${APP}"
  CreateShortcut "$SMPROGRAMS\${APP}\${APP}.lnk" "$INSTDIR\${EXENAME}" "" "$INSTDIR\${EXENAME}" 0
  CreateShortcut "$SMPROGRAMS\${APP}\Uninstall ${APP}.lnk" "$INSTDIR\Uninstall.exe"

  WriteRegStr HKCU "Software\${APPKEY}" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayName" "${APP}"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINST_KEY}" "Publisher" "${APP}"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayIcon" "$INSTDIR\${EXENAME},0"
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
  Delete "$INSTDIR\${EXENAME}"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  DeleteRegKey HKCU "${UNINST_KEY}"
  DeleteRegKey HKCU "Software\${APPKEY}"
SectionEnd
