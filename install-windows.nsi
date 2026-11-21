; Graphical installer for qdm12/ddns-updater on Windows.
;
; Build on Linux:  nix-shell -p nsis --run 'makensis install-windows.nsi'
; Build on Windows: right-click install-windows.nsi and choose "Compile".
;
; This wizard only collects settings and extracts the PowerShell installer.
; install-windows.ps1 still performs the actual install and self-elevates via
; UAC when it needs to manage the Windows service. Running NSIS unelevated is
; important: it keeps the original user's profile and registry hive intact.

!define APP_NAME        "DDNS Updater"
!define APP_VERSION     "1.2.0"
!define APP_PUBLISHER   "qdm12"
!define SCRIPT_NAME     "DDNS-Updater-Install.ps1"
!define INSTALLER_FILE  "DDNS-Updater-Setup-${APP_VERSION}.exe"

!include "MUI2.nsh"
!include "nsDialogs.nsh"

Name "${APP_NAME}"
OutFile "${INSTALLER_FILE}"
InstallDir "$LOCALAPPDATA\Programs\DDNS-Updater"
RequestExecutionLevel user
SetCompressor /SOLID lzma

!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_TITLE "Installation complete"
!define MUI_FINISHPAGE_TEXT "DDNS Updater is installed. Use the Start menu shortcuts to update, run or uninstall it."

!insertmacro MUI_PAGE_WELCOME
Page custom ConfigPageShow ConfigPageLeave
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_LANGUAGE "English"

Var ConfigDialog
Var DomainText
Var TokenText
Var ServiceCheckbox
Var PathCheckbox
Var DomainValue
Var TokenValue
Var ServiceFlag
Var PathFlag
Var ScriptExitCode
Var TempValue

Function ConfigPageShow
    nsDialogs::Create 1018
    Pop $ConfigDialog
    ${If} $ConfigDialog == error
        Abort
    ${EndIf}

    ${NSD_CreateLabel} 0 0 100% 14u "DuckDNS domain (for example myhome - .duckdns.org is added automatically):"
    Pop $TempValue
    ${NSD_CreateText} 0 17u 100% 13u ""
    Pop $DomainText

    ${NSD_CreateLabel} 0 42u 100% 14u "DuckDNS token - the value is shown so you can check that the paste worked:"
    Pop $TempValue
    ${NSD_CreateText} 0 59u 100% 13u ""
    Pop $TokenText

    ${NSD_CreateCheckbox} 0 88u 100% 12u "Install as a Windows service that starts at boot (recommended)"
    Pop $ServiceCheckbox
    ${NSD_SetState} $ServiceCheckbox 1

    ${NSD_CreateCheckbox} 0 105u 100% 12u "Add the install directory to my user PATH"
    Pop $PathCheckbox
    ${NSD_SetState} $PathCheckbox 1

    nsDialogs::Show
FunctionEnd

Function ConfigPageLeave
    ${NSD_GetText} $DomainText $DomainValue
    ${NSD_GetText} $TokenText $TokenValue

    ${If} $DomainValue == ""
        MessageBox MB_ICONEXCLAMATION "Please enter your DuckDNS domain."
        Abort
    ${EndIf}

    ; Add the top-level domain when the user entered only the subdomain. This
    ; mirrors Read-DuckDnsDomain in install-windows.ps1, and showing the result
    ; in the field lets the user see exactly what will be written to config.json.
    ; Drop trailing dots first so "myhome." does not become "myhome..duckdns.org".
    strip_trailing_dots:
    StrLen $0 $DomainValue
    ${If} $0 > 0
        IntOp $3 $0 - 1
        StrCpy $2 $DomainValue 1 $3
        ${If} $2 == "."
            StrCpy $DomainValue $DomainValue $3
            Goto strip_trailing_dots
        ${EndIf}
    ${EndIf}
    ${If} $DomainValue == ""
        MessageBox MB_ICONEXCLAMATION "Please enter your DuckDNS domain."
        Abort
    ${EndIf}

    StrLen $0 $DomainValue
    ${If} $0 > 11
        StrCpy $1 $DomainValue 12 -12
    ${Else}
        StrCpy $1 ""
    ${EndIf}
    ${If} $1 != ".duckdns.org"
        StrCpy $DomainValue "$DomainValue.duckdns.org"
    ${EndIf}
    ${NSD_SetText} $DomainText $DomainValue

    ; The domain must now be a subdomain of duckdns.org (12 characters).
    StrLen $0 $DomainValue
    ${If} $0 < 13
        MessageBox MB_ICONEXCLAMATION "The domain must end with .duckdns.org (for example myhome.duckdns.org)."
        Abort
    ${EndIf}
    StrCpy $1 $DomainValue 12 -12
    ${If} $1 != ".duckdns.org"
        MessageBox MB_ICONEXCLAMATION "The domain must end with .duckdns.org (for example myhome.duckdns.org)."
        Abort
    ${EndIf}

    ; A DuckDNS token is a 36-character UUID. Reject a failed paste such as a
    ; single Ctrl+V character here, before starting the installer.
    StrLen $0 $TokenValue
    ${If} $0 != 36
        MessageBox MB_ICONEXCLAMATION "The DuckDNS token must be a 36-character UUID, for example xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx. Check that the paste completed."
        Abort
    ${EndIf}
    StrCpy $1 $TokenValue 1 8
    StrCpy $2 $TokenValue 1 13
    StrCpy $3 $TokenValue 1 18
    StrCpy $4 $TokenValue 1 23
    ${If} $1 != "-"
    ${OrIf} $2 != "-"
    ${OrIf} $3 != "-"
    ${OrIf} $4 != "-"
        MessageBox MB_ICONEXCLAMATION "The DuckDNS token must be a 36-character UUID, for example xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx. Check that the paste completed."
        Abort
    ${EndIf}

    ${NSD_GetState} $ServiceCheckbox $0
    ${If} $0 == 1
        StrCpy $ServiceFlag ""
    ${Else}
        StrCpy $ServiceFlag "-NoService"
    ${EndIf}

    ${NSD_GetState} $PathCheckbox $0
    ${If} $0 == 1
        StrCpy $PathFlag ""
    ${Else}
        StrCpy $PathFlag "-NoPath"
    ${EndIf}
FunctionEnd

Section "Install DDNS Updater"
    SetOutPath "$INSTDIR"
    File /oname=${SCRIPT_NAME} "install-windows.ps1"

    ; Run unelevated so the PowerShell script can resolve the real user's
    ; profile before it requests elevation for the service. ExecWait lets us
    ; surface a failed install instead of showing a misleading "complete" page.
    ExecWait '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\${SCRIPT_NAME}" -Action Install -InstallDir "$INSTDIR" -Domain "$DomainValue" -Token "$TokenValue" $ServiceFlag $PathFlag' $ScriptExitCode
    ${If} $ScriptExitCode != 0
        MessageBox MB_ICONSTOP "DDNS Updater installation failed (exit code $ScriptExitCode). See the PowerShell window for details."
        Abort
    ${EndIf}
SectionEnd
