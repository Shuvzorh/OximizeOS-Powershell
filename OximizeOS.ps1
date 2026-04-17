#Requires -Version 5.1
<#
.SYNOPSIS
    Oximize OS — Windows 11 ISO Debloater
    A single-file, self-contained PowerShell GUI for debloating Windows ISOs.
.DESCRIPTION
    Mounts a Windows ISO, removes bloatware, applies privacy/telemetry registry
    tweaks, injects unattend.xml, and rebuilds a clean bootable ISO — all with
    a responsive dark-themed WinForms GUI and real-time log output.
#>

#region ── Auto-Elevation ──────────────────────────────────────────────────────
function Get-CurrentPowerShellHostPath {
    try {
        $proc = Get-Process -Id $PID -ErrorAction Stop
        if ($proc.ProcessName -match '^(pwsh|powershell)$' -and $proc.Path) {
            return $proc.Path
        }
    }
    catch {}

    if ($PSVersionTable.PSVersion.Major -ge 6) { return 'pwsh.exe' }
    return 'powershell.exe'
}

# Re-launch in a WinForms-safe host state if needed
$scriptPath = $MyInvocation.MyCommand.Path
if (-not $scriptPath) { $scriptPath = $PSCommandPath }
if ($scriptPath) {
    try { Unblock-File -LiteralPath $scriptPath -ErrorAction SilentlyContinue } catch {}
}
$currentThreadIsSta = ([Threading.Thread]::CurrentThread.ApartmentState -eq [Threading.ApartmentState]::STA)
$isAdministrator = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $currentThreadIsSta -or -not $isAdministrator) {
    $hostPath = Get-CurrentPowerShellHostPath
    $startArgs = @{
        FilePath     = $hostPath
        ArgumentList = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-STA',
            '-File', "`"$scriptPath`""
        )
    }
    if (-not $isAdministrator) {
        $startArgs.Verb = 'RunAs'
    }
    Start-Process @startArgs
    exit
}
#endregion

#region ── Assemblies ─────────────────────────────────────────────────────────
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
# Enable DPI Awareness to prevent blurry text on high-DPI displays
if (-not ('Win32Dpi' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Win32Dpi {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
}
'@
}
[void][Win32Dpi]::SetProcessDPIAware()

if (-not ('Win32Window' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Win32Window {
    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    public static extern int SetWindowTheme(IntPtr hWnd, string pszSubAppName, string pszSubIdList);
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
    public const int GWL_EXSTYLE          = -20;
    public const int WS_EX_COMPOSITED     = 0x02000000;
    public const int WM_SETREDRAW         = 0x000B;
    public const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
}
'@
}

function Invoke-FreezeRedraw {
    param([System.Windows.Forms.Control]$Control)
    if ($null -eq $Control -or -not $Control.IsHandleCreated) { return }
    try { [void][Win32Window]::SendMessage($Control.Handle, [Win32Window]::WM_SETREDRAW, [IntPtr]::Zero, [IntPtr]::Zero) } catch {}
}
function Invoke-ThawRedraw {
    param([System.Windows.Forms.Control]$Control)
    if ($null -eq $Control -or -not $Control.IsHandleCreated) { return }
    try { [void][Win32Window]::SendMessage($Control.Handle, [Win32Window]::WM_SETREDRAW, [IntPtr]1, [IntPtr]::Zero) } catch {}
    try { $Control.Invalidate($true); $Control.Update() } catch {}
}
function Set-DarkScrollbar {
    param([System.Windows.Forms.Control]$Control, [switch]$Recursive)
    if ($null -eq $Control) { return }
    # Only apply to ScrollableControls (panels/flow panels that can have scrollbars)
    if ($Control -is [System.Windows.Forms.ScrollableControl]) {
        try {
            if ($Control.IsHandleCreated) {
                [void][Win32Window]::SetWindowTheme($Control.Handle, 'DarkMode_Explorer', $null)
            } else {
                $Control.Add_HandleCreated({ [void][Win32Window]::SetWindowTheme($this.Handle, 'DarkMode_Explorer', $null) })
            }
        } catch {}
    }
    if ($Recursive) {
        foreach ($child in @($Control.Controls)) { Set-DarkScrollbar -Control $child -Recursive }
    }
}
#endregion

#region ── P/Invoke: SetThreadExecutionState ──────────────────────────────────
# Prevents sleep/screensaver during long ISO processing
if (-not ('PowerMgmt' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PowerMgmt {
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);
    public const uint ES_CONTINUOUS             = 0x80000000;
    public const uint ES_SYSTEM_REQUIRED        = 0x00000001;
    public const uint ES_AWAYMODE_REQUIRED      = 0x00000040;
}
'@
}
function Invoke-KeepAwake { [void][PowerMgmt]::SetThreadExecutionState([PowerMgmt]::ES_CONTINUOUS -bor [PowerMgmt]::ES_SYSTEM_REQUIRED -bor [PowerMgmt]::ES_AWAYMODE_REQUIRED) }
function Invoke-RestoreSleep { [void][PowerMgmt]::SetThreadExecutionState([PowerMgmt]::ES_CONTINUOUS) }

if (-not ('NativeIcons' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class NativeIcons {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr hIcon);
}
'@
}

if (-not ('MuiStringResolver' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class MuiStringResolver {
    [DllImport("shlwapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int SHLoadIndirectString(string pszSource, StringBuilder pszOutBuf, int cchOutBuf, IntPtr ppvReserved);
}
'@
}

function Resolve-MuiString {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $trimmed = $Value.Trim()
    if (-not $trimmed.StartsWith('@')) { return $trimmed }

    try {
        $sb = New-Object System.Text.StringBuilder 2048
        $hr = [MuiStringResolver]::SHLoadIndirectString($trimmed, $sb, $sb.Capacity, [IntPtr]::Zero)
        if ($hr -eq 0 -and $sb.Length -gt 0) {
            return $sb.ToString().Trim()
        }
    }
    catch {}

    if ($trimmed -match ';\s*(.+)$') {
        return [string]$Matches[1]
    }

    return $trimmed.TrimStart('@')
}

function Get-ServiceStartModeText {
    param([AllowNull()][object]$StartValue)

    if ($null -eq $StartValue) { return '' }

    $raw = [string]$StartValue
    switch -Regex ($raw.Trim()) {
        '^(?i)Auto(matic)?$' { return 'Automatic' }
        '^(?i)Manual|Demand$' { return 'Manual' }
        '^(?i)Disabled$' { return 'Disabled' }
        '^(?i)Boot$' { return 'Boot' }
        '^(?i)System$' { return 'System' }
        '^0$' { return 'Boot' }
        '^1$' { return 'System' }
        '^2$' { return 'Automatic' }
        '^3$' { return 'Manual' }
        '^4$' { return 'Disabled' }
        default { return $raw }
    }
}

function Get-ServiceTypeText {
    param([AllowNull()][object]$TypeValue)

    if ($null -eq $TypeValue) { return '' }

    $raw = [string]$TypeValue
    $n = 0
    if (-not [int]::TryParse($raw, [ref]$n)) {
        return $raw
    }

    $types = New-Object System.Collections.Generic.List[string]
    if (($n -band 0x1) -ne 0) { $types.Add('Kernel Driver') }
    if (($n -band 0x2) -ne 0) { $types.Add('File System Driver') }
    if (($n -band 0x4) -ne 0) { $types.Add('Adapter') }
    if (($n -band 0x8) -ne 0) { $types.Add('Recognizer Driver') }
    if (($n -band 0x10) -ne 0) { $types.Add('Win32 Own Process') }
    if (($n -band 0x20) -ne 0) { $types.Add('Win32 Share Process') }
    if (($n -band 0x100) -ne 0) { $types.Add('Interactive Process') }

    if ($types.Count -eq 0) { return $raw }
    return ($types -join ', ')
}
#endregion

#region ── Shared State Hashtable ─────────────────────────────────────────────
$sync = [hashtable]::Synchronized(@{
        Form                     = $null
        LogBox                   = $null
        ProgressBar              = $null
        StartButton              = $null
        CancelButton             = $null
        'Source ISO'             = ''
        'Output Folder'          = ''
        ScratchDir               = ''
        CustomUnattendXml        = ''
        CustomRegFiles           = @()
        CustomBatFiles           = @()
        DriverSourceDir          = ''
        DriverExtractDir         = ''
        InjectDriversInstallWim  = $true
        DriverInjectRecurse      = $true
        SecurityPreset           = 'Balanced'
        MountDir                 = ''
        WimMountDir              = ''
        SelectedIndex            = 1
        ProcessRunning           = $false
        CancelRequested          = $false
        BuildPollTimer           = $null
        CheckedAppx              = @()
        AppxSelectionExpansions  = @{}
        CheckedFeatures          = @()
        CheckedTasks             = @()
        CheckedServices          = @()
        CheckedExtraSecurity     = @()
        CheckedAdvancedOptions   = @()
        CustomTasks              = @()
        CustomTaskBoxes          = $null
        CustomTaskRows           = $null
        TasksFlow                = $null
        TasksSelectors           = $null
        TaskDetails              = $null
        TaskDetailsBase          = $null
        TaskDetailBox            = $null
        TasksBaseDef             = @()
        LastSelectedTaskCombo    = $null
        BuildVersion             = $null
        WimPath                  = ''
        IsMounted                = $false
        IsWimMounted             = $false
        PowerShellInstance       = $null
        SuppressUiChangeLog      = $false
        ExtraSecurityBoxes       = $null
        ExtraSecurityDef         = @()
        ExtraSecurityLabelById   = @{}
        AdvancedOptionsBoxes     = $null
        AdvancedOptionsDef       = @()
        AdvancedOptionsLabelById = @{}
        TaskDefaultStateById     = @{}
        ServiceDefaultModeById   = @{}
        PrivacyLabelById         = @{}
        CompactOsMode            = 'Default'
        SingleLanguageInstaller  = $false
        InstallerLanguage        = 'System Default'
        SessionLogPath           = ''
        FastMode                 = $true
        SkipPostUnmountVerify    = $true
        WimCompression           = 'Fast'
        UseIntegrityChecks       = $false
        ScratchMarkerFileName    = '.oximize_scratch.marker'
        ScriptPath               = ''
        ScriptBuildStamp         = ''
    })
if (-not [string]::IsNullOrWhiteSpace([string]$scriptPath)) {
    $sync.ScriptPath = [string]$scriptPath
}
#endregion

#region ── Debloat Lists ──────────────────────────────────────────────────────
$AppxChecked = @(
    'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.GamingApp',
    'Microsoft.GetHelp', 'Microsoft.Getstarted', 'Microsoft.MicrosoftOfficeHub',
    'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.MicrosoftTeams',
    'Microsoft.People', 'Microsoft.PowerAutomateDesktop', 'Microsoft.Todos',
    'Microsoft.WindowsFeedbackHub', 'Microsoft.WindowsMaps',
    'Microsoft.WindowsSoundRecorder', 'Microsoft.Xbox.TCUI',
    'Microsoft.XboxGameOverlay', 'Microsoft.XboxGamingOverlay',
    'Microsoft.XboxIdentityProvider', 'Microsoft.XboxSpeechToTextOverlay',
    'Microsoft.YourPhone', 'Microsoft.ZuneMusic', 'Microsoft.ZuneVideo',
    'Clipchamp.Clipchamp', 'MicrosoftCorporationII.MicrosoftFamily',
    'Microsoft.OneNote', 'Microsoft.OutlookForWindows', 'Microsoft.MicrosoftStickyNotes'
)
$AppxUnchecked = @(
    'Microsoft.MixedReality.Portal', 'Microsoft.OneNote',
    'Microsoft.Paint3D', 'Microsoft.SkypeApp'
)
$AppxRequestedExtra = @(
    'Microsoft.AV1VideoExtension',           # AV1 Video Extension
    'Microsoft.AVCEncoderVideoExtension',    # AVC Encoder Video Extension
    'Microsoft.HEVCVideoExtension',          # HEVC Video Extension
    'Microsoft.MPEG2VideoExtension',         # MPEG-2 Video Extension
    'Microsoft.RawImageExtension',           # Raw Image Extension
    'Microsoft.WebMediaExtensions',          # Web Media Extensions
    'Microsoft.ApplicationCompatibilityEnhancements', # Windows Application Compatibility Enhancements
    'MicrosoftWindows.CrossDevice',          # Cross Device Experience Host
    'Microsoft.Microsoft3DViewer',            # 3D Viewer
    'Microsoft.WindowsCamera',                # Camera
    'Microsoft.Windows.DevHome',              # Dev Home
    'Microsoft.OutlookForWindows',            # Outlook for Windows
    'Microsoft.Windows.Photos',               # Photos
    'Microsoft.WindowsNotepad',               # Notepad
    'Microsoft.WindowsAlarms',                # Alarms & Clock
    'Microsoft.WindowsMediaPlayer',           # Media Player
    'MicrosoftTeams',                         # Microsoft Teams (new package id)
    'Microsoft.Paint',                        # Paint
    'Microsoft.BingSearch',                   # Bing Search
    'Microsoft.Copilot',                      # Copilot
    'Microsoft.MicrosoftEdge.Stable',         # Microsoft Edge
    'Microsoft.OneDrive',                     # OneDrive
    'MicrosoftCorporationII.QuickAssist',     # Quick Assist
    'Microsoft.MicrosoftStickyNotes',         # Sticky Notes
    'Microsoft.ScreenSketch',                 # Snipping Tool
    'Microsoft.WindowsCalculator',            # Calculator
    'Microsoft.549981C3F5F10',                # Cortana
    'microsoft.windowscommunicationsapps',    # Mail and Calendar
    'Microsoft.WindowsTerminal',              # Terminal
    'Microsoft.MicrosoftEdgeDevToolsClient',  # Microsoft Edge DevTools Client
    'Runtime.Remove.MicrosoftEdge.System',    # Runtime action: Remove Edge (system install)
    'Runtime.Remove.MicrosoftEdge.WebView2',  # Runtime action: Remove WebView2
    'Runtime.Remove.MicrosoftEdge.Shortcuts'  # Runtime action: Remove Edge shortcuts
)
$AppxRemovedFromCatalog = @(
    'Microsoft.WindowsStore',
    'Microsoft.StorePurchaseApp',
    'Microsoft.WindowsAppRuntime.1.5',
    'Microsoft.WindowsAppRuntime.1.6',
    'MicrosoftWindows.Client.WebExperience'
)
$appxRemovedCatalogSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($appxId in $AppxRemovedFromCatalog) {
    if (-not [string]::IsNullOrWhiteSpace([string]$appxId)) {
        [void]$appxRemovedCatalogSet.Add([string]$appxId)
    }
}
$AppxChecked = $AppxChecked | Select-Object -Unique
$AppxUnchecked = ($AppxUnchecked + $AppxRequestedExtra) | Select-Object -Unique
$AppxUnchecked = $AppxUnchecked | Where-Object { $AppxChecked -notcontains $_ }
$AppxChecked = @($AppxChecked | Where-Object { -not $appxRemovedCatalogSet.Contains([string]$_) })
$AppxUnchecked = @($AppxUnchecked | Where-Object { -not $appxRemovedCatalogSet.Contains([string]$_) })

$AppxLabels = @{
    'Microsoft.BingNews'                             = 'Microsoft News'
    'Microsoft.BingWeather'                          = 'Weather'
    'Microsoft.GamingApp'                            = 'Xbox (includes overlays/components)'
    'Microsoft.GetHelp'                              = 'Get Help'
    'Microsoft.Getstarted'                           = 'Tips'
    'Microsoft.MicrosoftOfficeHub'                   = 'Microsoft 365 Office (Hub)'
    'Microsoft.MicrosoftSolitaireCollection'         = 'Solitaire Collection'
    'Microsoft.MicrosoftTeams'                       = 'Microsoft Teams Free (Personal)'
    'Microsoft.People'                               = 'Microsoft People'
    'Microsoft.PowerAutomateDesktop'                 = 'Power Automate Desktop'
    'Microsoft.Todos'                                = 'Microsoft To Do'
    'Microsoft.WindowsFeedbackHub'                   = 'Feedback Hub'
    'Microsoft.WindowsMaps'                          = 'Maps'
    'Microsoft.WindowsSoundRecorder'                 = 'Sound Recorder'
    'Microsoft.Xbox.TCUI'                            = 'Xbox TCUI'
    'Microsoft.XboxGameOverlay'                      = 'Xbox Game Overlay'
    'Microsoft.XboxGamingOverlay'                    = 'Xbox Gaming Overlay'
    'Microsoft.XboxIdentityProvider'                 = 'Xbox Identity Provider'
    'Microsoft.XboxSpeechToTextOverlay'              = 'Xbox Speech-to-Text Overlay'
    'Microsoft.YourPhone'                            = 'Microsoft Phone Link'
    'Microsoft.ZuneMusic'                            = 'Groove Music (Legacy)'
    'Microsoft.ZuneVideo'                            = 'Movies & TV'
    'Clipchamp.Clipchamp'                            = 'Microsoft Clipchamp'
    'MicrosoftCorporationII.MicrosoftFamily'         = 'Microsoft Family'
    'Microsoft.OneNote'                              = 'OneNote for Windows 10 (Legacy)'
    'Microsoft.OutlookForWindows'                    = 'New Outlook for Windows'
    'Microsoft.MicrosoftStickyNotes'                 = 'Sticky Notes'
    'Microsoft.MixedReality.Portal'                  = 'Mixed Reality Portal'
    'Microsoft.Paint3D'                              = 'Paint 3D'
    'Microsoft.SkypeApp'                             = 'Skype'
    'Microsoft.WindowsStore'                         = 'Microsoft Store'
    'Microsoft.Microsoft3DViewer'                    = '3D Viewer'
    'Microsoft.WindowsCamera'                        = 'Camera'
    'Microsoft.Windows.DevHome'                      = 'Dev Home'
    'Microsoft.Windows.Photos'                       = 'Microsoft Photos'
    'Microsoft.WindowsNotepad'                       = 'Notepad'
    'Microsoft.WindowsAlarms'                        = 'Clock'
    'Microsoft.WindowsMediaPlayer'                   = 'Media Player'
    'MicrosoftTeams'                                 = 'Microsoft Teams (Work or School)'
    'Microsoft.Paint'                                = 'Paint'
    'Microsoft.BingSearch'                           = 'Microsoft Bing Search'
    'Microsoft.Copilot'                              = 'Microsoft Copilot'
    'Microsoft.MicrosoftEdge.Stable'                 = 'Microsoft Edge'
    'Microsoft.OneDrive'                             = 'OneDrive'
    'MicrosoftCorporationII.QuickAssist'             = 'Quick Assist'
    'Microsoft.ScreenSketch'                         = 'Snipping Tool'
    'Microsoft.WindowsCalculator'                    = 'Calculator'
    'Microsoft.549981C3F5F10'                        = 'Cortana'
    'microsoft.windowscommunicationsapps'            = 'Mail and Calendar (Legacy)'
    'Microsoft.WindowsTerminal'                      = 'Windows Terminal'
    'Microsoft.MicrosoftEdgeDevToolsClient'          = 'Microsoft Edge DevTools Client'
    'Microsoft.AV1VideoExtension'                    = 'AV1 Video Extension'
    'Microsoft.AVCEncoderVideoExtension'             = 'AVC Encoder Video Extension'
    'Microsoft.HEVCVideoExtension'                   = 'HEVC Video Extension'
    'Microsoft.MPEG2VideoExtension'                  = 'MPEG-2 Video Extension'
    'Microsoft.RawImageExtension'                    = 'Raw Image Extension'
    'Microsoft.StorePurchaseApp'                     = 'Store Experience Host'
    'Microsoft.WebMediaExtensions'                   = 'Web Media Extensions'
    'Microsoft.ApplicationCompatibilityEnhancements' = 'Application Compatibility Enhancements'
    'MicrosoftWindows.CrossDevice'                   = 'Cross-Device Experience Host'
    'MicrosoftWindows.Client.WebExperience'          = 'Windows Web Experience Pack (Widgets)'
    'Microsoft.WindowsAppRuntime.1.5'                = 'Windows App Runtime 1.5 (Framework)'
    'Microsoft.WindowsAppRuntime.1.6'                = 'Windows App Runtime 1.6 (Framework)'
    'Runtime.Remove.MicrosoftEdge.System'            = 'Microsoft Edge (system uninstall - Beta)'
    'Runtime.Remove.MicrosoftEdge.WebView2'          = 'Microsoft Edge WebView2 Runtime (system uninstall - Beta)'
    'Runtime.Remove.MicrosoftEdge.Shortcuts'         = 'Microsoft Edge shortcuts'

}

# Plain-text, alphabetically sorted custom Remove Apps list (no colons).
$RequestedRemoveApps = @(
    '3D Viewer'
    'Add Suggested Folders To Library'
    'Adobe Photoshop Express'
    'Alarms & Clock'
    'App Connector'
    'App Resolver'
    'Assigned Access Lock App'
    'Calculator'
    'Call'
    'Camera'
    'Candy Crush Saga'
    'Candy Crush Soda Saga'
    'Capture Picker'
    'CBS Preview'
    'Code Writer'
    'Contact Support'
    'Content Delivery Manager'
    'Cortana'
    'Credential Dialog'
    'Desktop App Web Viewer'
    'Duolingo - Language Lessons'
    'Eclipse Manager'
    'Email and accounts'
    'Eye Control'
    'Feedback Hub'
    'Feedback Hub (legacy alias Windows Feedback)'
    'File Explorer (Extensions)'
    'File Explorer (Legacy)'
    'File Picker'
    'Flipboard'
    'Get Help app (breaks built-in troubleshooting)'
    'GPU Eject Dialog'
    'GroupMe'
    'HEIF Image Extensions'
    'HEVC Video Extensions'
    'Holographic First Run'
    'iHeart Radio, Music, Podcasts'
    'Kill OneDrive process'
    'Mail and Calendar'
    'Microsoft 365 (Office)'
    'Microsoft 3D Builder'
    'Microsoft Async Text Service'
    'Microsoft Edge'
    'Microsoft Edge (official uninstaller)'
    'Microsoft Edge Dev Tools Client'
    'Microsoft Edge shortcuts'
    'Microsoft Edge WebView2 Runtime'
    'Microsoft Family Safety'
    'Microsoft Messaging'
    'Microsoft News'
    'Microsoft Pay'
    'Microsoft People'
    'Microsoft Phone'
    'Microsoft Photos'
    'Microsoft PPI Projection'
    'Microsoft Remote Desktop'
    'Microsoft Solitaire Collection'
    'Microsoft Sticky Notes'
    'Microsoft Text Input Application'
    'Microsoft Tips'
    'Microsoft To Do'
    'Microsoft.UI.Xaml.2.8'
    'Microsoft.UI.Xaml.CBS'
    'Microsoft.Windows.AugLoop.CBS'
    'Minecraft for Windows'
    'Mixed Reality Portal'
    'Mobile Plans'
    'Movies & TV'
    'MSN Money'
    'MSN Sports'
    'MSN Weather'
    'My People'
    'Narrator'
    'Narrator QuickStart'
    'Network Speed Test'
    'OneDrive installation files and cache'
    'OneDrive shortcuts'
    'OneDrive startup entry'
    'OneDrive through official installer'
    'OneDrive user data and synced folders'
    'OneNote'
    'OOBE Network Captive Portal'
    'OOBE Network Connection Flow'
    'Out-of-box Experience (OOBE)'
    'Paint 3D'
    'Pandora'
    'Phone Companion'
    'Phone Link'
    'Pinning Confirmation Dialog'
    'Print 3D'
    'Print Queue app (breaks printing)'
    'Print UI app (breaks printing for some apps)'
    'PrintQueueActionCenter'
    'Raw Image Extension'
    'Safely Remove Device'
    'Search'
    'Secondary Tile Experience'
    'Settings'
    'Shazam'
    'Shell Experience Host'
    'Shell Services'
    'Skype'
    'SmartScreen'
    'Sound Recorder'
    'Spotify - Music and Podcasts'
    'Start Menu'
    'Sway'
    'Take a Test'
    'Twitter'
    'VP9 Video Extensions'
    'Web Media Extensions'
    'Webp Image Extensions'
    'WebView2 Runtime'
    'Win32 WebView Host'
    'Windows Application Runtime'
    'Windows Application Runtime v1.6'
    'Windows Application Runtime v1.8'
    'Windows Barcode Preview'
    'Windows Default Lock Screen'
    'Windows Feature Experience Pack'
    'Windows Feature Experience Pack - Core'
    'Windows Feature Experience Pack - CoreAI'
    'Windows Feature Experience Pack - Desktop'
    'Windows Feature Experience Pack - InputApp'
    'Windows Feature Experience Pack - Live'
    'Windows Feature Experience Pack - OOBE'
    'Windows Feature Experience Pack - Photon'
    'Windows Feature Experience Pack - Speech'
    'Windows Feature Experience Pack - Taskbar'
    'Windows Feature Experience Pack - Voice'
    'Windows Hello Setup'
    'Windows Maps'
    'Windows Media Player'
    'Windows Print'
    'Windows Shell Experience'
    'Windows Undocked Developer Kit (UDK)'
    'Windows Web Experience Pack (breaks Widgets)'
    'Work or school account'
    'Xbox'
    'Xbox Console Companion (legacy)'
    'Xbox Game Bar'
    'Xbox Game Callable UI app (breaks Xbox Live games)'
    'Xbox Game UI'
    'Xbox Gaming Overlay'
    'Xbox Identity Provider (breaks Xbox sign-in)'
    'Xbox Speech To Text Overlay'
)

$PrivacyToggleItems = @(
    [pscustomobject]@{ Label = 'Show me Windows welcome experience after updates'; Mode = 'Disabled' }
    [pscustomobject]@{ Label = 'Show most used apps'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Show recommendations for tips, shortcuts, new apps, and more'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Allow apps access - Appointments'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Allow apps access - Call history'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Allow apps access - Camera'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Allow apps access - Contacts'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Allow apps access - Diagnostic information'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Allow apps access - Documents Library'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Allow apps access - Email'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Allow apps access - File system'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Allow apps access - Messages (text or MMS)'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Allow apps access - Microphone'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Allow apps access - Notifications'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Allow apps access - Phone calls'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Allow apps access - Pictures Library'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Allow apps access - Radios'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Allow apps access - Share and sync info with non-explicitly paired wireless devices (e.g. beacons)'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Allow apps access - Tasks'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Allow apps access - User account info'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Allow apps access - Videos Library'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Allow experience improvement program (NVIDIA driver)'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Allow Experimentation'; Mode = 'Disabled' }
    [pscustomobject]@{ Label = 'Allow Location services'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Allow Telemetry'; Mode = 'Disabled' }
    [pscustomobject]@{ Label = 'Autocorrect misspelled words'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Automatic installation of sponsored apps (Consumer Experience)'; Mode = 'Disabled' }
    [pscustomobject]@{ Label = 'Automatically connect to hotspots temporarily to see if paid network services are available.'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Automatically connect to suggested open hotspots.'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Automatically install suggested apps'; Mode = 'Disabled' }
    [pscustomobject]@{ Label = 'Clipboard History'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Cloud optimized content'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Collect application inventory'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Collect contacts to let Windows and Cortana better understand you'; Mode = 'Enabled' }
    [pscustomobject]@{ Label = 'Collect typed text to let Windows and Cortana better understand you'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Collect written text (ink) to let Windows and Cortana better understand you'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Display last user name in logon screen'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Display locked user name in logon screen'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Display recent search entries in the File Explorer search box'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Enforce DCOM hardening changes'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Feedback frequency'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Highlight misspelled words'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Let apps on user''s other devices open apps and continue experiences on this device'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Let apps on user''s other devices use Bluetooth to open apps and continue experiences on this device'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Let apps run in the background'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Let apps use user advertising ID for experiences across apps'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Let Microsoft provide more tailored experiences with relevant tips and recommendations by using your diagnostic data'; Mode = 'Disabled' }
    [pscustomobject]@{ Label = 'Let Skype (if installed) help you connect with friends in your address book and verify your mobile number'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Let websites provide locally relevant content by accessing user language list'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Let Windows collect my activities from this PC (Timeline)'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Let Windows track app launches to improve Start and search results'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Let Windows track opened documents to populate Jump Lists'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Occasionally show suggestions in Start'; Mode = 'Disabled' }
    [pscustomobject]@{ Label = 'Online speech recognition services'; Mode = 'Disabled' }
    [pscustomobject]@{ Label = 'Personalize your speech, typing, and inking input by sending your input data to Microsoft'; Mode = 'Enabled' }
    [pscustomobject]@{ Label = 'Pre-installed apps'; Mode = 'Disabled' }
    [pscustomobject]@{ Label = 'Pre-installed OEM apps'; Mode = 'Disabled' }
    [pscustomobject]@{ Label = 'Program Compatibility Assistant'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Clear package install-location registry logs'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Search - Allow cloud search'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Search - Find My Files'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Search - Include Bing web results'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Search history on this device'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Send Microsoft info about how I write to help us improve typing and writing in the future'; Mode = 'Disabled' }
    [pscustomobject]@{ Label = 'Shared Experiences'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Clear Explorer folder view history (ShellBags)'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Show frequently used folders in Quick access'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Show me notifications in the Settings app'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Show me suggested content in the Settings app'; Mode = 'Disabled' }
    [pscustomobject]@{ Label = 'Show recently used files in Quick access'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Suggest ways I can finish setting up my device online (SCOOBE)'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Typing insights'; Mode = 'Disabled' }
    [pscustomobject]@{ Label = 'Use Hotspot 2.0 Online Sign-Up to get connected'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Use page prediction to improve reading, speed up browsing. Your browsing data will be sent to Microsoft.'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Windows Copilot'; Mode = 'Disabled' }
    [pscustomobject]@{ Label = 'Windows Copilot+ Recall'; Mode = 'Default' }
    [pscustomobject]@{ Label = 'Windows Spotlight (Tips and suggestions)'; Mode = 'Default' }
)

# Additional privacy toggles requested from external list (deduplicated by label).
$PrivacyRequestedExtra = @(
    'Disable Copilot'
    'Disable Recall'
    'Disable Input Insights and typing data harvesting'
    'Copilot in Edge'
    'Image Creator in Paint'
    'Remove AI Fabric Service'
    'Disable AI Actions'
    'Disable AI in Paint'
    'Disable Voice Access'
    'Disable AI Voice Effects'
    'Disable AI in Settings Search'
    'Disable Gaming Copilot'
    'Disable Copilot in All Office Apps'
    'Prevent Reinstall of AI Packages'
    'Disable Copilot policies'
    'Remove AI Appx Packages'
    'Remove Recall Optional Feature'
    'Remove AI Packages in CBS'
    'Remove AI Files'
    'Hide AI Components'
    'Disable Rewrite AI Feature in Notepad'
    'Remove Recall Tasks'
    'Update Cleanup Check'
    'Install Classic Apps'
    'Replace Notepad with classic version'
    'Replace Paint with classic version'
    'Replace Snipping Tool with classic version'
    'Replace Photo Viewer with classic version'
    'Install Photos Legacy'
    'Disable Location Tracking'
    'Disable Activity History'
    'Disable ConsumerFeatures'
    'Disable Explorer Automatic Folder Discovery'
    'Show most used apps'
    'Show recommendations for tips, shortcuts, new apps, and more'
    'Disable "Credentials" setting synchronization'
    'Disable "Language" setting synchronization'
    'Disable Activity Feed feature'
    'Disable ad customization with Advertising ID'
    'Disable all settings synchronization'
    'Disable app access to account information, name, and picture'
    'Disable app access to background activity (breaks Cortana, Search, live tiles, notifications)'
    'Disable app access to calendar'
    'Disable app access to call history'
    'Disable app access to contacts'
    'Disable app access to email'
    'Disable app access to eye tracking'
    'Disable app access to messaging (SMS / MMS)'
    'Disable app access to motion activity'
    'Disable app access to notifications'
    'Disable app access to phone calls (breaks phone calls through Phone Link)'
    'Disable app access to physical movement'
    'Disable app access to radios'
    'Disable app access to tasks'
    'Disable app access to unpaired Bluetooth devices'
    'Disable app access to voice activation'
    'Disable app access to voice activation on locked system'
    'Disable app usage tracking'
    'Disable automatic cloud configuration downloads'
    'Disable automatic Software Quality Metrics (SQM) data transmission'
    'Disable Background Apps'
    'Disable Bing search in start menu'
    'Disable cloud-based speech recognition'
    'Disable Cortana during search'
    'Disable Cortana experience'
    'Disable Cortana on locked device'
    'Disable customer experience data consolidation'
    'Disable customer experience data uploads'
    'Disable Customer Experience Improvement Program data collection'
    'Disable Customer Experience Improvement Program data uploads'
    'Disable Telemetry'
    'Disable daily compatibility data collection ("Microsoft Compatibility Appraiser" task)'
    'Disable device sensors'
    'Disable diagnostic and usage telemetry'
    'Block Workplace Join Messages'
    'Automatic Maintenance'
    'Remote Assistance'
    'Disable Edge Bing suggestions in address bar'
    'Disable Edge diagnostic data sending'
    'Disable Edge search and site suggestions'
    'Disable error reporting'
    'Disable internet access for Windows DRM'
    'Disable lock screen app notifications'
    'Disable Microsoft Copilot'
    'Disable Microsoft Store search results'
    'Disable Notification Tray/Calendar'
    'Disable location'
    'Disable location scripting'
    'Disable Recall'
    'Disable suggested content in Settings app'
    'Disable text and handwriting data collection'
    'Disable web results in Windows Search'
    'Disable web search in search bar'
    'Disable Wi-Fi Sense'
    'Disable Windows feedback collection'
    'Disable Windows Location Provider'
    'Disable Windows search highlights'
    'Disable Windows Spotlight (shows random wallpapers on lock screen)'
    'Disable Windows Tips'
    'Enable Do Not Track requests'
    'Enable Edge tracking prevention'
    'Ads, Suggestions and Promotional Content'
    'Online Speech Recognition'
    'Narrator Online Services'
    'Narrator Scripting Support'
    'Custom Inking and Typing Dictionary'
    'Send Diagnostic Data'
    'Improve inking and typing'
    'Tailored Experiences'
    'Allow Windows to ask you for feedback'
    'Show search highlights'
    'Cloud Content Search for Microsoft account'
    'Cloud Content Search for Work or School account'
    'Cross-Device Resume'
    'Allow Cortana'
    'Location Services'
    'Camera Access'
    'Microphone Access'
    'Account Info Access'
    'App Diagnostic Access'
    'Disable OneDrive Automatic Backups'
    'Content Delivery'
    'Subscribed Content'
    'Feature Management'
    'Soft Landing Experiences'
    'OEM Pre-installed Apps'
    'Pre-installed Suggested Apps'
    'Pre-installed Apps History Tracking'
    'Silent App Installation'
    'Let apps show me personalized ads by using my advertising ID'
    'Let websites show me locally relevant content by accessing my language list'
    'Let Windows improve Start and search results by tracking app launches'
    'Settings App Notifications'
    'Search history'
    'Search my accounts'
    'Microsoft account'
    'Work or School account'
    'Find my files'
    'Personalized offers'
    'Recommendations and offers in Settings'
    'Recommendations in Start Menu'
    'Improve Start and search results'
    'Send optional diagnostic data'
    'View diagnostic data'
    'Delete diagnostic data'
)

function Get-UniqueStringEntries {
    param([object[]]$Items)
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($Items)) {
        $value = [string]$item
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $trimmed = $value.Trim()
        if ($seen.Add($trimmed)) {
            [void]$result.Add($trimmed)
        }
    }
    return @($result)
}

$PrivacyRequestedExtra = @(Get-UniqueStringEntries -Items $PrivacyRequestedExtra)

function Normalize-PrivacyToggleLabel {
    param([string]$Label)

    if ([string]::IsNullOrWhiteSpace($Label)) { return '' }
    $value = $Label.Trim()
    $value = $value -replace '[\r\n\t]+', ' '
    $value = $value -replace '\s{2,}', ' '
    $value = $value -replace '\s*\(if installed\)\s*$', ''
    $value = $value -replace '\s*\(breaks[^)]*\)', ''
    $value = $value -replace '\s*\(shows random wallpapers on lock screen\)', ''
    $value = $value -replace '\s*\(text or MMS\)', ' (SMS/MMS)'
    $value = $value -replace '\s*\(BETA\)', ' (Beta)'
    $value = $value.Trim()

    switch -Regex ($value) {
        '^(?i)Show me Windows welcome experience after updates$' { return 'Windows welcome experience after updates' }
        '^(?i)Show recommendations for tips, shortcuts, new apps, and more$' { return 'Tips, shortcuts, and app recommendations' }
        '^(?i)Suggest ways I can finish setting up my device online \(SCOOBE\)$' { return 'OOBE: Finish setting up your device (SCOOBE)' }
        '^(?i)Allow Telemetry$' { return 'Diagnostic data' }
        '^(?i)Disable Telemetry$' { return 'Diagnostic data' }
        '^(?i)Send Diagnostic Data$' { return 'Diagnostic data' }
        '^(?i)Disable error reporting$' { return 'Windows Error Reporting' }
        '^(?i)Windows Error Reporting$' { return 'Windows Error Reporting' }
        '^(?i)Block Workplace Join Messages$' { return 'Workplace join prompts' }
        '^(?i)Workplace join prompts$' { return 'Workplace join prompts' }
        '^(?i)Automatic Maintenance$' { return 'Automatic maintenance' }
        '^(?i)Disable Automatic Maintenance$' { return 'Automatic maintenance' }
        '^(?i)Remote Assistance$' { return 'Remote Assistance' }
        '^(?i)Allow Windows to ask you for feedback$' { return 'Feedback frequency' }
        '^(?i)Improve inking and typing$' { return 'Inking and typing diagnostics' }
        '^(?i)Allow Location services$' { return 'Location services' }
        '^(?i)Location Services$' { return 'Location services' }
        '^(?i)Allow Experimentation$' { return 'Windows experimentation' }
        '^(?i)Clipboard History$' { return 'Clipboard history' }
        '^(?i)Cloud optimized content$' { return 'Cloud-optimized content' }
        '^(?i)Automatic installation of sponsored apps \(Consumer Experience\)$' { return 'Ads, suggestions, and promotional content' }
        '^(?i)Automatically install suggested apps$' { return 'Pre-installed suggested apps' }
        '^(?i)Pre-installed apps$' { return 'Pre-installed suggested apps' }
        '^(?i)Pre-installed OEM apps$' { return 'OEM pre-installed apps' }
        '^(?i)Pre-installed Apps History Tracking$' { return 'Pre-installed apps history tracking' }
        '^(?i)Silent App Installation$' { return 'Silent app installation' }
        '^(?i)Content Delivery$' { return 'Content delivery' }
        '^(?i)Subscribed Content$' { return 'Subscribed content' }
        '^(?i)Feature Management$' { return 'Feature management' }
        '^(?i)Soft Landing Experiences$' { return 'Soft landing experiences' }
        '^(?i)Online speech recognition services$' { return 'Online Speech Recognition' }
        '^(?i)Online Speech Recognition$' { return 'Online Speech Recognition' }
        '^(?i)Windows Copilot\+ Recall$' { return 'Windows Recall (Copilot+ PCs)' }
        '^(?i)Disable Copilot$' { return 'Windows Copilot' }
        '^(?i)Disable Microsoft Copilot$' { return 'Windows Copilot' }
        '^(?i)Disable Recall$' { return 'Windows Recall (Copilot+ PCs)' }
        '^(?i)Windows Copilot$' { return 'Windows Copilot' }
        '^(?i)Disable ConsumerFeatures$' { return 'Windows consumer features' }
        '^(?i)Disable Explorer Automatic Folder Discovery$' { return 'Explorer automatic folder discovery' }
        '^(?i)Disable app suggestions / Content Delivery Manager$' { return 'App suggestions (Content Delivery Manager)' }
        '^(?i)Ads, Suggestions and Promotional Content$' { return 'Ads, suggestions, and promotional content' }
        '^(?i)Disable Background Apps$' { return 'Let apps run in the background' }
        '^(?i)Disable Notification Tray/Calendar$' { return 'Notification center and tray' }
        '^(?i)Tailored Experiences$' { return 'Tailored experiences using diagnostic data' }
        '^(?i)Show search highlights$' { return 'Search: Search highlights' }
        '^(?i)Cloud Content Search for Microsoft account$' { return 'Search: Cloud content (Microsoft account)' }
        '^(?i)Cloud Content Search for Work or School account$' { return 'Search: Cloud content (Work or School account)' }
        '^(?i)Allow Cortana$' { return 'Search: Cortana' }
        '^(?i)Search history$' { return 'Search: Device search history' }
        '^(?i)Search history on this device$' { return 'Search: Device search history' }
        '^(?i)Search my accounts$' { return 'Search: Cloud content accounts' }
        '^(?i)Microsoft account$' { return 'Search: Cloud content (Microsoft account)' }
        '^(?i)Work or School account$' { return 'Search: Cloud content (Work or School account)' }
        '^(?i)Find my files$' { return 'Search: Find my files' }
        '^(?i)Bing Search in Start Menu$' { return 'Search: Bing web results in Start menu search' }
        '^(?i)Disable Microsoft Store search results$' { return 'Search: Microsoft Store app results in Start menu' }
        '^(?i)Cross-Device Resume$' { return 'Cross-device resume' }
        '^(?i)Search - Allow cloud search$' { return 'Search: Cloud content accounts' }
        '^(?i)Camera Access$' { return 'App Permissions: Camera' }
        '^(?i)Microphone Access$' { return 'App Permissions: Microphone' }
        '^(?i)Account Info Access$' { return 'App Permissions: Account info' }
        '^(?i)App Diagnostic Access$' { return 'App Permissions: App diagnostics' }
        '^(?i)Settings App Notifications$' { return 'Settings app notifications' }
        '^(?i)Personalized offers$' { return 'Personalized offers' }
        '^(?i)Recommendations and offers in Settings$' { return 'Recommendations and offers in Settings' }
        '^(?i)Show most used apps$' { return 'Start menu: Most used apps' }
        '^(?i)Recommendations in Start Menu$' { return 'Start menu suggestions' }
        '^(?i)Improve Start and search results$' { return 'Start menu: Track app launches' }
        '^(?i)Send optional diagnostic data$' { return 'Diagnostic data' }
        '^(?i)View diagnostic data$' { return 'View diagnostic data' }
        '^(?i)Delete diagnostic data$' { return 'Delete diagnostic data' }
        '^(?i)Let apps show me personalized ads by using my advertising ID$' { return 'Advertising ID personalization' }
        '^(?i)Let apps use user advertising ID for experiences across apps$' { return 'Advertising ID personalization' }
        '^(?i)Let websites provide locally relevant content by accessing user language list$' { return 'Language list access for websites' }
        '^(?i)Let websites show me locally relevant content by accessing my language list$' { return 'Language list access for websites' }
        '^(?i)Let Skype .*address book.*$' { return 'App Permissions: Contacts' }
        '^(?i)Let Windows track app launches to improve Start and search results$' { return 'Start menu: Track app launches' }
        '^(?i)Let Windows improve Start and search results by tracking app launches$' { return 'Start menu: Track app launches' }
        '^(?i)Let Microsoft provide more tailored experiences with relevant tips and recommendations by using your diagnostic data$' {
            return 'Tailored experiences using diagnostic data'
        }
        '^(?i)Personalize your speech, typing, and inking input by sending your input data to Microsoft$' {
            return 'Personalized speech, typing, and inking input'
        }
        '^(?i)Send Microsoft info about how I write to help us improve typing and writing in the future$' {
            return 'Send typing and writing data to Microsoft'
        }
        '^(?i)Show me notifications in the Settings app$' { return 'Settings app notifications' }
        '^(?i)Show me suggested content in the Settings app$' { return 'Settings app suggestions' }
        '^(?i)Show frequently used folders in Quick access$' { return 'Quick Access frequent folders' }
        '^(?i)Show recently used files in Quick access$' { return 'Quick Access recent files' }
        '^(?i)Display recent search entries in the File Explorer search box$' { return 'File Explorer search history' }
        '^(?i)ShellBags$' { return 'Clear Explorer folder view history (ShellBags)' }
        '^(?i)Clear Explorer folder view history \(ShellBags\)$' { return 'Clear Explorer folder view history (ShellBags)' }
        '^(?i)Remove registry logs of package install locations$' { return 'Clear package install-location registry logs' }
        '^(?i)Clear package install-location registry logs$' { return 'Clear package install-location registry logs' }
        '^(?i)Use Hotspot 2\.0 Online Sign-Up to get connected$' { return 'Hotspot 2.0 online sign-up' }
        '^(?i)Use page prediction to improve reading, speed up browsing\.?\s*Your browsing data will be sent to Microsoft\.?$' { return 'Edge network prediction' }
        '^(?i)Edge page prediction$' { return 'Edge network prediction' }
        '^(?i)Copilot in Edge$' { return 'Edge: Disable Copilot and AI features' }
        '^(?i)Disable AI Actions$' { return 'AI: Disable actions (Click to Do)' }
        '^(?i)Disable AI in Settings Search$' { return 'AI: Disable Settings agent' }
        '^(?i)Disable AI Voice Effects$' { return 'AI: Disable voice effects' }
        '^(?i)Disable Voice Access$' { return 'AI: Disable Voice Access' }
        '^(?i)Remove AI Fabric Service$' { return 'AI: Disable Fabric service' }
        '^(?i)Prevent Reinstall of AI Packages$' { return 'AI: Prevent Copilot package reinstall' }
        '^(?i)Hide AI Components$' { return 'AI: Hide Settings components pages' }
        '^(?i)Disable Rewrite AI Feature in Notepad$' { return 'Notepad: Disable AI features' }
        '^(?i)Disable AI in Paint$' { return 'Paint: Disable AI image features' }
        '^(?i)Image Creator in Paint$' { return 'Paint: Disable AI image features' }
        '^(?i)Disable Gaming Copilot$' { return 'Gaming: Disable Copilot widget' }
        '^(?i)Disable Copilot in All Office Apps$' { return 'Office: Disable Copilot and AI features' }
        '^(?i)Disable Copilot policies$' { return 'AI: Disable Copilot and Recall policies' }
        '^(?i)Remove Recall Optional Feature$' { return 'AI: Remove Recall optional feature' }
        '^(?i)Remove Recall Tasks$' { return 'AI: Remove Recall scheduled tasks' }
        '^(?i)Remove AI Appx Packages$' { return 'AI: Remove AI appx packages' }
        '^(?i)Remove AI Packages in CBS$' { return 'AI: Remove AI CBS packages' }
        '^(?i)Remove AI Files$' { return 'AI: Remove AI files and folders' }
        '^(?i)Update Cleanup Check$' { return 'AI: Install update cleanup checker task' }
        '^(?i)Install Classic Apps$' { return 'AI: Install classic Windows apps' }
        '^(?i)Replace Notepad with classic version$' { return 'Classic Apps: Replace Notepad' }
        '^(?i)Replace Paint with classic version$' { return 'Classic Apps: Replace Paint' }
        '^(?i)Replace Snipping Tool with classic version$' { return 'Classic Apps: Replace Snipping Tool' }
        '^(?i)Replace Photo Viewer with classic version$' { return 'Classic Apps: Replace Photo Viewer' }
        '^(?i)Install Photos Legacy$' { return 'Classic Apps: Install Photos Legacy' }
        '^(?i)Disable cloud-based speech recognition$' { return 'Online Speech Recognition' }
        '^(?i)Disable suggested content in Settings app$' { return 'Settings app suggestions' }
        '^(?i)Occasionally show suggestions in Start$' { return 'Start menu suggestions' }
        '^(?i)Disable lock screen app notifications$' { return 'Lock screen app notifications' }
        '^(?i)Program Compatibility Assistant$' { return 'Compatibility assistant (PCA)' }
        '^(?i)Collect application inventory$' { return 'Compatibility telemetry: Application inventory' }
        '^(?i)Disable daily compatibility data collection .*Compatibility Appraiser.*$' { return 'Compatibility telemetry: Compatibility Appraiser task' }
        '^(?i)Disable all settings synchronization$' { return 'Sync Settings: All settings' }
        '^(?i)Disable automatic cloud configuration downloads$' { return 'System cloud configuration downloads' }
        '^(?i)Disable \"Language\" setting synchronization$' { return 'Sync Settings: Other Windows settings' }
        '^(?i)Disable OneDrive Automatic Backups$' { return 'OneDrive automatic backups' }
        '^(?i)Disable web results in Windows Search$' { return 'Search: Web results in Windows Search' }
        '^(?i)Disable web search in search bar$' { return 'Search: Web results in taskbar search' }
        '^(?i)Disable Bing search in start menu$' { return 'Search: Bing web results in Start menu search' }
        '^(?i)WiFi-Sense$' { return 'Disable Wi-Fi Sense' }
        '^(?i)Disable Windows search highlights$' { return 'Search: Search highlights' }
        '^(?i)Disable Windows Tips$' { return 'Windows tips and suggestions' }
        '^(?i)Disable Windows Spotlight$' { return 'Windows Spotlight (lock screen)' }
        '^(?i)Disable Windows Spotlight \(Tips and suggestions\)$' { return 'Windows Spotlight (tips and suggestions)' }
        '^(?i)Windows Spotlight \(Tips and suggestions\)$' { return 'Windows Spotlight (tips and suggestions)' }
        '^(?i)Allow experience improvement program \(NVIDIA driver\)$' { return 'NVIDIA Experience Improvement Program' }
        '^(?i)(Allow|Let) apps on user''s other devices open apps and continue experiences on this device$' { return 'Shared experiences across devices' }
        '^(?i)(Allow|Let) apps on user''s other devices use Bluetooth to open apps and continue experiences on this device$' { return 'Shared experiences over Bluetooth' }
    }

    if ($value -match '^(?i)Allow apps access -\s*(.+)$') {
        $permissionName = [string]$Matches[1]
        $permissionName = $permissionName -replace '\s*\(SMS/MMS\)', ''
        $permissionName = $permissionName.Trim()
        return "App Permissions: $permissionName"
    }

    if ($value -match '^(?i)Disable app access to\s*(.+)$') {
        $permissionName = [string]$Matches[1]
        $permissionName = $permissionName -replace '\s*\(.*?\)\s*$', ''
        $permissionName = $permissionName.Trim()
        return "App Permissions: $permissionName"
    }

    if ($value -match '^(?i)Disable \"([^\"]+)\" setting synchronization$') {
        return "Sync Settings: $($Matches[1])"
    }

    if ($value -match '^(?i)Sync settings:\s*Disable\s*(.+)$') {
        return "Sync Settings: $($Matches[1])"
    }

    if ($value -match '^(?i)App permissions:\s*(.+)$') {
        return "App Permissions: $($Matches[1])"
    }

    if ($value -match '^(?i)Search -\s*(.+)$') {
        return "Search: $($Matches[1])"
    }

    return $value
}

$PrivacyToggleItems = @(
    foreach ($item in $PrivacyToggleItems) {
        [pscustomobject]@{
            Label = (Normalize-PrivacyToggleLabel -Label ([string]$item.Label))
            Mode  = if ($null -ne $item.PSObject.Properties['Mode']) { [string]$item.Mode } else { 'Default' }
        }
    }
)

$PrivacyRequestedExtra = @(
    foreach ($label in $PrivacyRequestedExtra) {
        $normalized = Normalize-PrivacyToggleLabel -Label ([string]$label)
        if (-not [string]::IsNullOrWhiteSpace($normalized)) { $normalized }
    }
)

foreach ($label in $PrivacyRequestedExtra) {
    $normalizedLabel = Normalize-PrivacyToggleLabel -Label ([string]$label)
    if ([string]::IsNullOrWhiteSpace($normalizedLabel)) { continue }
    $exists = $false
    foreach ($existingItem in $PrivacyToggleItems) {
        if ([string]::Equals([string]$existingItem.Label, [string]$normalizedLabel, [System.StringComparison]::OrdinalIgnoreCase)) {
            $exists = $true
            break
        }
    }
    if (-not $exists) {
        $defaultMode = if ($normalizedLabel -like 'Enable *') { 'Enabled' } else { 'Disabled' }
        $PrivacyToggleItems += [pscustomobject]@{
            Label = [string]$normalizedLabel
            Mode  = $defaultMode
        }
    }
}

$ExtraSecurityToggleItems = @(
    [pscustomobject]@{ Label = 'Set Windows Time Service NTP server (pool.ntp.org)'; Mode = 'Disabled'; Detail = 'Sets a trusted NTP source for consistent clock synchronization, which supports Kerberos, certificate validation, and reliable audit timestamps.' }
    [pscustomobject]@{ Label = 'Disable Windows PowerShell 2.0'; Mode = 'Disabled'; Detail = 'Removes legacy PowerShell 2.0 components to reduce downgrade abuse and old engine attack surface.' }
    [pscustomobject]@{ Label = 'Disable PowerShell 7 telemetry'; Mode = 'Disabled'; Detail = 'Sets machine environment variable POWERSHELL_TELEMETRY_OPTOUT=1 to opt out of PowerShell 7 telemetry collection.' }
    [pscustomobject]@{ Label = 'Enable SEHOP (Structured Exception Handling Overwrite Protection)'; Mode = 'Disabled'; Detail = 'Enables SEHOP to help block classic SEH overwrite exploitation techniques.' }
    [pscustomobject]@{ Label = 'Disable AlwaysInstallElevated policy (Windows Installer)'; Mode = 'Disabled'; Detail = 'Prevents MSI packages from being installed with elevated privileges by standard users via policy abuse.' }
    [pscustomobject]@{ Label = 'Disable LM hash storage (NoLMHash)'; Mode = 'Disabled'; Detail = 'Stops generation/storage of LAN Manager password hashes to reduce offline credential cracking risk.' }
    [pscustomobject]@{ Label = 'Disable AutoPlay and AutoRun (all drives)'; Mode = 'Disabled'; Detail = 'Blocks automatic media execution behavior commonly abused for removable-drive malware propagation.' }
    [pscustomobject]@{ Label = 'Disable Windows Script Host (WSH)'; Mode = 'Disabled'; Detail = 'Disables Windows Script Host (wscript/cscript), reducing direct .vbs/.js malware execution paths.' }
    [pscustomobject]@{ Label = 'Disable lock screen camera access'; Mode = 'Disabled'; Detail = 'Prevents camera access from the lock screen context to reduce pre-auth data exposure.' }
    [pscustomobject]@{ Label = 'Enable Defender and Edge PUA blocking'; Mode = 'Disabled'; Detail = 'Enables Potentially Unwanted App (PUA) blocking policy for Microsoft Defender and Microsoft Edge SmartScreen.' }
    [pscustomobject]@{ Label = 'Enable LSA protection (RunAsPPL)'; Mode = 'Disabled'; Detail = 'Enables LSASS protected process mode (RunAsPPL) to harden against credential theft techniques.' }
    [pscustomobject]@{ Label = 'Enable DEP (Data Execution Prevention)'; Mode = 'Disabled'; Detail = 'Enforces execute-protection policy to limit code execution from non-executable memory regions.' }
    [pscustomobject]@{ Label = 'Enable Spectre/Meltdown mitigations (host OS)'; Mode = 'Disabled'; Detail = 'Applies Spectre and Meltdown host mitigations where supported by hardware, microcode, and Windows updates.' }
    [pscustomobject]@{ Label = 'Enable Spectre/Meltdown mitigations (Hyper-V)'; Mode = 'Disabled'; Detail = 'Enables additional branch target injection protections for Hyper-V guest isolation scenarios.' }
    [pscustomobject]@{ Label = 'Diffie-Hellman minimum key length (2048-bit)'; Mode = 'Disabled'; Detail = 'Sets the minimum TLS Diffie-Hellman key size to 2048 bits for stronger key exchange.' }
    [pscustomobject]@{ Label = 'RSA minimum key length (2048-bit)'; Mode = 'Disabled'; Detail = 'Sets the minimum TLS RSA key-exchange size to 2048 bits; legacy clients may fail if they only support weaker keys.' }
    [pscustomobject]@{ Label = 'Disable RC2 Ciphers'; Mode = 'Disabled'; Detail = 'Removes RC2 from allowed cryptographic options due to obsolete security properties.' }
    [pscustomobject]@{ Label = 'Disable RC4 Ciphers'; Mode = 'Disabled'; Detail = 'Removes RC4 cipher usage due to well-known cryptographic weaknesses.' }
    [pscustomobject]@{ Label = 'Disable DES Ciphers'; Mode = 'Disabled'; Detail = 'Disables single-DES algorithms because effective key strength is insufficient for modern security.' }
    [pscustomobject]@{ Label = 'Disable 3DES Ciphers'; Mode = 'Disabled'; Detail = 'Disables Triple-DES to reduce legacy cipher exposure and improve modern TLS posture.' }
    [pscustomobject]@{ Label = 'Disable NULL Ciphers'; Mode = 'Disabled'; Detail = 'Prevents cipher suites that provide no encryption from being negotiated.' }
    [pscustomobject]@{ Label = 'Disable MD5 Hash Algorithms'; Mode = 'Disabled'; Detail = 'Blocks MD5 where policy allows, reducing collision-attack risk in cryptographic operations.' }
    [pscustomobject]@{ Label = 'Disable SHA-1 Hash Algorithms'; Mode = 'Disabled'; Detail = 'Disables SHA-1 usage in favor of stronger alternatives to address collision weaknesses.' }
    [pscustomobject]@{ Label = 'Disable SMB 1.0 (SMBv1) protocol'; Mode = 'Disabled'; Detail = 'Turns off SMBv1 client/server components to remove a deprecated protocol with major security risk.' }
    [pscustomobject]@{ Label = 'Disable NetBIOS over TCP/IP (NetBT)'; Mode = 'Disabled'; Detail = 'Reduces legacy name-resolution exposure and limits NetBIOS-based reconnaissance paths.' }
    [pscustomobject]@{ Label = 'SSL 2.0 protocol (legacy)'; Mode = 'Disabled'; Detail = 'Legacy protocol toggle. Keep disabled for modern web security.' }
    [pscustomobject]@{ Label = 'SSL 3.0 protocol (legacy)'; Mode = 'Disabled'; Detail = 'Legacy protocol toggle. Keep disabled to prevent downgrade exposure.' }
    [pscustomobject]@{ Label = 'TLS 1.0 protocol (legacy)'; Mode = 'Disabled'; Detail = 'Legacy protocol toggle. Keep disabled unless an old dependency requires it.' }
    [pscustomobject]@{ Label = 'TLS 1.1 protocol (legacy)'; Mode = 'Disabled'; Detail = 'Legacy protocol toggle. Keep disabled unless a compatibility exception is needed.' }
    [pscustomobject]@{ Label = 'DTLS 1.0 protocol (legacy)'; Mode = 'Disabled'; Detail = 'Legacy datagram TLS protocol toggle. Keep disabled in modern baselines.' }
    [pscustomobject]@{ Label = 'Restrict LM and NTLM authentication'; Mode = 'Disabled'; Detail = 'Hardens LAN Manager/NTLM policy levels to reduce use of weaker challenge-response protocols.' }
    [pscustomobject]@{ Label = 'Disable Insecure TLS Renegotiation'; Mode = 'Disabled'; Detail = 'Applies renegotiation hardening to prevent legacy insecure renegotiation behavior.' }
    [pscustomobject]@{ Label = '.NET use OS default TLS versions'; Mode = 'Disabled'; Detail = 'Makes .NET Framework use operating-system TLS defaults instead of pinned legacy protocol behavior.' }
    [pscustomobject]@{ Label = 'DTLS 1.2 protocol'; Mode = 'Disabled'; Detail = 'Modern datagram TLS protocol toggle.' }
    [pscustomobject]@{ Label = 'TLS 1.3 protocol'; Mode = 'Disabled'; Detail = 'Modern TLS protocol toggle for strongest current transport security.' }
    [pscustomobject]@{ Label = '.NET strong crypto mode'; Mode = 'Disabled'; Detail = 'Forces .NET Framework SchUseStrongCrypto settings to avoid weak TLS/cipher fallback in legacy apps.' }
    [pscustomobject]@{ Label = 'Disable WinRM Basic authentication'; Mode = 'Disabled'; Detail = 'Disables Basic auth for WinRM client/service to reduce credential exposure risk in remote management.' }
    [pscustomobject]@{ Label = 'Block anonymous SAM and share enumeration'; Mode = 'Disabled'; Detail = 'Enables network access policies that prevent anonymous discovery of local account/share information.' }
    [pscustomobject]@{ Label = 'Block anonymous access to named pipes and shares'; Mode = 'Disabled'; Detail = 'Restricts null-session access paths to named pipes and shares that can expose internal resources.' }
    [pscustomobject]@{ Label = 'Disable administrative shares (AutoShareWks/AutoShareServer)'; Mode = 'Disabled'; Detail = 'Prevents automatic creation of hidden administrative shares (C$, D$, ADMIN$); may break remote admin tools.' }
    [pscustomobject]@{ Label = 'Disable anonymous share enumeration'; Mode = 'Disabled'; Detail = 'Prevents unauthenticated users from listing available SMB shares.' }
    [pscustomobject]@{ Label = 'Disable cloud clipboard sync'; Mode = 'Disabled'; Detail = 'Turns off cloud clipboard synchronization to reduce accidental cross-device data leakage.' }
    [pscustomobject]@{ Label = 'Disable Hibernation'; Mode = 'Disabled'; Detail = 'Disables hibernation to avoid writing memory contents to disk and reduce sensitive data-at-rest exposure.' }
    [pscustomobject]@{ Label = 'Run DISM component cleanup (/ResetBase)'; Mode = 'Disabled'; Detail = 'Runs component store cleanup with /ResetBase to reduce superseded component data and image size.' }
    [pscustomobject]@{ Label = 'Delete volume shadow copies (VSS)'; Mode = 'Disabled'; Detail = 'Clears existing VSS snapshots to remove restore points that may retain sensitive prior-state data.' }
    [pscustomobject]@{ Label = 'TLS 1.2 protocol'; Mode = 'Disabled'; Detail = 'Windows Update, DISM, Store services, and many apps require TLS 1.2. Keep enabled unless you explicitly need to test disabling it.' }
    [pscustomobject]@{ Label = 'DTLS 1.1 protocol (legacy)'; Mode = 'Disabled'; Detail = 'Legacy DTLS protocol toggle. Keep disabled for modern security unless a specific dependency requires it.' }
)

$AdvancedOptionItems = @(
    [pscustomobject]@{ Label = 'Diagnostics - ETW AutoLogger sessions'; Mode = 'Disabled'; Detail = 'Controls selected ETW AutoLogger sessions used by diagnostics and telemetry. Enabled = Start=1, Disabled = Start=0.' }
    [pscustomobject]@{ Label = 'Logging - Windows Event Log service'; Mode = 'Disabled'; Detail = 'Controls the EventLog service startup behavior. Disabling reduces system event logging and can limit troubleshooting.' }
    [pscustomobject]@{ Label = 'UI - Windows Widgets'; Mode = 'Disabled'; Detail = 'Controls Widgets visibility and taskbar integration.' }
    [pscustomobject]@{ Label = 'UX - App suggestions (Content Delivery Manager)'; Mode = 'Disabled'; Detail = 'Controls suggested apps, tips, and promotional content delivery settings.' }
    [pscustomobject]@{ Label = 'Troubleshooting - Detailed BSOD information'; Mode = 'Disabled'; Detail = 'Shows detailed stop-error information on blue-screen crashes for troubleshooting.' }
    [pscustomobject]@{ Label = 'Explorer - Show file name extensions'; Mode = 'Disabled'; Detail = 'Shows file extensions in File Explorer to help identify true file types.' }
    [pscustomobject]@{ Label = 'Start - Recommendations in Start Menu'; Mode = 'Disabled'; Detail = 'Controls Start recommendations visibility. Disabled hides recommendation content and the Recommended section policy surface.' }
    [pscustomobject]@{ Label = 'Settings - Remove Home page'; Mode = 'Disabled'; Detail = 'Enabled hides the Home page in Settings (policy: SettingsPageVisibility=hide:home).' }
    [pscustomobject]@{ Label = 'Settings - Hide Windows Insider Program page'; Mode = 'Disabled'; Detail = 'Enabled hides Windows Insider Program settings pages (hide:windowsinsider;windowsinsider-optin) and applies Insider UI hide policy.' }
    [pscustomobject]@{ Label = 'Settings - Hide For developers page'; Mode = 'Disabled'; Detail = 'Enabled hides the For developers settings page (hide:developers).' }
    [pscustomobject]@{ Label = 'Settings - Hide Atlas recommended pages'; Mode = 'Disabled'; Detail = 'Enabled applies Atlas recommended hidden Settings pages (recovery, maps, privacy category roots, sync, phone-link, workplace/family/device-usage pages).' }
    [pscustomobject]@{ Label = 'Explorer - Remove Gallery from navigation pane'; Mode = 'Disabled'; Detail = 'Enabled removes Gallery from Explorer navigation by removing its NameSpace key.' }
    [pscustomobject]@{ Label = 'Explorer - Remove Home from navigation pane'; Mode = 'Disabled'; Detail = 'Enabled removes Home from Explorer navigation and sets Explorer launch target to This PC.' }
    [pscustomobject]@{ Label = 'Edge - Allow Microsoft Edge uninstall (Beta)'; Mode = 'Disabled'; Detail = 'Experimental option to run Edge system uninstall commands at first startup (beta behavior; may affect updates and apps that depend on Edge/WebView).' }
    [pscustomobject]@{ Label = 'Cleanup - Remove empty C:\Windows.old folder'; Mode = 'Disabled'; Detail = 'Removes an empty leftover Windows.old folder, when present.' }
    [pscustomobject]@{ Label = 'Encryption - Device encryption automatic enablement'; Mode = 'Disabled'; Detail = 'Controls automatic device encryption behavior during setup.' }
    [pscustomobject]@{ Label = 'Security - Core isolation (Memory integrity / VBS)'; Mode = 'Disabled'; Detail = 'Controls virtualization-based security and memory integrity settings.' }
    [pscustomobject]@{ Label = 'Security - Disable WPBT execution (Beta)'; Mode = 'Disabled'; Detail = 'Blocks Windows Platform Binary Table execution path used by firmware to run binaries at boot.' }
    [pscustomobject]@{ Label = 'Accessibility - Sticky Keys shortcut'; Mode = 'Disabled'; Detail = 'Controls Sticky Keys keyboard shortcut behavior.' }
    [pscustomobject]@{ Label = 'Setup - Bypass Windows 11 TPM/Secure Boot checks'; Mode = 'Disabled'; Detail = 'Applies setup bypass registry flags for hardware requirement checks.' }
    [pscustomobject]@{ Label = 'OOBE - Allow setup without internet'; Mode = 'Disabled'; Detail = 'Allows offline OOBE flow without requiring internet connectivity.' }
    [pscustomobject]@{ Label = 'OOBE - Remove Microsoft account requirement'; Mode = 'Disabled'; Detail = 'Allows local-account OOBE flow instead of forcing Microsoft account sign-in.' }
    [pscustomobject]@{ Label = 'Media - Trim language and capability payloads'; Mode = 'Disabled'; Detail = 'Aggressively trims non-primary language packs/capabilities from the image to reduce size.' }
    [pscustomobject]@{ Label = 'Encryption - BitLocker automatic device encryption'; Mode = 'Disabled'; Detail = 'Controls automatic BitLocker device encryption behavior during and after setup.' }
    [pscustomobject]@{ Label = 'Setup - Hide PowerShell windows'; Mode = 'Disabled'; Detail = 'Hides setup-time PowerShell windows used by generated scripts.' }
    [pscustomobject]@{ Label = 'Recovery - System Restore'; Mode = 'Disabled'; Detail = 'Controls System Protection (restore points) behavior for drive C:.' }
    [pscustomobject]@{ Label = 'PowerShell - Execution policy (RemoteSigned)'; Mode = 'Disabled'; Detail = 'Sets LocalMachine execution policy to RemoteSigned at first startup.' }
)

function Normalize-AdvancedOptionLabel {
    param([string]$Label)

    if ([string]::IsNullOrWhiteSpace($Label)) { return '' }
    $value = $Label.Trim()
    $value = $value -replace '[\r\n\t]+', ' '
    $value = $value -replace '\s{2,}', ' '
    $value = $value -replace '\s*\(BETA\)', ' (Beta)'
    $value = $value.Trim()

    switch -Regex ($value) {
        '^(?i)(Auto loggers|Diagnostics - ETW AutoLogger sessions)$' { return 'Diagnostics - ETW AutoLogger sessions' }
        '^(?i)(Event viewer|Windows Event Log service|Logging - Windows Event Log service)$' { return 'Logging - Windows Event Log service' }
        '^(?i)(Disable Widgets|Remove Widgets|Windows Widgets|UI - Windows Widgets)$' { return 'UI - Windows Widgets' }
        '^(?i)(Disable app suggestions \(Content Delivery Manager\)|App suggestions \(Content Delivery Manager\)|UX - App suggestions \(Content Delivery Manager\))$' { return 'UX - App suggestions (Content Delivery Manager)' }
        '^(?i)(Enable detailed BSOD information|Detailed BSOD information|Troubleshooting - Detailed BSOD information)$' { return 'Troubleshooting - Detailed BSOD information' }
        '^(?i)(Show file name extensions|Explorer - Show file name extensions)$' { return 'Explorer - Show file name extensions' }
        '^(?i)(Recommendations in Start Menu|Start menu suggestions|Start - Recommendations in Start Menu)$' { return 'Start - Recommendations in Start Menu' }
        '^(?i)(Remove Settings Home Page|Settings - Remove Home page)$' { return 'Settings - Remove Home page' }
        '^(?i)(Remove Windows Insider program in settings|Hide Windows Insider Program in Settings|Settings - Hide Windows Insider Program page)$' { return 'Settings - Hide Windows Insider Program page' }
        '^(?i)(Hide For developers page|Remove For developers page|Settings - Hide For developers page|Remove related setting option in settings page)$' { return 'Settings - Hide For developers page' }
        '^(?i)(Settings - Hide Atlas recommended pages|Hide Atlas recommended settings pages|Atlas hidden settings pages)$' { return 'Settings - Hide Atlas recommended pages' }
        '^(?i)(Remove Gallery from explorer|Remove Gallery from Explorer|Explorer - Remove Gallery from navigation pane)$' { return 'Explorer - Remove Gallery from navigation pane' }
        '^(?i)(Remove Home from Explorer|Explorer - Remove Home from navigation pane)$' { return 'Explorer - Remove Home from navigation pane' }
        '^(?i)(Allow Microsoft Edge uninstallation \(Beta\)|Allow Microsoft Edge uninstall \(Beta\)|Edge - Allow Microsoft Edge uninstall \(Beta\))$' { return 'Edge - Allow Microsoft Edge uninstall (Beta)' }
        '^(?i)(Delete empty C:\\Windows.old folder|Cleanup - Remove empty C:\\Windows.old folder)$' { return 'Cleanup - Remove empty C:\Windows.old folder' }
        '^(?i)(Prevent automatic device encryption|Encryption - Device encryption automatic enablement)$' { return 'Encryption - Device encryption automatic enablement' }
        '^(?i)(Disable Core Isolation / VBS|Core isolation \(Memory integrity / VBS\)|Security - Core isolation \(Memory integrity / VBS\))$' { return 'Security - Core isolation (Memory integrity / VBS)' }
        '^(?i)(Disable Windows Platform Binary Table \(WPBT\)|Disable Windows Platform Binary Table \(WPBT\) execution \(Beta\)|Disable WPBT execution \(Beta\)|Security - Disable WPBT execution \(Beta\))$' { return 'Security - Disable WPBT execution (Beta)' }
        '^(?i)(Disable Sticky Keys|Disable Sticky Keys shortcut|Accessibility - Sticky Keys shortcut)$' { return 'Accessibility - Sticky Keys shortcut' }
        '^(?i)(Bypass Windows 11 hardware requirement checks \(TPM, Secure Boot, etc\.\)|Bypass Windows 11 hardware requirement checks \(TPM, Secure Boot\)|Secure Boot and TPM 2\.0 requirement handling|Setup - Bypass Windows 11 TPM/Secure Boot checks)$' { return 'Setup - Bypass Windows 11 TPM/Secure Boot checks' }
        '^(?i)(Allow Windows 11 setup without internet connection|Allow Windows 11 setup without internet|OOBE - Allow setup without internet)$' { return 'OOBE - Allow setup without internet' }
        '^(?i)(Remove Microsoft account requirement during OOBE|Remove Microsoft account requirement \(OOBE\)|OOBE - Remove Microsoft account requirement)$' { return 'OOBE - Remove Microsoft account requirement' }
        '^(?i)(Remove more language/capability payloads|Media - Trim language and capability payloads)$' { return 'Media - Trim language and capability payloads' }
        '^(?i)(Disable BitLocker automatic device encryption|Encryption - BitLocker automatic device encryption)$' { return 'Encryption - BitLocker automatic device encryption' }
        '^(?i)(Hide PowerShell windows during Windows Setup|Hide PowerShell windows during setup|Setup - Hide PowerShell windows)$' { return 'Setup - Hide PowerShell windows' }
        '^(?i)(Disable System Protection / System Restore|Disable System Protection \(System Restore\)|Recovery - System Restore)$' { return 'Recovery - System Restore' }
        '^(?i)(Allow PowerShell script execution \(RemoteSigned\)|PowerShell script execution policy \(RemoteSigned\)|PowerShell - Execution policy \(RemoteSigned\))$' { return 'PowerShell - Execution policy (RemoteSigned)' }
    }

    return $value
}

$AdvancedOptionItems = @(
    foreach ($item in $AdvancedOptionItems) {
        [pscustomobject]@{
            Label  = (Normalize-AdvancedOptionLabel -Label ([string]$item.Label))
            Mode   = if ($null -ne $item.PSObject.Properties['Mode']) { [string]$item.Mode } else { 'Default' }
            Detail = if ($null -ne $item.PSObject.Properties['Detail']) { [string]$item.Detail } else { [string]$item.Label }
        }
    }
)

$FeaturesChecked = @(
    'WorkFolders-Client', 'Printing-PrintToPDFServices-Features',
    'MediaPlayback'
)
$FeaturesUnchecked = @(
    'NetFx3',
    'NetFx4-AdvSrvs',
    'DirectoryServices-ADAM-Client',
    'Containers-Server-For-Application-Guard',
    'Containers',
    'DataCenterBridging',
    'Client-DeviceLockdown',
    'HostGuardian',
    'Microsoft-Hyper-V-All',
    'IIS-WebServerRole',
    'IIS-HostableWebCore',
    'LegacyComponents',
    'MSMQ-Server',
    'HyperV-KernelInt-VirtualDevice',
    'HyperV-Guest-KernelInt',
    'Printing-XPSServices-Features',
    'MultiPoint-Connector',
    'SearchEngine-Client-Package',
    'ServicesForNFS-ClientOnly',
    'SimpleTCP',
    'SMB1Protocol',
    'SMBDirect',
    'TelnetClient',
    'TFTP',
    'VirtualMachinePlatform',
    'HypervisorPlatform',
    'Windows-Identity-Foundation',
    'WAS-WindowsActivationService',
    'Client-ProjFS',
    'Containers-DisposableClientVM',
    'Microsoft-Windows-Subsystem-Linux',
    'TIFFIFilter',
    'App.WirelessDisplay.Connect~~~~0.0.1.0',
    'MSRDC-Infrastructure'
)
$FeaturesChecked = $FeaturesChecked | Select-Object -Unique
$FeaturesUnchecked = $FeaturesUnchecked | Select-Object -Unique
$FeaturesUnchecked = $FeaturesUnchecked | Where-Object { $FeaturesChecked -notcontains $_ }
$FeatureLabels = @{
    'NetFx3'                                  = '.NET Framework 3.5 (includes .NET 2.0 and 3.0)'
    'NetFx4-AdvSrvs'                          = '.NET Framework 4.8 Advanced Services'
    'DirectoryServices-ADAM-Client'           = 'Active Directory Lightweight Directory Services'
    'Containers-Server-For-Application-Guard' = 'Container Support for Application Guard'
    'Containers'                              = 'Containers'
    'DataCenterBridging'                      = 'Data Center Bridging'
    'Client-DeviceLockdown'                   = 'Device Lockdown'
    'HostGuardian'                            = 'Guarded Host'
    'Microsoft-Hyper-V-All'                   = 'Hyper-V'
    'IIS-WebServerRole'                       = 'Internet Information Services (IIS)'
    'IIS-HostableWebCore'                     = 'IIS Hostable Web Core'
    'LegacyComponents'                        = 'Legacy Components'
    'MediaPlayback'                           = 'Media Features'
    'MSMQ-Server'                             = 'Microsoft Message Queue (MSMQ) Server'
    'HyperV-KernelInt-VirtualDevice'          = 'Hyper-V Integration Services: Virtual Device'
    'HyperV-Guest-KernelInt'                  = 'Hyper-V Integration Services: Guest Services Driver'
    'Printing-PrintToPDFServices-Features'    = 'Microsoft Print to PDF'
    'Printing-XPSServices-Features'           = 'Microsoft XPS Document Writer'
    'MultiPoint-Connector'                    = 'MultiPoint Connector'
    'SearchEngine-Client-Package'             = 'Windows Search'
    'ServicesForNFS-ClientOnly'               = 'Services for NFS'
    'SimpleTCP'                               = 'Simple TCP/IP services'
    'SMB1Protocol'                            = 'SMB 1.0/CIFS File Sharing Support'
    'SMBDirect'                               = 'SMB Direct'
    'TelnetClient'                            = 'Telnet Client'
    'TFTP'                                    = 'TFTP Client'
    'VirtualMachinePlatform'                  = 'Virtual Machine Platform'
    'HypervisorPlatform'                      = 'Windows Hypervisor Platform'
    'Windows-Identity-Foundation'             = 'Windows Identity Foundation 3.5'
    'WAS-WindowsActivationService'            = 'Windows Process Activation Service'
    'Client-ProjFS'                           = 'Windows Projected File System'
    'Containers-DisposableClientVM'           = 'Windows Sandbox'
    'Microsoft-Windows-Subsystem-Linux'       = 'Windows Subsystem for Linux'
    'TIFFIFilter'                             = 'Windows TIFF IFilter'
    'App.WirelessDisplay.Connect~~~~0.0.1.0'  = 'Wireless Display'
    'WorkFolders-Client'                      = 'Work Folders Client'
    'MSRDC-Infrastructure'                    = 'Microsoft Remote Desktop Client (MSRDC) Infrastructure'
}
$FeatureDetails = @{
    'NetFx3'                                  = 'Legacy .NET 2.0–3.5 runtime; required by older LOB/installer apps. Remove if no legacy managed apps are needed.'
    'NetFx4-AdvSrvs'                          = 'Advanced .NET 4.8 components (ASP.NET/WCF activation) for hosting managed apps and services. Keep only if such workloads run on the image.'
    'DirectoryServices-ADAM-Client'           = 'AD LDS/ADAM client libraries for apps that query Lightweight Directory Services. Rare on clients; safe to remove when unused.'
    'Containers-Server-For-Application-Guard' = 'Container plumbing used by Application Guard/WDAG isolation. Enable only when using those protected browser/Office scenarios.'
    'Containers'                              = 'Windows Containers platform for Docker/AKS-style containers. Needed for container workloads; remove on non-container images.'
    'DataCenterBridging'                      = 'Priority flow control/DCB for converged loss-sensitive networks (iSCSI/RDMA). Enable on datacenter NICs that need PFC; otherwise leave off.'
    'Client-DeviceLockdown'                   = 'Kiosk lockdown toolkit (Shell Launcher, Keyboard Filter, UWF). Enable for kiosks/embedded devices; unnecessary on general desktops.'
    'HostGuardian'                            = 'Host Guardian/attestation pieces for shielded VMs. Keep only in environments using shielded VMs with HGS.'
    'Microsoft-Hyper-V-All'                   = 'Hyper-V hypervisor and tools to run/host VMs (also required for Sandbox/WSA). Disable if using another hypervisor or to avoid virtualization overhead.'
    'IIS-WebServerRole'                       = 'Full IIS web server for hosting sites/APIs. Rarely needed on client images; keep for web server roles.'
    'IIS-HostableWebCore'                     = 'Embeddable IIS core for apps that self-host HTTP. Enable when an app vendor requires Hostable Web Core.'
    'LegacyComponents'                        = 'DirectPlay and legacy multimedia shims mainly for old games/apps. Disable unless required for legacy titles.'
    'MediaPlayback'                           = 'Built-in media codecs and Media Player components. Keep for audio/video playback; remove for minimal or VDI images without media use.'
    'MSMQ-Server'                             = 'Microsoft Message Queuing for queued/reliable messaging on unreliable networks. Enable only if applications depend on MSMQ.'
    'HyperV-KernelInt-VirtualDevice'          = 'Hyper-V guest integration device component. Needed in Hyper-V/WSL2 environments; otherwise optional.'
    'HyperV-Guest-KernelInt'                  = 'Hyper-V guest integration/VSC driver support. Keep in VM templates running under Hyper-V.'
    'Printing-PrintToPDFServices-Features'    = 'Microsoft Print to PDF virtual printer. Keep if users export to PDF; remove for locked-down builds.'
    'Printing-XPSServices-Features'           = 'Microsoft XPS Document Writer. Needed only for apps outputting XPS; otherwise removable.'
    'MultiPoint-Connector'                    = 'Connector for MultiPoint/education shared computing. Niche; disable unless using MultiPoint services.'
    'SearchEngine-Client-Package'             = 'Windows Search indexing service powering Start/File Explorer search. Disable for minimal images or privacy-focused builds.'
    'ServicesForNFS-ClientOnly'               = 'NFS client to access UNIX/Linux NFS shares. Enable when NFS access is required.'
    'SimpleTCP'                               = 'Legacy Simple TCP/IP services (echo/daytime/etc) for testing/compatibility. Leave off unless specifically needed.'
    'SMB1Protocol'                            = 'SMBv1 stack for very old NAS/printers. Keep disabled for security; enable only for legacy devices.'
    'SMBDirect'                               = 'SMB over RDMA for low-latency/high-throughput file access on RDMA NICs; useful for Hyper-V/SQL over file shares.'
    'TelnetClient'                            = 'Telnet CLI for legacy network equipment access. Off by default; enable only when required.'
    'TFTP'                                    = 'TFTP client utility for simple transfers/firmware/boot configs. Enable when interacting with TFTP servers.'
    'VirtualMachinePlatform'                  = 'Shared virtualization layer used by WSL2 and some VM/container stacks. Required for WSL2; remove if virtualization is undesired.'
    'HypervisorPlatform'                      = 'Hypervisor APIs for third-party hypervisors (e.g., VMware/VirtualBox with WHP). Enable when those tools require it.'
    'Windows-Identity-Foundation'             = 'Windows Identity Foundation 3.5 for claims-based auth in legacy .NET apps. Enable only for such apps.'
    'WAS-WindowsActivationService'            = 'Windows Process Activation Service for IIS/WCF activation (HTTP, Net.TCP, pipes, MSMQ). Needed when hosting those services.'
    'Client-ProjFS'                           = 'Projected File System used by virtualized file providers (e.g., OneDrive Files On-Demand, VFS for Git).'
    'Containers-DisposableClientVM'           = 'Windows Sandbox disposable VM environment; depends on virtualization. Enable for isolated app testing.'
    'Microsoft-Windows-Subsystem-Linux'       = 'WSL to run Linux userland (WSL2 needs virtualization). Enable for Linux tooling; remove if not required.'
    'TIFFIFilter'                             = 'TIFF iFilter so Windows Search can index TIFF OCR/text. Disable if search indexing is disabled.'
    'App.WirelessDisplay.Connect~~~~0.0.1.0'  = 'Wireless Display / Miracast Connect for projecting screens. Keep when users cast to/from this device.'
    'WorkFolders-Client'                      = 'Work Folders enterprise file sync for org-managed shares. Enable when using Work Folders.'
    'MSRDC-Infrastructure'                    = 'Modern Remote Desktop client infrastructure (MSRDC) used by the new Remote Desktop app. Enable when that client is needed.'
}

$TasksChecked = @(
    '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
    '\Microsoft\Windows\Application Experience\AitAgent',
    '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
    '\Microsoft\Windows\Application Experience\StartupAppTask',
    '\Microsoft\Windows\Autochk\Proxy',
    '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
    '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
    '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector',
    '\Microsoft\Windows\Feedback\Siuf\DmClient',
    '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload',
    '\Microsoft\Windows\Windows Error Reporting\QueueReporting',
    '\Microsoft\Windows\WindowsUpdate\Automatic App Update',
    '\Microsoft\Windows\License Manager\TempSignedLicenseExchange',
    '\Microsoft\Windows\Clip\License Validation',
    '\Microsoft\Windows\Power Efficiency Diagnostics\AnalyzeSystem',
    '\Microsoft\Windows\PushToInstall\LoginCheck',
    '\Microsoft\Windows\PushToInstall\Registration',
    '\Microsoft\Windows\Device Information\Device',
    '\Microsoft\Windows\Device Information\Device User',
    '\Microsoft\Windows\Maps\MapsUpdateTask',
    '\Microsoft\Windows\Maps\MapsToastTask',
    '\Microsoft\EdgeUpdate\MicrosoftEdgeUpdateTaskMachineCore',
    '\Microsoft\EdgeUpdate\MicrosoftEdgeUpdateTaskMachineUA',
    '\OneDrive Standalone Update Task',
    '\OneDrive Reporting Task',
    '\Microsoft\Windows\WindowsAI\Recall\InitialConfiguration',
    '\Microsoft\Windows\WindowsAI\Recall\PolicyConfiguration',
    '\Microsoft\Office\Office Actions Server'
)
$TaskDetails = @{
    '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'     = 'Runs Microsoft Compatibility Appraiser inventory to evaluate app and driver readiness for upgrades. Disabling stops that compatibility telemetry scan.'
    '\Microsoft\Windows\Application Experience\AitAgent'                              = 'Application Experience Inventory Collector task. Disabling stops inventory collection for compatibility telemetry.'
    '\Microsoft\Windows\Application Experience\ProgramDataUpdater'                    = 'Updates application telemetry used by Windows compatibility and application-experience components. Disabling stops that scheduled collection/update job.'
    '\Microsoft\Windows\Application Experience\StartupAppTask'                        = 'Measures startup application impact so Windows can surface startup-related recommendations. Disabling stops that startup impact analysis task.'
    '\Microsoft\Windows\Autochk\Proxy'                                                = 'Supports Autochk and disk-check related reporting after boot-time disk verification events. Disabling stops that scheduled proxy/reporting task.'
    '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator'         = 'Consolidates Customer Experience Improvement Program data before it is sent to Microsoft. Disabling stops that CEIP aggregation/upload task.'
    '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip'              = 'Collects CEIP data related to USB usage. Disabling stops that USB telemetry task.'
    '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector' = 'Collects disk diagnostic information when Windows detects storage-health concerns. Disabling stops that scheduled disk-diagnostics collection.'
    '\Microsoft\Windows\Feedback\Siuf\DmClient'                                       = 'Triggers Scheduled User Feedback diagnostic/feedback uploads. Disabling stops that SIUF feedback client task.'
    '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload'                     = 'Triggers scenario-based SIUF feedback collection after qualifying events. Disabling stops that scenario-driven feedback task.'
    '\Microsoft\Windows\Windows Error Reporting\QueueReporting'                       = 'Submits queued crash and hang reports through Windows Error Reporting. Disabling can reduce diagnostic signal for reliability and incident triage.'
    '\Microsoft\Windows\WindowsUpdate\Automatic App Update'                           = 'Checks for and installs Microsoft Store app updates automatically. Keeping this enabled helps app security patching.'
    '\Microsoft\Windows\License Manager\TempSignedLicenseExchange'                    = 'Handles temporary signed license exchange operations for Store and licensed content scenarios. Disabling stops that scheduled license-exchange task.'
    '\Microsoft\Windows\Clip\License Validation'                                      = 'Validates Microsoft Store app and content licenses through the Client License Platform. Disabling stops that periodic license validation task.'
    '\Microsoft\Windows\Power Efficiency Diagnostics\AnalyzeSystem'                   = 'Runs the built-in power efficiency diagnostics analysis job. Disabling stops that scheduled power-analysis task.'
    '\Microsoft\Windows\PushToInstall\LoginCheck'                                     = 'Checks sign-in state for Push To Install so Store apps can be sent to the device remotely. Disabling stops that login verification task.'
    '\Microsoft\Windows\PushToInstall\Registration'                                   = 'Registers the device for Push To Install and related remote app-install experiences. Disabling stops that registration task.'
    '\Microsoft\Windows\Device Information\Device'                                    = 'Collects device metadata through Device Information scheduled maintenance. Disabling stops that device task.'
    '\Microsoft\Windows\Device Information\Device User'                               = 'Per-user device information collection task. Disabling stops the device user task.'
    '\Microsoft\Windows\Maps\MapsUpdateTask'                                          = 'Checks and downloads updates for offline maps. Disabling stops automatic map downloads and map updates.'
    '\Microsoft\Windows\Maps\MapsToastTask'                                           = 'Displays offline-map related notifications and update prompts. Disabling suppresses those map toasts.'
    '\Microsoft\EdgeUpdate\MicrosoftEdgeUpdateTaskMachineCore'                        = 'Edge Update core scheduled task. Keeping this enabled helps browser security updates apply automatically.'
    '\Microsoft\EdgeUpdate\MicrosoftEdgeUpdateTaskMachineUA'                          = 'Edge Update UA scheduled task. Keeping this enabled helps automatic Edge update checks and installation.'
    '\OneDrive Standalone Update Task'                                                = 'OneDrive scheduled update task. Keeping this enabled helps OneDrive security and reliability updates.'
    '\OneDrive Reporting Task'                                                        = 'OneDrive scheduled reporting/telemetry task. Disabling stops that OneDrive reporting trigger.'
    '\Microsoft\Windows\WindowsAI\Recall\InitialConfiguration'                        = 'Initial Recall configuration task under WindowsAI. Disabling helps prevent Recall setup/config initialization.'
    '\Microsoft\Windows\WindowsAI\Recall\PolicyConfiguration'                         = 'Recall policy-configuration task under WindowsAI. Disabling helps prevent Recall policy tasks from running.'
    '\Microsoft\Office\Office Actions Server'                                         = 'Office Actions Server scheduled task used by newer Office AI/automation experiences. Disabling prevents this task from running.'
}

$TaskLabels = @{
    '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'     = 'Telemetry - Compatibility Appraiser'
    '\Microsoft\Windows\Application Experience\AitAgent'                              = 'Telemetry - App Inventory Collector (AITAgent)'
    '\Microsoft\Windows\Application Experience\ProgramDataUpdater'                    = 'Telemetry - Program Data Updater'
    '\Microsoft\Windows\Application Experience\StartupAppTask'                        = 'UX - Startup App Impact Monitor'
    '\Microsoft\Windows\Autochk\Proxy'                                                = 'Diagnostics - Autochk Proxy'
    '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator'         = 'Telemetry - CEIP Consolidator'
    '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip'              = 'Telemetry - CEIP USB'
    '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector' = 'Diagnostics - Disk Diagnostic Collector'
    '\Microsoft\Windows\Feedback\Siuf\DmClient'                                       = 'Feedback - SIUF Client'
    '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload'                     = 'Feedback - SIUF Scenario Download'
    '\Microsoft\Windows\Windows Error Reporting\QueueReporting'                       = 'Diagnostics - Error Report Queue Upload'
    '\Microsoft\Windows\WindowsUpdate\Automatic App Update'                           = 'Updates - Microsoft Store App Auto-Update'
    '\Microsoft\Windows\License Manager\TempSignedLicenseExchange'                    = 'Store Licensing - Temp Signed License Exchange'
    '\Microsoft\Windows\Clip\License Validation'                                      = 'Store Licensing - License Validation'
    '\Microsoft\Windows\Power Efficiency Diagnostics\AnalyzeSystem'                   = 'Diagnostics - Power Efficiency Analyzer'
    '\Microsoft\Windows\PushToInstall\LoginCheck'                                     = 'Store Remote Install - Login Check'
    '\Microsoft\Windows\PushToInstall\Registration'                                   = 'Store Remote Install - Registration'
    '\Microsoft\Windows\Device Information\Device'                                    = 'Telemetry - Device Information (System)'
    '\Microsoft\Windows\Device Information\Device User'                               = 'Telemetry - Device Information (User)'
    '\Microsoft\Windows\Maps\MapsUpdateTask'                                          = 'Maps - Offline Maps Auto-Update'
    '\Microsoft\Windows\Maps\MapsToastTask'                                           = 'Maps - Offline Maps Notifications'
    '\Microsoft\EdgeUpdate\MicrosoftEdgeUpdateTaskMachineCore'                        = 'Updates - Microsoft Edge Update (Core)'
    '\Microsoft\EdgeUpdate\MicrosoftEdgeUpdateTaskMachineUA'                          = 'Updates - Microsoft Edge Update (UA)'
    '\OneDrive Standalone Update Task'                                                = 'Updates - OneDrive Standalone Update'
    '\OneDrive Reporting Task'                                                        = 'Telemetry - OneDrive Reporting'
    '\Microsoft\Windows\WindowsAI\Recall\InitialConfiguration'                        = 'AI - Recall Initial Configuration'
    '\Microsoft\Windows\WindowsAI\Recall\PolicyConfiguration'                         = 'AI - Recall Policy Configuration'
    '\Microsoft\Office\Office Actions Server'                                         = 'AI - Office Actions Server'
}

$TaskRecommendedDefaultState = @{
    '\Microsoft\Windows\WindowsUpdate\Automatic App Update'    = 'Default'
    '\Microsoft\EdgeUpdate\MicrosoftEdgeUpdateTaskMachineCore' = 'Default'
    '\Microsoft\EdgeUpdate\MicrosoftEdgeUpdateTaskMachineUA'   = 'Default'
    '\OneDrive Standalone Update Task'                         = 'Default'
}

$TaskDisableWarnings = @{
    '\Microsoft\Windows\WindowsUpdate\Automatic App Update'    = 'Disabling this task can delay Microsoft Store app security updates.'
    '\Microsoft\EdgeUpdate\MicrosoftEdgeUpdateTaskMachineCore' = 'Disabling this task can delay Microsoft Edge security updates.'
    '\Microsoft\EdgeUpdate\MicrosoftEdgeUpdateTaskMachineUA'   = 'Disabling this task can delay Microsoft Edge security updates.'
    '\OneDrive Standalone Update Task'                         = 'Disabling this task can delay OneDrive security and reliability updates.'
}

# Additional task aliases requested externally (deduplicated before UI build).
$TasksRequestedExtra = @(
    '\Microsoft\Windows\Application Experience\AitAgent',   # Inventory Collector
    '\Microsoft\Windows\Maps\MapsUpdateTask',               # Automatic map downloads
    '\OneDrive Standalone Update Task',                     # OneDrive scheduled tasks
    '\OneDrive Reporting Task'
)
$TasksRequestedExtra = @(Get-UniqueStringEntries -Items $TasksRequestedExtra)
$TasksChecked = @(Get-UniqueStringEntries -Items ($TasksChecked + $TasksRequestedExtra))

$ServicesChecked = @(
    'DiagTrack', 'dmwappushservice', 'XblAuthManager', 'XblGameSave',
    'XboxGipSvc', 'XboxNetApiSvc', 'wisvc', 'RetailDemo', 'MapsBroker', 'lfsvc'
)
$ServicesRequestedExtra = @(
    'SysMain',
    'Spooler',
    'PcaSvc',
    'WerSvc',
    'SCardSvr',
    'ScDeviceEnum',
    'PhoneSvc',
    'Fax',
    'MixedRealityOpenXRSvc',
    'SmsRouter',
    'WpcMonSvc',
    'SEMgrSvc',
    'svsvc',
    'RasAuto',
    'SensorDataService',
    'TabletInputService',
    'SensrSvc',
    # Additional common services visible in stock images; allow disabling if present
    'BITS', 'DoSvc', 'edgeupdate', 'edgeupdatem', 'UsoSvc', 'WaaSMedicSvc', 'wuauserv',
    'wscsvc', 'SecurityHealthService', 'WinDefend', 'WdNisSvc', 'Sense',
    'StateRepository', 'AppXSVC', 'ClipSVC', 'AppReadiness', 'AppIDSvc', 'Appinfo', 'ALG',
    'AppMgmt', 'AarSvc', 'AssignedAccessManagerSvc', 'tzautoupdate', 'BthAvctpSvc',
    'BrokerInfrastructure', 'BFE', 'BDESVC', 'wbengine', 'bthserv', 'camsvc',
    'CertPropSvc', 'KeyIso', 'EventSystem', 'COMSysApp', 'CDPSvc', 'CDPUserSvc',
    'DcomLaunch', 'DsmSvc', 'DeviceAssociationService', 'DeviceAssociationBrokerSvc',
    'DevQueryBroker', 'Dhcp', 'DPS', 'WdiServiceHost', 'WdiSystemHost', 'DisplayEnhancementService',
    'DispBrokerDesktopSvc', 'TrkWks', 'MSDTC', 'Dnscache', 'EFS', 'EntAppSvc', 'EapHost',
    'fhsvc', 'fdPHost', 'FDResPub', 'BcastDVRUserService', 'GameInputSvc', 'GraphicsPerfSvc',
    'gpsvc', 'hidserv', 'icssvc', 'iphlpsvc', 'IKEEXT', 'LanmanWorkstation', 'LanmanServer',
    'NlaSvc', 'netprofm', 'Netman', 'NcbService', 'NcaSvc', 'NetSetupSvc', 'nsi', 'Wcmsvc',
    'wcncsvc', 'WinHttpAutoProxySvc', 'dot3svc', 'WlanSvc', 'WwanSvc', 'LicenseManager',
    'MSIServer', 'WinRM', 'PlugPlay', 'Power', 'PrintWorkflowUserSvc', 'PrintScanBrokerService',
    'QWAVE', 'RmSvc', 'Schedule', 'lmhosts', 'TapiSrv', 'Themes', 'TimeBrokerSvc', 'upnphost',
    'UserDataSvc', 'UnistoreSvc', 'UEVAgentService', 'UserManager', 'ProfSvc', 'VSS', 'W32Time',
    'defragsvc', 'ssh-agent', 'WalletService', 'Wecsvc', 'eventlog',
    # Additional services requested from latest screenshots
    'AxInstSV', 'ADPSvc', 'AasSvc', 'AppXSvc', 'AssignedAccessManagerSvc', 'BTAGService',
    'BthAvctpSvc', 'BthHFSrv', 'BluetoothUserService', 'CaptureService', 'cbdhsvc',
    'CDPSvc', 'CDPUserSvc', 'ConsentUxUserSvc', 'cphs', 'CredentialEnrollmentManagerUserSvc',
    'CryptSvc', 'DsSvc', 'dcsvc', 'DcpSvc', 'defragsvc', 'DialogBlockingService',
    'DisplayPolicyService', 'diagsvc', 'EapHost', 'FrameServer', 'FrameServerMonitor',
    'GraphicsPerfSvc', 'HvHost', 'vmickvpexchange', 'vmicguestinterface', 'vmicshutdown',
    'vmicheartbeat', 'vmicvmsession', 'vmicrdv', 'vmictimesync', 'vmicvss',
    'KtmRm', 'lfsvc', 'lltdsvc', 'wlidsvc', 'MicrosoftEdgeElevationService',
    'MSiSCSI', 'NgcSvc', 'NgcCtnrSvc', 'NgcIso', 'NcdAutoSetup', 'NcbService',
    'NPSMSvc', 'p2psvc', 'P9RdrService', 'PimIndexMaintenanceSvc', 'PerfHost',
    'pla', 'PrintDeviceConfigurationService', 'PrintNotify', 'PrintWorkflowUserSvc',
    'QWAVE', 'RmSvc', 'RasAuto', 'RasMan', 'RDSessMgr', 'RpcEptMapper', 'RpcLocator',
    'SstpSvc', 'SENS', 'SgrmBroker', 'SharedRealitySvc', 'ShellHWDetection',
    'snmptrap', 'SSDPSRV', 'stisvc', 'StorSvc', 'SENS', 'TextInputManagementService',
    'TimeBroker', 'UdkUserSvc', 'UsoSvc', 'VaultSvc', 'vds', 'vm3dservice',
    'WarpJITSvc', 'wbengine', 'WbioSrvc', 'Wcmsvc', 'Wecsvc', 'WEPHOSTSVC',
    'wercplsupport', 'WiaRpc', 'wisvc', 'wlpasvc', 'wmiApSrv', 'WpnService',
    'WpnUserService', 'WwanSvc', 'XblAuthManager', 'XblGameSave'
)
$ServicesChecked = @(Get-UniqueStringEntries -Items $ServicesChecked)
$ServicesRequestedExtra = @(Get-UniqueStringEntries -Items $ServicesRequestedExtra)
$ServicesUnchecked = @(
    'WMPNetworkSvc', 'RemoteRegistry', 'SharedAccess', 'WSearch'
)
$ServicesUnchecked = @(Get-UniqueStringEntries -Items ($ServicesUnchecked + $ServicesRequestedExtra))
$ServicesUnchecked = @($ServicesUnchecked | Where-Object { $ServicesChecked -notcontains $_ })
$ServiceRuntimeDetails = @{}
$ServiceDetails = @{
    'DiagTrack'             = 'Connected User Experiences and Telemetry collects diagnostic, usage, and reliability data for Microsoft. Disabling it reduces diagnostic-data collection and upload.'
    'dmwappushservice'      = 'Routes WAP push messages and some device-management style push traffic used by Windows components. Disabling it removes that push-routing path and can reduce some telemetry-related messaging.'
    'XblAuthManager'        = 'Provides Xbox Live sign-in and authentication for games and Xbox-integrated apps. Disabling it breaks Xbox account sign-in features.'
    'XblGameSave'           = 'Handles Xbox Live game-save synchronization between the device and cloud. Disabling it stops Xbox cloud-save sync.'
    'XboxGipSvc'            = 'Manages Xbox accessory input devices and related peripheral integration. Disabling it can affect Xbox controller and accessory features.'
    'XboxNetApiSvc'         = 'Provides Xbox Live networking APIs used by multiplayer and Xbox-connected experiences. Disabling it breaks those Xbox networking features.'
    'wisvc'                 = 'Supports Windows Insider flighting and Insider Program enrollment/management. Disabling it prevents Insider servicing features from functioning.'
    'RetailDemo'            = 'Supports Windows Retail Demo mode used on store display PCs. Disabling it removes retail-demo functionality.'
    'MapsBroker'            = 'Manages downloaded and offline maps for apps and Windows features that rely on map data. Disabling it removes offline map-management support.'
    'lfsvc'                 = 'Provides the Windows location framework used by apps and services that request device location. Disabling it prevents geolocation features from working.'
    'WMPNetworkSvc'         = 'Shares Windows Media Player libraries and streams with compatible devices on the network. Disabling it stops that media-sharing service.'
    'RemoteRegistry'        = 'Allows authorized remote users and administrators to read or modify the registry over the network. Disabling it closes that remote registry management path.'
    'SharedAccess'          = 'Implements Internet Connection Sharing and related software NAT/sharing services. Disabling it removes built-in ICS support.'
    'WSearch'               = 'Indexes file, mail, and content metadata so Windows Search can return fast results. Disabling it turns off the Windows Search indexing service.'
    'SysMain'               = 'SysMain analyzes usage patterns to improve memory and app-launch responsiveness. Disabling it removes that prefetching and memory-optimization behavior.'
    'Spooler'               = 'Queues print jobs and brokers communication with printers and print drivers. Disabling it turns off local and network print queue processing.'
    'PcaSvc'                = 'Program Compatibility Assistant detects known compatibility issues in older apps and installers and can suggest or apply fixes. Disabling it removes that compatibility-assistance service.'
    'WerSvc'                = 'Windows Error Reporting collects crash, hang, and fault data and can upload reports to Microsoft or enterprise endpoints. Disabling it stops that reporting service.'
    'SCardSvr'              = 'Manages smart card access, reader interactions, and certificate-based smart card operations. Disabling it breaks smart-card sign-in and related workflows.'
    'ScDeviceEnum'          = 'Enumerates and helps manage smart card reader devices for the smart card stack. Disabling it removes that device-enumeration support.'
    'PhoneSvc'              = 'Supports telephony and phone-related platform features used by certain Windows apps and experiences. Disabling it removes that background phone-integration service.'
    'Fax'                   = 'Provides fax send and receive functionality for Windows fax-capable workflows. Disabling it removes built-in fax service support.'
    'MixedRealityOpenXRSvc' = 'Supports the Windows Mixed Reality OpenXR runtime and related immersive application experiences. Disabling it removes that Mixed Reality/OpenXR service layer.'
    'SmsRouter'             = 'Routes SMS messages for Windows components and apps on supported mobile-connected devices. Disabling it removes that messaging integration service.'
    'WpcMonSvc'             = 'Monitors parental controls and Microsoft Family Safety policy activity. Disabling it stops that parental-controls monitoring service.'
    'SEMgrSvc'              = 'Manages payments and NFC secure-element interactions on supported hardware. Disabling it removes those payment and NFC management functions.'
    'svsvc'                 = 'Spot Verifier helps verify data integrity and investigate potential corruption scenarios in supported storage workflows. Disabling it removes that verification service.'
    'RasAuto'               = 'Automatically starts remote access or VPN connections when certain remote resources are referenced. Disabling it stops automatic dial or VPN triggers.'
    'SensorDataService'     = 'Collects and brokers sensor data for apps and platform features that use installed sensors. Disabling it removes that sensor-data pipeline.'
    'TabletInputService'    = 'Provides the touch keyboard, handwriting panel, and parts of modern text input and inking. Disabling it breaks those input experiences.'
    'SensrSvc'              = 'Monitors sensor state changes for Windows and applications. Disabling it removes that sensor-monitoring service.'
}
$ServiceLabels = @{
    'DiagTrack'             = 'Connected User Experiences and Telemetry Service'
    'SysMain'               = 'SysMain Service (Superfetch)'
    'Spooler'               = 'Print Spooler Service'
    'PcaSvc'                = 'Program Compatibility Assistant Service'
    'WerSvc'                = 'Windows Error Reporting Service'
    'lfsvc'                 = 'Geolocation Service'
    'RetailDemo'            = 'Retail Demo Service'
    'wisvc'                 = 'Windows Insider Service'
    'SCardSvr'              = 'Smart Card Service'
    'ScDeviceEnum'          = 'Smart Card Device Enumeration Service'
    'PhoneSvc'              = 'Phone Service'
    'MapsBroker'            = 'Downloaded Maps Manager'
    'Fax'                   = 'Fax Service'
    'WMPNetworkSvc'         = 'Windows Media Player Network Sharing Service'
    'MixedRealityOpenXRSvc' = 'Windows Mixed Reality OpenXR Service'
    'SmsRouter'             = 'Microsoft Windows SMS Router Service'
    'WpcMonSvc'             = 'Parental Controls Service'
    'SEMgrSvc'              = 'Payments and NFC/SE Manager'
    'svsvc'                 = 'Spot Verifier Service'
    'RasAuto'               = 'Remote Access Auto Connection Manager'
    'SensorDataService'     = 'Sensor Data Service'
    'TabletInputService'    = 'Touch Keyboard and Handwriting Panel Service'
    'SensrSvc'              = 'Sensor Monitoring Service'
    'XboxGipSvc'            = 'Gaming Peripherals (Xbox GIP)'
    'AxInstSV'              = 'ActiveX Installer Service'
}

# Enrich service names/details from local Windows service metadata when available.
# Source basis: Microsoft Win32_Service class (DisplayName/Description).
try {
    # Pre-prune to service keys that actually exist on this host to reduce UI load.
    $existingServiceIds = @()
    try {
        $existingServiceIds = @(Get-ChildItem -Path 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction Stop | ForEach-Object { [string]$_.PSChildName })
    }
    catch {
        $existingServiceIds = @()
    }

    if ($existingServiceIds.Count -gt 0) {
        $existingLookup = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($sid in $existingServiceIds) {
            if (-not [string]::IsNullOrWhiteSpace($sid)) { [void]$existingLookup.Add($sid.Trim()) }
        }
        $ServicesChecked = @($ServicesChecked | Where-Object { $existingLookup.Contains(([string]$_).Trim()) })
        $ServicesUnchecked = @($ServicesUnchecked | Where-Object { $existingLookup.Contains(([string]$_).Trim()) })
    }

    $allServiceIds = @($ServicesChecked + $ServicesUnchecked) | Select-Object -Unique
    if ($allServiceIds.Count -gt 0) {
        $nameFilter = ($allServiceIds | ForEach-Object { "Name='$($_.Replace("'", "''"))'" }) -join ' OR '
        $svcRows = @()
        $svcRowsById = @{}
        try {
            $svcRows = @(Get-CimInstance -ClassName Win32_Service -Filter $nameFilter -ErrorAction Stop)
        }
        catch {
            $svcRows = @()
        }
        if ($svcRows.Count -eq 0) {
            # Fallback: query all and filter in-process if WMI filter length/provider fails.
            try {
                $svcRows = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop | Where-Object { $allServiceIds -contains $_.Name })
            }
            catch {
                $svcRows = @()
            }
        }

        foreach ($svc in $svcRows) {
            $sid = [string]$svc.Name
            if ([string]::IsNullOrWhiteSpace($sid)) { continue }
            $svcRowsById[$sid] = $svc

            # Prefer authoritative local Windows metadata when present.
            if (-not [string]::IsNullOrWhiteSpace([string]$svc.DisplayName)) {
                $ServiceLabels[$sid] = [string]$svc.DisplayName
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$svc.Description)) {
                $ServiceDetails[$sid] = [string]$svc.Description
            }

            $runtimeParts = New-Object System.Collections.Generic.List[string]
            $startMode = Get-ServiceStartModeText -StartValue $svc.StartMode
            if (-not [string]::IsNullOrWhiteSpace($startMode)) { $runtimeParts.Add("Start: $startMode") }
            if (-not [string]::IsNullOrWhiteSpace([string]$svc.State)) { $runtimeParts.Add("State: $([string]$svc.State)") }
            if (-not [string]::IsNullOrWhiteSpace([string]$svc.ServiceType)) { $runtimeParts.Add("Type: $([string]$svc.ServiceType)") }
            if (-not [string]::IsNullOrWhiteSpace([string]$svc.StartName)) { $runtimeParts.Add("Logon: $([string]$svc.StartName)") }
            if (-not [string]::IsNullOrWhiteSpace([string]$svc.PathName)) { $runtimeParts.Add("Path: $([string]$svc.PathName)") }
            if ($runtimeParts.Count -gt 0) {
                $ServiceRuntimeDetails[$sid] = ($runtimeParts -join '; ')
            }
        }

        # Also enrich from Services registry keys so kernel drivers and non-running
        # services can display useful names/details.
        foreach ($sid in $allServiceIds) {
            $serviceId = [string]$sid
            if ([string]::IsNullOrWhiteSpace($serviceId)) { continue }

            $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceId"
            if (-not (Test-Path -LiteralPath $regPath)) { continue }

            try {
                $reg = Get-ItemProperty -LiteralPath $regPath -ErrorAction Stop
            }
            catch {
                continue
            }

            $resolvedDisplay = Resolve-MuiString -Value ([string]$reg.DisplayName)
            $resolvedDesc = Resolve-MuiString -Value ([string]$reg.Description)

            $currentLabel = if ($ServiceLabels.ContainsKey($serviceId)) { [string]$ServiceLabels[$serviceId] } else { '' }
            $fallbackLabel = Convert-ServiceIdToUiLabel -ServiceId $serviceId
            $labelLooksFallback = (
                [string]::IsNullOrWhiteSpace($currentLabel) -or
                [string]::Equals($currentLabel, $serviceId, [System.StringComparison]::OrdinalIgnoreCase) -or
                [string]::Equals($currentLabel, $fallbackLabel, [System.StringComparison]::OrdinalIgnoreCase) -or
                $currentLabel -match [regex]::Escape("($serviceId)")
            )
            if ($labelLooksFallback -and -not [string]::IsNullOrWhiteSpace($resolvedDisplay)) {
                $ServiceLabels[$serviceId] = $resolvedDisplay
            }

            $currentDetail = if ($ServiceDetails.ContainsKey($serviceId)) { [string]$ServiceDetails[$serviceId] } else { '' }
            if ([string]::IsNullOrWhiteSpace($currentDetail) -and -not [string]::IsNullOrWhiteSpace($resolvedDesc)) {
                $ServiceDetails[$serviceId] = $resolvedDesc
            }

            $runtimeParts = New-Object System.Collections.Generic.List[string]
            if ($svcRowsById.ContainsKey($serviceId)) {
                $liveSvc = $svcRowsById[$serviceId]
                $startMode = Get-ServiceStartModeText -StartValue $liveSvc.StartMode
                if (-not [string]::IsNullOrWhiteSpace($startMode)) { $runtimeParts.Add("Start: $startMode") }
                if (-not [string]::IsNullOrWhiteSpace([string]$liveSvc.State)) { $runtimeParts.Add("State: $([string]$liveSvc.State)") }
                if (-not [string]::IsNullOrWhiteSpace([string]$liveSvc.ServiceType)) { $runtimeParts.Add("Type: $([string]$liveSvc.ServiceType)") }
            }
            else {
                $startMode = Get-ServiceStartModeText -StartValue $reg.Start
                $typeName = Get-ServiceTypeText -TypeValue $reg.Type
                if (-not [string]::IsNullOrWhiteSpace($startMode)) { $runtimeParts.Add("Start: $startMode") }
                if (-not [string]::IsNullOrWhiteSpace($typeName)) { $runtimeParts.Add("Type: $typeName") }
                if (-not [string]::IsNullOrWhiteSpace([string]$reg.ImagePath)) { $runtimeParts.Add("Path: $([string]$reg.ImagePath)") }
            }
            if ($runtimeParts.Count -gt 0) {
                $ServiceRuntimeDetails[$serviceId] = ($runtimeParts -join '; ')
            }
        }
    }
}
catch {
    # Keep static label/detail maps if metadata lookup is unavailable.
}

# AutoLoggers to force-disable (backend only; intentionally not exposed in UI).
$AutoLoggersForceDisabled = @(
    'AutoLogger-Diagtrack-Listener',
    'CloudExperienceHostOobe',
    'DiagLog',
    'LwtNetLog',
    'Mellanox-Kernel',
    'Microsoft-Windows-AssignedAccess-Trace',
    'NBSMBLOGGER',
    'PEAuthLog',
    'RdrLog',
    'SetupPlatformTel',
    'SQMLogger',
    'TCPIPLOGGER',
    'TileStore',
    'WFP-IPsec Trace',
    'WiFiDriverIHVSessionRepro',
    'WMI_Traces'
)

# Extra tweaks for Windows 11 24H2+ (build >= 10.0.26100)
$ExpeditedAppsKeys = @(
    'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate',
    'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate',
    'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\MSTeamsUpdate'
)
#endregion

#region ── Color Helpers ──────────────────────────────────────────────────────
$script:ThemeMode = 'Dark'
$script:UseCustomButtonPaint = $true
$script:UseCustomPanelPaint = $false

function Convert-HexColor {
    param([Parameter(Mandatory)][string]$Hex)
    return [System.Drawing.ColorTranslator]::FromHtml($Hex)
}

$script:ThemePalettes = @{
    Dark  = @{
        MainBg            = '#0B0F14'
        CardBg            = '#121821'
        SecondaryPanel    = '#0F141B'
        TextPrimary       = '#E6EDF3'
        TextSecondary     = '#9AA7B2'
        TextDisabled      = '#5F6B76'
        AccentCyan        = '#00E5FF'
        AccentCyanHover   = '#00C8E0'
        AccentOrange      = '#FF8C42'
        AccentOrangeHover = '#E6762E'
        Border            = '#1E2630'
        Divider           = '#18202A'
        Success           = '#22C55E'
        Warning           = '#F59E0B'
        Error             = '#EF4444'
    }
    Light = @{
        MainBg            = '#F4F7FA'
        CardBg            = '#FFFFFF'
        SecondaryPanel    = '#E9EEF5'
        TextPrimary       = '#0F172A'
        TextSecondary     = '#475569'
        TextDisabled      = '#94A3B8'
        AccentCyan        = '#00B8D9'
        AccentCyanHover   = '#00A6C3'
        AccentOrange      = '#F97316'
        AccentOrangeHover = '#EA580C'
        Border            = '#D8E0EA'
        Divider           = '#E2E8F0'
        Success           = '#16A34A'
        Warning           = '#D97706'
        Error             = '#DC2626'
    }
}

function Set-ThemePalette {
    param([ValidateSet('Dark', 'Light')][string]$Mode)

    $script:ThemeMode = $Mode
    $palette = $script:ThemePalettes[$Mode]
    $shiftColor = {
        param([System.Drawing.Color]$Color, [int]$Delta)
        $r = [Math]::Max(0, [Math]::Min(255, $Color.R + $Delta))
        $g = [Math]::Max(0, [Math]::Min(255, $Color.G + $Delta))
        $b = [Math]::Max(0, [Math]::Min(255, $Color.B + $Delta))
        [System.Drawing.Color]::FromArgb($r, $g, $b)
    }

    $script:clrBg = Convert-HexColor $palette.MainBg
    $script:clrPanel = Convert-HexColor $palette.CardBg
    $script:clrPanelAlt = Convert-HexColor $palette.SecondaryPanel
    $script:clrBorder = Convert-HexColor $palette.Border
    $script:clrDivider = Convert-HexColor $palette.Divider

    $script:clrText = Convert-HexColor $palette.TextPrimary
    $script:clrMutedText = Convert-HexColor $palette.TextSecondary
    $script:clrDisabledText = Convert-HexColor $palette.TextDisabled

    $script:clrAccent = Convert-HexColor $palette.AccentCyan
    $script:clrAccentHover = Convert-HexColor $palette.AccentCyanHover
    $script:clrAccentDown = & $shiftColor $script:clrAccentHover (-18)
    if ($Mode -eq 'Dark') {
        $script:clrAccentText = Convert-HexColor '#04212A'
    }
    else {
        $script:clrAccentText = Convert-HexColor '#05242B'
    }
    $script:clrAccentSoft = Convert-HexColor $palette.AccentOrange

    $script:clrDanger = Convert-HexColor $palette.AccentOrange
    $script:clrDangerHover = Convert-HexColor $palette.AccentOrangeHover
    $script:clrDangerDown = & $shiftColor $script:clrDangerHover (-18)
    if ($Mode -eq 'Dark') {
        $script:clrDangerText = Convert-HexColor '#2B1407'
    }
    else {
        $script:clrDangerText = Convert-HexColor '#2E1607'
    }

    $script:clrSuccess = Convert-HexColor $palette.Success
    $script:clrWarning = Convert-HexColor $palette.Warning
    $script:clrError = Convert-HexColor $palette.Error

    $script:clrCyan = $script:clrAccent
    $script:clrBrowseBtn = $script:clrAccent
    $script:clrBrowseBtnHover = $script:clrAccentHover
    $script:clrBrowseBtnDown = $script:clrAccentDown
    $script:clrBrowseBorder = $script:clrBorder

    if ($Mode -eq 'Dark') {
        $script:clrNavBtn = Convert-HexColor '#141C27'
        $script:clrNavActiveBg = Convert-HexColor '#17293A'
        $script:clrInputBg = Convert-HexColor '#121A25'
        $script:clrLogBg = Convert-HexColor '#0F141B'
        $script:clrBtn = Convert-HexColor '#1A2533'
        $btnHoverDelta = 12
        $btnDownDelta = -8
    }
    else {
        $script:clrNavBtn = Convert-HexColor '#F2F6FB'
        $script:clrNavActiveBg = Convert-HexColor '#DBF4FA'
        $script:clrInputBg = Convert-HexColor '#FFFFFF'
        # Keep log pane dark in light mode for stable readability of previously written lines.
        $script:clrLogBg = Convert-HexColor '#0F141B'
        $script:clrBtn = Convert-HexColor '#F3F7FC'
        $btnHoverDelta = -8
        $btnDownDelta = -16
    }
    $script:clrLogText = Convert-HexColor '#E6EDF3'
    $script:clrLogCyan = Convert-HexColor '#22D3EE'
    $script:clrLogSuccess = Convert-HexColor '#22C55E'
    $script:clrLogWarning = Convert-HexColor '#F59E0B'
    $script:clrLogError = Convert-HexColor '#EF4444'
    $script:clrBtnHover = & $shiftColor $script:clrBtn $btnHoverDelta
    $script:clrBtnDown = & $shiftColor $script:clrBtn $btnDownDelta
    if ($Mode -eq 'Dark') {
        $script:clrNeutral = Convert-HexColor '#9BE7A8'
        $script:clrNeutralText = Convert-HexColor '#08230F'
    }
    else {
        $script:clrNeutral = Convert-HexColor '#B7EFC5'
        $script:clrNeutralText = Convert-HexColor '#0A2A12'
    }
    $script:clrNeutralHover = & $shiftColor $script:clrNeutral 10
    $script:clrNeutralDown = & $shiftColor $script:clrNeutral (-12)
}

function Get-ThemeToggleIcon {
    param([ValidateSet('Dark', 'Light')][string]$Mode)
    $size = 32
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

    if ($Mode -eq 'Dark') {
        # Crescent moon for dark mode indicator
        $penColor = $clrAccent
        $bgColor = $clrBg
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.FillEllipse((New-Object System.Drawing.SolidBrush($penColor)), 6, 6, 20, 20)
        $g.FillEllipse((New-Object System.Drawing.SolidBrush($bgColor)), 13, 6, 20, 20)
        $g.DrawEllipse((New-Object System.Drawing.Pen($penColor, 1.6)), 6, 6, 20, 20)
    }
    else {
        # Sun for light mode indicator
        $penColor = $clrDanger
        $center = New-Object System.Drawing.PointF(16, 16)
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.FillEllipse((New-Object System.Drawing.SolidBrush($penColor)), 9, 9, 14, 14)
        $pen = New-Object System.Drawing.Pen($penColor, 2.0)
        for ($i = 0; $i -lt 8; $i++) {
            $angle = ($i * 45) * [Math]::PI / 180
            $sx = $center.X + [Math]::Cos($angle) * 12
            $sy = $center.Y + [Math]::Sin($angle) * 12
            $ex = $center.X + [Math]::Cos($angle) * 16
            $ey = $center.Y + [Math]::Sin($angle) * 16
            $g.DrawLine($pen, $sx, $sy, $ex, $ey)
        }
        $pen.Dispose()
    }

    $g.Dispose()
    return $bmp
}

function Get-SettingsIcon {
    param([ValidateSet('Dark', 'Light')][string]$Mode)
    $size = 32
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $stroke = if ($Mode -eq 'Dark') { $clrText } else { $clrMutedText }
    $pen = New-Object System.Drawing.Pen($stroke, 2.0)
    $g.Clear([System.Drawing.Color]::Transparent)
    $cx = 16; $cy = 16; $rOuter = 11; $rInner = 4
    for ($i = 0; $i -lt 8; $i++) {
        $angle = ($i * 45) * [Math]::PI / 180
        $sx = $cx + [Math]::Cos($angle) * ($rOuter - 3)
        $sy = $cy + [Math]::Sin($angle) * ($rOuter - 3)
        $ex = $cx + [Math]::Cos($angle) * ($rOuter + 2.5)
        $ey = $cy + [Math]::Sin($angle) * ($rOuter + 2.5)
        $g.DrawLine($pen, $sx, $sy, $ex, $ey)
    }
    $g.DrawEllipse($pen, $cx - $rOuter, $cy - $rOuter, $rOuter * 2, $rOuter * 2)
    $g.FillEllipse((New-Object System.Drawing.SolidBrush($stroke)), $cx - $rInner, $cy - $rInner, $rInner * 2, $rInner * 2)
    $pen.Dispose(); $g.Dispose()
    return $bmp
}

function New-RoundedRectPath {
    param([System.Drawing.RectangleF]$Rect, [float]$Radius)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($Radius -le 0) {
        $path.AddRectangle($Rect)
        return $path
    }
    $d = $Radius * 2
    $path.AddArc($Rect.X, $Rect.Y, $d, $d, 180, 90)
    $path.AddArc($Rect.Right - $d, $Rect.Y, $d, $d, 270, 90)
    $path.AddArc($Rect.Right - $d, $Rect.Bottom - $d, $d, $d, 0, 90)
    $path.AddArc($Rect.X, $Rect.Bottom - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    return $path
}

function Get-ShiftedColor {
    param([System.Drawing.Color]$Color, [int]$Delta)
    $r = [Math]::Max(0, [Math]::Min(255, $Color.R + $Delta))
    $g = [Math]::Max(0, [Math]::Min(255, $Color.G + $Delta))
    $b = [Math]::Max(0, [Math]::Min(255, $Color.B + $Delta))
    [System.Drawing.Color]::FromArgb($r, $g, $b)
}

Set-ThemePalette -Mode 'Dark'

$script:CachedUiFontFamily = $null
function New-UiFont {
    param(
        [float]$Size = 10,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular
    )
    if ($null -eq $script:CachedUiFontFamily) {
        $candidates = @('Segoe UI', 'Segoe UI Semibold', 'Bahnschrift')
        foreach ($name in $candidates) {
            try { $t = New-Object System.Drawing.Font($name, 9); $script:CachedUiFontFamily = $name; $t.Dispose(); break } catch {}
        }
        if ($null -eq $script:CachedUiFontFamily) { $script:CachedUiFontFamily = [System.Drawing.SystemFonts]::MessageBoxFont.FontFamily.Name }
    }
    return New-Object System.Drawing.Font($script:CachedUiFontFamily, $Size, $Style)
}

function Set-ModernPanelPaint {
    param(
        [System.Windows.Forms.Control]$Control,
        [bool]$ShowAccentLine = $true
    )
    if ($null -eq $Control) { return }
    if (-not $script:UseCustomPanelPaint) { return }
    $showAccent = $ShowAccentLine
    $Control.Add_Paint({
            param($sender, $e)
            $r = $sender.ClientRectangle
            if ($r.Width -le 0 -or $r.Height -le 0) { return }
            $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $rectF = New-Object System.Drawing.RectangleF(0.5, 0.5, ($r.Width - 1.5), ($r.Height - 1.5))
            $path = New-RoundedRectPath -Rect $rectF -Radius 8
            $borderPen = New-Object System.Drawing.Pen($clrBorder, 1)
            $dividerPen = New-Object System.Drawing.Pen($clrDivider, 1)
            $accentGlow = [System.Drawing.Color]::FromArgb(78, $clrAccent.R, $clrAccent.G, $clrAccent.B)
            $accentPen = New-Object System.Drawing.Pen($accentGlow, 1)
            try {
                $e.Graphics.DrawPath($borderPen, $path)
                $e.Graphics.DrawLine($dividerPen, 8, 1, [Math]::Max(8, $r.Width - 8), 1)
                if ($showAccent) {
                    $e.Graphics.DrawLine($accentPen, 10, 2, [Math]::Min(170, [Math]::Max(10, $r.Width - 10)), 2)
                }
            }
            finally {
                if ($path) { $path.Dispose() }
                if ($borderPen) { $borderPen.Dispose() }
                if ($dividerPen) { $dividerPen.Dispose() }
                if ($accentPen) { $accentPen.Dispose() }
            }
        })
}

function Enable-ControlDoubleBuffer {
    param(
        [System.Windows.Forms.Control]$Control,
        [switch]$Recursive
    )
    if ($null -eq $Control) { return }
    try {
        $typeName = $Control.GetType().FullName
        $isBufferCandidate = (
            $typeName -like 'System.Windows.Forms.Form' -or
            $typeName -like 'System.Windows.Forms.Panel' -or
            $typeName -like 'System.Windows.Forms.FlowLayoutPanel' -or
            $typeName -like 'System.Windows.Forms.TabControl' -or
            $typeName -like 'System.Windows.Forms.TabPage'
        )
        if ($isBufferCandidate) {
            $doubleBufferedProp = $Control.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'NonPublic,Instance')
            if ($doubleBufferedProp) {
                $doubleBufferedProp.SetValue($Control, $true, $null)
            }
            # Suppress WM_ERASEBKGND on containers to prevent white-flash artifacts
            $setStyleMethod = $Control.GetType().GetMethod('SetStyle', [System.Reflection.BindingFlags]'NonPublic,Instance')
            if ($setStyleMethod) {
                $flags = [System.Windows.Forms.ControlStyles]::AllPaintingInWmPaint -bor [System.Windows.Forms.ControlStyles]::OptimizedDoubleBuffer
                $setStyleMethod.Invoke($Control, @($flags, $true))
            }
        }
    }
    catch {}

    if ($Recursive) {
        foreach ($child in @($Control.Controls)) {
            Enable-ControlDoubleBuffer -Control $child -Recursive
        }
    }
}

function Set-ProjectIconFromPng {
    param(
        [System.Windows.Forms.Form]$TargetForm,
        [string]$PngPath
    )
    if ($null -eq $TargetForm -or [string]::IsNullOrWhiteSpace($PngPath)) { return }
    if (-not (Test-Path -LiteralPath $PngPath)) { return }
    try {
        $bmp = [System.Drawing.Bitmap]::FromFile($PngPath)
        $hIcon = $bmp.GetHicon()
        $tmpIcon = [System.Drawing.Icon]::FromHandle($hIcon)
        $iconClone = [System.Drawing.Icon]$tmpIcon.Clone()
        $TargetForm.Icon = $iconClone
        $tmpIcon.Dispose()
        [void][NativeIcons]::DestroyIcon($hIcon)
        $bmp.Dispose()
    }
    catch {}
}
function Get-ProjectIconPath {
    param([string]$RootPath)
    if ([string]::IsNullOrWhiteSpace($RootPath)) { return $null }
    $names = @(
        'OximizeOS.png',
        'OximizeOS.ico',
        'oximizeos.png',
        'oximizeos.ico',
        'project-icon.png',
        'project-icon.ico',
        'icon.png',
        'icon.ico',
        'oximize.png',
        'oximize.ico',
        'logo.png',
        'logo.jpg',
        'logo.jpeg'
    )
    $folders = @('', 'image', 'assets', 'images', 'img', 'branding')
    foreach ($folder in $folders) {
        foreach ($name in $names) {
            $relative = if ([string]::IsNullOrWhiteSpace($folder)) { $name } else { Join-Path $folder $name }
            $fullPath = Join-Path $RootPath $relative
            if (Test-Path -LiteralPath $fullPath -PathType Leaf) { return $fullPath }
        }
    }
    return $null
}

function Get-DefaultOutputIsoName {
    param([string]$SourceIsoPath)

    $baseName = 'OximizeOS_Custom'
    if (-not [string]::IsNullOrWhiteSpace($SourceIsoPath)) {
        try {
            $candidate = [System.IO.Path]::GetFileNameWithoutExtension($SourceIsoPath)
            if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                $baseName = $candidate
            }
        }
        catch {}
    }

    return '{0}_Oximize.iso' -f $baseName
}

function Resolve-OutputIsoPath {
    param(
        [string]$CandidatePath,
        [string]$SourceIsoPath
    )

    if ([string]::IsNullOrWhiteSpace($CandidatePath)) { return '' }

    $resolvedPath = [Environment]::ExpandEnvironmentVariables($CandidatePath.Trim().Trim('"'))
    $defaultName = Get-DefaultOutputIsoName -SourceIsoPath $SourceIsoPath
    $treatAsDirectory = $false

    if ($resolvedPath.EndsWith('\') -or $resolvedPath.EndsWith('/')) {
        $treatAsDirectory = $true
    }
    elseif (Test-Path -LiteralPath $resolvedPath -PathType Container) {
        $treatAsDirectory = $true
    }

    if ($treatAsDirectory) {
        $resolvedPath = Join-Path $resolvedPath $defaultName
    }
    elseif ([string]::IsNullOrWhiteSpace([System.IO.Path]::GetExtension($resolvedPath))) {
        $resolvedPath = '{0}.iso' -f $resolvedPath
    }

    try { return [System.IO.Path]::GetFullPath($resolvedPath) } catch { return $resolvedPath }
}

function Ensure-ParentDirectory {
    param([string]$FilePath)

    if ([string]::IsNullOrWhiteSpace($FilePath)) { return }

    $parentDir = Split-Path -Parent $FilePath
    if ([string]::IsNullOrWhiteSpace($parentDir)) { return }
    if (Test-Path -LiteralPath $parentDir -PathType Container) { return }

    New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
}

function Test-ScratchDirectorySafety {
    param(
        [string]$ScratchPath,
        [string]$MarkerFileName = '.oximize_scratch.marker'
    )

    if ([string]::IsNullOrWhiteSpace($MarkerFileName)) {
        $MarkerFileName = '.oximize_scratch.marker'
    }
    if ([string]::IsNullOrWhiteSpace($ScratchPath)) {
        return [pscustomobject]@{
            IsValid    = $false
            Path       = ''
            MarkerPath = ''
            Reason     = 'TempBuildDirectory cannot be empty.'
        }
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($ScratchPath.Trim().Trim('"'))
    try {
        $fullPath = [System.IO.Path]::GetFullPath($expanded)
    }
    catch {
        return [pscustomobject]@{
            IsValid    = $false
            Path       = $expanded
            MarkerPath = ''
            Reason     = 'TempBuildDirectory is not a valid filesystem path.'
        }
    }

    $pathNorm = $fullPath.TrimEnd('\')
    $rootPath = [System.IO.Path]::GetPathRoot($fullPath)
    $rootNorm = if ([string]::IsNullOrWhiteSpace($rootPath)) { '' } else { $rootPath.TrimEnd('\') }
    if ([string]::IsNullOrWhiteSpace($rootNorm) -or
        [string]::Equals($pathNorm, $rootNorm, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{
            IsValid    = $false
            Path       = $fullPath
            MarkerPath = ''
            Reason     = 'TempBuildDirectory cannot be a drive root.'
        }
    }

    $protectedExact = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in @(
            $env:windir,
            $env:SystemRoot,
            [Environment]::GetFolderPath('ProgramFiles'),
            [Environment]::GetFolderPath('ProgramFilesX86'),
            (Join-Path $env:SystemDrive 'Users'),
            $env:USERPROFILE,
            $env:PUBLIC,
            ([System.IO.Path]::GetTempPath()).TrimEnd('\')
        )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
            [void]$protectedExact.Add(([string]$candidate).TrimEnd('\'))
        }
    }
    if ($protectedExact.Contains($pathNorm)) {
        return [pscustomobject]@{
            IsValid    = $false
            Path       = $fullPath
            MarkerPath = ''
            Reason     = "TempBuildDirectory cannot be a protected system/user folder ($fullPath)."
        }
    }

    if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
        return [pscustomobject]@{
            IsValid    = $false
            Path       = $fullPath
            MarkerPath = ''
            Reason     = 'TempBuildDirectory points to a file, not a folder.'
        }
    }

    $markerPath = Join-Path $fullPath $MarkerFileName
    if (Test-Path -LiteralPath $fullPath -PathType Container) {
        $hasMarker = Test-Path -LiteralPath $markerPath -PathType Leaf
        $entries = @(Get-ChildItem -LiteralPath $fullPath -Force -ErrorAction SilentlyContinue)
        if (-not $hasMarker -and $entries.Count -gt 0) {
            return [pscustomobject]@{
                IsValid    = $false
                Path       = $fullPath
                MarkerPath = $markerPath
                Reason     = 'TempBuildDirectory must be empty or previously created by Oximize OS.'
            }
        }
    }

    return [pscustomobject]@{
        IsValid    = $true
        Path       = $fullPath
        MarkerPath = $markerPath
        Reason     = ''
    }
}

function New-DarkLabel {
    param([string]$Text, [int]$Width = 90, [int]$Height = 22)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text
    $lbl.ForeColor = $clrText
    $lbl.BackColor = [System.Drawing.Color]::Transparent
    $lbl.AutoSize = $false
    $lbl.Width = $Width
    $lbl.Height = $Height
    $lbl.AutoEllipsis = $true
    $lbl.TextAlign = 'MiddleLeft'
    $lbl.Font = New-UiFont -Size 9.5
    return $lbl
}

function New-DarkTextBox {
    param([string]$Text = '', [int]$Width = 360, [bool]$ReadOnly = $false, [bool]$Masked = $false)

    $pnl = New-Object System.Windows.Forms.Panel
    $pnl.Width = $Width
    $pnl.Height = 34
    $pnl.BackColor = $clrInputBg
    $pnl.Padding = New-Object System.Windows.Forms.Padding(10, 6, 10, 6)

    if ($Masked) {
        $tb = New-Object System.Windows.Forms.MaskedTextBox
        $tb.PasswordChar = [char]0x2022
    }
    else {
        $tb = New-Object System.Windows.Forms.TextBox
    }
    $tb.Text = $Text
    $tb.ReadOnly = $ReadOnly
    $tb.Dock = 'Fill'
    $tb.BackColor = $clrInputBg
    $tb.ForeColor = $clrText
    $tb.BorderStyle = 'None'
    $tb.Font = New-UiFont -Size 9.5

    $pnl.Controls.Add($tb)

    $pnl.Add_Paint({
            param($sender, $e)
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $pen = New-Object System.Drawing.Pen($clrBorder, 1.5)
            try {
                $rectF = New-Object System.Drawing.RectangleF(0.5, 0.5, ($sender.Width - 1.5), ($sender.Height - 1.5))
                $path = New-RoundedRectPath -Rect $rectF -Radius 8
                try {
                    $g.DrawPath($pen, $path)
                }
                finally {
                    if ($path) { $path.Dispose() }
                }
            }
            finally {
                if ($pen) { $pen.Dispose() }
            }
        })

    return [pscustomobject]@{
        Panel   = $pnl
        TextBox = $tb
    }
}

function Format-UiByteSize {
    param([Int64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Get-PathRowInfoText {
    param(
        [string]$PathValue,
        [ValidateSet('File', 'Folder', 'Output')]
        [string]$Mode = 'File'
    )

    $value = [string]$PathValue
    if ([string]::IsNullOrWhiteSpace($value)) {
        switch ($Mode) {
            'File' { return 'No file selected.' }
            'Folder' { return 'Folder path not set.' }
            'Output' { return 'Choose an output folder or ISO file path.' }
        }
    }

    switch ($Mode) {
        'File' {
            if (Test-Path -LiteralPath $value -PathType Leaf) {
                try {
                    return "File size: $(Format-UiByteSize -Bytes ([System.IO.FileInfo](Get-Item -LiteralPath $value)).Length)"
                }
                catch {
                    return 'File selected.'
                }
            }
            return 'File path entered.'
        }
        'Folder' {
            if (Test-Path -LiteralPath $value -PathType Container) {
                return 'Folder ready.'
            }
            return 'Folder will be created when needed.'
        }
        'Output' {
            if (Test-Path -LiteralPath $value -PathType Leaf) {
                try {
                    return "Existing ISO: $(Format-UiByteSize -Bytes ([System.IO.FileInfo](Get-Item -LiteralPath $value)).Length)"
                }
                catch {
                    return 'Output ISO file selected.'
                }
            }
            if (Test-Path -LiteralPath $value -PathType Container) {
                return 'Output folder selected.'
            }

            $ext = [System.IO.Path]::GetExtension($value)
            if (-not [string]::IsNullOrWhiteSpace($ext) -and $ext.ToLowerInvariant() -eq '.iso') {
                return 'Custom ISO file path selected.'
            }
            return 'Output folder path selected.'
        }
    }
}

function New-CompactPathRow {
    param(
        [string]$LabelText,
        [string]$DefaultText = '',
        [bool]$ReadOnly = $false,
        [ValidateSet('File', 'Folder', 'Output')][string]$InfoMode = 'File',
        [string]$CueText = '',
        [int]$Top = 0,
        [System.Windows.Forms.Panel]$Parent
    )

    $rowHeight = 60
    $rowPanel = New-Object System.Windows.Forms.Panel
    $rowPanel.Left = 8
    $rowPanel.Top = $Top
    $rowPanel.Width = [Math]::Max(360, $Parent.ClientSize.Width - 16)
    $rowPanel.Height = $rowHeight
    $rowPanel.BackColor = $Parent.BackColor
    $rowPanel.Anchor = 'Top, Left, Right'
    $rowPanel.Tag = 'PathRowPanel'

    # Label
    $lbl = New-DarkLabel -Text $LabelText -Width 300 -Height 20
    $lbl.Left = 2; $lbl.Top = 0
    $lbl.Font = New-UiFont -Size 9.5 -Style ([System.Drawing.FontStyle]::Bold)
    $rowPanel.Controls.Add($lbl)

    # Input Container
    $buttonWidth = 96
    $gap = 10
    $inputHeight = 34
    $inputTop = 24

    $txtObj = New-DarkTextBox -Text $DefaultText -Width 100 -ReadOnly $ReadOnly
    $tb = $txtObj.TextBox
    $txtPanel = $txtObj.Panel
    $txtPanel.Left = 0; $txtPanel.Top = $inputTop
    $txtPanel.Height = $inputHeight
    $txtPanel.AutoSize = $false
    $txtPanel.Anchor = 'Top, Left, Right'
    $txtPanel.Margin = New-Object System.Windows.Forms.Padding(0)

    if (-not [string]::IsNullOrWhiteSpace($CueText)) {
        Initialize-PathTextBoxPlaceholder -Control $tb -PlaceholderText $CueText
    }

    $btn = New-DarkButton -Text 'Browse' -Width $buttonWidth -Height $inputHeight -BgColor $clrBrowseBtn -Role 'Browse'
    $btn.Top = $inputTop
    $btn.Left = [Math]::Max(0, $rowPanel.Width - $buttonWidth)
    $btn.Anchor = 'Top, Right'

    $layoutRow = {
        $rowPanel.Width = [Math]::Max(360, $Parent.ClientSize.Width - 16)
        $btn.Left = [Math]::Max(0, $rowPanel.ClientSize.Width - $buttonWidth)
        $txtPanel.Width = [Math]::Max(100, $btn.Left - $gap)
    }.GetNewClosure()

    $rowPanel.Add_Resize($layoutRow)
    $rowPanel.Controls.Add($txtPanel)
    $rowPanel.Controls.Add($btn)
    & $layoutRow
    $Parent.Controls.Add($rowPanel)

    return [pscustomobject]@{
        TextBox = $tb
        Button  = $btn
        Panel   = $rowPanel
    }
}

function New-DarkButton {
    param(
        [string]$Text,
        [int]$Width = 90,
        [int]$Height = 34,
        [System.Drawing.Color]$BgColor,
        [string]$Role = 'Normal'
    )
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    $btn.Width = $Width
    $btn.Height = $Height
    $btn.FlatStyle = 'Flat'
    $btn.FlatAppearance.BorderSize = 0
    if ($BgColor) {
        $btn.FlatAppearance.MouseOverBackColor = $BgColor
    }
    $btn.UseVisualStyleBackColor = $false
    $btn.UseMnemonic = $false
    $btn.Cursor = 'Hand'
    $btn.Font = New-UiFont -Size 9.5 -Style ([System.Drawing.FontStyle]::Bold)
    $btn.TextAlign = 'MiddleCenter'
    $btn.BackColor = $clrBtn
    $btn.ForeColor = $clrText
    $btn.FlatAppearance.BorderSize = 1

    if ($Role -eq 'Normal' -and $BgColor) {
        if ($BgColor.ToArgb() -eq $clrAccent.ToArgb()) { $Role = 'Accent' }
        elseif ($BgColor.ToArgb() -eq $clrDanger.ToArgb()) { $Role = 'Danger' }
        elseif ($BgColor.ToArgb() -eq $clrPanel.ToArgb()) { $Role = 'Nav' }
    }

    $btn.Tag = @{ State = 'Normal'; Role = $Role }

    if (-not $script:UseCustomButtonPaint) {
        $btn.FlatAppearance.BorderSize = 1
        $btn.UseVisualStyleBackColor = $false
        $btn.Add_MouseEnter({ $this.Tag.State = 'Hover'; Set-ButtonVisualStyle -Button $this })
        $btn.Add_MouseLeave({ $this.Tag.State = 'Normal'; Set-ButtonVisualStyle -Button $this })
        $btn.Add_MouseDown({ $this.Tag.State = 'Down'; Set-ButtonVisualStyle -Button $this })
        $btn.Add_MouseUp({ $this.Tag.State = 'Hover'; Set-ButtonVisualStyle -Button $this })
        $btn.Add_EnabledChanged({ Set-ButtonVisualStyle -Button $this })
        Set-ButtonVisualStyle -Button $btn
        return $btn
    }

    $btn.Add_Paint({
            param($sender, $e)
            if ($null -eq $sender -or $sender.IsDisposed) { return }
            if ($sender.Width -le 0 -or $sender.Height -le 0) { return }
            try {
                $g = $e.Graphics
                $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
                $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

                $rawParentBack = if ($null -ne $sender.Parent -and -not $sender.Parent.IsDisposed) { $sender.Parent.BackColor } else { $script:clrBg }
                # Guard against default white/gray parent color during intermediate repaints
                $parentBack = if ($rawParentBack.GetBrightness() -gt 0.85 -and $script:ThemeMode -eq 'Dark') { $script:clrBg } else { $rawParentBack }
                $g.Clear($parentBack)

                $tagData = if ($sender.Tag -is [hashtable]) { $sender.Tag } else { @{ Role = 'Normal'; State = 'Normal' } }
                $role = [string]$tagData.Role
                if ([string]::IsNullOrWhiteSpace($role)) { $role = 'Normal' }
                $state = [string]$tagData.State
                if ([string]::IsNullOrWhiteSpace($state)) { $state = 'Normal' }

                $currentBgColor = switch ($role) {
                    'Accent' { $clrAccent }
                    'Danger' { $clrDanger }
                    'Neutral' { $clrNeutral }
                    'Browse' { $clrBrowseBtn }
                    'NavActive' { $clrNavActiveBg }
                    'PresetActive' { $clrNavActiveBg }
                    'Nav' { $clrNavBtn }
                    'Icon' { $parentBack }
                    'Cyan' { $clrCyan }
                    default { $clrBtn }
                }
                $currentFgColor = switch ($role) {
                    'Accent' { $clrAccentText }
                    'Danger' { $clrDangerText }
                    'Neutral' { $clrNeutralText }
                    'Browse' { [System.Drawing.Color]::Black }
                    'NavActive' { $clrAccent }
                    'PresetActive' { $clrText }
                    'Cyan' { $clrAccentText }
                    'Icon' { $clrMutedText }
                    default { $clrText }
                }
                $isDisabled = -not $sender.Enabled
                if ($isDisabled) {
                    $disabledDelta = if ($script:ThemeMode -eq 'Dark') { -8 } else { -4 }
                    $currentBgColor = Get-ShiftedColor -Color $currentBgColor -Delta $disabledDelta
                    $currentFgColor = $clrDisabledText
                }

                $hoverBgColor = switch ($role) {
                    'Accent' { $clrAccentHover }
                    'Danger' { $clrDangerHover }
                    'Neutral' { $clrNeutralHover }
                    'Browse' { $clrBrowseBtnHover }
                    'Nav' { Get-ShiftedColor -Color $clrNavBtn -Delta 10 }
                    'NavActive' { $clrNavActiveBg }
                    'PresetActive' { $clrNavActiveBg }
                    'Icon' { Get-ShiftedColor -Color $parentBack -Delta 10 }
                    'Cyan' { $clrAccentHover }
                    default { $clrBtnHover }
                }
                $downBgColor = switch ($role) {
                    'Accent' { $clrAccentDown }
                    'Danger' { $clrDangerDown }
                    'Neutral' { $clrNeutralDown }
                    'Browse' { $clrBrowseBtnDown }
                    'Nav' { Get-ShiftedColor -Color $clrNavBtn -Delta -8 }
                    'NavActive' { Get-ShiftedColor -Color $clrNavActiveBg -Delta -8 }
                    'PresetActive' { Get-ShiftedColor -Color $clrNavActiveBg -Delta -8 }
                    'Icon' { Get-ShiftedColor -Color $parentBack -Delta -8 }
                    'Cyan' { $clrAccentDown }
                    default { $clrBtnDown }
                }

                if (-not $isDisabled) {
                    if ($state -eq 'Hover') { $currentBgColor = $hoverBgColor }
                    elseif ($state -eq 'Down') { $currentBgColor = $downBgColor }
                }

                $rectF = New-Object System.Drawing.RectangleF(0.5, 0.5, ($sender.Width - 1.5), ($sender.Height - 1.5))
                $radius = if ($role -eq 'Icon') { 10 } else { 8 }
                $path = New-RoundedRectPath -Rect $rectF -Radius $radius
                try {
                    $brush = New-Object System.Drawing.SolidBrush($currentBgColor)
                    try {
                        $g.FillPath($brush, $path)
                    }
                    finally {
                        if ($brush) { $brush.Dispose() }
                    }

                    $borderColor = if ($isDisabled) {
                        $clrDivider
                    }
                    else {
                        switch ($role) {
                            'NavActive' { $clrAccent }
                            'PresetActive' { $clrAccent }
                            'Accent' { Get-ShiftedColor -Color $clrAccent -Delta -38 }
                            'Danger' { Get-ShiftedColor -Color $clrDanger -Delta -30 }
                            'Neutral' { Get-ShiftedColor -Color $clrNeutral -Delta -34 }
                            default { $clrBorder }
                        }
                    }
                    $borderWidth = if ($role -in @('NavActive', 'PresetActive')) { 1.4 } else { 1.0 }
                    $borderPen = New-Object System.Drawing.Pen($borderColor, $borderWidth)
                    try {
                        $g.DrawPath($borderPen, $path)
                    }
                    finally {
                        if ($borderPen) { $borderPen.Dispose() }
                    }
                }
                finally {
                    if ($path) { $path.Dispose() }
                }

                if ($null -ne $sender.Image) {
                    $img = $sender.Image
                    $x = ($sender.Width - $img.Width) / 2
                    $y = ($sender.Height - $img.Height) / 2
                    if ($sender.ImageAlign -eq 'MiddleLeft') {
                        $x = if ($sender.Padding.Left -gt 0) { $sender.Padding.Left } else { 6 }
                    }
                    $g.DrawImage($img, [int]$x, [int]$y, $img.Width, $img.Height)
                }

                $tf = [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::WordEllipsis -bor [System.Windows.Forms.TextFormatFlags]::NoPadding
                $textRect = $sender.ClientRectangle
                if ($sender.TextAlign -eq 'MiddleLeft') {
                    $tf = $tf -bor [System.Windows.Forms.TextFormatFlags]::Left
                    $textRect.X += 8; $textRect.Width -= 8
                }
                else {
                    $tf = $tf -bor [System.Windows.Forms.TextFormatFlags]::HorizontalCenter
                }

                [System.Windows.Forms.TextRenderer]::DrawText($g, $sender.Text, $sender.Font, $textRect, $currentFgColor, $tf)
            }
            catch {
                try { Set-ButtonVisualStyle -Button $sender } catch {}
            }
        })

    $btn.Add_MouseEnter({ $this.Tag.State = 'Hover'; $this.Invalidate() })
    $btn.Add_MouseLeave({ $this.Tag.State = 'Normal'; $this.Invalidate() })
    $btn.Add_MouseDown({ $this.Tag.State = 'Down'; $this.Invalidate() })
    $btn.Add_MouseUp({ $this.Tag.State = 'Hover'; $this.Invalidate() })
    $btn.Add_EnabledChanged({ $this.Invalidate() })
    $btn.Add_TextChanged({ $this.Invalidate() })
    $btn.Add_VisibleChanged({
            if ($this.Visible) { $this.Invalidate() }
        })

    Set-ButtonVisualStyle -Button $btn

    return $btn
}

function Set-ButtonVisualStyle {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Button]$Button
    )
    if ($null -eq $Button) { return }

    $tagData = if ($Button.Tag -is [hashtable]) { $Button.Tag } else { @{ State = 'Normal'; Role = 'Normal' } }
    $role = [string]$tagData.Role
    $state = [string]$tagData.State

    $baseBg = switch ($role) {
        'Accent' { $clrAccent }
        'Danger' { $clrDanger }
        'Neutral' { $clrNeutral }
        'Browse' { $clrBrowseBtn }
        'NavActive' { $clrNavActiveBg }
        'PresetActive' { $clrNavActiveBg }
        'Nav' { $clrNavBtn }
        'Icon' { if ($Button.Parent) { $Button.Parent.BackColor } else { $clrPanel } }
        'Cyan' { $clrCyan }
        default { $clrBtn }
    }
    $baseFg = switch ($role) {
        'Accent' { $clrAccentText }
        'Danger' { $clrDangerText }
        'Neutral' { $clrNeutralText }
        'Browse' { [System.Drawing.Color]::Black }
        'NavActive' { $clrAccent }
        'PresetActive' { $clrText }
        'Cyan' { $clrAccentText }
        'Icon' { $clrMutedText }
        default { $clrText }
    }
    $hoverBg = switch ($role) {
        'Accent' { $clrAccentHover }
        'Danger' { $clrDangerHover }
        'Neutral' { $clrNeutralHover }
        'Browse' { $clrBrowseBtnHover }
        'Nav' { Get-ShiftedColor -Color $clrNavBtn -Delta 10 }
        'NavActive' { $clrNavActiveBg }
        'PresetActive' { $clrNavActiveBg }
        'Icon' { Get-ShiftedColor -Color $baseBg -Delta 10 }
        'Cyan' { $clrAccentHover }
        default { $clrBtnHover }
    }
    $downBg = switch ($role) {
        'Accent' { $clrAccentDown }
        'Danger' { $clrDangerDown }
        'Neutral' { $clrNeutralDown }
        'Browse' { $clrBrowseBtnDown }
        'Nav' { Get-ShiftedColor -Color $clrNavBtn -Delta -8 }
        'NavActive' { Get-ShiftedColor -Color $clrNavActiveBg -Delta -8 }
        'PresetActive' { Get-ShiftedColor -Color $clrNavActiveBg -Delta -8 }
        'Icon' { Get-ShiftedColor -Color $baseBg -Delta -8 }
        'Cyan' { $clrAccentDown }
        default { $clrBtnDown }
    }

    $isDisabled = -not $Button.Enabled
    $bg = $baseBg
    $fg = $baseFg
    if (-not $isDisabled) {
        if ($state -eq 'Hover') { $bg = $hoverBg }
        elseif ($state -eq 'Down') { $bg = $downBg }
    }
    else {
        $disabledDelta = if ($script:ThemeMode -eq 'Dark') { -8 } else { -4 }
        $bg = Get-ShiftedColor -Color $baseBg -Delta $disabledDelta
        $fg = $clrDisabledText
    }

    $borderColor = if ($isDisabled) {
        $clrDivider
    }
    else {
        switch ($role) {
            'NavActive' { $clrAccent }
            'PresetActive' { $clrAccent }
            'Accent' { Get-ShiftedColor -Color $clrAccent -Delta -38 }
            'Danger' { Get-ShiftedColor -Color $clrDanger -Delta -30 }
            'Neutral' { Get-ShiftedColor -Color $clrNeutral -Delta -34 }
            default { $clrBorder }
        }
    }

    $Button.UseVisualStyleBackColor = $false
    $Button.BackColor = $bg
    $Button.ForeColor = $fg
    $Button.FlatAppearance.BorderColor = $borderColor
    $Button.FlatAppearance.MouseOverBackColor = $hoverBg
    $Button.FlatAppearance.MouseDownBackColor = $downBg
    $Button.Invalidate()
}

function Set-ButtonRole {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Button]$Button,
        [Parameter(Mandatory)][string]$Role
    )
    $needsInvalidate = $true
    if ($null -eq $Button.Tag -or -not ($Button.Tag -is [hashtable])) {
        $Button.Tag = @{ State = 'Normal'; Role = $Role }
    }
    else {
        if ($Button.Tag.Role -eq $Role -and $Button.Tag.State -eq 'Normal') {
            $needsInvalidate = $false
        }
        $Button.Tag.Role = $Role
        $Button.Tag.State = 'Normal'
    }
    if ($needsInvalidate) {
        if (-not $script:UseCustomButtonPaint) {
            Set-ButtonVisualStyle -Button $Button
        }
        else {
            $Button.Invalidate()
        }
    }
}

function New-DarkCheckBox {
    param([string]$Text, [bool]$Checked = $false)
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text = $Text
    $cb.Checked = $Checked
    $cb.ForeColor = $clrText
    $cb.BackColor = [System.Drawing.Color]::Transparent
    $cb.UseVisualStyleBackColor = $false
    # Standard style keeps checkmark glyph legible across light/dark themes.
    $cb.FlatStyle = 'Standard'
    $cb.AutoSize = $true
    $cb.Font = New-UiFont -Size 9.5 -Style ([System.Drawing.FontStyle]::Regular)
    return $cb
}

function New-DarkComboBox {
    param(
        [string[]]$Items,
        [string]$Text,
        [int]$Width = 120
    )
    $cb = New-Object System.Windows.Forms.ComboBox
    $cb.Width = $Width
    $cb.DropDownStyle = 'DropDownList'
    $cb.FlatStyle = 'Flat'
    $cb.BackColor = $script:clrInputBg
    $cb.ForeColor = $script:clrText
    $cb.Font = New-UiFont -Size 9.5
    if ($Items) { $cb.Items.AddRange($Items) }
    if ($Text -and $cb.Items.Contains($Text)) { $cb.SelectedItem = $Text }
    elseif ($cb.Items.Count -gt 0) { $cb.SelectedIndex = 0 }
    return $cb
}
#endregion

#region ── Write-Log Helper ───────────────────────────────────────────────────
# Per-session persistent log file (includes UI and backend changes/errors).
$script:ResolvedScriptDirectory = ''
if (-not [string]::IsNullOrWhiteSpace([string]$scriptPath)) {
    try {
        $script:ResolvedScriptDirectory = Split-Path -LiteralPath $scriptPath -Parent
    }
    catch {}
}
if ([string]::IsNullOrWhiteSpace($script:ResolvedScriptDirectory)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$PSScriptRoot)) {
        $script:ResolvedScriptDirectory = $PSScriptRoot
    }
    else {
        $script:ResolvedScriptDirectory = (Get-Location).Path
    }
}
$script:IsBootstrapTempRun = $false
$script:IsTempScriptRun = $false
if (-not [string]::IsNullOrWhiteSpace([string]$scriptPath)) {
    try {
        $scriptFileName = [System.IO.Path]::GetFileName([string]$scriptPath)
        $scriptFullPath = [System.IO.Path]::GetFullPath([string]$scriptPath)
        $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        $isUnderTemp = $scriptFullPath.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)
        if ($isUnderTemp) {
            $script:IsTempScriptRun = $true
        }
        if ($isUnderTemp -and $scriptFileName -match '^(?i)OximizeOS_bootstrap_.*\.ps1$') {
            $script:IsBootstrapTempRun = $true
        }
    }
    catch {}
}

# Preferred log directory can be forced by launcher via env var.
$script:SessionLogDirectory = ''
$envLogDir = [string]$env:OXIMIZE_LOG_DIR
if (-not [string]::IsNullOrWhiteSpace($envLogDir)) {
    try {
        $expandedLogDir = [Environment]::ExpandEnvironmentVariables($envLogDir)
        if (-not [string]::IsNullOrWhiteSpace([string]$expandedLogDir)) {
            $script:SessionLogDirectory = [System.IO.Path]::GetFullPath($expandedLogDir)
        }
    }
    catch {}
}

# If script runs from TEMP or via irm|iex (no script file path), default logs to Documents.
$script:IsInMemoryRun = [string]::IsNullOrWhiteSpace([string]$scriptPath) -and [string]::IsNullOrWhiteSpace([string]$PSScriptRoot)
if ([string]::IsNullOrWhiteSpace($script:SessionLogDirectory) -and ($script:IsBootstrapTempRun -or $script:IsTempScriptRun -or $script:IsInMemoryRun)) {
    $documentsPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    if ([string]::IsNullOrWhiteSpace([string]$documentsPath)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$env:USERPROFILE)) {
            $documentsPath = Join-Path $env:USERPROFILE 'Documents'
        }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$documentsPath)) {
        $script:SessionLogDirectory = Join-Path $documentsPath 'OximizeOS\Logs'
    }
    else {
        $script:SessionLogDirectory = $script:ResolvedScriptDirectory
    }
}

if ([string]::IsNullOrWhiteSpace($script:SessionLogDirectory)) {
    $script:SessionLogDirectory = $script:ResolvedScriptDirectory
}
$script:SessionLogPath = Join-Path $script:SessionLogDirectory ("OximizeOS_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
$script:SessionLogWriteLock = New-Object object

function Write-SessionLogLine {
    param(
        [string]$Message,
        [string]$Level = 'INFO',
        [string]$Source = 'APP'
    )
    try {
        if ([string]::IsNullOrWhiteSpace($script:SessionLogPath)) { return }
        $line = "[{0}] [{1}] [{2}] {3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Source, $Message
        [System.Threading.Monitor]::Enter($script:SessionLogWriteLock)
        try {
            $logDir = [System.IO.Path]::GetDirectoryName($script:SessionLogPath)
            if (-not [string]::IsNullOrWhiteSpace($logDir)) {
                [System.IO.Directory]::CreateDirectory($logDir) | Out-Null
            }
            [System.IO.File]::AppendAllText($script:SessionLogPath, $line + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
        }
        finally {
            [System.Threading.Monitor]::Exit($script:SessionLogWriteLock)
        }
    }
    catch {}
}

function Initialize-SessionLog {
    try {
        if (-not [string]::IsNullOrWhiteSpace($script:SessionLogDirectory)) {
            [System.IO.Directory]::CreateDirectory($script:SessionLogDirectory) | Out-Null
        }
    }
    catch {}
    $sync.SessionLogPath = $script:SessionLogPath
    $resolvedScript = if (-not [string]::IsNullOrWhiteSpace([string]$scriptPath)) { [string]$scriptPath } else { [string]$PSCommandPath }
    if ([string]::IsNullOrWhiteSpace($resolvedScript)) { $resolvedScript = '(unknown)' }
    Write-SessionLogLine -Message "Session started. Script: $resolvedScript" -Level 'INFO' -Source 'APP'
}

Initialize-SessionLog

# Thread-safe log appender with color coding
$script:LogWriteCounter = 0
$script:LogTrimThresholdChars = 700000
$script:LogTrimTargetChars = 500000
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Cyan', 'Green', 'Yellow', 'Red', 'White')]
        [string]$Color = 'White'
    )
    $logBox = $sync.LogBox
    if ($null -eq $logBox -or $logBox.IsDisposed) { return }
    $colorMap = @{
        'Cyan'   = $clrLogCyan
        'Green'  = $clrLogSuccess
        'Yellow' = $clrLogWarning
        'Red'    = $clrLogError
        'White'  = $clrLogText
    }
    $level = switch ($Color) {
        'Red' { 'ERROR' }
        'Yellow' { 'WARN' }
        'Green' { 'SUCCESS' }
        default { 'INFO' }
    }
    Write-SessionLogLine -Message $Message -Level $level -Source 'UI'
    $timestamp = Get-Date -Format 'HH:mm:ss'
    $line = "[$timestamp] $Message`n"
    $lineColor = if ($colorMap.ContainsKey($Color)) { $colorMap[$Color] } else { $clrText }
    $action = {
        if ($null -eq $logBox -or $logBox.IsDisposed) { return }
        try {
            $logBox.SelectionStart = $logBox.TextLength
            $logBox.SelectionLength = 0
            $logBox.SelectionColor = $lineColor
            $logBox.AppendText($line)
            $logBox.SelectionStart = $logBox.TextLength
            # ScrollToCaret can throw transient 0x8000000A while handle/data is not ready.
            if ($logBox.IsHandleCreated -and $logBox.Visible) {
                try { $logBox.ScrollToCaret() } catch {}
            }
        }
        catch {}

        # Keep log responsive during very large DISM/Robocopy streams.
        $script:LogWriteCounter++
        if (($script:LogWriteCounter % 200) -eq 0 -and $logBox.TextLength -gt $script:LogTrimThresholdChars) {
            $targetStart = [Math]::Max(0, $logBox.TextLength - $script:LogTrimTargetChars)
            $newlineAt = $logBox.Text.IndexOf("`n", $targetStart)
            if ($newlineAt -lt 0) { $newlineAt = $targetStart }
            if ($newlineAt -gt 0) {
                $logBox.Select(0, $newlineAt + 1)
                $logBox.SelectedText = ''
            }
        }
    }
    if ($logBox.InvokeRequired) {
        try {
            [void]$logBox.BeginInvoke([System.Action]$action)
        }
        catch {}
    }
    else {
        & $action
    }
}
#endregion

#region ── Update-ProgressBar ─────────────────────────────────────────────────
function Update-ProgressBar {
    param([int]$Value)
    $pb = $sync.ProgressBar
    if ($null -eq $pb) { return }
    $action = { $pb.Value = [Math]::Min([Math]::Max($Value, 0), 100) }
    if ($pb.InvokeRequired) { $pb.Invoke([System.Action]$action) } else { & $action }
}

function Initialize-PathTextBoxPlaceholder {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Control]$Control,
        [string]$PlaceholderText
    )
    if ($null -eq $Control) { return }
    if ([string]::IsNullOrWhiteSpace($PlaceholderText)) {
        $Control.Tag = @{ UiRole = 'PathInput'; Placeholder = ''; IsPlaceholder = $false }
        return
    }

    $tag = @{
        UiRole        = 'PathInput'
        Placeholder   = $PlaceholderText
        IsPlaceholder = $false
    }
    $Control.Tag = $tag

    $showPlaceholder = {
        $tag['IsPlaceholder'] = $true
        $Control.ForeColor = $clrMutedText
        $Control.Text = $tag['Placeholder']
    }.GetNewClosure()

    $clearPlaceholder = {
        if ($tag['IsPlaceholder']) {
            $tag['IsPlaceholder'] = $false
            $Control.ForeColor = $clrText
            $Control.Text = ''
        }
    }.GetNewClosure()

    if (-not $Control.ReadOnly) {
        $Control.Add_Enter($clearPlaceholder)
        $Control.Add_Leave({
                if ([string]::IsNullOrWhiteSpace($Control.Text)) {
                    & $showPlaceholder
                }
            }.GetNewClosure())
    }

    if ([string]::IsNullOrWhiteSpace($Control.Text)) {
        & $showPlaceholder
    }
}

function Get-PathTextBoxValue {
    param([Parameter(Mandatory)][System.Windows.Forms.Control]$Control)
    if ($null -eq $Control) { return '' }
    $tag = $Control.Tag
    if ($tag -is [System.Collections.IDictionary] -and $tag['UiRole'] -eq 'PathInput' -and $tag['IsPlaceholder']) {
        return ''
    }
    return ([string]$Control.Text).Trim()
}

function Set-PathTextBoxValue {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Control]$Control,
        [AllowNull()][string]$Value
    )
    if ($null -eq $Control) { return }
    $tag = $Control.Tag
    $actualValue = [string]$Value
    if ($tag -is [System.Collections.IDictionary] -and $tag['UiRole'] -eq 'PathInput') {
        if ([string]::IsNullOrWhiteSpace($actualValue) -and -not [string]::IsNullOrWhiteSpace([string]$tag['Placeholder'])) {
            $tag['IsPlaceholder'] = $true
            $Control.ForeColor = $clrMutedText
            $Control.Text = [string]$tag['Placeholder']
        }
        else {
            $tag['IsPlaceholder'] = $false
            $Control.ForeColor = $clrText
            $Control.Text = $actualValue
        }
        return
    }
    $Control.Text = $actualValue
}

function Show-ExplorerFolderPicker {
    param(
        [string]$Title = 'Select Folder',
        [string]$InitialPath = ''
    )
    # "Hack" to use OpenFileDialog for folders, as it's often preferred over FolderBrowserDialog
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Title = $Title
    $ofd.Filter = 'Folder Selection|*.folder'
    $ofd.CheckFileExists = $false
    $ofd.CheckPathExists = $true
    $ofd.FileName = 'Select Folder'

    if (-not [string]::IsNullOrWhiteSpace($InitialPath) -and (Test-Path -LiteralPath $InitialPath)) {
        $ofd.InitialDirectory = $InitialPath
    }

    if ($ofd.ShowDialog($form) -eq 'OK') {
        return [System.IO.Path]::GetDirectoryName($ofd.FileName)
    }
    return $null
}
#endregion

#region ── Form Construction ──────────────────────────────────────────────────
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Oximize OS — Windows 11 ISO Builder'
$workingArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$targetWidth = [Math]::Min(1400, [Math]::Max(1024, $workingArea.Width - 40))
$targetHeight = [Math]::Min(1100, [Math]::Max(720, $workingArea.Height - 40))
$form.Size = New-Object System.Drawing.Size($targetWidth, $targetHeight)
$form.MinimumSize = New-Object System.Drawing.Size(1024, 720)
$form.FormBorderStyle = 'Sizable'
$form.MaximizeBox = $true
$form.StartPosition = 'CenterScreen'
$form.BackColor = $clrBg
$form.ForeColor = $clrText
$form.Font = New-UiFont -Size 9
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.AutoScroll = $false
$form.Opacity = 0
$sync.Form = $form
if ($workingArea.Width -lt 1180 -or $workingArea.Height -lt 780) {
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Maximized
}
# Apply dark title bar and dark scrollbars as soon as the Win32 handle exists.
$form.Add_HandleCreated({
        try {
            $dm = 1
            [void][Win32Window]::DwmSetWindowAttribute($this.Handle, [Win32Window]::DWMWA_USE_IMMERSIVE_DARK_MODE, [ref]$dm, 4)
        } catch {}
    })

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$projectIconPath = Get-ProjectIconPath -RootPath $scriptRoot
if (-not [string]::IsNullOrWhiteSpace($projectIconPath)) {
    Set-ProjectIconFromPng -TargetForm $form -PngPath $projectIconPath
}

# ── Container Panels ──────────────────────────────────────────────────────
$script:ShowWelcomeScreen = $true

$panelMainUI = New-Object System.Windows.Forms.Panel
$panelMainUI.Dock = 'Fill'
$panelMainUI.Visible = (-not $script:ShowWelcomeScreen)
$panelMainUI.AutoScroll = $false
$panelMainUI.BackColor = $clrBg
$form.Controls.Add($panelMainUI)

$panelWelcome = New-Object System.Windows.Forms.Panel
$panelWelcome.Dock = 'Fill'
$panelWelcome.Visible = $script:ShowWelcomeScreen
$panelWelcome.AutoScroll = $false
$panelWelcome.BackColor = $clrBg
$panelWelcome.Padding = New-Object System.Windows.Forms.Padding(40)
$form.Controls.Add($panelWelcome)

# ── Welcome Page Content ──────────────────────────────────────────────────
$btnThemeModeWelcome = New-DarkButton -Text '' -Width 54 -Height 44 -Role 'Icon'
$btnThemeModeWelcome.ImageAlign = 'MiddleLeft'
$btnThemeModeWelcome.Padding = New-Object System.Windows.Forms.Padding(10, 2, 4, 2)
$btnThemeModeWelcome.Left = $panelWelcome.Width - $btnThemeModeWelcome.Width - 10
$btnThemeModeWelcome.Top = 10
$btnThemeModeWelcome.Anchor = 'Top, Right'

$lblWelTitle = New-DarkLabel -Text "Welcome to Oximize ISO Builder"
$lblWelTitle.AutoSize = $true
$lblWelTitle.Font = New-UiFont -Size 20 -Style ([System.Drawing.FontStyle]::Bold)
$lblWelTitle.ForeColor = $clrText
$lblWelTitle.Dock = 'None'
$lblWelTitle.Location = New-Object System.Drawing.Point(30, 40)
$lblWelTitle.Padding = New-Object System.Windows.Forms.Padding(0)
$lblWelTitle.Tag = 'WelcomeTitle'

$lblWarnTitle = New-DarkLabel -Text "⚠ WARNING – Official Microsoft ISO Required" -Width 600
$lblWarnTitle.AutoSize = $true
$lblWarnTitle.Dock = 'None'
$lblWarnTitle.Font = New-UiFont -Size 12 -Style ([System.Drawing.FontStyle]::Bold)
$lblWarnTitle.ForeColor = $clrWarning
$lblWarnTitle.Location = New-Object System.Drawing.Point(30, 122)
$lblWarnTitle.Padding = New-Object System.Windows.Forms.Padding(0)
$lblWarnTitle.Tag = 'WarningTitle'

$msgWarning = "Only official Microsoft Windows 11 ISOs are supported.`nModified or `"Lite`" ISOs may cause build failures.`n`nThey may also introduce potential privacy and security risks.`n`nPlease download the official ISO directly from Microsoft."
$lblWarnMsg = New-Object System.Windows.Forms.Label
$lblWarnMsg.Text = $msgWarning
$lblWarnMsg.Font = New-UiFont -Size 9.5
$lblWarnMsg.ForeColor = $clrText
$lblWarnMsg.BackColor = $panelWelcome.BackColor
$lblWarnMsg.AutoSize = $true
$lblWarnMsg.Dock = 'None'
$lblWarnMsg.Location = New-Object System.Drawing.Point(30, 162)
$lblWarnMsg.MaximumSize = New-Object System.Drawing.Size(900, 0)
$lblWarnMsg.Padding = New-Object System.Windows.Forms.Padding(0)
$lblWarnMsg.Tag = 'WelcomeText'

$btnMsDl = New-DarkButton -Text "Download Windows 11" -Width 280 -Height 40 -Role 'Cyan'
$btnMsDl.Add_Click({ Start-Process "https://www.microsoft.com/en-in/software-download/windows11" })

$flowWelBtns = New-Object System.Windows.Forms.FlowLayoutPanel
$flowWelBtns.FlowDirection = 'TopDown'
$flowWelBtns.Anchor = 'Bottom, Right'
$flowWelBtns.AutoSize = $true
$flowWelBtns.AutoSizeMode = 'GrowAndShrink'
$flowWelBtns.BackColor = [System.Drawing.Color]::Transparent
$flowWelBtns.WrapContents = $false
$flowWelBtns.Padding = New-Object System.Windows.Forms.Padding(0)
$flowWelBtns.Location = New-Object System.Drawing.Point(
    ([int]$panelWelcome.ClientSize.Width - 280 - 30),
    ([int]$panelWelcome.ClientSize.Height - 40 - 9 - 40 - 30)
)

$btnCont = New-DarkButton -Text "Continue to Oximize" -Width 280 -Height 40 -Role 'Accent'
$btnMsDl.Margin = New-Object System.Windows.Forms.Padding(0)
$btnCont.Margin = New-Object System.Windows.Forms.Padding(0, 9, 0, 0)

function Invoke-UiStabilizeRedraw {
    param([System.Windows.Forms.Control]$Root)
    if ($null -eq $Root -or $Root.IsDisposed) { return }
    try {
        [void]$Root.BeginInvoke([System.Action]({
                    if ($null -eq $Root -or $Root.IsDisposed) { return }
                    try {
                        $Root.SuspendLayout()
                        if ($Root.IsHandleCreated) {
                            $Root.Invalidate($true)
                            $Root.Update()
                        }
                        foreach ($child in @($Root.Controls)) {
                            if ($null -eq $child -or $child.IsDisposed -or -not $child.Visible) { continue }
                            $child.Invalidate()
                            if ($child.IsHandleCreated) { $child.Update() }
                        }
                    }
                    catch {}
                    finally {
                        try { $Root.ResumeLayout($true) } catch {}
                    }
                }.GetNewClosure()))
    }
    catch {}
}

function Show-MainUi {
    if ($panelMainUI.Visible -and -not $panelWelcome.Visible) { return }
    Invoke-FreezeRedraw -Control $form
    $form.SuspendLayout()
    $panelMainUI.SuspendLayout()
    try {
        Apply-Theme -Mode $script:ThemeMode
        Enable-ControlDoubleBuffer -Control $panelMainUI -Recursive
        $panelWelcome.Visible = $false
        $panelMainUI.Visible = $true
        $panelMainUI.BringToFront()
        $panelMainUI.PerformLayout()
        $form.PerformLayout()
        Update-SectionLayout
    }
    finally {
        $panelMainUI.ResumeLayout($true)
        $form.ResumeLayout($true)
        Invoke-ThawRedraw -Control $form
    }
    try {
        [void]$form.BeginInvoke([System.Action] {
                Update-SectionLayout
                if ($null -ne $mainContainer) { $mainContainer.Invalidate() }
                if ($null -ne $contentPanel) { $contentPanel.Invalidate() }
                $panelMainUI.Refresh()
                Reset-HorizontalScrollRecursively -Root $panelMainUI
                Invoke-UiStabilizeRedraw -Root $panelMainUI
            })
    }
    catch {}
    try {
        $postSwitchTimer = New-Object System.Windows.Forms.Timer
        $postSwitchTimer.Interval = 180
        $postSwitchTimer.Add_Tick({
                $postSwitchTimer.Stop()
                try {
                    Apply-Theme -Mode $script:ThemeMode
                    Update-SectionLayout
                    Reset-HorizontalScrollRecursively -Root $panelMainUI
                    Invoke-UiStabilizeRedraw -Root $panelMainUI
                }
                catch {}
                finally {
                    try { $postSwitchTimer.Dispose() } catch {}
                }
            }.GetNewClosure())
        $postSwitchTimer.Start()
    }
    catch {}
}

$btnCont.Add_Click({ Show-MainUi })

$btnThemeModeWelcome.Add_Click({
        try {
            $nextMode = if ($script:ThemeMode -eq 'Dark') { 'Light' } else { 'Dark' }
            Apply-Theme -Mode $nextMode
            Write-Log "Theme changed to $nextMode mode." -Color Cyan
        }
        catch {
            $themeErr = [string]$_
            Write-SessionLogLine -Message ("Theme toggle warning (welcome): {0}" -f $themeErr) -Level 'WARN' -Source 'UI'
            try { Write-Log ("Theme toggle warning: {0}" -f $themeErr) -Color Yellow } catch {}
        }
    })

$flowWelBtns.Controls.Add($btnMsDl)
$flowWelBtns.Controls.Add($btnCont)

$updateWelcomeLayout = {
    $warningGap = 10
    $warningBlockHeight = $lblWarnTitle.Height + $warningGap + $lblWarnMsg.Height
    $warningTop = [Math]::Max(110, [int](($panelWelcome.ClientSize.Height - $warningBlockHeight) / 2))

    $lblWarnTitle.Location = New-Object System.Drawing.Point(30, $warningTop)
    $lblWarnMsg.Location = New-Object System.Drawing.Point(30, ($warningTop + $lblWarnTitle.Height + $warningGap))

    $flowWelBtns.Location = New-Object System.Drawing.Point(
        ([int]$panelWelcome.ClientSize.Width - $flowWelBtns.Width - 30),
        ([int]$panelWelcome.ClientSize.Height - $flowWelBtns.Height - 30)
    )
}

$panelWelcome.Add_Resize({
        & $updateWelcomeLayout
    })

$panelWelcome.Controls.AddRange(@(
        $lblWarnMsg,
        $lblWarnTitle,
        $lblWelTitle,
        $flowWelBtns,
        $btnThemeModeWelcome
    ))

& $updateWelcomeLayout

# ── Top Panel (path rows + option checkboxes) ─────────────────────────────
$topPanel = New-Object System.Windows.Forms.Panel
$topPanel.Dock = 'Top'
$topPanel.Height = 264
$topPanel.BackColor = $clrPanel
$topPanel.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 4)
Set-ModernPanelPaint -Control $topPanel -ShowAccentLine $false

$srcRow = New-CompactPathRow -LabelText 'Source ISO:' -ReadOnly $true -InfoMode 'File' -CueText 'Select source ISO...' -Top 60 -Parent $topPanel
$tbSourceISO = $srcRow.TextBox
$btnBrowseSrc = $srcRow.Button
$tbSourceISO.Cursor = 'Hand'

$outRow = New-CompactPathRow -LabelText 'Output Folder:' -ReadOnly $false -InfoMode 'Output' -CueText 'Select output folder or ISO path...' -Top 128 -Parent $topPanel
$tbOutputISO = $outRow.TextBox
$btnBrowseOut = $outRow.Button
$tbOutputISO.Cursor = 'Hand'

$scratchRow = New-CompactPathRow -LabelText 'TempBuildDirectory:' -ReadOnly $false -InfoMode 'Folder' -CueText 'Select TempBuildDirectory...' -Top 196 -Parent $topPanel
$tbScratch = $scratchRow.TextBox
$btnBrowseScr = $scratchRow.Button
$tbScratch.Cursor = 'Hand'

$btnSettings = New-DarkButton -Text '' -Width 54 -Height 44 -Role 'Icon'
$btnSettings.ImageAlign = 'MiddleLeft'
$btnSettings.Padding = New-Object System.Windows.Forms.Padding(10, 2, 4, 2)
$btnSettings.Left = $topPanel.Width - 62
$btnSettings.Top = 8
$btnSettings.Anchor = 'Top, Right'

$btnThemeMode = New-DarkButton -Text '' -Width 54 -Height 44 -Role 'Icon'
$btnThemeMode.ImageAlign = 'MiddleLeft'
$btnThemeMode.Padding = New-Object System.Windows.Forms.Padding(10, 2, 4, 2)
$btnThemeMode.Left = $topPanel.Width - 120
$btnThemeMode.Top = 8
$btnThemeMode.Anchor = 'Top, Right'

$topPanel.Controls.AddRange(@($btnSettings, $btnThemeMode))

$panelMainUI.Controls.Add($topPanel)

# ── Advanced Options Panel (rendered as a sidebar page) ─────────────────────
$advancedPanel = New-Object System.Windows.Forms.Panel
$advancedPanel.BackColor = $clrPanelAlt
$advancedPanel.Padding = New-Object System.Windows.Forms.Padding(8)

# ── Browse Dialogs ────────────────────────────────────────────────────────
$btnBrowseSrc.Add_Click({
        $ofd = $null
        try {
            $ofd = New-Object System.Windows.Forms.OpenFileDialog
            $ofd.Filter = 'ISO Images (*.iso)|*.iso|All Files (*.*)|*.*'
            $ofd.Title = 'Select Source ISO'
            if ($ofd.ShowDialog($form) -eq 'OK') {
                Set-PathTextBoxValue -Control $tbSourceISO -Value $ofd.FileName
                $sync['Source ISO'] = $ofd.FileName

                $currentOut = Get-PathTextBoxValue -Control $tbOutputISO
                if ([string]::IsNullOrWhiteSpace($currentOut)) {
                    $defaultName = Get-DefaultOutputIsoName -SourceIsoPath $ofd.FileName
                    $defaultOut = Join-Path (Split-Path -Parent $ofd.FileName) $defaultName
                    Set-PathTextBoxValue -Control $tbOutputISO -Value $defaultOut
                    $sync['Output Folder'] = $defaultOut
                }
            }
        }
        catch { [System.Windows.Forms.MessageBox]::Show("Error: $_", "Error", "OK", "Error") }
        finally { if ($null -ne $ofd) { try { $ofd.Dispose() } catch {} } }
    })
$btnBrowseOut.Add_Click({
        $sfd = $null
        try {
            $sfd = New-Object System.Windows.Forms.SaveFileDialog
            $sfd.Title = 'Select Output ISO File'
            $sfd.Filter = 'ISO Image (*.iso)|*.iso'
            $sfd.FileName = 'OximizeOS_Custom.iso'
            $sfd.OverwritePrompt = $true
            $sfd.CheckPathExists = $true

            if ($sfd.ShowDialog($form) -eq 'OK') {
                $finalPath = $sfd.FileName
                Set-PathTextBoxValue -Control $tbOutputISO -Value $finalPath
                $sync['Output Folder'] = $finalPath
            }
        }
        catch { [System.Windows.Forms.MessageBox]::Show("Error: $_", "Error", "OK", "Error") }
        finally { if ($null -ne $sfd) { try { $sfd.Dispose() } catch {} } }
    })
$btnBrowseScr.Add_Click({
        try {
            $selectedFolder = Show-ExplorerFolderPicker -Title 'Select TempBuildDirectory' -InitialPath (Get-PathTextBoxValue -Control $tbScratch)
            if (-not [string]::IsNullOrWhiteSpace($selectedFolder)) {
                Set-PathTextBoxValue -Control $tbScratch -Value $selectedFolder
                $sync.ScratchDir = $selectedFolder
            }
        }
        catch { [System.Windows.Forms.MessageBox]::Show("Error: $_", "Error", "OK", "Error") }
    })

$tbSourceISO.Add_Click({ $btnBrowseSrc.PerformClick() })
$tbSourceISO.Add_DoubleClick({ $btnBrowseSrc.PerformClick() })
$tbOutputISO.Add_Click({ $btnBrowseOut.PerformClick() })
$tbOutputISO.Add_DoubleClick({ $btnBrowseOut.PerformClick() })
$tbScratch.Add_Click({ $btnBrowseScr.PerformClick() })
$tbScratch.Add_DoubleClick({ $btnBrowseScr.PerformClick() })

function Update-SectionLayout {
    $panelMainUI.SuspendLayout()
    try {
        $outerGap = 8
        $topGap = 10
        $hostWidth = $panelMainUI.ClientSize.Width
        $hostHeight = $panelMainUI.ClientSize.Height
        if (($hostWidth -le 0 -or $hostHeight -le 0) -and $null -ne $form) {
            $hostWidth = [Math]::Max($hostWidth, $form.ClientSize.Width)
            $hostHeight = [Math]::Max($hostHeight, $form.ClientSize.Height)
        }
        if ($hostWidth -le 0 -or $hostHeight -le 0) { return }

        $bottomLimit = if ($null -ne $botPanel) { $hostHeight - $botPanel.Height - $outerGap } else { $hostHeight - $outerGap }
        if ($null -ne $mainContainer) {
            $mainTop = if ($null -ne $topPanel -and $topPanel.Visible) { $topPanel.Bottom + $topGap } else { $outerGap }
            $mainContainer.Left = $outerGap
            $mainContainer.Top = $mainTop
            $mainContainer.Width = [Math]::Max(0, $hostWidth - ($outerGap * 2))
            $newHeight = $bottomLimit - $mainContainer.Top
            $mainContainer.Height = [Math]::Max(220, $newHeight)
        }
    }
    finally {
        $panelMainUI.ResumeLayout()
    }
}


# ── Main Content Area (Sidebar + Pages) ────────────────────────────────────
$mainContainer = New-Object System.Windows.Forms.Panel
$mainContainer.Left = 8
$mainContainer.Top = $topPanel.Bottom + 10
$mainContainer.Width = ($form.ClientSize.Width - 16)
$mainContainer.Height = 300
$mainContainer.Anchor = 'Top,Left,Right,Bottom'
$mainContainer.BackColor = $clrBg
$panelMainUI.Controls.Add($mainContainer)

$navPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$navPanel.Dock = 'Left'
$navPanel.Width = 190
$navPanel.FlowDirection = 'TopDown'
$navPanel.WrapContents = $false
$navPanel.AutoScroll = $false
$navPanel.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 4)
$navPanel.BackColor = $clrPanel
$navPanel.Margin = New-Object System.Windows.Forms.Padding(0)
$navPanel.Tag = 'NavFlow'
Set-DarkScrollbar -Control $navPanel
$navPanel.Add_Resize({
        $targetWidth = [Math]::Max(150, $navPanel.ClientSize.Width - $navPanel.Padding.Horizontal - 2)
        foreach ($ctrl in $navPanel.Controls) {
            if ($ctrl -is [System.Windows.Forms.Button]) {
                $ctrl.Width = $targetWidth
            }
        }
    })

$contentPanel = New-Object System.Windows.Forms.Panel
$contentPanel.Dock = 'Fill'
$contentPanel.BackColor = $clrPanelAlt
$mainContainer.Controls.Add($contentPanel)
$mainContainer.Controls.Add($navPanel)

$uiToolTip = New-Object System.Windows.Forms.ToolTip
$uiToolTip.AutoPopDelay = 15000
$uiToolTip.InitialDelay = 250
$uiToolTip.ReshowDelay = 100
$uiToolTip.ShowAlways = $true

$script:ActiveNavBtn = $null
$script:ActivePage = $null
$script:LastNonLogNavBtn = $null
$script:LastNonLogPage = $null
$script:IsLogsStandaloneVisible = $false
$script:FontNavReg = New-UiFont -Size 9.5 -Style ([System.Drawing.FontStyle]::Regular)
$script:FontNavBold = New-UiFont -Size 9.5 -Style ([System.Drawing.FontStyle]::Bold)
$script:UiLoggingRegisteredControls = [System.Collections.Generic.HashSet[int]]::new()

function Switch-Tab {
    param([System.Windows.Forms.Button]$Btn, [System.Windows.Forms.Panel]$Page)
    if ($null -eq $Btn -or $null -eq $Page) { return }
    if ($Btn.IsDisposed -or $Page.IsDisposed) { return }
    if ($script:ActiveNavBtn -eq $Btn -and $script:ActivePage -eq $Page -and -not $script:IsLogsStandaloneVisible) { return }

    # Prevent stale ComboBox dropdown popups from appearing over other pages.
    $comboRoot = if ($null -ne $script:ActivePage -and -not $script:ActivePage.IsDisposed) { $script:ActivePage } else { $contentPanel }
    Close-AllComboDropDowns -Root $comboRoot

    Invoke-FreezeRedraw -Control $form
    $contentPanel.SuspendLayout()
    if ($null -ne $mainContainer) { $mainContainer.SuspendLayout() }
    try {
        if ($script:ActiveNavBtn) {
            $script:ActiveNavBtn.Tag.Role = 'Nav' # Set role to inactive
            $script:ActiveNavBtn.Font = $script:FontNavReg
            $script:ActiveNavBtn.Invalidate() # Trigger repaint
        }

        if ($script:ActivePage -and $script:ActivePage -ne $Page) {
            $script:ActivePage.Visible = $false
        }
        elseif (-not $script:ActivePage) {
            foreach ($c in $contentPanel.Controls) {
                if ($c.Visible) { $c.Visible = $false }
            }
        }

        $script:ActiveNavBtn = $Btn
        $script:ActivePage = $Page
        $Btn.Tag.Role = 'NavActive' # Set role to active
        $Btn.Font = $script:FontNavBold
        $Btn.Invalidate() # Trigger repaint

        if ($script:IsLogsStandaloneVisible) {
            $script:IsLogsStandaloneVisible = $false
            if ($null -ne $topPanel -and $topPanel.Visible -ne $true) { $topPanel.Visible = $true }
            if ($null -ne $navPanel -and $navPanel.Visible -ne $true) { $navPanel.Visible = $true }
            Update-SectionLayout
        }
        if ($null -ne $tabLogs -and $Page -ne $tabLogs) {
            $script:LastNonLogNavBtn = $Btn
            $script:LastNonLogPage = $Page
        }

        # Apply double-buffering and pre-size rows before making the page visible to
        # prevent white-flash and spurious overflow scrollbars on first open.
        if ($Page.Visible -ne $true) {
            Enable-ControlDoubleBuffer -Control $Page -Recursive
            # Recursively pre-size all AutoScroll FlowLayoutPanels (may be nested in bodyPanel)
            # so row widths are correct before the first WM_PAINT, avoiding overflow scrollbars.
            $presizeFlows = {
                param($Root)
                foreach ($c in @($Root.Controls)) {
                    if ($c -is [System.Windows.Forms.FlowLayoutPanel] -and $c.AutoScroll) {
                        try {
                            $c.SuspendLayout()
                            $c.HorizontalScroll.Enabled = $false
                            $c.HorizontalScroll.Visible = $false
                            $safeW = [Math]::Max(120, $c.ClientSize.Width - $c.Padding.Horizontal - [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth - 34)
                            foreach ($row in @($c.Controls)) {
                                if ($null -ne $row -and $row -is [System.Windows.Forms.Control] -and $row.Width -ne $safeW) {
                                    $row.Width = $safeW
                                }
                            }
                        } catch {}
                        finally { try { $c.ResumeLayout($false) } catch {} }
                    } elseif ($c.Controls.Count -gt 0) {
                        & $presizeFlows $c
                    }
                }
            }
            & $presizeFlows $Page
            $Page.Visible = $true
        }
    }
    finally {
        if ($null -ne $mainContainer) { $mainContainer.ResumeLayout() }
        $contentPanel.ResumeLayout()
        Invoke-ThawRedraw -Control $form
    }
    try {
        [void]$Page.BeginInvoke([System.Action]({
                    Reset-HorizontalScrollRecursively -Root $Page
                }.GetNewClosure()))
    }
    catch {
        Reset-HorizontalScrollRecursively -Root $Page
    }
    Write-SessionLogLine -Message ("UI change: Switched tab -> {0}" -f [string]$Btn.Text) -Level 'INFO' -Source 'UI'
}

function New-ContentPage {
    param([string]$Title)
    $p = New-Object System.Windows.Forms.Panel
    $p.Dock = 'Fill'
    $p.Visible = $false
    $p.BackColor = $clrPanelAlt
    $contentPanel.Controls.Add($p)

    $navBtnWidth = [Math]::Max(150, $navPanel.ClientSize.Width - $navPanel.Padding.Horizontal - 2)
    $btn = New-DarkButton -Text $Title -Width $navBtnWidth -Height 44 -Role 'Nav'
    $btn.TextAlign = 'MiddleLeft'
    $btn.FlatStyle = 'Flat'
    $btn.FlatAppearance.BorderSize = 0
    $btn.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
    $btn.Add_Click({ Switch-Tab -Btn $btn -Page $p }.GetNewClosure())
    $navPanel.Controls.Add($btn)

    return $p, $btn
}

function Add-ExistingContentPage {
    param(
        [string]$Title,
        [System.Windows.Forms.Panel]$Page
    )
    if ($null -eq $Page) { return $null, $null }
    $Page.Dock = 'Fill'
    $Page.Visible = $false
    $Page.BackColor = $clrPanelAlt
    $contentPanel.Controls.Add($Page)

    $navBtnWidth = [Math]::Max(150, $navPanel.ClientSize.Width - $navPanel.Padding.Horizontal - 2)
    $btn = New-DarkButton -Text $Title -Width $navBtnWidth -Height 44 -Role 'Nav'
    $btn.TextAlign = 'MiddleLeft'
    $btn.FlatStyle = 'Flat'
    $btn.FlatAppearance.BorderSize = 0
    $btn.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
    $btn.Add_Click({ Switch-Tab -Btn $btn -Page $Page }.GetNewClosure())
    $navPanel.Controls.Add($btn)

    return $Page, $btn
}

function Get-UiControlDisplayName {
    param([System.Windows.Forms.Control]$Control)
    if ($null -eq $Control) { return 'UnknownControl' }
    $label = ''
    try { $label = [string]$Control.Text } catch {}
    if ([string]::IsNullOrWhiteSpace($label)) {
        try { $label = [string]$Control.Name } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($label)) {
        $label = $Control.GetType().Name
    }
    return $label.Trim()
}

function Test-ShouldWriteUiChangeLog {
    param([System.Windows.Forms.Control]$Control)
    if ($null -eq $Control -or $Control.IsDisposed) { return $false }

    try {
        if ($sync -and $sync.ContainsKey('SuppressUiChangeLog') -and [bool]$sync.SuppressUiChangeLog) {
            return $false
        }
    }
    catch {}

    try {
        if (-not $Control.Visible) { return $false }
    }
    catch {}

    $tagData = $null
    try { $tagData = $Control.Tag } catch {}
    if ($tagData -is [hashtable]) {
        if ($tagData.ContainsKey('SuppressUiChangeLog') -and [bool]$tagData.SuppressUiChangeLog) { return $false }
        if ($tagData.ContainsKey('UiRole') -and [string]$tagData.UiRole -eq 'InternalState') { return $false }
    }
    return $true
}

function Register-UiChangeLogging {
    param(
        [System.Windows.Forms.Control]$Root,
        [switch]$Recursive
    )
    if ($null -eq $Root) { return }

    $id = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($Root)
    if (-not $script:UiLoggingRegisteredControls.Add($id)) { return }

    if ($Root -is [System.Windows.Forms.Button]) {
        $Root.Add_Click({
                if (-not (Test-ShouldWriteUiChangeLog -Control $this)) { return }
                $name = Get-UiControlDisplayName -Control $this
                if ($this.Tag -is [hashtable] -and $this.Tag.Role -in @('Nav', 'NavActive')) { return }
                Write-Log ("UI change: Button clicked -> {0}" -f $name) -Color White
            })
    }
    elseif ($Root -is [System.Windows.Forms.CheckBox]) {
        $Root.Add_CheckedChanged({
                if (-not (Test-ShouldWriteUiChangeLog -Control $this)) { return }
                $name = Get-UiControlDisplayName -Control $this
                Write-Log ("UI change: Checkbox '{0}' -> {1}" -f $name, [bool]$this.Checked) -Color White
            })
    }
    elseif ($Root -is [System.Windows.Forms.RadioButton]) {
        $Root.Add_CheckedChanged({
                if (-not (Test-ShouldWriteUiChangeLog -Control $this)) { return }
                if ($this.Checked) {
                    $name = Get-UiControlDisplayName -Control $this
                    Write-Log ("UI change: Radio selected -> {0}" -f $name) -Color White
                }
            })
    }
    elseif ($Root -is [System.Windows.Forms.ComboBox]) {
        $Root.Add_SelectedIndexChanged({
                if (-not (Test-ShouldWriteUiChangeLog -Control $this)) { return }
                $name = Get-UiControlDisplayName -Control $this
                Write-Log ("UI change: Combo '{0}' -> {1}" -f $name, [string]$this.Text) -Color White
            })
    }
    elseif ($Root -is [System.Windows.Forms.TextBox] -or $Root -is [System.Windows.Forms.MaskedTextBox]) {
        $lastValue = [string]$Root.Text
        $Root.Add_Leave({
                if (-not (Test-ShouldWriteUiChangeLog -Control $this)) { return }
                $newValue = [string]$this.Text
                if ($newValue -eq $lastValue) { return }
                $name = Get-UiControlDisplayName -Control $this
                $isSecret = ($this -is [System.Windows.Forms.MaskedTextBox]) -or (($this -is [System.Windows.Forms.TextBox]) -and ($this.PasswordChar -ne [char]0))
                $valueToLog = if ($isSecret) { '<redacted>' } else { $newValue }
                Write-Log ("UI change: Text '{0}' -> {1}" -f $name, $valueToLog) -Color White
                $lastValue = $newValue
            }.GetNewClosure())
    }

    if ($Recursive) {
        foreach ($child in @($Root.Controls)) {
            Register-UiChangeLogging -Root $child -Recursive
        }
    }
}

$script:CheckRowHeightCache = @{}
function Get-CheckRowHeight {
    param(
        [string]$Text,
        [System.Drawing.Font]$Font,
        [int]$Width,
        [int]$MinHeight = 24,
        [int]$MaxHeight = 0,
        [switch]$FastSingleLine
    )

    if ([string]::IsNullOrEmpty($Text)) { return [int]$MinHeight }
    $safeWidth = [Math]::Max($Width, 120)
    $containsNewLine = ($Text -match "`r`n|`n")
    if ($FastSingleLine -and -not $containsNewLine -and $null -ne $Font) {
        $approxChars = [Math]::Max([int][Math]::Floor($safeWidth / [Math]::Max(([double]$Font.Size * 0.58), 5.0)), 18)
        if ($Text.Length -le $approxChars) { return [int]$MinHeight }
    }

    $fontKey = if ($null -ne $Font) {
        "{0}|{1:0.0}|{2}" -f $Font.Name, [double]$Font.Size, [int]$Font.Style
    }
    else {
        'default'
    }
    $cacheKey = "{0}|{1}|{2}|{3}|{4}" -f $fontKey, $safeWidth, $MinHeight, $MaxHeight, $Text
    if ($script:CheckRowHeightCache.ContainsKey($cacheKey)) {
        return [int]$script:CheckRowHeightCache[$cacheKey]
    }

    $measureBounds = New-Object System.Drawing.Size($safeWidth, 0)
    $measureFlags = [System.Windows.Forms.TextFormatFlags]::WordBreak
    $measuredText = [System.Windows.Forms.TextRenderer]::MeasureText($Text, $Font, $measureBounds, $measureFlags)
    $height = [Math]::Max($MinHeight, $measuredText.Height + 8)
    if ($MaxHeight -gt 0) {
        $height = [Math]::Min($MaxHeight, $height)
    }
    $script:CheckRowHeightCache[$cacheKey] = [int]$height
    if ($script:CheckRowHeightCache.Count -gt 5000) { $script:CheckRowHeightCache.Clear() }
    return [int]$height
}

function Add-TabCheckItem {
    param(
        [System.Windows.Forms.FlowLayoutPanel]$Flow,
        [System.Collections.IList]$Boxes,
        [string]$Item,
        [bool]$Checked = $true,
        [hashtable]$ItemDetails = $null,
        [System.Windows.Forms.RichTextBox]$DetailBox = $null
    )
    if ($null -eq $Flow -or $null -eq $Boxes -or [string]::IsNullOrWhiteSpace($Item)) { return }
    $detail = if ($ItemDetails -and $ItemDetails.ContainsKey($Item)) { [string]$ItemDetails[$Item] } else { '' }
    $cbText = $Item
    $cbFont = New-UiFont -Size 9.5 -Style ([System.Drawing.FontStyle]::Regular)
    $cb = New-DarkCheckBox -Text $cbText -Checked $Checked
    $cb.AutoSize = $false
    $cb.Width = $Flow.ClientSize.Width - $Flow.Padding.Horizontal - 5
    $cb.Height = Get-CheckRowHeight -Text $cbText -Font $cbFont -Width ([Math]::Max($cb.Width - 24, 120)) -MinHeight 24 -FastSingleLine
    $cb.Margin = New-Object System.Windows.Forms.Padding(3, 2, 3, 2)
    $cb.BackColor = $Flow.BackColor
    $cb.ForeColor = $clrText
    $cb.Font = $cbFont
    if ($detail) {
        $uiToolTip.SetToolTip($cb, "$Item`r`n$detail")
    }
    if ($null -ne $DetailBox) {
        $detailText = if ([string]::IsNullOrWhiteSpace($detail)) {
            "$Item`r`n`r`nNo additional details available."
        }
        else {
            "$Item`r`n`r`n$detail"
        }
        $showDetail = {
            $DetailBox.Text = $detailText
        }.GetNewClosure()
        $cb.Add_Click($showDetail)
        $cb.Add_MouseEnter($showDetail)
        $cb.Add_GotFocus($showDetail)
    }
    $Flow.Controls.Add($cb)
    [void]$Boxes.Add($cb)
}

function New-DetailPanel {
    param(
        [string]$DefaultText = 'Select an item to view details.',
        [int]$Height = 150
    )
    $pnl = New-Object System.Windows.Forms.Panel
    $pnl.Dock = 'Bottom'
    $pnl.Height = $Height
    $pnl.Padding = New-Object System.Windows.Forms.Padding(12, 8, 12, 12)
    $pnl.BackColor = $script:clrPanel
    $pnl.Tag = 'DetailPanel'

    $pnl.Add_Paint({
            param($sender, $e)
            $pen = New-Object System.Drawing.Pen($script:clrBg, 2)
            $e.Graphics.DrawLine($pen, 0, 0, $sender.Width, 0)
            $pen.Dispose()
        })

    $lbl = New-DarkLabel -Text 'DETAILS' -Width 100
    $lbl.Dock = 'Top'
    $lbl.Height = 24
    $lbl.Font = New-UiFont -Size 9 -Style ([System.Drawing.FontStyle]::Bold)
    $lbl.ForeColor = $script:clrMutedText
    $lbl.Tag = 'DetailHeader'

    $rtb = New-Object System.Windows.Forms.RichTextBox
    $rtb.Dock = 'Fill'
    $rtb.ReadOnly = $true
    $rtb.BorderStyle = 'None'
    $rtb.BackColor = $script:clrPanel
    $rtb.ForeColor = $script:clrText
    $rtb.Font = New-UiFont -Size 10.5
    $rtb.ScrollBars = 'Vertical'
    $rtb.WordWrap = $true
    $rtb.Text = $DefaultText

    $pnl.Controls.Add($rtb)
    $pnl.Controls.Add($lbl)

    return [pscustomobject]@{ Panel = $pnl; Box = $rtb }
}

function Get-SafeScrollableRowWidth {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Control]$Container,
        [int]$MinWidth = 140,
        [int]$RightGutter = 34
    )

    $clientWidth = 0
    $paddingWidth = 0
    try { $clientWidth = [int]$Container.ClientSize.Width } catch {}
    try { $paddingWidth = [int]$Container.Padding.Horizontal } catch {}

    $reservedScrollWidth = [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth
    $computedWidth = $clientWidth - $paddingWidth - $reservedScrollWidth - $RightGutter
    return [Math]::Max($MinWidth, $computedWidth)
}

function Register-DeferredRowWidthLayout {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Control]$Flow,
        [Parameter(Mandatory)][System.Collections.IEnumerable]$Rows,
        [int]$MinWidth = 140
    )

    $lastAppliedWidth = -1
    $lastVerticalScrollVisible = $false
    $applyWidths = {
        # Always reserve vertical-scrollbar width so row sizing remains stable before/after
        # the scrollbar appears, avoiding horizontal overflow and scroll drift.
        $isScrollable = ($Flow -is [System.Windows.Forms.ScrollableControl])
        $verticalScrollVisible = if ($isScrollable) { [bool]$Flow.VerticalScroll.Visible } else { $false }
        $newWidth = Get-SafeScrollableRowWidth -Container $Flow -MinWidth $MinWidth -RightGutter 34
        $widthChanged = ($newWidth -ne $lastAppliedWidth)
        $scrollStateChanged = ($verticalScrollVisible -ne $lastVerticalScrollVisible)
        if ($widthChanged) {
            foreach ($row in $Rows) {
                if ($null -eq $row) { continue }
                if ($row -is [System.Windows.Forms.Control]) {
                    if ($row.Width -ne $newWidth) {
                        $row.Width = $newWidth
                    }
                }
            }
            $lastAppliedWidth = $newWidth
        }
        if ($isScrollable) {
            try {
                $currentY = [Math]::Abs([int]$Flow.AutoScrollPosition.Y)
                if ($widthChanged -or $scrollStateChanged -or $Flow.AutoScrollPosition.X -ne 0 -or $Flow.HorizontalScroll.Value -ne 0) {
                    $Flow.AutoScrollPosition = [System.Drawing.Point]::new(0, $currentY)
                }
            }
            catch {}
            try {
                if ($widthChanged -or $scrollStateChanged -or $Flow.HorizontalScroll.Enabled -or $Flow.HorizontalScroll.Visible -or $Flow.HorizontalScroll.Maximum -ne 0) {
                    $Flow.HorizontalScroll.Enabled = $false
                    $Flow.HorizontalScroll.Visible = $false
                    if ($Flow.HorizontalScroll.Maximum -ne 0) { $Flow.HorizontalScroll.Maximum = 0 }
                }
            }
            catch {}
        }
        $lastVerticalScrollVisible = $verticalScrollVisible
    }.GetNewClosure()

    $Flow.Add_Resize({ & $applyWidths }.GetNewClosure())
    $Flow.Add_Layout({ & $applyWidths }.GetNewClosure())
    $Flow.Add_ControlAdded({ & $applyWidths }.GetNewClosure())
    $Flow.Add_ControlRemoved({ & $applyWidths }.GetNewClosure())
    $Flow.Add_Scroll({
            param($sender, $e)
            if ($sender -isnot [System.Windows.Forms.ScrollableControl]) { return }
            try {
                if ($e.ScrollOrientation -eq [System.Windows.Forms.ScrollOrientation]::HorizontalScroll -or $sender.HorizontalScroll.Value -ne 0) {
                    $currentY = [Math]::Abs([int]$sender.AutoScrollPosition.Y)
                    $sender.AutoScrollPosition = [System.Drawing.Point]::new(0, $currentY)
                }
            }
            catch {}
        }.GetNewClosure())
    # Fix: run applyWidths synchronously the moment the flow becomes visible so row
    # widths are correct before the first paint, preventing spurious overflow scrollbars.
    $Flow.Add_VisibleChanged({
            if ($Flow.Visible -and $Flow.IsHandleCreated) {
                $Flow.SuspendLayout()
                try { & $applyWidths } catch {}
                finally { $Flow.ResumeLayout($false) }
            }
        }.GetNewClosure())
    if ($Flow.Parent) {
        $Flow.Parent.Add_Resize({ & $applyWidths }.GetNewClosure())
        $Flow.Parent.Add_VisibleChanged({
                if ($Flow.Parent.Visible) { & $applyWidths }
            }.GetNewClosure())
    }

    Set-DarkScrollbar -Control $Flow
    # Run synchronously for initial layout, then async to catch any post-layout adjustments
    & $applyWidths
    try {
        [void]$Flow.BeginInvoke([System.Action]({ & $applyWidths }.GetNewClosure()))
    }
    catch {}
}

function Close-AllComboDropDowns {
    param([System.Windows.Forms.Control]$Root)
    if ($null -eq $Root) { return }
    foreach ($child in @($Root.Controls)) {
        try {
            if ($child -is [System.Windows.Forms.ComboBox] -and $child.DroppedDown) {
                $child.DroppedDown = $false
            }
        }
        catch {}
        if ($child.Controls.Count -gt 0) {
            Close-AllComboDropDowns -Root $child
        }
    }
}

function Reset-HorizontalScrollRecursively {
    param([System.Windows.Forms.Control]$Root)
    if ($null -eq $Root) { return }

    if ($Root -is [System.Windows.Forms.ScrollableControl]) {
        try {
            $currentY = [Math]::Abs([int]$Root.AutoScrollPosition.Y)
            if ($Root.HorizontalScroll.Enabled -or $Root.HorizontalScroll.Visible -or $Root.HorizontalScroll.Maximum -ne 0) {
                $Root.HorizontalScroll.Enabled = $false
                $Root.HorizontalScroll.Visible = $false
                if ($Root.HorizontalScroll.Maximum -ne 0) { $Root.HorizontalScroll.Maximum = 0 }
            }
            if ($Root.AutoScrollPosition.X -ne 0 -or ($Root.HorizontalScroll.Visible -and $Root.HorizontalScroll.Value -ne 0)) {
                $Root.AutoScrollPosition = [System.Drawing.Point]::new(0, $currentY)
            }
        }
        catch {}
    }

    foreach ($child in @($Root.Controls)) {
        if ($null -eq $child) { continue }
        if ($child.Controls.Count -gt 0) {
            Reset-HorizontalScrollRecursively -Root $child
        }
        elseif ($child -is [System.Windows.Forms.ScrollableControl]) {
            try {
                $currentY = [Math]::Abs([int]$child.AutoScrollPosition.Y)
                if ($child.HorizontalScroll.Enabled -or $child.HorizontalScroll.Visible -or $child.HorizontalScroll.Maximum -ne 0) {
                    $child.HorizontalScroll.Enabled = $false
                    $child.HorizontalScroll.Visible = $false
                    if ($child.HorizontalScroll.Maximum -ne 0) { $child.HorizontalScroll.Maximum = 0 }
                }
                if ($child.AutoScrollPosition.X -ne 0 -or ($child.HorizontalScroll.Visible -and $child.HorizontalScroll.Value -ne 0)) {
                    $child.AutoScrollPosition = [System.Drawing.Point]::new(0, $currentY)
                }
            }
            catch {}
        }
    }
}

function New-TabContent {
    param(
        [System.Windows.Forms.Control]$Tab,
        [object[]]$UnifiedItems = $null,
        [string[]]$CheckedItems,
        [string[]]$UncheckedItems,
        [hashtable]$ItemDetails = $null,
        [string[]]$ExtraButtons = @(),
        [switch]$ReturnContext
    )
    # Micro-buttons row
    $pnlMicro = New-Object System.Windows.Forms.Panel
    $pnlMicro.Dock = 'Top'; $pnlMicro.Height = 26; $pnlMicro.BackColor = $clrPanel; $pnlMicro.Tag = 'MicroPanel'

    $btnAll = New-DarkButton -Text '✔ Select All'  -Width 100 -Height 24 -Role 'Accent'
    $btnAll.Left = 0; $btnAll.Top = 2
    $btnNone = New-DarkButton -Text '✖ Clear All' -Width 100 -Height 24 -Role 'Danger'
    $btnNone.Left = 108; $btnNone.Top = 2
    $pnlMicro.Controls.AddRange(@($btnAll, $btnNone))

    $extraButtonMap = @{}
    $nextButtonLeft = 216
    foreach ($extraText in $ExtraButtons) {
        if ([string]::IsNullOrWhiteSpace($extraText)) { continue }

        $btnWidth = 110
        $btnColor = $null
        $btnRole = 'Normal'

        if ($extraText -match 'Add') {
            $btnColor = $script:clrBrowseBtn
            $btnRole = 'Browse'
        }
        elseif ($extraText -match 'Remove') {
            $btnColor = $script:clrDanger
            $btnRole = 'Danger'
        }

        $btnExtra = New-DarkButton -Text $extraText -Width $btnWidth -Height 24 -BgColor $btnColor -Role $btnRole
        $btnExtra.Left = $nextButtonLeft
        $btnExtra.Top = 2
        $nextButtonLeft += ($btnWidth + 4)
        $pnlMicro.Controls.Add($btnExtra)
        $extraButtonMap[$extraText] = $btnExtra
    }

    # Scrollable FlowLayoutPanel for checkboxes
    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock = 'Fill'
    $flow.FlowDirection = 'TopDown'
    $flow.WrapContents = $false
    $flow.AutoScroll = $true
    $flow.HorizontalScroll.Enabled = $false
    $flow.HorizontalScroll.Visible = $false
    $flow.BackColor = $clrPanelAlt
    $flow.Padding = New-Object System.Windows.Forms.Padding(4, 2, 4, 2)
    $flow.BorderStyle = 'None'

    $allBoxes = [System.Collections.Generic.List[System.Windows.Forms.CheckBox]]::new()
    $detailBox = $null
    $bodyPanel = New-Object System.Windows.Forms.Panel
    $bodyPanel.Dock = 'Fill'
    $bodyPanel.BackColor = $clrPanelAlt
    $bodyPanel.Tag = 'PageBody'

    $detailPanel = $null
    if ($ItemDetails -and $ItemDetails.Count -gt 0) {
        $dpObj = New-DetailPanel -Height 160 -DefaultText "Select an item to view its details."
        $detailPanel = $dpObj.Panel
        $detailBox = $dpObj.Box
    }

    $flow.SuspendLayout()
    if ($null -ne $UnifiedItems) {
        foreach ($u in $UnifiedItems) {
            Add-TabCheckItem -Flow $flow -Boxes $allBoxes -Item $u.Label -Checked $u.Checked -ItemDetails $ItemDetails -DetailBox $detailBox
        }
    }
    else {
        foreach ($item in $CheckedItems) {
            Add-TabCheckItem -Flow $flow -Boxes $allBoxes -Item $item -Checked $true -ItemDetails $ItemDetails -DetailBox $detailBox
        }
        foreach ($item in $UncheckedItems) {
            Add-TabCheckItem -Flow $flow -Boxes $allBoxes -Item $item -Checked $false -ItemDetails $ItemDetails -DetailBox $detailBox
        }
    }
    $flow.ResumeLayout($true)

    Register-DeferredRowWidthLayout -Flow $flow -Rows $allBoxes -MinWidth 120

    $bodyPanel.Controls.Add($flow)
    if ($null -ne $detailPanel) {
        $bodyPanel.Controls.Add($detailPanel)
    }
    $Tab.Controls.Add($bodyPanel)
    $Tab.Controls.Add($pnlMicro)

    # Capture $allBoxes in closures so click handlers keep per-tab checkbox references.
    $btnAll.Add_Click({ foreach ($b in $allBoxes) { $b.Checked = $true } }.GetNewClosure())
    $btnNone.Add_Click({ foreach ($b in $allBoxes) { $b.Checked = $false } }.GetNewClosure())

    if ($ReturnContext) {
        return [pscustomobject]@{
            Boxes        = $allBoxes
            Flow         = $flow
            Panel        = $pnlMicro
            BodyPanel    = $bodyPanel
            ButtonAll    = $btnAll
            ButtonNone   = $btnNone
            ExtraButtons = $extraButtonMap
            DetailBox    = $detailBox
        }
    }

    return $allBoxes
}

function Set-AppxToggleButtonState {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Button]$Button,
        [Parameter(Mandatory)][bool]$IsMarkedForRemoval
    )
    if ($IsMarkedForRemoval) {
        $Button.Text = 'Remove'
        $Button.Tag.Role = 'Danger'
    }
    else {
        $Button.Text = 'Keep'
        $Button.Tag.Role = 'Accent'
    }
    $Button.Tag.State = 'Normal'
    $Button.Invalidate()
}

function New-AppxToggleTabContent {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Control]$Tab,
        [Parameter(Mandatory)][object[]]$UnifiedItems
    )

    $pnlMicro = New-Object System.Windows.Forms.Panel
    $pnlMicro.Dock = 'Top'; $pnlMicro.Height = 28; $pnlMicro.BackColor = $clrPanel; $pnlMicro.Tag = 'MicroPanel'

    $btnNone = New-DarkButton -Text 'Keep All' -Width 100 -Height 24 -Role 'Accent'
    $btnNone.Left = 0; $btnNone.Top = 2
    $btnAll = New-DarkButton -Text 'Remove All' -Width 112 -Height 24 -Role 'Danger'
    $btnAll.Left = 108; $btnAll.Top = 2
    $pnlMicro.Controls.AddRange(@($btnNone, $btnAll))

    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock = 'Fill'
    $flow.FlowDirection = 'TopDown'
    $flow.WrapContents = $false
    $flow.AutoScroll = $true
    $flow.HorizontalScroll.Enabled = $false
    $flow.HorizontalScroll.Visible = $false
    $flow.BackColor = $clrPanelAlt
    $flow.Padding = New-Object System.Windows.Forms.Padding(4, 2, 4, 2)
    $flow.BorderStyle = 'None'

    $allBoxes = [System.Collections.Generic.List[System.Windows.Forms.CheckBox]]::new()
    $toggleButtons = [System.Collections.Generic.List[System.Windows.Forms.Button]]::new()
    $allRows = [System.Collections.Generic.List[System.Windows.Forms.Panel]]::new()

    $bodyPanel = New-Object System.Windows.Forms.Panel
    $bodyPanel.Dock = 'Fill'
    $bodyPanel.BackColor = $clrPanelAlt
    $bodyPanel.Tag = 'PageBody'
    $bodyPanel.Controls.Add($flow)
    $Tab.Controls.Add($bodyPanel)
    $Tab.Controls.Add($pnlMicro)

    $flow.SuspendLayout()
    foreach ($u in $UnifiedItems) {
        $row = New-Object System.Windows.Forms.Panel
        $row.Height = 34
        $row.BackColor = $flow.BackColor
        $row.Margin = New-Object System.Windows.Forms.Padding(0, 1, 0, 1)
        $row.Width = Get-SafeScrollableRowWidth -Container $flow -MinWidth 220 -RightGutter 34

        $stateBox = New-Object System.Windows.Forms.CheckBox
        $stateBox.Checked = [bool]$u.Checked
        $stateBox.Visible = $false
        $stateBox.Tag = @{ UiRole = 'InternalState'; SuppressUiChangeLog = $true }

        $lbl = New-DarkLabel -Text ([string]$u.Label) -Width 100 -Height 30
        $lbl.Left = 0
        $lbl.Top = 2
        $lbl.AutoEllipsis = $true
        $lbl.Anchor = 'Top, Left, Right'

        $btnToggle = New-DarkButton -Text 'Keep' -Width 90 -Height 26 -Role 'Accent'
        $btnToggle.Left = $row.Width - $btnToggle.Width
        $btnToggle.Top = 4
        $btnToggle.Anchor = 'Top, Right'

        $stateBox.Add_CheckedChanged({
            Set-AppxToggleButtonState -Button $btnToggle -IsMarkedForRemoval $stateBox.Checked
        }.GetNewClosure())

        $toggleClick = {
            $stateBox.Checked = -not $stateBox.Checked
            Set-AppxToggleButtonState -Button $btnToggle -IsMarkedForRemoval $stateBox.Checked
        }.GetNewClosure()
        $btnToggle.Add_Click($toggleClick)
        Set-AppxToggleButtonState -Button $btnToggle -IsMarkedForRemoval ([bool]$u.Checked)

        $row.Add_Resize({
                $btnToggle.Left = $row.ClientSize.Width - $btnToggle.Width
                $lbl.Width = [Math]::Max(120, $btnToggle.Left - 8)
            }.GetNewClosure())
        $row.Controls.Add($lbl)
        $row.Controls.Add($btnToggle)
        $row.Controls.Add($stateBox)
        $flow.Controls.Add($row)

        [void]$allRows.Add($row)
        [void]$allBoxes.Add($stateBox)
        [void]$toggleButtons.Add($btnToggle)
    }
    $flow.ResumeLayout($true)

    $btnAll.Add_Click({
            for ($i = 0; $i -lt $allBoxes.Count; $i++) {
                $allBoxes[$i].Checked = $true
                Set-AppxToggleButtonState -Button $toggleButtons[$i] -IsMarkedForRemoval $true
            }
        }.GetNewClosure())
    $btnNone.Add_Click({
            for ($i = 0; $i -lt $allBoxes.Count; $i++) {
                $allBoxes[$i].Checked = $false
                Set-AppxToggleButtonState -Button $toggleButtons[$i] -IsMarkedForRemoval $false
            }
        }.GetNewClosure())

    Register-DeferredRowWidthLayout -Flow $flow -Rows $allRows -MinWidth 220

    return [pscustomobject]@{
        Boxes     = $allBoxes
        Flow      = $flow
        BodyPanel = $bodyPanel
    }
}

function New-ServiceTabContent {
    param(
        [System.Windows.Forms.Control]$Tab,
        [object[]]$UnifiedItems,
        [hashtable]$ItemDetails
    )
    # Micro-buttons
    $pnlMicro = New-Object System.Windows.Forms.Panel
    $pnlMicro.Dock = 'Top'; $pnlMicro.Height = 28; $pnlMicro.BackColor = $script:clrPanel; $pnlMicro.Tag = 'MicroPanel'

    $btnEnableAll = New-DarkButton -Text 'Automatic' -Width 96 -Height 26 -Role 'Accent'
    $btnEnableAll.Left = 0; $btnEnableAll.Top = 2
    $btnManualAll = New-DarkButton -Text 'Manual' -Width 86 -Height 26 -Role 'Neutral'
    $btnManualAll.Left = 102; $btnManualAll.Top = 2
    $btnDisableAll = New-DarkButton -Text 'Disable' -Width 86 -Height 26 -Role 'Danger'
    $btnDisableAll.Left = 194; $btnDisableAll.Top = 2
    $btnSelectToggle = New-DarkButton -Text 'Select All' -Width 96 -Height 26 -Role 'Accent'
    $btnSelectToggle.Left = 286; $btnSelectToggle.Top = 2

    $pnlMicro.Controls.AddRange(@($btnEnableAll, $btnManualAll, $btnDisableAll, $btnSelectToggle))

    # Flow
    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock = 'Fill'
    $flow.FlowDirection = 'TopDown'
    $flow.WrapContents = $false
    $flow.AutoScroll = $true
    $flow.HorizontalScroll.Enabled = $false
    $flow.HorizontalScroll.Visible = $false
    $flow.BackColor = $script:clrPanelAlt
    $flow.Padding = New-Object System.Windows.Forms.Padding(4, 2, 4, 2)
    $flow.BorderStyle = 'None'

    $allCombos = [System.Collections.Generic.List[System.Windows.Forms.ComboBox]]::new()
    $allToggleButtons = [System.Collections.Generic.List[System.Windows.Forms.Button]]::new()
    $allSelectors = [System.Collections.Generic.List[System.Windows.Forms.CheckBox]]::new()
    $allRows = [System.Collections.Generic.List[System.Windows.Forms.Panel]]::new()

    # Details Panel
    $dpObj = New-DetailPanel -Height 140 -DefaultText "Hover over a service to view details."
    $detailPanel = $dpObj.Panel
    $detailBox = $dpObj.Box

    $bodyPanel = New-Object System.Windows.Forms.Panel
    $bodyPanel.Dock = 'Fill'
    $bodyPanel.BackColor = $script:clrPanelAlt
    $bodyPanel.Tag = 'PageBody'
    $bodyPanel.Controls.Add($flow)
    $bodyPanel.Controls.Add($detailPanel)
    $Tab.Controls.Add($bodyPanel)
    $Tab.Controls.Add($pnlMicro)

    $flow.SuspendLayout()
    foreach ($u in $UnifiedItems) {
        $row = New-Object System.Windows.Forms.Panel
        $row.Height = 34
        $row.BackColor = $flow.BackColor
        $row.Margin = New-Object System.Windows.Forms.Padding(0, 1, 0, 1)

        $cb = New-DarkComboBox -Items @('Disabled', 'Manual', 'Automatic') -Text 'Automatic' -Width 1
        # State-only control: not added to row UI, prevents random drop-down artifacts.
        $cb.Visible = $false
        $cb.IntegralHeight = $false
        $cb.MaxDropDownItems = 1
        $cb.DropDownHeight = 1
        $cb.TabStop = $false
        $cb.Tag = @{ UiRole = 'InternalState'; SuppressUiChangeLog = $true }

        $lbl = New-DarkLabel -Text $u.Label -Width 300 -Height 22
        $lbl.TextAlign = 'MiddleLeft'
        $lbl.AutoEllipsis = $true
        $lbl.Left = 30
        $lbl.Top = 4
        $lbl.Anchor = 'Top, Left, Right'

        $rowSelector = New-Object System.Windows.Forms.CheckBox
        $rowSelector.Text = '✓'
        $rowSelector.Checked = $false
        $rowSelector.UseVisualStyleBackColor = $false
        $rowSelector.Appearance = 'Button'
        $rowSelector.TextAlign = 'MiddleCenter'
        $rowSelector.BackColor = $script:clrInputBg
        $rowSelector.ForeColor = $script:clrAccent
        $rowSelector.FlatStyle = 'Flat'
        $rowSelector.FlatAppearance.BorderColor = $script:clrBorder
        $rowSelector.FlatAppearance.BorderSize = 1
        $rowSelector.FlatAppearance.CheckedBackColor = Get-ShiftedColor -Color $script:clrAccent -Delta -95
        $rowSelector.FlatAppearance.MouseOverBackColor = Get-ShiftedColor -Color $script:clrInputBg -Delta 8
        $rowSelector.FlatAppearance.MouseDownBackColor = Get-ShiftedColor -Color $script:clrInputBg -Delta -6
        $rowSelector.AutoSize = $false
        $rowSelector.Width = 22
        $rowSelector.Height = 22
        $rowSelector.Left = 8
        $rowSelector.Top = 4
        $rowSelector.Cursor = 'Hand'
        $rowSelector.Font = New-UiFont -Size 9.5 -Style ([System.Drawing.FontStyle]::Bold)
        $rowSelector.Tag = @{ UiRole = 'InternalState'; SuppressUiChangeLog = $true }
        $rowSelector.Add_CheckedChanged({
                if ($rowSelector.Checked) {
                    $rowSelector.Text = '✓'
                    $rowSelector.ForeColor = $clrAccent
                }
                else {
                    $rowSelector.Text = ''
                    $rowSelector.ForeColor = $clrMutedText
                }
            }.GetNewClosure())
        if (-not $rowSelector.Checked) {
            $rowSelector.Text = ''
            $rowSelector.ForeColor = $clrMutedText
        }

        $btnToggle = New-DarkButton -Text 'Automatic' -Width 118 -Height 24 -Role 'Accent'
        $btnToggle.Left = [Math]::Max(32, $row.Width - $btnToggle.Width - 4)
        $btnToggle.Top = 2
        $btnToggle.Anchor = 'Top, Right'

        $syncServiceModeVisual = {
            switch ([string]$cb.SelectedItem) {
                'Disabled' {
                    Set-ButtonRole -Button $btnToggle -Role 'Danger'
                    $btnToggle.Text = 'Disable'
                }
                'Manual' {
                    Set-ButtonRole -Button $btnToggle -Role 'Neutral'
                    $btnToggle.Text = 'Manual'
                }
                default {
                    Set-ButtonRole -Button $btnToggle -Role 'Accent'
                    $btnToggle.Text = 'Automatic'
                }
            }
        }.GetNewClosure()

        $setServiceMode = {
            param([string]$mode)
            switch ($mode) {
                'Disabled' {
                    $cb.SelectedItem = 'Disabled'
                }
                'Manual' {
                    $cb.SelectedItem = 'Manual'
                }
                default {
                    $cb.SelectedItem = 'Automatic'
                }
            }
            & $syncServiceModeVisual
        }.GetNewClosure()
        $cb.Add_SelectedIndexChanged($syncServiceModeVisual)
        $cb.Add_TextChanged($syncServiceModeVisual)

        $initialServiceMode = if ($null -ne $u.PSObject.Properties['DefaultMode']) { [string]$u.DefaultMode } else { 'Automatic' }
        if ($initialServiceMode -notin @('Automatic', 'Manual', 'Disabled')) { $initialServiceMode = 'Automatic' }
        & $setServiceMode $initialServiceMode
        $btnToggle.Add_Click({
                $nextMode = switch ([string]$cb.SelectedItem) {
                    'Automatic' { 'Manual' }
                    'Manual' { 'Disabled' }
                    default { 'Automatic' }
                }
                & $setServiceMode $nextMode
            }.GetNewClosure())

        $layoutRow = {
            $btnToggle.Left = [Math]::Max(32, $row.ClientSize.Width - $btnToggle.Width - 4)
            $lbl.Left = 30
            $lbl.Width = [Math]::Max(80, $btnToggle.Left - $lbl.Left - 8)
        }.GetNewClosure()
        $row.Add_Resize($layoutRow)
        & $layoutRow

        $row.Controls.Add($lbl)
        $row.Controls.Add($rowSelector)
        $row.Controls.Add($btnToggle)
        $flow.Controls.Add($row)
        $allCombos.Add($cb)
        $allToggleButtons.Add($btnToggle)
        $allSelectors.Add($rowSelector)
        $allRows.Add($row)

        $detailText = if ($ItemDetails -and $ItemDetails.ContainsKey($u.Label)) { $ItemDetails[$u.Label] } else { $u.Label }
        $showDetail = { $detailBox.Text = $detailText }.GetNewClosure()
        $lbl.Add_MouseEnter($showDetail)
        $btnToggle.Add_MouseEnter($showDetail)
        $lbl.Add_Click({
                $rowSelector.Checked = -not $rowSelector.Checked
                & $showDetail
            }.GetNewClosure())
        $lbl.Add_GotFocus($showDetail)
        $btnToggle.Add_GotFocus($showDetail)
    }
    $flow.ResumeLayout($true)

    $flow.Add_Resize({
            param($sender, $e)
            $newWidth = Get-SafeScrollableRowWidth -Container $sender -MinWidth 220 -RightGutter 34
            foreach ($r in $allRows) {
                $r.Width = $newWidth
            }
        }.GetNewClosure())

    $applyModeToSelected = {
        param([string]$mode)
        for ($i = 0; $i -lt $allCombos.Count; $i++) {
            if (-not $allSelectors[$i].Checked) { continue }
            switch ($mode) {
                'Automatic' {
                    $allCombos[$i].SelectedItem = 'Automatic'
                    Set-ButtonRole -Button $allToggleButtons[$i] -Role 'Accent'
                    $allToggleButtons[$i].Text = 'Automatic'
                }
                'Manual' {
                    $allCombos[$i].SelectedItem = 'Manual'
                    Set-ButtonRole -Button $allToggleButtons[$i] -Role 'Neutral'
                    $allToggleButtons[$i].Text = 'Manual'
                }
                'Disabled' {
                    $allCombos[$i].SelectedItem = 'Disabled'
                    Set-ButtonRole -Button $allToggleButtons[$i] -Role 'Danger'
                    $allToggleButtons[$i].Text = 'Disable'
                }
            }
        }
    }.GetNewClosure()

    $btnEnableAll.Add_Click({ & $applyModeToSelected 'Automatic' }.GetNewClosure())
    $btnManualAll.Add_Click({ & $applyModeToSelected 'Manual' }.GetNewClosure())
    $btnDisableAll.Add_Click({ & $applyModeToSelected 'Disabled' }.GetNewClosure())
    $btnSelectToggle.Add_Click({
            $shouldSelectAll = ($btnSelectToggle.Text -eq 'Select All')
            foreach ($s in $allSelectors) {
                $s.Checked = $shouldSelectAll
            }
            if ($shouldSelectAll) {
                $btnSelectToggle.Text = 'Clear All'
                Set-ButtonRole -Button $btnSelectToggle -Role 'Danger'
            }
            else {
                $btnSelectToggle.Text = 'Select All'
                Set-ButtonRole -Button $btnSelectToggle -Role 'Accent'
            }
        }.GetNewClosure())

    return $allCombos
}

function New-FeatureTabContent {
    param(
        [System.Windows.Forms.Control]$Tab,
        [object[]]$UnifiedItems,
        [hashtable]$ItemDetails
    )
    # Micro-buttons
    $pnlMicro = New-Object System.Windows.Forms.Panel
    $pnlMicro.Dock = 'Top'; $pnlMicro.Height = 28; $pnlMicro.BackColor = $script:clrPanel; $pnlMicro.Tag = 'MicroPanel'

    $btnDef = New-DarkButton -Text 'Default All' -Width 90 -Height 26 -Role 'Neutral'
    $btnDef.Left = 0; $btnDef.Top = 2
    $btnEn = New-DarkButton -Text 'Enable All' -Width 90 -Height 26 -Role 'Accent'
    $btnEn.Left = 96; $btnEn.Top = 2
    $btnDis = New-DarkButton -Text 'Disable All' -Width 90 -Height 26 -Role 'Danger'
    $btnDis.Left = 192; $btnDis.Top = 2

    $pnlMicro.Controls.AddRange(@($btnDef, $btnEn, $btnDis))

    # Flow
    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock = 'Fill'
    $flow.FlowDirection = 'TopDown'
    $flow.WrapContents = $false
    $flow.AutoScroll = $true
    $flow.HorizontalScroll.Enabled = $false
    $flow.HorizontalScroll.Visible = $false
    $flow.BackColor = $script:clrPanelAlt
    $flow.Padding = New-Object System.Windows.Forms.Padding(4, 2, 4, 2)
    $flow.BorderStyle = 'None'

    $allCombos = [System.Collections.Generic.List[System.Windows.Forms.ComboBox]]::new()
    $allRows = [System.Collections.Generic.List[System.Windows.Forms.Panel]]::new()

    # Details Panel
    $dpObj = New-DetailPanel -Height 160 -DefaultText "Hover over a feature to view details."
    $detailPanel = $dpObj.Panel
    $detailBox = $dpObj.Box

    $bodyPanel = New-Object System.Windows.Forms.Panel
    $bodyPanel.Dock = 'Fill'
    $bodyPanel.BackColor = $script:clrPanelAlt
    $bodyPanel.Tag = 'PageBody'
    $bodyPanel.Controls.Add($flow)
    $bodyPanel.Controls.Add($detailPanel)
    $Tab.Controls.Add($bodyPanel)
    $Tab.Controls.Add($pnlMicro)

    $flow.SuspendLayout()
    foreach ($u in $UnifiedItems) {
        $row = New-Object System.Windows.Forms.Panel
        $row.Height = 44
        $row.BackColor = $flow.BackColor
        $row.Margin = New-Object System.Windows.Forms.Padding(0, 1, 0, 1)

        $cb = New-DarkComboBox -Items @('Default', 'Enabled', 'Disabled') -Text $u.DefaultState -Width 120
        $cb.Dock = 'Right'

        $chk = New-DarkCheckBox -Text $u.Label -Checked ($u.DefaultState -ne 'Default')
        $chk.Dock = 'Fill'
        $chk.AutoSize = $false
        $chk.AutoEllipsis = $true

        $chk.Add_Click({
                if ($chk.Checked) { $cb.SelectedItem = 'Disabled' } else { $cb.SelectedItem = 'Default' }
            }.GetNewClosure())
        $cb.Add_SelectedIndexChanged({ $chk.Checked = ($cb.SelectedItem -ne 'Default') }.GetNewClosure())

        $row.Controls.Add($chk)
        $row.Controls.Add($cb)
        $flow.Controls.Add($row)
        $allCombos.Add($cb)
        $allRows.Add($row)

        $detailText = if ($ItemDetails -and $ItemDetails.ContainsKey($u.Label)) { $ItemDetails[$u.Label] } else { $u.Label }
        $showDetail = { $detailBox.Text = $detailText }.GetNewClosure()
        $chk.Add_MouseEnter($showDetail)
        $cb.Add_MouseEnter($showDetail)
        $chk.Add_Click($showDetail)
        $chk.Add_GotFocus($showDetail)
        $cb.Add_GotFocus($showDetail)
    }
    $flow.ResumeLayout($true)

    $flow.Add_Resize({
            param($sender, $e)
            $newWidth = Get-SafeScrollableRowWidth -Container $sender -MinWidth 240 -RightGutter 34
            foreach ($r in $allRows) {
                $r.Width = $newWidth
            }
        }.GetNewClosure())

    $btnDef.Add_Click({ foreach ($c in $allCombos) { $c.SelectedItem = 'Default' } }.GetNewClosure())
    $btnEn.Add_Click({ foreach ($c in $allCombos) { $c.SelectedItem = 'Enabled' } }.GetNewClosure())
    $btnDis.Add_Click({ foreach ($c in $allCombos) { $c.SelectedItem = 'Disabled' } }.GetNewClosure())

    return $allCombos
}

function New-PrivacyToggleTabContent {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Control]$Tab,
        [Parameter(Mandatory)][object[]]$UnifiedItems
    )
    $pnlMicro = New-Object System.Windows.Forms.Panel
    $pnlMicro.Dock = 'Top'; $pnlMicro.Height = 28; $pnlMicro.BackColor = $script:clrPanel; $pnlMicro.Tag = 'MicroPanel'

    $btnDefAll = New-DarkButton -Text 'Default' -Width 86 -Height 26 -Role 'Neutral'
    $btnDefAll.Left = 0; $btnDefAll.Top = 2
    $btnEnableAll = New-DarkButton -Text 'Enable' -Width 86 -Height 26 -Role 'Accent'
    $btnEnableAll.Left = 92; $btnEnableAll.Top = 2
    $btnDisableAll = New-DarkButton -Text 'Disable' -Width 86 -Height 26 -Role 'Danger'
    $btnDisableAll.Left = 184; $btnDisableAll.Top = 2
    $btnSelectToggle = New-DarkButton -Text 'Select All' -Width 96 -Height 26 -Role 'Accent'
    $btnSelectToggle.Left = 276; $btnSelectToggle.Top = 2
    $pnlMicro.Controls.AddRange(@($btnDefAll, $btnEnableAll, $btnDisableAll, $btnSelectToggle))

    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock = 'Fill'
    $flow.FlowDirection = 'TopDown'
    $flow.WrapContents = $false
    $flow.AutoScroll = $true
    $flow.HorizontalScroll.Enabled = $false
    $flow.HorizontalScroll.Visible = $false
    $flow.BackColor = $script:clrPanelAlt
    $flow.Padding = New-Object System.Windows.Forms.Padding(4, 2, 4, 2)
    $flow.BorderStyle = 'None'

    $allCombos = [System.Collections.Generic.List[System.Windows.Forms.ComboBox]]::new()
    $allButtons = [System.Collections.Generic.List[System.Windows.Forms.Button]]::new()
    $allSelectors = [System.Collections.Generic.List[System.Windows.Forms.CheckBox]]::new()
    $allRows = [System.Collections.Generic.List[System.Windows.Forms.Panel]]::new()

    $bodyPanel = New-Object System.Windows.Forms.Panel
    $bodyPanel.Dock = 'Fill'
    $bodyPanel.BackColor = $script:clrPanelAlt
    $bodyPanel.Tag = 'PageBody'
    $bodyPanel.Controls.Add($flow)
    $Tab.Controls.Add($bodyPanel)
    $Tab.Controls.Add($pnlMicro)

    $flow.SuspendLayout()
    foreach ($u in $UnifiedItems) {
        $row = New-Object System.Windows.Forms.Panel
        $row.Height = 30
        $row.BackColor = $flow.BackColor
        $row.Margin = New-Object System.Windows.Forms.Padding(0, 1, 0, 1)
        $row.Add_Paint({
                param($sender, $e)
                $pen = New-Object System.Drawing.Pen($clrDivider)
                try {
                    $y = $sender.ClientSize.Height - 1
                    $e.Graphics.DrawLine($pen, 0, $y, $sender.ClientSize.Width, $y)
                }
                finally {
                    if ($pen) { $pen.Dispose() }
                }
            }.GetNewClosure())

        $cb = New-DarkComboBox -Items @('Default', 'Enabled', 'Disabled') -Text 'Default' -Width 1
        # State-only control: not added to row UI, prevents random drop-down artifacts.
        $cb.Visible = $false
        $cb.IntegralHeight = $false
        $cb.MaxDropDownItems = 1
        $cb.DropDownHeight = 1
        $cb.TabStop = $false
        $cb.Tag = @{ UiRole = 'InternalState'; SuppressUiChangeLog = $true }

        $lbl = New-DarkLabel -Text ([string]$u.Label) -Width 320 -Height 34
        $lbl.AutoSize = $false
        $lbl.TextAlign = 'TopLeft'
        $lbl.AutoEllipsis = $false
        $lbl.UseMnemonic = $false
        $lbl.Tag = 'PrivacyLabel'
        $lbl.Font = New-UiFont -Size 9.5 -Style ([System.Drawing.FontStyle]::Regular)
        $lbl.ForeColor = $clrText
        $lbl.BackColor = [System.Drawing.Color]::Transparent
        $lbl.Left = 34
        $lbl.Top = 3
        $lbl.Anchor = 'Top, Left, Right'

        $rowSelector = New-Object System.Windows.Forms.CheckBox
        $rowSelector.Text = '✓'
        $rowSelector.Checked = $false
        $rowSelector.UseVisualStyleBackColor = $false
        $rowSelector.Appearance = 'Button'
        $rowSelector.TextAlign = 'MiddleCenter'
        $rowSelector.BackColor = $script:clrInputBg
        $rowSelector.ForeColor = $script:clrAccent
        $rowSelector.FlatStyle = 'Flat'
        $rowSelector.FlatAppearance.BorderColor = $script:clrBorder
        $rowSelector.FlatAppearance.BorderSize = 1
        $rowSelector.FlatAppearance.CheckedBackColor = Get-ShiftedColor -Color $script:clrAccent -Delta -95
        $rowSelector.FlatAppearance.MouseOverBackColor = Get-ShiftedColor -Color $script:clrInputBg -Delta 8
        $rowSelector.FlatAppearance.MouseDownBackColor = Get-ShiftedColor -Color $script:clrInputBg -Delta -6
        $rowSelector.AutoSize = $false
        $rowSelector.Width = 22
        $rowSelector.Height = 22
        $rowSelector.Left = 8
        $rowSelector.Top = 4
        $rowSelector.Cursor = 'Hand'
        $rowSelector.Font = New-UiFont -Size 9.5 -Style ([System.Drawing.FontStyle]::Bold)
        $rowSelector.Tag = @{ UiRole = 'InternalState'; SuppressUiChangeLog = $true }
        $rowSelector.Add_CheckedChanged({
                if ($rowSelector.Checked) {
                    $rowSelector.Text = '✓'
                    $rowSelector.ForeColor = $clrAccent
                }
                else {
                    $rowSelector.Text = ''
                    $rowSelector.ForeColor = $clrMutedText
                }
            }.GetNewClosure())
        if (-not $rowSelector.Checked) {
            $rowSelector.Text = ''
            $rowSelector.ForeColor = $clrMutedText
        }

        $btnToggle = New-DarkButton -Text 'Default' -Width 116 -Height 24
        $btnToggle.Left = [Math]::Max(80, $row.Width - $btnToggle.Width - 4)
        $btnToggle.Top = 4
        $btnToggle.Anchor = 'Top, Right'

        $applyPrivacyButton = {
            param([string]$mode)
            switch ($mode) {
                'Enabled' {
                    Set-ButtonRole -Button $btnToggle -Role 'Accent'
                    $btnToggle.Text = 'Enable'
                }
                'Disabled' {
                    Set-ButtonRole -Button $btnToggle -Role 'Danger'
                    $btnToggle.Text = 'Disable'
                }
                default {
                    Set-ButtonRole -Button $btnToggle -Role 'Neutral'
                    $btnToggle.Text = 'Default'
                }
            }
        }.GetNewClosure()

        $setPrivacyMode = {
            param([string]$mode)
            if ($mode -notin @('Default', 'Enabled', 'Disabled')) { $mode = 'Default' }
            if ([string]$cb.SelectedItem -ne $mode) { $cb.SelectedItem = $mode }
            & $applyPrivacyButton $mode
        }.GetNewClosure()

        $cb.Add_SelectedIndexChanged({
                & $applyPrivacyButton ([string]$cb.SelectedItem)
            }.GetNewClosure())

        $initial = if ($null -ne $u.PSObject.Properties['Mode']) { [string]$u.Mode } else { 'Default' }
        if ($initial -notin @('Default', 'Enabled', 'Disabled')) { $initial = 'Default' }
        & $setPrivacyMode $initial
        $btnToggle.Add_Click({
                $nextMode = switch ([string]$cb.SelectedItem) {
                    'Default' { 'Enabled' }
                    'Enabled' { 'Disabled' }
                    default { 'Default' }
                }
                & $setPrivacyMode $nextMode
            }.GetNewClosure())

        $layoutRow = {
            $btnToggle.Left = [Math]::Max(80, $row.ClientSize.Width - $btnToggle.Width - 4)
            $lbl.Left = 34
            $lbl.Width = [Math]::Max(120, $btnToggle.Left - $lbl.Left - 10)
            $measureBounds = New-Object System.Drawing.Size([Math]::Max(120, $lbl.Width), 0)
            $measureFlags = [System.Windows.Forms.TextFormatFlags]::WordBreak
            $measuredText = [System.Windows.Forms.TextRenderer]::MeasureText($lbl.Text, $lbl.Font, $measureBounds, $measureFlags)
            # Keep long labels readable without allowing runaway row heights.
            $desiredLabelHeight = [Math]::Max(22, [Math]::Min(170, $measuredText.Height + 4))
            $lbl.Height = $desiredLabelHeight
            $row.Height = [Math]::Max(30, $desiredLabelHeight + 8)
            $btnToggle.Top = [Math]::Max(2, [int](($row.ClientSize.Height - $btnToggle.Height) / 2))
            $rowSelector.Top = [Math]::Max(2, [int](($row.ClientSize.Height - $rowSelector.Height) / 2))
        }.GetNewClosure()
        $row.Add_Resize($layoutRow)
        & $layoutRow

        $row.Controls.Add($rowSelector)
        $row.Controls.Add($lbl)
        $row.Controls.Add($btnToggle)
        $flow.Controls.Add($row)

        $allCombos.Add($cb)
        $allButtons.Add($btnToggle)
        $allSelectors.Add($rowSelector)
        $allRows.Add($row)

        $lbl.Add_Click({
                $rowSelector.Checked = -not $rowSelector.Checked
            }.GetNewClosure())
    }
    $flow.ResumeLayout($true)

    Register-DeferredRowWidthLayout -Flow $flow -Rows $allRows -MinWidth 240

    $setModeForSelected = {
        param([string]$mode)
        if ($mode -notin @('Default', 'Enabled', 'Disabled')) { return }
        for ($i = 0; $i -lt $allCombos.Count; $i++) {
            if (-not $allSelectors[$i].Checked) { continue }
            if ([string]$allCombos[$i].SelectedItem -ne $mode) { $allCombos[$i].SelectedItem = $mode }
        }
    }.GetNewClosure()
    $btnDefAll.Add_Click({ & $setModeForSelected 'Default' }.GetNewClosure())
    $btnEnableAll.Add_Click({ & $setModeForSelected 'Enabled' }.GetNewClosure())
    $btnDisableAll.Add_Click({ & $setModeForSelected 'Disabled' }.GetNewClosure())
    $btnSelectToggle.Add_Click({
            $shouldSelectAll = ($btnSelectToggle.Text -eq 'Select All')
            foreach ($sel in $allSelectors) { $sel.Checked = $shouldSelectAll }
            if ($shouldSelectAll) {
                $btnSelectToggle.Text = 'Clear All'
                Set-ButtonRole -Button $btnSelectToggle -Role 'Danger'
            }
            else {
                $btnSelectToggle.Text = 'Select All'
                Set-ButtonRole -Button $btnSelectToggle -Role 'Accent'
            }
        }.GetNewClosure())

    return $allCombos
}

function New-FeatureToggleTabContent {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Control]$Tab,
        [Parameter(Mandatory)][object[]]$UnifiedItems,
        [hashtable]$ItemDetails,
        [switch]$ReturnContext
    )
    $pnlMicro = New-Object System.Windows.Forms.Panel
    $pnlMicro.Dock = 'Top'; $pnlMicro.Height = 28; $pnlMicro.BackColor = $script:clrPanel; $pnlMicro.Tag = 'MicroPanel'

    $btnDefAll = New-DarkButton -Text 'Default' -Width 86 -Height 26 -Role 'Neutral'
    $btnDefAll.Left = 0; $btnDefAll.Top = 2
    $btnEnableAll = New-DarkButton -Text 'Enable' -Width 86 -Height 26 -Role 'Accent'
    $btnEnableAll.Left = 92; $btnEnableAll.Top = 2
    $btnDisableAll = New-DarkButton -Text 'Disable' -Width 86 -Height 26 -Role 'Danger'
    $btnDisableAll.Left = 184; $btnDisableAll.Top = 2
    $btnSelectToggle = New-DarkButton -Text 'Select All' -Width 96 -Height 26 -Role 'Accent'
    $btnSelectToggle.Left = 276; $btnSelectToggle.Top = 2
    $pnlMicro.Controls.AddRange(@($btnDefAll, $btnEnableAll, $btnDisableAll, $btnSelectToggle))

    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock = 'Fill'
    $flow.FlowDirection = 'TopDown'
    $flow.WrapContents = $false
    $flow.AutoScroll = $true
    $flow.HorizontalScroll.Enabled = $false
    $flow.HorizontalScroll.Visible = $false
    $flow.BackColor = $script:clrPanelAlt
    $flow.Padding = New-Object System.Windows.Forms.Padding(4, 2, 4, 2)
    $flow.BorderStyle = 'None'

    $allCombos = [System.Collections.Generic.List[System.Windows.Forms.ComboBox]]::new()
    $allButtons = [System.Collections.Generic.List[System.Windows.Forms.Button]]::new()
    $allSelectors = [System.Collections.Generic.List[System.Windows.Forms.CheckBox]]::new()
    $allRows = [System.Collections.Generic.List[System.Windows.Forms.Panel]]::new()

    $dpObj = New-DetailPanel -Height 150 -DefaultText "Hover over a feature to view details."
    $detailPanel = $dpObj.Panel
    $detailBox = $dpObj.Box

    $bodyPanel = New-Object System.Windows.Forms.Panel
    $bodyPanel.Dock = 'Fill'
    $bodyPanel.BackColor = $script:clrPanelAlt
    $bodyPanel.Tag = 'PageBody'
    $bodyPanel.Controls.Add($flow)
    $bodyPanel.Controls.Add($detailPanel)
    $Tab.Controls.Add($bodyPanel)
    $Tab.Controls.Add($pnlMicro)

    $flow.SuspendLayout()
    foreach ($u in $UnifiedItems) {
        $row = New-Object System.Windows.Forms.Panel
        $row.Height = 30
        $row.BackColor = $flow.BackColor
        $row.Margin = New-Object System.Windows.Forms.Padding(0, 1, 0, 1)

        $cb = New-DarkComboBox -Items @('Default', 'Enabled', 'Disabled') -Text 'Default' -Width 1
        # State-only control: not added to row UI, prevents random drop-down artifacts.
        $cb.Visible = $false
        $cb.IntegralHeight = $false
        $cb.MaxDropDownItems = 1
        $cb.DropDownHeight = 1
        $cb.TabStop = $false
        $cb.Tag = @{ UiRole = 'InternalState'; SuppressUiChangeLog = $true }

        $lbl = New-DarkLabel -Text ([string]$u.Label) -Width 320 -Height 22
        $lbl.TextAlign = 'MiddleLeft'
        $lbl.AutoEllipsis = $true
        $lbl.Left = 34
        $lbl.Top = 4
        $lbl.Anchor = 'Top, Left, Right'

        $rowSelector = New-Object System.Windows.Forms.CheckBox
        $rowSelector.Text = '✓'
        $rowSelector.Checked = $false
        $rowSelector.UseVisualStyleBackColor = $false
        $rowSelector.Appearance = 'Button'
        $rowSelector.TextAlign = 'MiddleCenter'
        $rowSelector.BackColor = $script:clrInputBg
        $rowSelector.ForeColor = $script:clrAccent
        $rowSelector.FlatStyle = 'Flat'
        $rowSelector.FlatAppearance.BorderColor = $script:clrBorder
        $rowSelector.FlatAppearance.BorderSize = 1
        $rowSelector.FlatAppearance.CheckedBackColor = Get-ShiftedColor -Color $script:clrAccent -Delta -95
        $rowSelector.FlatAppearance.MouseOverBackColor = Get-ShiftedColor -Color $script:clrInputBg -Delta 8
        $rowSelector.FlatAppearance.MouseDownBackColor = Get-ShiftedColor -Color $script:clrInputBg -Delta -6
        $rowSelector.AutoSize = $false
        $rowSelector.Width = 22
        $rowSelector.Height = 22
        $rowSelector.Left = 8
        $rowSelector.Top = 4
        $rowSelector.Cursor = 'Hand'
        $rowSelector.Font = New-UiFont -Size 9.5 -Style ([System.Drawing.FontStyle]::Bold)
        $rowSelector.Tag = @{ UiRole = 'InternalState'; SuppressUiChangeLog = $true }
        $rowSelector.Add_CheckedChanged({
                if ($rowSelector.Checked) {
                    $rowSelector.Text = '✓'
                    $rowSelector.ForeColor = $clrAccent
                }
                else {
                    $rowSelector.Text = ''
                    $rowSelector.ForeColor = $clrMutedText
                }
            }.GetNewClosure())
        if (-not $rowSelector.Checked) {
            $rowSelector.Text = ''
            $rowSelector.ForeColor = $clrMutedText
        }

        $btnToggle = New-DarkButton -Text 'Default' -Width 112 -Height 24 -Role 'Neutral'
        $btnToggle.Left = [Math]::Max(80, $row.Width - $btnToggle.Width - 4)
        $btnToggle.Top = 2
        $btnToggle.Anchor = 'Top, Right'

        $applyFeatureButton = {
            param([string]$mode)
            switch ($mode) {
                'Enabled' {
                    Set-ButtonRole -Button $btnToggle -Role 'Accent'
                    $btnToggle.Text = 'Enable'
                }
                'Disabled' {
                    Set-ButtonRole -Button $btnToggle -Role 'Danger'
                    $btnToggle.Text = 'Disable'
                }
                default {
                    Set-ButtonRole -Button $btnToggle -Role 'Neutral'
                    $btnToggle.Text = 'Default'
                }
            }
        }.GetNewClosure()

        $setFeatureMode = {
            param([string]$mode)
            if ($mode -notin @('Default', 'Enabled', 'Disabled')) { $mode = 'Default' }
            if ([string]$cb.SelectedItem -ne $mode) { $cb.SelectedItem = $mode }
            & $applyFeatureButton $mode
        }.GetNewClosure()

        $cb.Add_SelectedIndexChanged({
                & $applyFeatureButton ([string]$cb.SelectedItem)
            }.GetNewClosure())

        $initialMode = if ($null -ne $u.PSObject.Properties['Mode']) { [string]$u.Mode } else { 'Default' }
        if ($initialMode -notin @('Default', 'Enabled', 'Disabled')) { $initialMode = 'Default' }
        & $setFeatureMode $initialMode

        $btnToggle.Add_Click({
                $nextMode = switch ([string]$cb.SelectedItem) {
                    'Default' { 'Enabled' }
                    'Enabled' { 'Disabled' }
                    default { 'Default' }
                }
                & $setFeatureMode $nextMode
            }.GetNewClosure())

        $layoutRow = {
            $btnToggle.Left = [Math]::Max(80, $row.ClientSize.Width - $btnToggle.Width - 4)
            $lbl.Left = 34
            $lbl.Width = [Math]::Max(120, $btnToggle.Left - $lbl.Left - 10)
            $rowSelector.Top = [Math]::Max(2, [int](($row.ClientSize.Height - $rowSelector.Height) / 2))
        }.GetNewClosure()
        $row.Add_Resize($layoutRow)
        & $layoutRow

        $row.Controls.Add($rowSelector)
        $row.Controls.Add($lbl)
        $row.Controls.Add($btnToggle)
        $flow.Controls.Add($row)
        $allCombos.Add($cb)
        $allButtons.Add($btnToggle)
        $allSelectors.Add($rowSelector)
        $allRows.Add($row)

        $detailText = if ($ItemDetails -and $ItemDetails.ContainsKey([string]$u.Label)) { [string]$ItemDetails[[string]$u.Label] } else { [string]$u.Label }
        $showDetail = { $detailBox.Text = $detailText }.GetNewClosure()
        $lbl.Add_MouseEnter($showDetail)
        $btnToggle.Add_MouseEnter($showDetail)
        $lbl.Add_GotFocus($showDetail)
        $btnToggle.Add_GotFocus($showDetail)
        $lbl.Add_Click({
                $rowSelector.Checked = -not $rowSelector.Checked
                & $showDetail
            }.GetNewClosure())
    }
    $flow.ResumeLayout($true)

    Register-DeferredRowWidthLayout -Flow $flow -Rows $allRows -MinWidth 240

    $setModeForSelected = {
        param([string]$mode)
        if ($mode -notin @('Default', 'Enabled', 'Disabled')) { return }
        for ($i = 0; $i -lt $allCombos.Count; $i++) {
            if (-not $allSelectors[$i].Checked) { continue }
            if ([string]$allCombos[$i].SelectedItem -ne $mode) { $allCombos[$i].SelectedItem = $mode }
        }
    }.GetNewClosure()
    $btnDefAll.Add_Click({ & $setModeForSelected 'Default' }.GetNewClosure())
    $btnEnableAll.Add_Click({ & $setModeForSelected 'Enabled' }.GetNewClosure())
    $btnDisableAll.Add_Click({ & $setModeForSelected 'Disabled' }.GetNewClosure())
    $btnSelectToggle.Add_Click({
            $shouldSelectAll = ($btnSelectToggle.Text -eq 'Select All')
            foreach ($sel in $allSelectors) { $sel.Checked = $shouldSelectAll }
            if ($shouldSelectAll) {
                $btnSelectToggle.Text = 'Clear All'
                Set-ButtonRole -Button $btnSelectToggle -Role 'Danger'
            }
            else {
                $btnSelectToggle.Text = 'Select All'
                Set-ButtonRole -Button $btnSelectToggle -Role 'Accent'
            }
        }.GetNewClosure())

    if ($ReturnContext) {
        return [pscustomobject]@{
            Combos    = $allCombos
            DetailBox = $detailBox
            Flow      = $flow
            Selectors = $allSelectors
        }
    }
    return $allCombos
}

function Add-TaskUiRow {
    param(
        [System.Windows.Forms.FlowLayoutPanel]$Flow,
        [System.Collections.IList]$Combos,
        [System.Collections.IList]$Rows,
        [System.Collections.IList]$Selectors = $null,
        [string]$Label,
        [string]$State = 'Default',
        [hashtable]$ItemDetails = $null,
        [System.Windows.Forms.RichTextBox]$DetailBox = $null
    )
    $row = New-Object System.Windows.Forms.Panel
    $row.Height = 30
    $row.BackColor = $Flow.BackColor
    $row.Margin = New-Object System.Windows.Forms.Padding(0, 1, 0, 1)
    $row.Width = Get-SafeScrollableRowWidth -Container $Flow -MinWidth 240 -RightGutter 34

    $cb = New-DarkComboBox -Items @('Default', 'Enabled', 'Disabled') -Text $State -Width 1
    # State-only control: not added to row UI, prevents random drop-down artifacts.
    $cb.Visible = $false
    $cb.IntegralHeight = $false
    $cb.MaxDropDownItems = 1
    $cb.DropDownHeight = 1
    $cb.TabStop = $false
    $cb.Tag = @{ UiRole = 'InternalState'; SuppressUiChangeLog = $true }

    $lbl = New-DarkLabel -Text $Label -Width 320 -Height 22
    $lbl.TextAlign = 'MiddleLeft'
    $lbl.AutoEllipsis = $true
    $lbl.Left = 34
    $lbl.Top = 4
    $lbl.Anchor = 'Top, Left, Right'

    $rowSelector = New-Object System.Windows.Forms.CheckBox
    $rowSelector.Text = '✓'
    $rowSelector.Checked = $false
    $rowSelector.UseVisualStyleBackColor = $false
    $rowSelector.Appearance = 'Button'
    $rowSelector.TextAlign = 'MiddleCenter'
    $rowSelector.BackColor = $script:clrInputBg
    $rowSelector.ForeColor = $script:clrAccent
    $rowSelector.FlatStyle = 'Flat'
    $rowSelector.FlatAppearance.BorderColor = $script:clrBorder
    $rowSelector.FlatAppearance.BorderSize = 1
    $rowSelector.FlatAppearance.CheckedBackColor = Get-ShiftedColor -Color $script:clrAccent -Delta -95
    $rowSelector.FlatAppearance.MouseOverBackColor = Get-ShiftedColor -Color $script:clrInputBg -Delta 8
    $rowSelector.FlatAppearance.MouseDownBackColor = Get-ShiftedColor -Color $script:clrInputBg -Delta -6
    $rowSelector.AutoSize = $false
    $rowSelector.Width = 22
    $rowSelector.Height = 22
    $rowSelector.Left = 8
    $rowSelector.Top = 4
    $rowSelector.Cursor = 'Hand'
    $rowSelector.Font = New-UiFont -Size 9.5 -Style ([System.Drawing.FontStyle]::Bold)
    $rowSelector.Tag = @{ UiRole = 'InternalState'; SuppressUiChangeLog = $true }
    $rowSelector.Add_CheckedChanged({
            if ($rowSelector.Checked) {
                $rowSelector.Text = '✓'
                $rowSelector.ForeColor = $clrAccent
            }
            else {
                $rowSelector.Text = ''
                $rowSelector.ForeColor = $clrMutedText
            }
        }.GetNewClosure())
    if (-not $rowSelector.Checked) {
        $rowSelector.Text = ''
        $rowSelector.ForeColor = $clrMutedText
    }

    $btnToggle = New-DarkButton -Text 'Default' -Width 112 -Height 24 -Role 'Neutral'
    $btnToggle.Left = [Math]::Max(80, $row.Width - $btnToggle.Width - 4)
    $btnToggle.Top = 2
    $btnToggle.Anchor = 'Top, Right'

    $applyTaskButton = {
        param([string]$mode)
        switch ($mode) {
            'Enabled' {
                Set-ButtonRole -Button $btnToggle -Role 'Accent'
                $btnToggle.Text = 'Enable'
            }
            'Disabled' {
                Set-ButtonRole -Button $btnToggle -Role 'Danger'
                $btnToggle.Text = 'Disable'
            }
            default {
                Set-ButtonRole -Button $btnToggle -Role 'Neutral'
                $btnToggle.Text = 'Default'
            }
        }
    }.GetNewClosure()

    $setTaskMode = {
        param([string]$mode)
        if ($mode -notin @('Default', 'Enabled', 'Disabled')) { $mode = 'Default' }
        if ([string]$cb.SelectedItem -ne $mode) { $cb.SelectedItem = $mode }
        & $applyTaskButton $mode
    }.GetNewClosure()

    $cb.Add_SelectedIndexChanged({
            & $applyTaskButton ([string]$cb.SelectedItem)
        }.GetNewClosure())

    $initialState = if ($State -in @('Default', 'Enabled', 'Disabled')) { $State } else { 'Default' }
    & $setTaskMode $initialState

    $btnToggle.Add_Click({
            $nextMode = switch ([string]$cb.SelectedItem) {
                'Default' { 'Enabled' }
                'Enabled' { 'Disabled' }
                default { 'Default' }
            }
            & $setTaskMode $nextMode
        }.GetNewClosure())

    $layoutRow = {
        $btnToggle.Left = [Math]::Max(80, $row.ClientSize.Width - $btnToggle.Width - 4)
        $lbl.Left = 34
        $lbl.Width = [Math]::Max(120, $btnToggle.Left - $lbl.Left - 10)
        $rowSelector.Top = [Math]::Max(2, [int](($row.ClientSize.Height - $rowSelector.Height) / 2))
    }.GetNewClosure()
    $row.Add_Resize($layoutRow)
    & $layoutRow

    $row.Controls.Add($rowSelector)
    $row.Controls.Add($lbl)
    $row.Controls.Add($btnToggle)
    $Flow.Controls.Add($row)
    [void]$Combos.Add($cb)
    [void]$Rows.Add($row)
    if ($null -ne $Selectors) { [void]$Selectors.Add($rowSelector) }

    $detailText = if ($ItemDetails -and $ItemDetails.ContainsKey($Label)) { $ItemDetails[$Label] } else { $Label }
    $showDetail = {
        if ($null -ne $DetailBox) { $DetailBox.Text = $detailText }
        $sync.LastSelectedTaskCombo = $cb
    }.GetNewClosure()

    $lbl.Add_MouseEnter($showDetail)
    $btnToggle.Add_MouseEnter($showDetail)
    $lbl.Add_Click({
            $rowSelector.Checked = -not $rowSelector.Checked
            & $showDetail
        }.GetNewClosure())
    $btnToggle.Add_Click($showDetail)
    $lbl.Add_GotFocus($showDetail)
    $btnToggle.Add_GotFocus($showDetail)

    return $row
}

function New-TaskTabContent {
    param(
        [System.Windows.Forms.Control]$Tab,
        [object[]]$UnifiedItems,
        [hashtable]$ItemDetails,
        [string[]]$ExtraButtons
    )
    $extraButtonMap = @{}
    $pnlMicro = New-Object System.Windows.Forms.Panel
    $pnlMicro.Dock = 'Top'; $pnlMicro.Height = 28; $pnlMicro.BackColor = $script:clrPanel; $pnlMicro.Tag = 'MicroPanel'

    $btnDefAll = New-DarkButton -Text 'Default' -Width 86 -Height 26 -Role 'Neutral'
    $btnDefAll.Left = 0; $btnDefAll.Top = 2
    $btnEnableAll = New-DarkButton -Text 'Enable' -Width 86 -Height 26 -Role 'Accent'
    $btnEnableAll.Left = 92; $btnEnableAll.Top = 2
    $btnDisableAll = New-DarkButton -Text 'Disable' -Width 86 -Height 26 -Role 'Danger'
    $btnDisableAll.Left = 184; $btnDisableAll.Top = 2
    $btnSelectToggle = New-DarkButton -Text 'Select All' -Width 96 -Height 26 -Role 'Accent'
    $btnSelectToggle.Left = 276; $btnSelectToggle.Top = 2
    $pnlMicro.Controls.AddRange(@($btnDefAll, $btnEnableAll, $btnDisableAll, $btnSelectToggle))

    $nextButtonLeft = 378
    foreach ($extraText in $ExtraButtons) {
        if ([string]::IsNullOrWhiteSpace($extraText)) { continue }
        $btnWidth = 110
        $btnColor = $null; $btnRole = 'Normal'
        if ($extraText -match 'Add') { $btnColor = $script:clrBrowseBtn; $btnRole = 'Browse' }
        elseif ($extraText -match 'Remove') { $btnColor = $script:clrDanger; $btnRole = 'Danger' }
        $btnExtra = New-DarkButton -Text $extraText -Width $btnWidth -Height 26 -BgColor $btnColor -Role $btnRole
        $btnExtra.Left = $nextButtonLeft; $btnExtra.Top = 2
        $nextButtonLeft += ($btnWidth + 4)
        $pnlMicro.Controls.Add($btnExtra)
        $extraButtonMap[$extraText] = $btnExtra
    }

    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock = 'Fill'; $flow.FlowDirection = 'TopDown'; $flow.WrapContents = $false; $flow.AutoScroll = $true; $flow.HorizontalScroll.Enabled = $false; $flow.HorizontalScroll.Visible = $false
    $flow.BackColor = $script:clrPanelAlt; $flow.Padding = New-Object System.Windows.Forms.Padding(4, 2, 4, 2); $flow.BorderStyle = 'None'

    $allCombos = [System.Collections.Generic.List[System.Windows.Forms.ComboBox]]::new()
    $allSelectors = [System.Collections.Generic.List[System.Windows.Forms.CheckBox]]::new()
    $allRows = [System.Collections.Generic.List[System.Windows.Forms.Panel]]::new()

    $dpObj = New-DetailPanel -Height 140 -DefaultText "Hover over a task to view details."
    $detailPanel = $dpObj.Panel
    $detailBox = $dpObj.Box

    $bodyPanel = New-Object System.Windows.Forms.Panel
    $bodyPanel.Dock = 'Fill'; $bodyPanel.BackColor = $script:clrPanelAlt; $bodyPanel.Tag = 'PageBody'
    $bodyPanel.Controls.Add($flow); $bodyPanel.Controls.Add($detailPanel)
    $Tab.Controls.Add($bodyPanel)
    $Tab.Controls.Add($pnlMicro)

    $flow.SuspendLayout()
    foreach ($u in $UnifiedItems) {
        Add-TaskUiRow -Flow $flow -Combos $allCombos -Rows $allRows -Selectors $allSelectors -Label $u.Label -State $u.DefaultState -ItemDetails $ItemDetails -DetailBox $detailBox
    }
    $flow.ResumeLayout($true)

    $flow.Add_Resize({
            param($sender, $e)
            $newWidth = Get-SafeScrollableRowWidth -Container $sender -MinWidth 240 -RightGutter 34
            foreach ($r in $allRows) { $r.Width = $newWidth }
        }.GetNewClosure())

    $setModeForSelected = {
        param([string]$mode)
        if ($mode -notin @('Default', 'Enabled', 'Disabled')) { return }
        for ($i = 0; $i -lt $allCombos.Count; $i++) {
            if (-not $allSelectors[$i].Checked) { continue }
            if ([string]$allCombos[$i].SelectedItem -ne $mode) { $allCombos[$i].SelectedItem = $mode }
        }
    }.GetNewClosure()
    $btnDefAll.Add_Click({ & $setModeForSelected 'Default' }.GetNewClosure())
    $btnEnableAll.Add_Click({ & $setModeForSelected 'Enabled' }.GetNewClosure())
    $btnDisableAll.Add_Click({ & $setModeForSelected 'Disabled' }.GetNewClosure())
    $btnSelectToggle.Add_Click({
            $shouldSelectAll = ($btnSelectToggle.Text -eq 'Select All')
            foreach ($sel in $allSelectors) { $sel.Checked = $shouldSelectAll }
            if ($shouldSelectAll) {
                $btnSelectToggle.Text = 'Clear All'
                Set-ButtonRole -Button $btnSelectToggle -Role 'Danger'
            }
            else {
                $btnSelectToggle.Text = 'Select All'
                Set-ButtonRole -Button $btnSelectToggle -Role 'Accent'
            }
        }.GetNewClosure())

    return [pscustomobject]@{
        Combos       = $allCombos
        Selectors    = $allSelectors
        Rows         = $allRows
        Flow         = $flow
        DetailBox    = $detailBox
        ExtraButtons = $extraButtonMap
    }
}

function Format-ScheduledTaskPath {
    param([string]$TaskPath)
    $path = [string]$TaskPath
    if ([string]::IsNullOrWhiteSpace($path)) { return '' }
    $path = ($path -replace '/', '\').Trim().Trim('"')
    $path = $path -replace '\\{2,}', '\'
    if (-not $path.StartsWith('\')) { $path = "\$path" }
    return $path
}

function Test-ScheduledTaskPathIsSafe {
    param([string]$TaskPath)

    if ([string]::IsNullOrWhiteSpace($TaskPath)) { return $false }
    $value = [string]$TaskPath
    if ($value.Length -gt 260) { return $false }

    # Reject control characters and command-string breakers used later in generated scripts.
    if ($value -match '[\r\n\t`"]') { return $false }
    return $true
}

function Get-ScheduledTaskUiLabel {
    param([string]$TaskPath)
    $normalizedPath = Format-ScheduledTaskPath -TaskPath $TaskPath
    if ([string]::IsNullOrWhiteSpace($normalizedPath)) { return '' }
    if ($TaskLabels.ContainsKey($normalizedPath)) { return [string]$TaskLabels[$normalizedPath] }
    return $normalizedPath
}

function Convert-ServiceIdToUiLabel {
    param([string]$ServiceId)
    $id = [string]$ServiceId
    if ([string]::IsNullOrWhiteSpace($id)) { return '' }

    $pretty = $id
    $pretty = $pretty -replace '[_\-]+', ' '
    $pretty = $pretty -creplace '([a-z0-9])([A-Z])', '$1 $2'
    $pretty = $pretty -creplace '([A-Z]+)([A-Z][a-z])', '$1 $2'
    $pretty = $pretty -creplace '\bSvc\b', 'Service'
    $pretty = $pretty -creplace '\bMgr\b', 'Manager'
    $pretty = $pretty -creplace '\bWMI\b', 'WMI'
    $pretty = $pretty -creplace '\bRPC\b', 'RPC'
    $pretty = $pretty -replace '\s+', ' '
    $pretty = $pretty.Trim()

    if ([string]::Equals($pretty, $id, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $id
    }
    return "$pretty ($id)"
}

function Normalize-ServiceUiLabel {
    param(
        [string]$Label,
        [string]$ServiceId = ''
    )

    $value = [string]$Label
    if ([string]::IsNullOrWhiteSpace($value)) { return '' }
    $value = $value.Trim()

    switch -Regex ($value) {
        '^(?i)Connected User Experiences and Telemetry Service$' { return 'Connected User Experiences and Telemetry' }
        '^(?i)SysMain Service \(Superfetch\)$' { return 'SysMain' }
        '^(?i)Print Spooler Service$' { return 'Print Spooler' }
        '^(?i)Windows Insider Service$' { return 'Windows Insider' }
        '^(?i)Smart Card Service$' { return 'Smart Card' }
        '^(?i)Fax Service$' { return 'Fax' }
        '^(?i)Windows Mixed Reality OpenXR Service$' { return 'Windows Mixed Reality OpenXR' }
    }

    return $value
}

function Get-ServiceUiLabelBase {
    param([string]$ServiceId)
    if ($ServiceLabels.ContainsKey($ServiceId) -and -not [string]::IsNullOrWhiteSpace([string]$ServiceLabels[$ServiceId])) {
        return (Normalize-ServiceUiLabel -Label ([string]$ServiceLabels[$ServiceId]) -ServiceId $ServiceId)
    }
    return (Convert-ServiceIdToUiLabel -ServiceId $ServiceId)
}

function Test-ServiceHasMetadata {
    param([string]$ServiceId)

    if ([string]::IsNullOrWhiteSpace($ServiceId)) { return $false }
    $sid = [string]$ServiceId

    $hasEffect = $ServiceDetails.ContainsKey($sid) -and -not [string]::IsNullOrWhiteSpace([string]$ServiceDetails[$sid])
    $hasRuntime = $ServiceRuntimeDetails.ContainsKey($sid) -and -not [string]::IsNullOrWhiteSpace([string]$ServiceRuntimeDetails[$sid])
    return ($hasEffect -or $hasRuntime)
}

function Get-ServiceDetailText {
    param([string]$ServiceId)
    $serviceLabel = Get-ServiceUiLabelBase -ServiceId $ServiceId
    $serviceEffect = if ($ServiceDetails.ContainsKey($ServiceId) -and -not [string]::IsNullOrWhiteSpace([string]$ServiceDetails[$ServiceId])) {
        [string]$ServiceDetails[$ServiceId]
    }
    else {
        ''
    }
    $runtimeDetail = if ($ServiceRuntimeDetails.ContainsKey($ServiceId) -and -not [string]::IsNullOrWhiteSpace([string]$ServiceRuntimeDetails[$ServiceId])) {
        [string]$ServiceRuntimeDetails[$ServiceId]
    }
    else {
        ''
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Service: $serviceLabel")
    $lines.Add("Service ID: $ServiceId")
    if (-not [string]::IsNullOrWhiteSpace($serviceEffect)) {
        $lines.Add("Effect: $serviceEffect")
    }
    if (-not [string]::IsNullOrWhiteSpace($runtimeDetail)) {
        $lines.Add("Runtime: $runtimeDetail")
    }
    return ($lines -join "`r`n")
}

$tabAppx, $btnAppx = New-ContentPage 'App Packages'
$tabFeatures, $btnFeatures = New-ContentPage 'Features & Capabilities'
$tabDrivers, $btnDrivers = New-ContentPage 'Driver Packages'
$tabSecurity, $btnSecurity = New-ContentPage 'Security Baselines'
$tabExtraSecurity, $btnExtraSecurity = New-ContentPage 'Security Hardening'
$tabPrivacy, $btnPrivacy = New-ContentPage 'Privacy & Security'
$tabTasks, $btnTasks = New-ContentPage 'Task Scheduler'
$tabServices, $btnServices = New-ContentPage 'Windows Services'
$tabAdvanced, $btnAdvancedNav = Add-ExistingContentPage -Title 'Advanced Setup' -Page $advancedPanel

# Keep Logs page available as a standalone build page (not in left nav).
$tabLogs = New-Object System.Windows.Forms.Panel
$tabLogs.Dock = 'Fill'
$tabLogs.Visible = $false
$tabLogs.BackColor = $clrPanelAlt
$contentPanel.Controls.Add($tabLogs)
$script:LastNonLogNavBtn = $btnAppx
$script:LastNonLogPage = $tabAppx

function Show-StandaloneLogsPage {
    if ($null -eq $tabLogs -or $tabLogs.IsDisposed) { return }
    if ($script:IsLogsStandaloneVisible -and $script:ActivePage -eq $tabLogs) { return }

    if ($script:ActivePage -ne $tabLogs) {
        if ($null -ne $script:ActiveNavBtn -and -not $script:ActiveNavBtn.IsDisposed) {
            $script:LastNonLogNavBtn = $script:ActiveNavBtn
            $script:LastNonLogPage = $script:ActivePage
        }
        elseif ($null -eq $script:LastNonLogPage) {
            $script:LastNonLogNavBtn = $btnAppx
            $script:LastNonLogPage = $tabAppx
        }
    }

    $comboRoot = if ($null -ne $script:ActivePage -and -not $script:ActivePage.IsDisposed) { $script:ActivePage } else { $contentPanel }
    Close-AllComboDropDowns -Root $comboRoot

    if ($script:ActiveNavBtn) {
        $script:ActiveNavBtn.Tag.Role = 'Nav'
        $script:ActiveNavBtn.Font = $script:FontNavReg
        $script:ActiveNavBtn.Invalidate()
    }
    $script:ActiveNavBtn = $null

    $contentPanel.SuspendLayout()
    if ($null -ne $mainContainer) { $mainContainer.SuspendLayout() }
    try {
        if ($null -ne $script:ActivePage -and $script:ActivePage -ne $tabLogs -and -not $script:ActivePage.IsDisposed) {
            $script:ActivePage.Visible = $false
        }
        elseif ($null -eq $script:ActivePage) {
            foreach ($c in $contentPanel.Controls) {
                if ($c.Visible) { $c.Visible = $false }
            }
        }
        $script:ActivePage = $tabLogs
        if ($tabLogs.Visible -ne $true) { $tabLogs.Visible = $true }
        $script:IsLogsStandaloneVisible = $true
        if ($topPanel.Visible -ne $false) { $topPanel.Visible = $false }
        if ($navPanel.Visible -ne $false) { $navPanel.Visible = $false }
        Update-SectionLayout
    }
    finally {
        if ($null -ne $mainContainer) { $mainContainer.ResumeLayout() }
        $contentPanel.ResumeLayout()
    }

    Write-Log "UI change: Switched page -> Logs (standalone)" -Color White
}

function Exit-StandaloneLogsPage {
    if (-not $script:IsLogsStandaloneVisible) { return }

    $targetBtn = $btnAppx
    $targetPage = $tabAppx
    if ($null -ne $script:LastNonLogNavBtn -and -not $script:LastNonLogNavBtn.IsDisposed -and
        $null -ne $script:LastNonLogPage -and -not $script:LastNonLogPage.IsDisposed) {
        $targetBtn = $script:LastNonLogNavBtn
        $targetPage = $script:LastNonLogPage
    }
    Switch-Tab -Btn $targetBtn -Page $targetPage
}

# Activate first tab
Switch-Tab -Btn $btnAppx -Page $tabAppx

# Drivers page (active feature page)
$lblDrvTitle = New-DarkLabel -Text 'Driver Packages' -Width 600 -Height 28
$lblDrvTitle.Left = 12
$lblDrvTitle.Top = 12
$lblDrvTitle.Anchor = 'Top, Left, Right'
$lblDrvTitle.Font = New-UiFont -Size 13 -Style ([System.Drawing.FontStyle]::Bold)

$lblDrvExtract = New-DarkLabel -Text 'Export Driver Packages from This PC (Online)' -Width 460 -Height 22
$lblDrvExtract.Left = 12
$lblDrvExtract.Top = 52
$lblDrvExtract.Anchor = 'Top, Left, Right'
$lblDrvExtract.Font = New-UiFont -Size 10 -Style ([System.Drawing.FontStyle]::Bold)

$drvExtractRow = New-CompactPathRow -LabelText 'Export Destination:' -DefaultText $sync.DriverExtractDir -ReadOnly $false -InfoMode 'Folder' -CueText 'Select destination folder for exported driver packages (.inf)...' -Top 78 -Parent $tabDrivers
$tbDriverExtract = $drvExtractRow.TextBox
$btnBrowseDriverExtract = $drvExtractRow.Button
$btnExtractDrivers = New-DarkButton -Text 'Export Drivers' -Width 150 -Height 32 -Role 'Cyan'
$btnExtractDrivers.Left = 12
$btnExtractDrivers.Top = 146

$lblDrvInject = New-DarkLabel -Text 'Add Driver Packages to install.wim (Offline Image)' -Width 460 -Height 22
$lblDrvInject.Left = 12
$lblDrvInject.Top = 196
$lblDrvInject.Anchor = 'Top, Left, Right'
$lblDrvInject.Font = New-UiFont -Size 10 -Style ([System.Drawing.FontStyle]::Bold)

$drvInjectRow = New-CompactPathRow -LabelText 'Driver Package Source:' -DefaultText $sync.DriverSourceDir -ReadOnly $false -InfoMode 'Folder' -CueText 'Select source folder containing driver .inf files...' -Top 222 -Parent $tabDrivers
$tbDriverSource = $drvInjectRow.TextBox
$btnBrowseDriverSource = $drvInjectRow.Button

$cbInjectInstall = New-DarkCheckBox -Text 'Add to install.wim (DISM /Add-Driver)'
$cbInjectInstall.Left = 12
$cbInjectInstall.Top = 292
$cbInjectInstall.Checked = [bool]$sync.InjectDriversInstallWim

$cbDriverRecurse = New-DarkCheckBox -Text 'Include subfolders (/Recurse)'
$cbDriverRecurse.Left = 12
$cbDriverRecurse.Top = 320
$cbDriverRecurse.Checked = [bool]$sync.DriverInjectRecurse

$lblDrvHint = New-Object System.Windows.Forms.Label
$lblDrvHint.Left = 12
$lblDrvHint.Top = 354
$lblDrvHint.Width = [Math]::Max(320, $tabDrivers.ClientSize.Width - 24)
$lblDrvHint.Height = 66
$lblDrvHint.Anchor = 'Top, Left, Right'
$lblDrvHint.AutoSize = $false
$lblDrvHint.ForeColor = $clrMutedText
$lblDrvHint.Font = New-UiFont -Size 9
$lblDrvHint.Text = "Uses Microsoft driver-package servicing (.inf). Best results: vendor signed packs (Intel/Realtek/Qualcomm/AMD/NVIDIA)."

$layoutDrivers = {
    $contentWidth = [Math]::Max(520, $tabDrivers.ClientSize.Width - 24)

    $lblDrvTitle.Width = $contentWidth
    $lblDrvExtract.Width = $contentWidth
    $lblDrvInject.Width = $contentWidth

    $drvExtractRow.Panel.Left = 12
    $drvExtractRow.Panel.Width = $contentWidth
    $btnExtractDrivers.Top = $drvExtractRow.Panel.Bottom + 12

    $lblDrvInject.Top = $btnExtractDrivers.Bottom + 16
    $drvInjectRow.Panel.Left = 12
    $drvInjectRow.Panel.Top = $lblDrvInject.Bottom + 6
    $drvInjectRow.Panel.Width = $contentWidth

    $cbInjectInstall.Left = 12
    $cbInjectInstall.Top = $drvInjectRow.Panel.Bottom + 12

    $cbDriverRecurse.Left = 12
    $cbDriverRecurse.Top = $cbInjectInstall.Bottom + 8

    $lblDrvHint.Left = 12
    $lblDrvHint.Width = [Math]::Max(320, $tabDrivers.ClientSize.Width - 24)
    $lblDrvHint.Top = $cbDriverRecurse.Bottom + 12

    $tabDrivers.AutoScrollMinSize = [System.Drawing.Size]::new(0, [int]($lblDrvHint.Bottom + 20))
}.GetNewClosure()

$tabDrivers.Controls.AddRange(@(
        $lblDrvTitle,
        $lblDrvExtract,
        $btnExtractDrivers,
        $lblDrvInject,
        $cbInjectInstall,
        $cbDriverRecurse,
        $lblDrvHint
    ))
$tabDrivers.Add_Resize($layoutDrivers)
$tabDrivers.Add_VisibleChanged({
        if ($tabDrivers.Visible) { & $layoutDrivers }
    }.GetNewClosure())
& $layoutDrivers

$btnBrowseDriverExtract.Add_Click({
        try {
            $selectedFolder = Show-ExplorerFolderPicker -Title 'Select Driver Package Export Destination' -InitialPath (Get-PathTextBoxValue -Control $tbDriverExtract)
            if (-not [string]::IsNullOrWhiteSpace($selectedFolder)) {
                Set-PathTextBoxValue -Control $tbDriverExtract -Value $selectedFolder
                $sync.DriverExtractDir = $selectedFolder
            }
        }
        catch { [System.Windows.Forms.MessageBox]::Show("Error: $_", "Error", "OK", "Error") | Out-Null }
    })

$btnBrowseDriverSource.Add_Click({
        try {
            $selectedFolder = Show-ExplorerFolderPicker -Title 'Select Driver Package Source Folder' -InitialPath (Get-PathTextBoxValue -Control $tbDriverSource)
            if (-not [string]::IsNullOrWhiteSpace($selectedFolder)) {
                Set-PathTextBoxValue -Control $tbDriverSource -Value $selectedFolder
                $sync.DriverSourceDir = $selectedFolder
            }
        }
        catch { [System.Windows.Forms.MessageBox]::Show("Error: $_", "Error", "OK", "Error") | Out-Null }
    })

$btnExtractDrivers.Add_Click({
        try {
            $targetDir = Get-PathTextBoxValue -Control $tbDriverExtract
            if ([string]::IsNullOrWhiteSpace($targetDir)) {
                [System.Windows.Forms.MessageBox]::Show("Please select an export destination folder first.", "Driver Packages", "OK", "Warning") | Out-Null
                return
            }
            if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }

            Write-Log "Extracting current system drivers to: $targetDir" -Color Cyan
            $btnExtractDrivers.Enabled = $false
            try {
                $usedFallback = $false
                $primaryError = $null

                try {
                    if (Get-Command -Name Export-WindowsDriver -ErrorAction SilentlyContinue) {
                        Export-WindowsDriver -Online -Destination $targetDir -ErrorAction Stop | Out-Null
                    }
                    else {
                        throw "Export-WindowsDriver cmdlet is not available in this PowerShell host."
                    }
                }
                catch {
                    $primaryError = $_.Exception.Message
                    $usedFallback = $true
                    Write-Log "Export-WindowsDriver failed. Falling back to dism.exe..." -Color Yellow

                    $dismOutput = & dism.exe /Online /Export-Driver /Destination:"$targetDir" 2>&1
                    if ($dismOutput) { Write-Log ($dismOutput -join "`n") -Color White }
                    if ($LASTEXITCODE -notin @(0, 3010)) {
                        throw "DISM fallback failed (exit code $LASTEXITCODE). Primary error: $primaryError"
                    }
                }

                $infCount = (Get-ChildItem -Path $targetDir -Filter '*.inf' -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
                if ($infCount -eq 0) {
                    throw "Driver export completed but no .inf files were found in the destination folder."
                }

                Write-Log "Driver package export completed." -Color Green
                $method = if ($usedFallback) { "DISM fallback" } else { "Export-WindowsDriver" }
                [System.Windows.Forms.MessageBox]::Show("Driver packages exported successfully using $method.`n`nExported .inf files: $infCount`nLocation: $targetDir", "Driver Packages", "OK", "Information") | Out-Null
            }
            finally {
                $btnExtractDrivers.Enabled = $true
            }
        }
        catch {
            Write-Log "Driver package export failed: $_" -Color Red
            [System.Windows.Forms.MessageBox]::Show("Driver package export failed:`n`n$_", "Driver Packages", "OK", "Error") | Out-Null
        }
    })

# Security baseline profiles page
$lblSecTitle = New-DarkLabel -Text 'Security Baselines' -Width 620 -Height 28
$lblSecTitle.Left = 12
$lblSecTitle.Top = 12
$lblSecTitle.Anchor = 'Top, Left, Right'
$lblSecTitle.Font = New-UiFont -Size 13 -Style ([System.Drawing.FontStyle]::Bold)

$btnSecurityBalanced = New-DarkButton -Text 'Recommended' -Width 170 -Height 38 -Role 'PresetActive'
$btnSecurityBalanced.Left = 12
$btnSecurityBalanced.Top = 52
$btnSecurityHardened = New-DarkButton -Text 'Hardened' -Width 170 -Height 38 -Role 'Nav'
$btnSecurityHardened.Left = 198
$btnSecurityHardened.Top = 52

$btnSecurityMaximum = New-DarkButton -Text 'Maximum' -Width 170 -Height 38 -Role 'Nav'
$btnSecurityMaximum.Left = 384
$btnSecurityMaximum.Top = 52

$securityPresetDetails = @{
    'Balanced' = @(
        'Recommended baseline profile (best compatibility).'
        'Attack Surface Reduction (ASR): Safe = Block | Moderate = Audit | Aggressive = Off'
        'User Account Control (UAC): Default notify level.'
        'Microsoft Defender MAPS: Enabled | Sample submission: Prompt | Reporting: Enabled'
    )
    'Hardened' = @(
        'Hardened baseline profile for security-focused deployments.'
        'First-Run Safety Mode: first boot uses Moderate ASR = Audit.'
        'UAC: Always notify.'
        'After first successful sign-in, Moderate ASR automatically switches to Block.'
    )
    'Maximum'  = @(
        'Maximum lockdown baseline profile.'
        'ASR policy levels: Safe = Block | Moderate = Block | Aggressive = Block'
        'UAC: Always notify.'
        'Microsoft Defender MAPS: Enabled | Sample submission: Automatic | Reporting: Enabled'
    )
}

$lblSecDetail = New-Object System.Windows.Forms.Label
$lblSecDetail.Left = 12
$lblSecDetail.Top = 118
$lblSecDetail.Width = 640
$lblSecDetail.Height = 100
$lblSecDetail.Anchor = 'Top, Left, Right'
$lblSecDetail.AutoSize = $false
$lblSecDetail.AutoEllipsis = $false
$lblSecDetail.UseCompatibleTextRendering = $true
$lblSecDetail.Tag = 'SecurityDetailLabel'
$lblSecDetail.ForeColor = $clrText
$lblSecDetail.BackColor = $clrPanelAlt
$lblSecDetail.Font = New-UiFont -Size 10
$lblSecDetail.TextAlign = 'TopLeft'
$lblSecDetail.Padding = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)

$updateSecurityDetailLayout = {
    $measureBounds = New-Object System.Drawing.Size([Math]::Max(220, $lblSecDetail.Width), 0)
    $measureFlags = [System.Windows.Forms.TextFormatFlags]::WordBreak
    $measuredText = [System.Windows.Forms.TextRenderer]::MeasureText($lblSecDetail.Text, $lblSecDetail.Font, $measureBounds, $measureFlags)
    $lblSecDetail.Height = [Math]::Max(100, [int]($measuredText.Height + 10))
}.GetNewClosure()

$setSecurityPreset = {
    param([ValidateSet('Balanced', 'Hardened', 'Maximum')][string]$Preset)
    $sync.SecurityPreset = $Preset

    $roleBalanced = 'Nav'
    $roleHardened = 'Nav'
    $roleMaximum = 'Nav'
    if ($Preset -eq 'Balanced') { $roleBalanced = 'PresetActive' }
    elseif ($Preset -eq 'Hardened') { $roleHardened = 'PresetActive' }
    elseif ($Preset -eq 'Maximum') { $roleMaximum = 'PresetActive' }

    Set-ButtonRole -Button $btnSecurityBalanced -Role $roleBalanced
    Set-ButtonRole -Button $btnSecurityHardened -Role $roleHardened
    Set-ButtonRole -Button $btnSecurityMaximum -Role $roleMaximum

    if ($Preset -eq 'Balanced') { $btnSecurityBalanced.Font = $script:FontNavBold } else { $btnSecurityBalanced.Font = $script:FontNavReg }
    if ($Preset -eq 'Hardened') { $btnSecurityHardened.Font = $script:FontNavBold } else { $btnSecurityHardened.Font = $script:FontNavReg }
    if ($Preset -eq 'Maximum') { $btnSecurityMaximum.Font = $script:FontNavBold } else { $btnSecurityMaximum.Font = $script:FontNavReg }

    $detailLines = @($securityPresetDetails[$Preset])
    $lblSecDetail.Text = ($detailLines -join "`r`n")
    & $updateSecurityDetailLayout
}.GetNewClosure()

$layoutSecurityPreset = {
    $contentWidth = [Math]::Max(560, $tabSecurity.ClientSize.Width - 24)
    $lblSecTitle.Width = $contentWidth
    $btnSecurityBalanced.Left = 12
    $btnSecurityHardened.Left = $btnSecurityBalanced.Right + 16
    $btnSecurityMaximum.Left = $btnSecurityHardened.Right + 16
    $lblSecDetail.Top = $btnSecurityMaximum.Bottom + 28
    $lblSecDetail.Width = [Math]::Max(540, $tabSecurity.ClientSize.Width - 24)
    & $updateSecurityDetailLayout
    $tabSecurity.AutoScrollMinSize = [System.Drawing.Size]::new(0, [int]($lblSecDetail.Bottom + 20))
}.GetNewClosure()

$btnSecurityBalanced.Add_Click({ & $setSecurityPreset 'Balanced' })
$btnSecurityHardened.Add_Click({ & $setSecurityPreset 'Hardened' })
$btnSecurityMaximum.Add_Click({ & $setSecurityPreset 'Maximum' })

$tabSecurity.Controls.AddRange(@(
        $lblSecTitle,
        $btnSecurityBalanced,
        $btnSecurityHardened,
        $btnSecurityMaximum,
        $lblSecDetail
    ))
$tabSecurity.Add_Resize($layoutSecurityPreset)
$tabSecurity.Add_VisibleChanged({
        if ($tabSecurity.Visible) { & $layoutSecurityPreset }
    }.GetNewClosure())
& $setSecurityPreset ([string]$sync.SecurityPreset)
& $layoutSecurityPreset

# Remove Apps toggle list (deduplicated)
$appxEntryMap = [ordered]@{}
$appxEntryIdSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$appxSelectionExpansions = @{
    'Microsoft.GamingApp' = @(
        'Microsoft.Xbox.TCUI'
        'Microsoft.XboxGameOverlay'
        'Microsoft.XboxGamingOverlay'
        'Microsoft.XboxIdentityProvider'
        'Microsoft.XboxSpeechToTextOverlay'
    )
}
$appxUiHiddenIdSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$appxUiCollapsedIdMap = @{}
foreach ($group in $appxSelectionExpansions.GetEnumerator()) {
    $canonicalId = [string]$group.Key
    if ([string]::IsNullOrWhiteSpace($canonicalId)) { continue }
    foreach ($memberId in @($group.Value)) {
        $memberKey = [string]$memberId
        if ([string]::IsNullOrWhiteSpace($memberKey)) { continue }
        if ([string]::Equals($memberKey, $canonicalId, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        [void]$appxUiHiddenIdSet.Add($memberKey)
        if (-not $appxUiCollapsedIdMap.ContainsKey($memberKey)) {
            $appxUiCollapsedIdMap[$memberKey] = $canonicalId
        }
    }
}
function Add-AppxUiEntry {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Label,
        [bool]$Checked = $false
    )
    $idKey = $Id.Trim()
    if ([string]::IsNullOrWhiteSpace($idKey)) { return }
    if ($appxUiHiddenIdSet.Contains($idKey)) { return }
    if (-not $appxEntryIdSet.Add($idKey)) { return }

    $key = $Label.Trim().ToLowerInvariant()
    if ($appxEntryMap.Contains($key)) { return }
    $appxEntryMap[$key] = [pscustomobject]@{
        Id      = $idKey
        Label   = $Label
        Checked = [bool]$Checked
    }
}

function Get-AppxLookupKey {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $norm = $Text.Trim().ToLowerInvariant()
    $norm = $norm -replace '\([^)]*\)', ' '
    $norm = $norm -replace '&', ' and '
    $norm = $norm -replace '[^a-z0-9]+', ''
    return $norm
}

function Add-AppxLookupEntry {
    param(
        [Parameter(Mandatory)][hashtable]$Lookup,
        [Parameter(Mandatory)][string]$Candidate,
        [Parameter(Mandatory)][string]$ResolvedId
    )
    $key = Get-AppxLookupKey -Text $Candidate
    if ([string]::IsNullOrWhiteSpace($key)) { return }
    if (-not $Lookup.ContainsKey($key)) { $Lookup[$key] = $ResolvedId }
}

function Get-UniqueUiItems {
    param(
        [object[]]$Items,
        [string]$PrimaryKey = 'Label'
    )

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($it in @($Items)) {
        if ($null -eq $it) { continue }
        $rawKey = ''
        if ($it.PSObject.Properties[$PrimaryKey]) {
            $rawKey = [string]$it.$PrimaryKey
        }
        elseif ($it.PSObject.Properties['Id']) {
            $rawKey = [string]$it.Id
        }
        if ([string]::IsNullOrWhiteSpace($rawKey)) { continue }
        $norm = $rawKey.Trim().ToLowerInvariant()
        if ($seen.Add($norm)) {
            [void]$result.Add($it)
        }
    }
    return @($result)
}

function Get-UniqueToggleItemsByLabel {
    param([object[]]$Items)
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($it in @($Items)) {
        if ($null -eq $it) { continue }
        $label = if ($it.PSObject.Properties['Label']) { [string]$it.Label } else { '' }
        if ([string]::IsNullOrWhiteSpace($label)) { continue }
        $key = $label.Trim().ToLowerInvariant()
        if ($seen.Add($key)) {
            [void]$result.Add($it)
        }
    }
    return @($result)
}

$RequestedRemoveApps = @($RequestedRemoveApps | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
$PrivacyToggleItems = @(Get-UniqueToggleItemsByLabel -Items $PrivacyToggleItems)
$ExtraSecurityToggleItems = @(Get-UniqueToggleItemsByLabel -Items $ExtraSecurityToggleItems)
$AdvancedOptionItems = @(Get-UniqueToggleItemsByLabel -Items $AdvancedOptionItems)

foreach ($pkg in $AppxChecked) {
    $label = if ($AppxLabels.ContainsKey($pkg)) { [string]$AppxLabels[$pkg] } else { [string]$pkg }
    # Keep all app entries visible, but do not pre-select removals by default.
    Add-AppxUiEntry -Id $pkg -Label $label -Checked $false
}
foreach ($pkg in $AppxUnchecked) {
    $label = if ($AppxLabels.ContainsKey($pkg)) { [string]$AppxLabels[$pkg] } else { [string]$pkg }
    Add-AppxUiEntry -Id $pkg -Label $label -Checked $false
}

$appxLookup = @{}
$knownAppxIds = @(
    $AppxChecked
    $AppxUnchecked
    $AppxRequestedExtra
    @($AppxLabels.Keys)
) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique
foreach ($id in $knownAppxIds) {
    $idText = [string]$id
    Add-AppxLookupEntry -Lookup $appxLookup -Candidate $idText -ResolvedId $idText
    if ($AppxLabels.ContainsKey($idText)) {
        $labelText = [string]$AppxLabels[$idText]
        Add-AppxLookupEntry -Lookup $appxLookup -Candidate $labelText -ResolvedId $idText
        $labelNoVendor = ($labelText -replace '^(?i)microsoft\s+', '').Trim()
        if (-not [string]::IsNullOrWhiteSpace($labelNoVendor)) {
            Add-AppxLookupEntry -Lookup $appxLookup -Candidate $labelNoVendor -ResolvedId $idText
        }
    }
}

$requestedAppxAliasMap = @{
    'alarmsandclock'                        = 'Microsoft.WindowsAlarms'
    'clock'                                 = 'Microsoft.WindowsAlarms'
    'feedbackhublegacyaliaswindowsfeedback' = 'Microsoft.WindowsFeedbackHub'
    'mailandcalendar'                       = 'microsoft.windowscommunicationsapps'
    'moviesandtv'                           = 'Microsoft.ZuneVideo'
    'xboxgamebar'                           = 'Microsoft.XboxGamingOverlay'
    'windowsapplicationruntime'             = 'Microsoft.WindowsAppRuntime.1.5'
    'windowsapplicationruntimev16'          = 'Microsoft.WindowsAppRuntime.1.6'
    'microsoftedgedevtoolsclient'           = 'Microsoft.MicrosoftEdgeDevToolsClient'
    'microsoftedgeofficialuninstaller'      = 'Runtime.Remove.MicrosoftEdge.System'
    'removemicrosoftedge'                   = 'Runtime.Remove.MicrosoftEdge.System'
    'removeedge'                            = 'Runtime.Remove.MicrosoftEdge.System'
    'microsoftedgewebview2runtime'          = 'Runtime.Remove.MicrosoftEdge.WebView2'
    'webview2runtime'                       = 'Runtime.Remove.MicrosoftEdge.WebView2'
    'removewebview2'                        = 'Runtime.Remove.MicrosoftEdge.WebView2'
    'removewebview2runtime'                 = 'Runtime.Remove.MicrosoftEdge.WebView2'
    'win32webviewhost'                      = 'Runtime.Remove.MicrosoftEdge.WebView2'
    'removewebviewhost'                     = 'Runtime.Remove.MicrosoftEdge.WebView2'
    'microsoftedgeshortcuts'                = 'Runtime.Remove.MicrosoftEdge.Shortcuts'
}
foreach ($aliasKey in @($requestedAppxAliasMap.Keys)) {
    $aliasId = [string]$requestedAppxAliasMap[$aliasKey]
    if ([string]::IsNullOrWhiteSpace($aliasId)) { continue }
    if ($knownAppxIds -contains $aliasId) {
        if (-not $appxLookup.ContainsKey($aliasKey)) { $appxLookup[$aliasKey] = $aliasId }
    }
}

$skippedRequestedRemoveApps = [System.Collections.Generic.List[string]]::new()
foreach ($item in $RequestedRemoveApps) {
    $rawLabel = [string]$item
    $lookupKey = Get-AppxLookupKey -Text $rawLabel
    if ([string]::IsNullOrWhiteSpace($lookupKey)) { continue }
    if (-not $appxLookup.ContainsKey($lookupKey)) {
        [void]$skippedRequestedRemoveApps.Add($rawLabel)
        continue
    }

    $resolvedId = [string]$appxLookup[$lookupKey]
    $resolvedLabel = if ($AppxLabels.ContainsKey($resolvedId)) { [string]$AppxLabels[$resolvedId] } else { $rawLabel }
    Add-AppxUiEntry -Id $resolvedId -Label $resolvedLabel -Checked $false
}
if ($skippedRequestedRemoveApps.Count -gt 0) {
    Write-Log ("App list cleanup: skipped {0} non-Appx requested entries." -f $skippedRequestedRemoveApps.Count) -Color Yellow
}

$appxUnifiedItems = @(Get-UniqueUiItems -Items @($appxEntryMap.Values) -PrimaryKey 'Label' | Sort-Object Label)
$appxContext = New-AppxToggleTabContent -Tab $tabAppx -UnifiedItems $appxUnifiedItems
$appxBoxes = $appxContext.Boxes
$AppxDef = @($appxUnifiedItems | ForEach-Object { [string]$_.Id })

# Privacy toggle list
$privacyEntryMap = [ordered]@{}
foreach ($item in $PrivacyToggleItems) {
    $label = [string]$item.Label
    if ([string]::IsNullOrWhiteSpace($label)) { continue }
    $key = $label.Trim().ToLowerInvariant()
    if ($privacyEntryMap.Contains($key)) { continue }
    # Requested behavior: privacy toggles must not auto-select on startup.
    # Always initialize to Default; user/config import can explicitly change later.
    $mode = 'Default'
    $privacyEntryMap[$key] = [pscustomobject]@{
        Id    = "privacy.$($privacyEntryMap.Count + 1)"
        Label = $label
        Mode  = $mode
    }
}
$privacyUnifiedItems = @(Get-UniqueUiItems -Items @($privacyEntryMap.Values) -PrimaryKey 'Label' | Sort-Object Label)
$privacyBoxes = New-PrivacyToggleTabContent -Tab $tabPrivacy -UnifiedItems $privacyUnifiedItems
$PrivacyDef = @($privacyUnifiedItems | ForEach-Object { [string]$_.Id })
$PrivacyLabelById = @{}
foreach ($privacyItem in $privacyUnifiedItems) {
    $PrivacyLabelById[[string]$privacyItem.Id] = [string]$privacyItem.Label
}

# Extra Security toggle list
$extraSecurityEntryMap = [ordered]@{}
foreach ($item in $ExtraSecurityToggleItems) {
    $label = [string]$item.Label
    if ([string]::IsNullOrWhiteSpace($label)) { continue }
    $key = $label.Trim().ToLowerInvariant()
    if ($extraSecurityEntryMap.Contains($key)) { continue }
    $mode = 'Default'
    $detailValue = $label
    if ($null -ne $item.PSObject.Properties['Detail'] -and -not [string]::IsNullOrWhiteSpace([string]$item.Detail)) {
        $detailValue = [string]$item.Detail
    }
    $extraSecurityEntryMap[$key] = [pscustomobject]@{
        Id     = "extrasecurity.$($extraSecurityEntryMap.Count + 1)"
        Label  = $label
        Mode   = $mode
        Detail = $detailValue
    }
}
$extraSecurityUnifiedItems = @(Get-UniqueUiItems -Items @($extraSecurityEntryMap.Values) -PrimaryKey 'Label' | Sort-Object Label)
$extraSecurityDetailsByLabel = @{}
foreach ($item in $extraSecurityUnifiedItems) { $extraSecurityDetailsByLabel[[string]$item.Label] = [string]$item.Detail }
$extraSecurityContext = if ($extraSecurityUnifiedItems.Count -gt 0) {
    New-FeatureToggleTabContent -Tab $tabExtraSecurity -UnifiedItems $extraSecurityUnifiedItems -ItemDetails $extraSecurityDetailsByLabel -ReturnContext
}
else {
    [pscustomobject]@{
        Combos    = [System.Collections.Generic.List[System.Windows.Forms.ComboBox]]::new()
        DetailBox = $null
        Flow      = $null
    }
}

$extraSecurityBoxes = $extraSecurityContext.Combos
$ExtraSecurityDef = @($extraSecurityUnifiedItems | ForEach-Object { [string]$_.Id })
$ExtraSecurityLabelById = @{}
foreach ($extraItem in $extraSecurityUnifiedItems) {
    $ExtraSecurityLabelById[[string]$extraItem.Id] = [string]$extraItem.Label
}

# Advanced Options content (themed toggle rows + Compact OS mode radios)
$advancedEntryMap = [ordered]@{}
foreach ($item in $AdvancedOptionItems) {
    $label = [string]$item.Label
    if ([string]::IsNullOrWhiteSpace($label)) { continue }
    $key = $label.Trim().ToLowerInvariant()
    if ($advancedEntryMap.Contains($key)) { continue }
    $mode = 'Default'
    $detail = if ($null -ne $item.PSObject.Properties['Detail'] -and -not [string]::IsNullOrWhiteSpace([string]$item.Detail)) { [string]$item.Detail } else { $label }
    $advancedEntryMap[$key] = [pscustomobject]@{
        Id     = "advanced.$($advancedEntryMap.Count + 1)"
        Label  = $label
        Mode   = $mode
        Detail = $detail
    }
}
$advancedUnifiedItems = @(Get-UniqueUiItems -Items @($advancedEntryMap.Values) -PrimaryKey 'Label' | Sort-Object Label)
$advancedDetailsByLabel = @{}
foreach ($item in $advancedUnifiedItems) { $advancedDetailsByLabel[[string]$item.Label] = [string]$item.Detail }

foreach ($ctl in @($advancedPanel.Controls)) { $advancedPanel.Controls.Remove($ctl) }

$compactPanel = New-Object System.Windows.Forms.Panel
$compactPanel.Dock = 'Top'
$compactPanel.Height = 286
$compactPanel.BackColor = $clrPanelAlt
$compactPanel.Padding = New-Object System.Windows.Forms.Padding(12, 8, 12, 8)
$compactInputLeft = 260
$compactRowLeft = 12

$lblCompact = New-DarkLabel -Text 'Compact OS:' -Width 140 -Height 22
$lblCompact.Left = 12
$lblCompact.Top = 10
$lblCompact.Font = New-UiFont -Size 10 -Style ([System.Drawing.FontStyle]::Bold)

$rbCompactDefault = New-Object System.Windows.Forms.RadioButton
$rbCompactDefault.Text = 'Let Windows decide whether to use Compact OS'
$rbCompactDefault.Left = $compactInputLeft
$rbCompactDefault.Top = 10
$rbCompactDefault.Width = 520
$rbCompactDefault.Height = 22
$rbCompactDefault.ForeColor = $clrText
$rbCompactDefault.BackColor = [System.Drawing.Color]::Transparent
$rbCompactDefault.Font = New-UiFont -Size 9.5
$rbCompactDefault.Checked = $true

$rbCompactOn = New-Object System.Windows.Forms.RadioButton
$rbCompactOn.Text = 'Use Compact OS'
$rbCompactOn.Left = $compactInputLeft
$rbCompactOn.Top = 38
$rbCompactOn.Width = 240
$rbCompactOn.Height = 22
$rbCompactOn.ForeColor = $clrText
$rbCompactOn.BackColor = [System.Drawing.Color]::Transparent
$rbCompactOn.Font = New-UiFont -Size 9.5

$rbCompactOff = New-Object System.Windows.Forms.RadioButton
$rbCompactOff.Text = 'Do not use Compact OS'
$rbCompactOff.Left = $compactInputLeft
$rbCompactOff.Top = 66
$rbCompactOff.Width = 260
$rbCompactOff.Height = 22
$rbCompactOff.ForeColor = $clrText
$rbCompactOff.BackColor = [System.Drawing.Color]::Transparent
$rbCompactOff.Font = New-UiFont -Size 9.5

$cbSingleLang = New-DarkCheckBox -Text 'Enable'
$cbSingleLang.Text = 'Single language installer'
$cbSingleLang.Left = $compactRowLeft
$cbSingleLang.Top = 106
$cbSingleLang.Checked = [bool]$sync.SingleLanguageInstaller

$langCombo = New-DarkComboBox -Items @(
    'System Default',
    'English (United States) - en-US',
    'English (United Kingdom) - en-GB',
    'German (Germany) - de-DE',
    'French (France) - fr-FR',
    'Spanish (Spain) - es-ES',
    'Japanese (Japan) - ja-JP',
    'Chinese (Simplified, China) - zh-CN'
) -Text ([string]$sync.InstallerLanguage) -Width 320
$langCombo.Left = 300
$langCombo.Top = 104
$langCombo.DropDownStyle = 'DropDownList'
$langCombo.FlatStyle = 'Standard'
$langCombo.BackColor = $clrInputBg
$langCombo.ForeColor = $clrText
if ($langCombo.SelectedIndex -lt 0 -and $langCombo.Items.Count -gt 0) {
    $langCombo.SelectedIndex = 0
}

$layoutCompactLanguageRow = {
    $rightPadding = 12
    $cbSingleLang.Left = $compactRowLeft
    $langCombo.Left = $cbSingleLang.Left + [Math]::Max(180, $cbSingleLang.PreferredSize.Width + 12)
    $langCombo.Width = [Math]::Max(260, $compactPanel.ClientSize.Width - $langCombo.Left - $rightPadding)
}.GetNewClosure()
$compactPanel.Add_Resize($layoutCompactLanguageRow)

$compactPanel.Controls.AddRange(@(
        $lblCompact, $rbCompactDefault, $rbCompactOn, $rbCompactOff,
        $cbSingleLang, $langCombo
    ))

$advancedBody = New-Object System.Windows.Forms.Panel
$advancedBody.Dock = 'Fill'
$advancedBody.BackColor = $clrPanelAlt
$advancedPanel.Controls.Add($advancedBody)
$advancedPanel.Controls.Add($compactPanel)

$advancedContext = if ($advancedUnifiedItems.Count -gt 0) {
    New-FeatureToggleTabContent -Tab $advancedBody -UnifiedItems $advancedUnifiedItems -ItemDetails $advancedDetailsByLabel -ReturnContext
}
else {
    [pscustomobject]@{
        Combos    = [System.Collections.Generic.List[System.Windows.Forms.ComboBox]]::new()
        DetailBox = $null
        Flow      = $null
    }
}
$advancedBoxes = $advancedContext.Combos
$advancedDetailBox = $advancedContext.DetailBox
$AdvancedOptionsDef = @($advancedUnifiedItems | ForEach-Object { [string]$_.Id })
$AdvancedOptionsLabelById = @{}
foreach ($advancedItem in $advancedUnifiedItems) {
    $AdvancedOptionsLabelById[[string]$advancedItem.Id] = [string]$advancedItem.Label
}

# Advanced Options only: remove inner boxed list look and blend with page.
if ($advancedContext.Flow) {
    $advancedContext.Flow.BorderStyle = 'None'
    $advancedContext.Flow.BackColor = $clrPanelAlt
}

$setCompactMode = {
    if ($rbCompactOn.Checked) {
        $sync.CompactOsMode = 'Enabled'
        if ($advancedDetailBox) {
            $advancedDetailBox.Text = "Compact OS`r`n`r`nEnabled: compresses system binaries to save disk space, with a small CPU overhead during decompression."
        }
    }
    elseif ($rbCompactOff.Checked) {
        $sync.CompactOsMode = 'Disabled'
        if ($advancedDetailBox) {
            $advancedDetailBox.Text = "Compact OS`r`n`r`nDisabled: keeps files uncompressed for best runtime performance, but uses more disk space."
        }
    }
    else {
        $sync.CompactOsMode = 'Default'
        if ($advancedDetailBox) {
            $advancedDetailBox.Text = "Compact OS`r`n`r`nDefault: Windows automatically decides based on device/storage profile."
        }
    }
}.GetNewClosure()
$rbCompactDefault.Add_CheckedChanged($setCompactMode)
$rbCompactOn.Add_CheckedChanged($setCompactMode)
$rbCompactOff.Add_CheckedChanged($setCompactMode)
$rbCompactDefault.Add_GotFocus($setCompactMode)
$rbCompactOn.Add_GotFocus($setCompactMode)
$rbCompactOff.Add_GotFocus($setCompactMode)
$cbSingleLang.Add_GotFocus({
        if ($advancedDetailBox) { $advancedDetailBox.Text = "Single language installer`r`n`r`nWhen enabled, setup uses one selected language package for installation media behavior." }
    }.GetNewClosure())
$cbSingleLang.Add_MouseEnter({
        if ($advancedDetailBox) { $advancedDetailBox.Text = "Single language installer`r`n`r`nWhen enabled, setup uses one selected language package for installation media behavior." }
    }.GetNewClosure())
$langCombo.Add_SelectedIndexChanged({ $sync.InstallerLanguage = [string]$langCombo.SelectedItem }.GetNewClosure())
$langCombo.Add_GotFocus({
        if ($advancedDetailBox) { $advancedDetailBox.Text = "Installer language`r`n`r`nSelects the preferred language used when single language installer mode is enabled." }
    }.GetNewClosure())
$langCombo.Add_MouseEnter({
        if ($advancedDetailBox) { $advancedDetailBox.Text = "Installer language`r`n`r`nSelects the preferred language used when single language installer mode is enabled." }
    }.GetNewClosure())
$updateSingleLanguageUiState = {
    $isEnabled = [bool]$cbSingleLang.Checked
    $langCombo.Enabled = $isEnabled
    if ($isEnabled) {
        $langCombo.BackColor = $clrInputBg
        $langCombo.ForeColor = $clrText
    }
    else {
        $langCombo.BackColor = $clrInputBg
        $langCombo.ForeColor = $clrMutedText
    }
}.GetNewClosure()
$cbSingleLang.Add_CheckedChanged({
        $sync.SingleLanguageInstaller = [bool]$cbSingleLang.Checked
        & $updateSingleLanguageUiState
    }.GetNewClosure())
& $setCompactMode
& $layoutCompactLanguageRow
$sync.SingleLanguageInstaller = [bool]$cbSingleLang.Checked
$sync.InstallerLanguage = [string]$langCombo.SelectedItem
& $updateSingleLanguageUiState

# Custom unattend.xml picker (themed)
$lblCustomXml = New-DarkLabel -Text 'Custom unattend.xml:' -Width 190 -Height 22
$lblCustomXml.Left = 12
$lblCustomXml.Top = 122
$lblCustomXml.Font = New-UiFont -Size 9.5 -Style ([System.Drawing.FontStyle]::Bold)

$customXmlTbObj = New-DarkTextBox -Text ([string]$sync.CustomUnattendXml) -Width 360 -ReadOnly $true
$tbCustomXml = $customXmlTbObj.TextBox
$pnlCustomXml = $customXmlTbObj.Panel
$pnlCustomXml.Left = $compactRowLeft
$pnlCustomXml.Top = 146
$pnlCustomXml.Height = 34

$updateCustomXmlDisplay = {
    if ([string]::IsNullOrWhiteSpace([string]$sync.CustomUnattendXml)) {
        $tbCustomXml.Text = 'No custom unattend.xml selected'
        $tbCustomXml.ForeColor = $clrMutedText
    }
    else {
        $tbCustomXml.Text = [string]$sync.CustomUnattendXml
        $tbCustomXml.ForeColor = $clrText
    }

    # Reset caret/scroll so the text always renders from the left edge.
    try {
        $tbCustomXml.SelectionStart = 0
        $tbCustomXml.SelectionLength = 0
        $tbCustomXml.Select(0, 0)
        $tbCustomXml.Text = [string]$tbCustomXml.Text
        $tbCustomXml.Select(0, 0)
    }
    catch {}
}.GetNewClosure()
& $updateCustomXmlDisplay
$tbCustomXml.Add_Enter({ try { $tbCustomXml.Select(0, 0) } catch {} }.GetNewClosure())
$tbCustomXml.Add_Click({ try { $tbCustomXml.Select(0, 0) } catch {} }.GetNewClosure())
$tbCustomXml.Add_MouseDown({ try { $tbCustomXml.Select(0, 0) } catch {} }.GetNewClosure())

$btnBrowseCustomXml = New-DarkButton -Text 'Browse' -Width 88 -Height 34 -Role 'Browse'
$btnBrowseCustomXml.Left = 580
$btnBrowseCustomXml.Top = 146

$btnBrowseCustomXml.Add_Click({
        $ofdXml = $null
        try {
            $ofdXml = New-Object System.Windows.Forms.OpenFileDialog
            $ofdXml.Title = 'Select Custom unattend.xml'
            $ofdXml.Filter = 'XML Files (*.xml)|*.xml|All Files (*.*)|*.*'
            if (-not [string]::IsNullOrWhiteSpace([string]$sync.CustomUnattendXml) -and (Test-Path -LiteralPath $sync.CustomUnattendXml -PathType Leaf)) {
                $ofdXml.InitialDirectory = Split-Path -Parent $sync.CustomUnattendXml
            }
            if ($ofdXml.ShowDialog($form) -eq 'OK') {
                $sync.CustomUnattendXml = [string]$ofdXml.FileName
                & $updateCustomXmlDisplay
                if ($advancedDetailBox) {
                    $advancedDetailBox.Text = "Custom unattend.xml`r`n`r`nUses the selected XML as merge input for unattended setup values."
                }
                Write-Log "Selected custom unattend.xml: $($sync.CustomUnattendXml)" -Color Cyan
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Failed to select XML file.`n`n$_", "XML Picker", "OK", "Error") | Out-Null
        }
        finally { if ($null -ne $ofdXml) { try { $ofdXml.Dispose() } catch {} } }
    }.GetNewClosure())

$layoutCustomXmlRow = {
    $rightPadding = 8
    $gapToBrowse = 8
    $pnlCustomXml.Left = $compactRowLeft
    $btnBrowseCustomXml.Left = [Math]::Max(320, $compactPanel.ClientSize.Width - $btnBrowseCustomXml.Width - $rightPadding)
    $pnlCustomXml.Width = [Math]::Max(260, $btnBrowseCustomXml.Left - $pnlCustomXml.Left - $gapToBrowse)
}.GetNewClosure()
$compactPanel.Add_Resize($layoutCustomXmlRow)

$tbCustomXml.Add_MouseEnter({
        if ($advancedDetailBox) { $advancedDetailBox.Text = "Custom unattend.xml`r`n`r`nUses the selected XML as merge input for unattended setup values." }
    }.GetNewClosure())
$btnBrowseCustomXml.Add_MouseEnter({
        if ($advancedDetailBox) { $advancedDetailBox.Text = "Custom unattend.xml`r`n`r`nUses the selected XML as merge input for unattended setup values." }
    }.GetNewClosure())

$compactPanel.Controls.AddRange(@($lblCustomXml, $pnlCustomXml, $btnBrowseCustomXml))
& $layoutCustomXmlRow

# Themed selector dialog to remove one or more custom files from a list.
function Show-RemoveCustomFilesDialog {
    param(
        [AllowEmptyCollection()][string[]]$CurrentFiles = @(),
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$KindLabel
    )

    $files = @($CurrentFiles | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($files.Count -eq 0) { return $null }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title
    $dlg.Size = New-Object System.Drawing.Size(760, 420)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = $clrBg
    $dlg.ForeColor = $clrText
    $dlg.Font = New-UiFont -Size 9.5

    $lbl = New-DarkLabel -Text "Select $KindLabel to remove:" -Width 560 -Height 24
    $lbl.Left = 12
    $lbl.Top = 10

    $list = New-Object System.Windows.Forms.CheckedListBox
    $list.Left = 12
    $list.Top = 38
    $list.Width = 730
    $list.Height = 288
    $list.CheckOnClick = $true
    $list.BackColor = $clrInputBg
    $list.ForeColor = $clrText
    $list.BorderStyle = 'FixedSingle'
    $list.Font = New-UiFont -Size 9.5
    foreach ($f in $files) { [void]$list.Items.Add([string]$f, $false) }

    $btnSelectAll = New-DarkButton -Text 'Select All' -Width 96 -Height 30
    $btnSelectAll.Left = 12
    $btnSelectAll.Top = 338
    $btnClear = New-DarkButton -Text 'Clear' -Width 86 -Height 30
    $btnClear.Left = 114
    $btnClear.Top = 338
    $btnRemove = New-DarkButton -Text 'Remove Selected' -Width 142 -Height 30 -Role 'Danger'
    $btnRemove.Left = 504
    $btnRemove.Top = 338
    $btnCancel = New-DarkButton -Text 'Cancel' -Width 96 -Height 30
    $btnCancel.Left = 652
    $btnCancel.Top = 338

    $btnSelectAll.Add_Click({
            for ($i = 0; $i -lt $list.Items.Count; $i++) { $list.SetItemChecked($i, $true) }
        }.GetNewClosure())
    $btnClear.Add_Click({
            for ($i = 0; $i -lt $list.Items.Count; $i++) { $list.SetItemChecked($i, $false) }
        }.GetNewClosure())
    $btnCancel.Add_Click({ $dlg.DialogResult = 'Cancel'; $dlg.Close() }.GetNewClosure())
    $btnRemove.Add_Click({
            if ($list.CheckedItems.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show("Select at least one item to remove.", "No Selection", "OK", "Information") | Out-Null
                return
            }
            $dlg.DialogResult = 'OK'
            $dlg.Close()
        }.GetNewClosure())

    $dlg.Controls.AddRange(@($lbl, $list, $btnSelectAll, $btnClear, $btnRemove, $btnCancel))
    $dlg.AcceptButton = $btnRemove
    $dlg.CancelButton = $btnCancel

    if ($dlg.ShowDialog($form) -ne 'OK') { return $null }

    $toRemove = @($list.CheckedItems | ForEach-Object { [string]$_ })
    $remaining = @($files | Where-Object { $toRemove -notcontains [string]$_ })
    return , $remaining
}

# Custom .reg files picker (themed)
$customRegTbObj = New-DarkTextBox -Text '' -Width 360 -ReadOnly $true
$tbCustomReg = $customRegTbObj.TextBox
$pnlCustomReg = $customRegTbObj.Panel
$pnlCustomReg.Left = $compactRowLeft
$pnlCustomReg.Top = 188
$pnlCustomReg.Height = 34

$updateCustomRegDisplay = {
    $files = @($sync.CustomRegFiles | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($files.Count -eq 0) {
        $tbCustomReg.Text = 'No custom .reg files selected'
        $tbCustomReg.ForeColor = $clrMutedText
    }
    elseif ($files.Count -eq 1) {
        $tbCustomReg.Text = [string]$files[0]
        $tbCustomReg.ForeColor = $clrText
    }
    else {
        $tbCustomReg.Text = "$($files.Count) .reg files selected"
        $tbCustomReg.ForeColor = $clrText
    }
    try {
        $tbCustomReg.SelectionStart = 0
        $tbCustomReg.SelectionLength = 0
        $tbCustomReg.Select(0, 0)
        $tbCustomReg.Text = [string]$tbCustomReg.Text
        $tbCustomReg.Select(0, 0)
    }
    catch {}
}.GetNewClosure()
& $updateCustomRegDisplay
$tbCustomReg.Add_Enter({ try { $tbCustomReg.Select(0, 0) } catch {} }.GetNewClosure())
$tbCustomReg.Add_Click({ try { $tbCustomReg.Select(0, 0) } catch {} }.GetNewClosure())
$tbCustomReg.Add_MouseDown({ try { $tbCustomReg.Select(0, 0) } catch {} }.GetNewClosure())

$btnBrowseCustomReg = New-DarkButton -Text 'Browse' -Width 88 -Height 34 -Role 'Browse'
$btnBrowseCustomReg.Top = 188
$btnRemoveCustomReg = New-DarkButton -Text 'Remove' -Width 88 -Height 34 -Role 'Danger'
$btnRemoveCustomReg.Top = 188
$btnBrowseCustomReg.Add_Click({
        $ofdReg = $null
        try {
            $ofdReg = New-Object System.Windows.Forms.OpenFileDialog
            $ofdReg.Title = 'Select Custom .reg File(s)'
            $ofdReg.Filter = 'Registry Files (*.reg)|*.reg|All Files (*.*)|*.*'
            $ofdReg.Multiselect = $true
            if (@($sync.CustomRegFiles).Count -gt 0 -and (Test-Path -LiteralPath $sync.CustomRegFiles[0] -PathType Leaf)) {
                $ofdReg.InitialDirectory = Split-Path -Parent $sync.CustomRegFiles[0]
            }
            if ($ofdReg.ShowDialog($form) -eq 'OK') {
                $sync.CustomRegFiles = @($ofdReg.FileNames | Where-Object { $_ })
                & $updateCustomRegDisplay
                if ($advancedDetailBox) {
                    $advancedDetailBox.Text = "Custom .reg files`r`n`r`nStages selected registry script files into the build custom folder for post-install use."
                }
                Write-Log "Selected custom .reg files: $($sync.CustomRegFiles.Count)" -Color Cyan
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Failed to select .reg files.`n`n$_", "REG Picker", "OK", "Error") | Out-Null
        }
        finally { if ($null -ne $ofdReg) { try { $ofdReg.Dispose() } catch {} } }
    }.GetNewClosure())
$btnRemoveCustomReg.Add_Click({
        $existingFiles = @($sync.CustomRegFiles | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($existingFiles.Count -eq 0) {
            Write-Log "No custom .reg files are selected to remove." -Color Yellow
            return
        }
        $remaining = Show-RemoveCustomFilesDialog -CurrentFiles $existingFiles -Title 'Remove Custom .reg Files' -KindLabel '.reg file(s)'
        if ($null -eq $remaining) { return }
        $sync.CustomRegFiles = @($remaining)
        & $updateCustomRegDisplay
        Write-Log "Remaining custom .reg files: $($sync.CustomRegFiles.Count)" -Color Cyan
    }.GetNewClosure())

$layoutCustomRegRow = {
    $rightPadding = 8
    $gapBetweenButtons = 8
    $gapToText = 8
    $pnlCustomReg.Left = $compactRowLeft
    $btnBrowseCustomReg.Left = [Math]::Max(320, $compactPanel.ClientSize.Width - $btnBrowseCustomReg.Width - $rightPadding)
    $btnRemoveCustomReg.Left = [Math]::Max(220, $btnBrowseCustomReg.Left - $gapBetweenButtons - $btnRemoveCustomReg.Width)
    $pnlCustomReg.Width = [Math]::Max(220, $btnRemoveCustomReg.Left - $pnlCustomReg.Left - $gapToText)
}.GetNewClosure()
$compactPanel.Add_Resize($layoutCustomRegRow)
$tbCustomReg.Add_MouseEnter({
        if ($advancedDetailBox) { $advancedDetailBox.Text = "Custom .reg files`r`n`r`nStages selected registry script files into the build custom folder for post-install use." }
    }.GetNewClosure())
$btnBrowseCustomReg.Add_MouseEnter({
        if ($advancedDetailBox) { $advancedDetailBox.Text = "Custom .reg files`r`n`r`nStages selected registry script files into the build custom folder for post-install use." }
    }.GetNewClosure())
$btnRemoveCustomReg.Add_MouseEnter({
        if ($advancedDetailBox) { $advancedDetailBox.Text = "Custom .reg files`r`n`r`nRemove selected custom registry files from the current selection list." }
    }.GetNewClosure())
$compactPanel.Controls.AddRange(@($pnlCustomReg, $btnRemoveCustomReg, $btnBrowseCustomReg))
& $layoutCustomRegRow

# Custom .bat/.cmd files picker (themed)
$customBatTbObj = New-DarkTextBox -Text '' -Width 360 -ReadOnly $true
$tbCustomBat = $customBatTbObj.TextBox
$pnlCustomBat = $customBatTbObj.Panel
$pnlCustomBat.Left = $compactRowLeft
$pnlCustomBat.Top = 230
$pnlCustomBat.Height = 34

$updateCustomBatDisplay = {
    $files = @($sync.CustomBatFiles | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($files.Count -eq 0) {
        $tbCustomBat.Text = 'No custom .bat/.cmd files selected'
        $tbCustomBat.ForeColor = $clrMutedText
    }
    elseif ($files.Count -eq 1) {
        $tbCustomBat.Text = [string]$files[0]
        $tbCustomBat.ForeColor = $clrText
    }
    else {
        $tbCustomBat.Text = "$($files.Count) .bat/.cmd files selected"
        $tbCustomBat.ForeColor = $clrText
    }
    try {
        $tbCustomBat.SelectionStart = 0
        $tbCustomBat.SelectionLength = 0
        $tbCustomBat.Select(0, 0)
        $tbCustomBat.Text = [string]$tbCustomBat.Text
        $tbCustomBat.Select(0, 0)
    }
    catch {}
}.GetNewClosure()
& $updateCustomBatDisplay
$tbCustomBat.Add_Enter({ try { $tbCustomBat.Select(0, 0) } catch {} }.GetNewClosure())
$tbCustomBat.Add_Click({ try { $tbCustomBat.Select(0, 0) } catch {} }.GetNewClosure())
$tbCustomBat.Add_MouseDown({ try { $tbCustomBat.Select(0, 0) } catch {} }.GetNewClosure())

$btnBrowseCustomBat = New-DarkButton -Text 'Browse' -Width 88 -Height 34 -Role 'Browse'
$btnBrowseCustomBat.Top = 230
$btnRemoveCustomBat = New-DarkButton -Text 'Remove' -Width 88 -Height 34 -Role 'Danger'
$btnRemoveCustomBat.Top = 230
$btnBrowseCustomBat.Add_Click({
        $ofdBat = $null
        try {
            $ofdBat = New-Object System.Windows.Forms.OpenFileDialog
            $ofdBat.Title = 'Select Custom .bat/.cmd File(s)'
            $ofdBat.Filter = 'Batch Files (*.bat;*.cmd)|*.bat;*.cmd|All Files (*.*)|*.*'
            $ofdBat.Multiselect = $true
            if (@($sync.CustomBatFiles).Count -gt 0 -and (Test-Path -LiteralPath $sync.CustomBatFiles[0] -PathType Leaf)) {
                $ofdBat.InitialDirectory = Split-Path -Parent $sync.CustomBatFiles[0]
            }
            if ($ofdBat.ShowDialog($form) -eq 'OK') {
                $sync.CustomBatFiles = @($ofdBat.FileNames | Where-Object { $_ })
                & $updateCustomBatDisplay
                if ($advancedDetailBox) {
                    $advancedDetailBox.Text = "Custom .bat/.cmd files`r`n`r`nStages selected batch scripts into the build custom folder for post-install use."
                }
                Write-Log "Selected custom .bat/.cmd files: $($sync.CustomBatFiles.Count)" -Color Cyan
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Failed to select .bat/.cmd files.`n`n$_", "BAT/CMD Picker", "OK", "Error") | Out-Null
        }
        finally { if ($null -ne $ofdBat) { try { $ofdBat.Dispose() } catch {} } }
    }.GetNewClosure())
$btnRemoveCustomBat.Add_Click({
        $existingFiles = @($sync.CustomBatFiles | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($existingFiles.Count -eq 0) {
            Write-Log "No custom .bat/.cmd files are selected to remove." -Color Yellow
            return
        }
        $remaining = Show-RemoveCustomFilesDialog -CurrentFiles $existingFiles -Title 'Remove Custom .bat/.cmd Files' -KindLabel '.bat/.cmd file(s)'
        if ($null -eq $remaining) { return }
        $sync.CustomBatFiles = @($remaining)
        & $updateCustomBatDisplay
        Write-Log "Remaining custom .bat/.cmd files: $($sync.CustomBatFiles.Count)" -Color Cyan
    }.GetNewClosure())

$layoutCustomBatRow = {
    $rightPadding = 8
    $gapBetweenButtons = 8
    $gapToText = 8
    $pnlCustomBat.Left = $compactRowLeft
    $btnBrowseCustomBat.Left = [Math]::Max(320, $compactPanel.ClientSize.Width - $btnBrowseCustomBat.Width - $rightPadding)
    $btnRemoveCustomBat.Left = [Math]::Max(220, $btnBrowseCustomBat.Left - $gapBetweenButtons - $btnRemoveCustomBat.Width)
    $pnlCustomBat.Width = [Math]::Max(220, $btnRemoveCustomBat.Left - $pnlCustomBat.Left - $gapToText)
}.GetNewClosure()
$compactPanel.Add_Resize($layoutCustomBatRow)
$tbCustomBat.Add_MouseEnter({
        if ($advancedDetailBox) { $advancedDetailBox.Text = "Custom .bat/.cmd files`r`n`r`nStages selected batch scripts into the build custom folder for post-install use." }
    }.GetNewClosure())
$btnBrowseCustomBat.Add_MouseEnter({
        if ($advancedDetailBox) { $advancedDetailBox.Text = "Custom .bat/.cmd files`r`n`r`nStages selected batch scripts into the build custom folder for post-install use." }
    }.GetNewClosure())
$btnRemoveCustomBat.Add_MouseEnter({
        if ($advancedDetailBox) { $advancedDetailBox.Text = "Custom .bat/.cmd files`r`n`r`nRemove selected custom batch files from the current selection list." }
    }.GetNewClosure())
$compactPanel.Controls.AddRange(@($pnlCustomBat, $btnRemoveCustomBat, $btnBrowseCustomBat))
& $layoutCustomBatRow

# Optional Features toggle list (Enable/Disable only, no header actions)
$featureEntryMap = [ordered]@{}
function Add-FeatureUiEntry {
    param(
        [Parameter(Mandatory)][string]$Id,
        [bool]$IsEnabled = $false
    )
    if ([string]::IsNullOrWhiteSpace($Id)) { return }
    if ($featureEntryMap.Contains($Id)) { return }
    $label = if ($FeatureLabels.ContainsKey($Id)) { [string]$FeatureLabels[$Id] } else { [string]$Id }
    $featureEntryMap[$Id] = [pscustomobject]@{
        Id    = $Id
        Label = $label
        # Keep UI neutral on first load; user explicitly chooses actions.
        Mode  = 'Default'
    }
}
function Add-FeatureUiLabelOnlyEntry {
    param(
        [Parameter(Mandatory)][string]$Label,
        [bool]$IsEnabled = $false
    )
    if ([string]::IsNullOrWhiteSpace($Label)) { return }
    foreach ($existing in $featureEntryMap.Values) {
        if ([string]::Equals([string]$existing.Label, [string]$Label, [System.StringComparison]::OrdinalIgnoreCase)) {
            return
        }
    }
    $customId = ('custom.optionalfeature.{0}' -f ($featureEntryMap.Count + 1))
    $featureEntryMap[$customId] = [pscustomobject]@{
        Id    = $customId
        Label = [string]$Label
        Mode  = 'Default'
    }
}
foreach ($fid in $FeaturesChecked) { Add-FeatureUiEntry -Id ([string]$fid) -IsEnabled $true }
foreach ($fid in $FeaturesUnchecked) { Add-FeatureUiEntry -Id ([string]$fid) -IsEnabled $false }

# Additional optional components requested for GUI (deduplicated by display label).
$OptionalFeaturesRequestedExtra = @(
    'Language Components'
    'Hyper-V Integration Services'
    'User Experience Virtualization (UE-V)'
    'Program Compatibility Assistant (PCA) (Feature)'
    'Hyper-V (Feature)'
    'Hyper-V GUI Management Tools (Feature)'
    'Hyper-V Management Tools (Feature)'
    'Hyper-V PowerShell Module (Feature)'
    'Internet Printing Client (Feature)'
    'LPD Print Service (Feature)'
    'LPR Port Monitor (Feature)'
    'Microsoft Print to PDF (Feature)'
    'Microsoft XPS Document Writer (Feature)'
    'XPS Viewer (Feature)'
    'Work Folders Client (Feature)'
    'DirectPlay (Feature)'
    'Legacy Components (Feature)'
    'Media Features (Feature)'
    'Scan Management (Feature)'
    'Windows Fax and Scan (Feature)'
    'Windows Media Player (Feature)'
    'Windows Search (Feature)'
    'Telnet Client (Feature)'
    'Windows Remote Assistance (Feature)'
    'Net.TCP Port Sharing (Feature)'
    'SMB Direct (Feature)'
    'TFTP Client (Feature)'
    'RAS Connection Manager Administration Kit (CMAK) (Capability)'
    'RIP Listener (Capability)'
    'Simple Network Management Protocol (SNMP) (Capability)'
    'SNMP WMI Provider (Capability)'
    'Math Recognizer (Capability)'
    'OneSync (Capability)'
    'Print Management Console (Capability)'
    'Quick Assist (Capability)'
    'Steps Recorder (Capability)'
    'Windows Fax and Scan (Capability)'
    'Enterprise Cloud Print (Capability)'
    'Mopria Cloud Service (Capability)'
    'Active Directory Domain Services and Lightweight Directory Services Tools (Capability)'
    'Active Directory Certificate Services Tools (Capability)'
    'XPS Viewer (Capability)'
    'Windows Emergency Management Services and Serial Console (Capability)'
    'DHCP Server Tools (Capability)'
    'DNS Server Tools (Capability)'
    'Failover Clustering Tools (Capability)'
    'File Services Tools (Capability)'
    'IP Address Management (IPAM) Client (Capability)'
    'Data Center Bridging LLDP Tools (Capability)'
    'Network Controller Management Tools (Capability)'
    'Remote Access Management Tools (Capability)'
    'Network Load Balancing Tools (Capability)'
    'Server Manager Tools (Capability)'
    'Shielded VM Tools (Capability)'
    'Storage Replica PowerShell Module (Capability)'
    'Volume Activation Tools (Capability)'
    'Windows Server Update Services Tools (Capability)'
    'Storage Migration Service Management Tools (Capability)'
    'Systems Insights PowerShell Module (Capability)'
    'Mixed Reality (Capability)'
    'Braille Support (Accessibility) (Capability)'
    'Graphics Tools (Capability)'
    'Microsoft WebDriver (Capability)'
    'IrDA (Capability)'
)
$OptionalFeaturesRequestedExtra = @($OptionalFeaturesRequestedExtra | Select-Object -Unique)
# Keep this section backend-accurate: placeholder-only labels are not added by default.
$OptionalFeaturesRequestedExtra = @()
foreach ($label in $OptionalFeaturesRequestedExtra) {
    Add-FeatureUiLabelOnlyEntry -Label $label -IsEnabled $false
}

$featuresUnifiedItems = @(Get-UniqueUiItems -Items @($featureEntryMap.Values) -PrimaryKey 'Label' | Sort-Object Label)
$featureDetailsByLabel = @{}
foreach ($f in $featuresUnifiedItems) {
    $featureDetailsByLabel[[string]$f.Label] = if ($FeatureDetails.ContainsKey([string]$f.Id)) { [string]$FeatureDetails[[string]$f.Id] } else { [string]$f.Label }
}
$featuresBoxes = New-FeatureToggleTabContent -Tab $tabFeatures -UnifiedItems $featuresUnifiedItems -ItemDetails $featureDetailsByLabel
$FeatDef = @($featuresUnifiedItems)

# Build Services page content from service definitions.
$serviceEntryMap = [ordered]@{}
$serviceLabelSeen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$ServicesChecked = @($ServicesChecked | Select-Object -Unique)
$ServicesUnchecked = @($ServicesUnchecked | Select-Object -Unique)
function Add-ServiceUiEntry {
    param(
        [string]$Id,
        [bool]$Checked = $false
    )
    if ([string]::IsNullOrWhiteSpace($Id)) { return }
    $key = $Id.Trim()
    if ($serviceEntryMap.Contains($key)) { return }
    if (-not (Test-ServiceHasMetadata -ServiceId $key)) { return }

    $baseLabel = Get-ServiceUiLabelBase -ServiceId $key
    $labelToUse = $baseLabel
    if (-not [string]::IsNullOrWhiteSpace($baseLabel)) {
        if (-not $serviceLabelSeen.Add($baseLabel.Trim())) {
            $labelToUse = "$baseLabel ($key)"
            [void]$serviceLabelSeen.Add($labelToUse.Trim())
        }
    }
    else {
        $labelToUse = $key
    }
    $serviceEntryMap[$key] = [pscustomobject]@{
        Id      = $key
        Label   = $labelToUse
        # Keep UI neutral on first load; service changes apply only when user selects.
        Checked = $false
        DefaultMode = 'Automatic'
    }
}

foreach ($sid in @($ServicesUnchecked + $ServicesChecked)) {
    Add-ServiceUiEntry -Id ([string]$sid) -Checked ($ServicesChecked -contains $sid)
}

$servicesUnifiedItems = @(
    Get-UniqueUiItems -Items @($serviceEntryMap.Values) -PrimaryKey 'Id' |
    Where-Object { Test-ServiceHasMetadata -ServiceId ([string]$_.Id) } |
    Sort-Object Label
)
$serviceDetailsByLabel = @{}
foreach ($svc in $servicesUnifiedItems) {
    $detailText = Get-ServiceDetailText -ServiceId ([string]$svc.Id)
    if (-not [string]::IsNullOrWhiteSpace($detailText)) {
        $serviceDetailsByLabel[[string]$svc.Label] = $detailText
    }
}
$servicesBoxes = New-ServiceTabContent -Tab $tabServices -UnifiedItems $servicesUnifiedItems -ItemDetails $serviceDetailsByLabel
$ServDef = @($servicesUnifiedItems | ForEach-Object { [string]$_.Id })

# Build Scheduled Tasks page content from task definitions.
$taskEntryMap = [ordered]@{}
$TasksChecked = @($TasksChecked | Select-Object -Unique)
foreach ($taskPath in $TasksChecked) {
    $normalizedTask = Format-ScheduledTaskPath -TaskPath ([string]$taskPath)
    if ([string]::IsNullOrWhiteSpace($normalizedTask)) { continue }
    if ($taskEntryMap.Contains($normalizedTask)) { continue }
    $taskLabel = Get-ScheduledTaskUiLabel -TaskPath $normalizedTask
    # Keep UI neutral on first load; task changes apply only when user selects.
    $taskDefaultState = 'Default'
    $taskEntryMap[$normalizedTask] = [pscustomobject]@{
        Id           = $normalizedTask
        Label        = $taskLabel
        DefaultState = $taskDefaultState
    }
}
$tasksUnifiedItems = @(Get-UniqueUiItems -Items @($taskEntryMap.Values) -PrimaryKey 'Id' | Sort-Object Label)
$taskUiDetails = @{}
foreach ($taskItem in $tasksUnifiedItems) {
    $taskId = [string]$taskItem.Id
    $taskLabel = [string]$taskItem.Label
    $taskUiDetails[$taskLabel] = if ($TaskDetails.ContainsKey($taskId)) { [string]$TaskDetails[$taskId] } else { $taskId }
}
$taskContext = New-TaskTabContent -Tab $tabTasks -UnifiedItems $tasksUnifiedItems -ItemDetails $taskUiDetails -ExtraButtons @()
$tasksBoxes = $taskContext.Combos
$TasksCheckedSorted = @($tasksUnifiedItems | ForEach-Object { [string]$_.Id })
$TaskDefaultStateById = @{}
foreach ($taskItem in $tasksUnifiedItems) {
    $TaskDefaultStateById[[string]$taskItem.Id] = [string]$taskItem.DefaultState
}
$ServiceDefaultModeById = @{}
foreach ($svcItem in $servicesUnifiedItems) {
    $ServiceDefaultModeById[[string]$svcItem.Id] = if ($null -ne $svcItem.PSObject.Properties['DefaultMode']) { [string]$svcItem.DefaultMode } else { 'Automatic' }
}

$logToolsPanel = New-Object System.Windows.Forms.Panel
$logToolsPanel.Dock = 'Top'
$logToolsPanel.Height = 34
$logToolsPanel.BackColor = $clrPanel

$btnClearLog = New-DarkButton -Text 'Clear' -Width 80 -Height 28
$btnClearLog.Left = 0
$btnClearLog.Top = 4
$btnCopyLog = New-DarkButton -Text 'Copy' -Width 80 -Height 28
$btnCopyLog.Left = 86
$btnCopyLog.Top = 4
$btnBackFromLogs = New-DarkButton -Text '← Back to Builder' -Width 170 -Height 28
$btnBackFromLogs.Left = 172
$btnBackFromLogs.Top = 4
$logToolsPanel.Controls.AddRange(@($btnClearLog, $btnCopyLog, $btnBackFromLogs))

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Dock = 'Fill'
$logBox.ReadOnly = $true
$logBox.BackColor = $clrLogBg
$logBox.ForeColor = $clrLogText
$logBox.Font = New-Object System.Drawing.Font('Consolas', 10)
$logBox.ScrollBars = 'Vertical'
Set-DarkScrollbar -Control $logBox
$logBox.BorderStyle = 'FixedSingle'
$logBox.HideSelection = $false
$logBox.WordWrap = $false
$tabLogs.Controls.Add($logBox)
$tabLogs.Controls.Add($logToolsPanel)
$sync.LogBox = $logBox

$btnClearLog.Add_Click({
        $logBox.Clear()
    })
$btnCopyLog.Add_Click({
        try {
            [System.Windows.Forms.Clipboard]::SetText($logBox.Text)
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Failed to copy log contents.`n`n$_",
                "Clipboard Error", "OK", "Error") | Out-Null
        }
    })
$btnBackFromLogs.Add_Click({
        if ($sync.ProcessRunning) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                "Build is still running. Return to builder page anyway?",
                "Build Running",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        Exit-StandaloneLogsPage
    })

# Store checkbox list references in sync for the runspace to read
$sync.AppxBoxes = $appxBoxes
$sync.AppxDef = @($AppxDef)
$sync.AppxSelectionExpansions = @{} + $appxSelectionExpansions
$sync.FeaturesBoxes = $featuresBoxes
$sync.FeatDef = @($FeatDef)
$sync.TasksBoxes = $tasksBoxes
$sync.TasksFlow = $taskContext.Flow
$sync.TasksSelectors = $taskContext.Selectors
$sync.ServicesBoxes = $servicesBoxes
$sync.ServDef = @($ServDef)
$sync.PrivacyBoxes = $privacyBoxes
$sync.PrivacyDef = @($PrivacyDef)
$sync.PrivacyLabelById = @{} + $PrivacyLabelById
$sync.ExtraSecurityBoxes = $extraSecurityBoxes
$sync.ExtraSecurityDef = @($ExtraSecurityDef)
$sync.ExtraSecurityLabelById = @{} + $ExtraSecurityLabelById
$sync.AdvancedOptionsBoxes = $advancedBoxes
$sync.AdvancedOptionsDef = @($AdvancedOptionsDef)
$sync.AdvancedOptionsLabelById = @{} + $AdvancedOptionsLabelById
$sync.TaskDefaultStateById = @{} + $TaskDefaultStateById
$sync.ServiceDefaultModeById = @{} + $ServiceDefaultModeById
$sync.ExpeditedKeys = $ExpeditedAppsKeys
$sync.TasksBaseDef = @($TasksCheckedSorted)
$sync.TasksAllDef = @($TasksCheckedSorted)
$sync.TaskDetailsBase = @{} + $taskUiDetails
$sync.TaskDetails = @{} + $taskUiDetails
$sync.TaskDisableWarnings = @{} + $TaskDisableWarnings
$sync.TaskDetailBox = $taskContext.DetailBox
$sync.CustomTaskBoxes = [System.Collections.Generic.List[System.Windows.Forms.ComboBox]]::new()
$sync.CustomTaskRows = [System.Collections.Generic.List[System.Windows.Forms.Panel]]::new()

function Set-ContentAreaPlaceholder {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Control]$Page,
        [Parameter(Mandatory)][string]$Message
    )
    foreach ($ctl in @($Page.Controls)) {
        $ctl.Visible = $false
    }
    $placeholder = New-Object System.Windows.Forms.Label
    $placeholder.Dock = 'Fill'
    $placeholder.AutoSize = $false
    $placeholder.TextAlign = 'MiddleCenter'
    $placeholder.Text = $Message
    $placeholder.ForeColor = $clrMutedText
    $placeholder.BackColor = $Page.BackColor
    $placeholder.Font = New-UiFont -Size 10
    $placeholder.Tag = 'PagePlaceholder'
    $Page.Controls.Add($placeholder)
    $placeholder.BringToFront()
}

#region ── Config Import/Export Helpers ───────────────────────────────────────
function Get-CheckedItemsByDefinition {
    param([System.Collections.IList]$Boxes, [string[]]$Definition)
    $selected = @()
    $max = [Math]::Min($Boxes.Count, $Definition.Count)
    for ($i = 0; $i -lt $max; $i++) {
        if ($Boxes[$i].Checked) { $selected += $Definition[$i] }
    }
    return $selected
}

function Set-CheckedItemsByDefinition {
    param([System.Collections.IList]$Boxes, [string[]]$Definition, [object[]]$SelectedItems)
    $selected = @($SelectedItems)
    $max = [Math]::Min($Boxes.Count, $Definition.Count)
    for ($i = 0; $i -lt $max; $i++) {
        $Boxes[$i].Checked = ($selected -contains $Definition[$i])
    }
}

function Get-ConfigPropertyValue {
    param([object]$Object, [string]$Name, [object]$Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -ne $prop) { return $prop.Value }
    return $Default
}

function Test-ConfigPropertyExists {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object -or [string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-PrivacySelectionIsHardened {
    param(
        [string]$Label,
        [string]$Mode
    )

    if ($Mode -notin @('Enabled', 'Disabled')) { return $null }

    $labelText = [string]$Label
    $isDisableStyle = $false
    $isEnableStyle = $false
    if ($labelText -match '^(?i)\s*(disable|block|prevent|remove|hide)\b') {
        $isDisableStyle = $true
    }
    elseif ($labelText -match '(?i)\bturn\s+off\b') {
        $isDisableStyle = $true
    }
    elseif ($labelText -match '(?i)\bdisable\b') {
        $isDisableStyle = $true
    }
    elseif ($labelText -match '^(?i)\s*enable\b') {
        $isEnableStyle = $true
    }

    if ($Mode -eq 'Enabled') { return ($isDisableStyle -or $isEnableStyle) }
    return (-not ($isDisableStyle -or $isEnableStyle))
}

function Get-PrivacyConsentCapabilityName {
    param([string]$PermissionText)

    if ([string]::IsNullOrWhiteSpace($PermissionText)) { return '' }
    $key = $PermissionText.Trim().ToLowerInvariant()
    $key = $key -replace '^(disable|allow)\s+', ''
    $key = $key -replace '\s*\(.*?\)\s*', ' '
    $key = ($key -replace '\s+', ' ').Trim()

    switch -Regex ($key) {
        '(appointments?|calendar)' { return 'appointments' }
        '^call history$' { return 'phoneCallHistory' }
        '^camera$' { return 'webcam' }
        '^contacts?$' { return 'contacts' }
        'diagnostic' { return 'appDiagnostics' }
        '^documents library$' { return 'documentsLibrary' }
        '^email$' { return 'email' }
        '^file system$' { return 'broadFileSystemAccess' }
        '(messages|messaging|sms|mms)' { return 'chat' }
        '^microphone$' { return 'microphone' }
        'notifications?' { return 'userNotificationListener' }
        '^phone calls?$' { return 'phoneCall' }
        '^pictures library$' { return 'picturesLibrary' }
        '^radios$' { return 'radios' }
        '(share and sync|unpaired bluetooth|non-explicitly paired wireless)' { return 'bluetoothSync' }
        '^tasks?$' { return 'userDataTasks' }
        '(user account info|account information|account info|name, and picture)' { return 'userAccountInformation' }
        '^videos library$' { return 'videosLibrary' }
        '^location$' { return 'location' }
        'voice activation' { return 'voiceActivation' }
        '(eye tracking|gaze)' { return 'gazeInput' }
        '(physical movement|motion activity|activity)' { return 'activity' }
        default { return '' }
    }
}

function Convert-PrivacySelectionsToRegistryTweaks {
    param(
        [System.Collections.IDictionary]$PrivacyConfig,
        [hashtable]$PrivacyLabelById
    )

    $resultMap = [ordered]@{}
    $mappedSeen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $unmappedSeen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $mappedLabels = [System.Collections.Generic.List[string]]::new()
    $unmappedLabels = [System.Collections.Generic.List[string]]::new()

    if ($null -eq $PrivacyConfig) {
        return [pscustomobject]@{
            Tweaks         = @()
            MappedLabels   = @()
            UnmappedLabels = @()
        }
    }

    $addSetting = {
        param(
            [string]$Hive,
            [string]$KeyPath,
            [string]$ValueName,
            [object]$HardenedData,
            [object]$RelaxedData,
            [string]$ValueType,
            [bool]$Hardened
        )
        $chosenData = if ($Hardened) { $HardenedData } else { $RelaxedData }
        $mapKey = "{0}\{1}|{2}" -f $Hive, $KeyPath, $ValueName
        $resultMap[$mapKey] = @($Hive, $KeyPath, $ValueName, $chosenData, $ValueType)
    }.GetNewClosure()

    foreach ($entry in $PrivacyConfig.GetEnumerator()) {
        $privacyId = [string]$entry.Key
        $mode = [string]$entry.Value
        if ($mode -notin @('Enabled', 'Disabled')) { continue }

        $label = if ($null -ne $PrivacyLabelById -and $PrivacyLabelById.ContainsKey($privacyId)) {
            [string]$PrivacyLabelById[$privacyId]
        }
        else {
            $privacyId
        }

        $hardened = Get-PrivacySelectionIsHardened -Label $label -Mode $mode
        if ($null -eq $hardened) { continue }
        $matched = $false

        switch -Regex ($label) {
            '(?i)^App permissions:\s*(.+)$' {
                $permissionText = [string]$Matches[1]
                $capabilityName = Get-PrivacyConsentCapabilityName -PermissionText $permissionText
                if (-not [string]::IsNullOrWhiteSpace($capabilityName)) {
                    & $addSetting 'zSOFTWARE' "Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$capabilityName" 'Value' 'Deny' 'Allow' 'String' $hardened
                    & $addSetting 'zNTUSER' "SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$capabilityName" 'Value' 'Deny' 'Allow' 'String' $hardened
                    $matched = $true
                }
                break
            }
            '(?i)^Search:\s*Cloud content \(Microsoft account\)$' {
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsMSACloudSearchEnabled' 0 1 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Search:\s*Cloud content \(Work or School account\)$' {
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsAADCloudSearchEnabled' 0 1 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Search:\s*Cloud content accounts$' {
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsMSACloudSearchEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsAADCloudSearchEnabled' 0 1 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Search:\s*Device search history$' {
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsDeviceSearchHistoryEnabled' 0 1 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Search:\s*Search highlights$' {
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\Windows Search' 'EnableDynamicContentInWSB' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsDynamicSearchBoxEnabled' 0 1 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Search:\s*Find my files$' {
                & $addSetting 'zSOFTWARE' 'Microsoft\Windows Search' 'EnableFindMyFiles' 0 1 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Recommendations and offers in Settings$' {
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338393Enabled' 0 1 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Personalized offers$' {
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\CloudContent' 'DisableTailoredExperiencesWithDiagnosticData' 1 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^View diagnostic data$' {
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\DataCollection' 'DisableDiagnosticDataViewer' 1 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Delete diagnostic data$' {
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\DataCollection' 'DisableDeleteDiagnosticData' 1 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^OOBE:\s*Finish setting up your device \(SCOOBE\)$' {
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsSpotlightWindowsWelcomeExperience' 1 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Settings app suggestions$' {
                & $addSetting 'zNTUSER' 'SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsSpotlightOnSettings' 1 0 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338393Enabled' 0 1 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Start menu suggestions$' {
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_IrisRecommendations' 0 1 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Cross-device resume$' {
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\CrossDeviceResume\Configuration' 'IsResumeAllowed' 0 1 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Compatibility telemetry:\s*Application inventory$' {
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\AppCompat' 'DisableInventory' 1 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Compatibility telemetry:\s*Compatibility Appraiser task$' {
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\AppCompat' 'DisableInventory' 1 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Compatibility assistant \(PCA\)$' {
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\AppCompat' 'DisablePCA' 1 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Lock screen app notifications$' {
                & $addSetting 'zNTUSER' 'SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications' 'NoToastApplicationNotificationOnLockScreen' 1 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Notification center and tray$' {
                & $addSetting 'zNTUSER' 'SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableNotificationCenter' 1 0 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0 1 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Sync Settings:\s*All settings$' {
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\SettingSync' 'DisableSettingSync' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\SettingSync' 'DisableWindowsSettingSync' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\SettingSync' 'DisableCredentialsSettingSync' 1 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Sync Settings:\s*Credentials$' {
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\SettingSync' 'DisableCredentialsSettingSync' 1 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Sync Settings:\s*(Other Windows settings|Language)$' {
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\SettingSync' 'DisableWindowsSettingSync' 1 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^System cloud configuration downloads$' {
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\DataCollection' 'DisableOneSettingsDownloads' 1 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Edge network prediction$' {
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'NetworkPredictionOptions' 2 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^File Explorer search history$' {
                & $addSetting 'zNTUSER' 'SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Windows experimentation$' {
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\PreviewBuilds' 'EnableExperimentation' 0 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\PreviewBuilds' 'EnableConfigFlighting' 0 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Microsoft\PolicyManager\default\System\AllowExperimentation' 'value' 0 1 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Disable internet access for Windows DRM$' {
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\WMDRM' 'DisableOnline' 1 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Autocorrect misspelled words$' {
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\TabletTip\1.7' 'EnableAutocorrection' 0 1 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Highlight misspelled words$' {
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\TabletTip\1.7' 'EnableSpellchecking' 0 1 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Display last user name in logon screen$' {
                & $addSetting 'zSOFTWARE' 'Microsoft\Windows\CurrentVersion\Policies\System' 'DontDisplayLastUserName' 1 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Display locked user name in logon screen$' {
                & $addSetting 'zSOFTWARE' 'Microsoft\Windows\CurrentVersion\Policies\System' 'DontDisplayLockedUserId' 3 2 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Enforce DCOM hardening changes$' {
                & $addSetting 'zSOFTWARE' 'Microsoft\Ole\AppCompat' 'RequireIntegrityActivationAuthenticationLevel' 1 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Explorer automatic folder discovery$' {
                & $addSetting 'zNTUSER' 'SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell' 'FolderType' 'NotSpecified' '' 'String' $hardened
                $matched = $true
                break
            }
            '(?i)^NVIDIA Experience Improvement Program$' {
                & $addSetting 'zSOFTWARE' 'NVIDIA Corporation\NvControlPanel2\Client' 'OptInOrOutPreference' 0 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'NVIDIA Corporation\Global\FTS' 'EnableRID44231' 0 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'NVIDIA Corporation\Global\FTS' 'EnableRID64640' 0 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'NVIDIA Corporation\Global\FTS' 'EnableRID66610' 0 1 'DWord' $hardened
                & $addSetting 'zSYSTEM' 'ControlSet001\Services\nvlddmkm\Global\Startup' 'SendTelemetryData' 0 1 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^(ShellBags|Clear Explorer folder view history \(ShellBags\)|Remove registry logs of package install locations|Clear package install-location registry logs)$' {
                # Handled by first-startup cleanup actions.
                $matched = $true
                break
            }
            '(?i)^Search:\s*Microsoft Store app results in Start menu$' {
                # Handled by first-startup runtime actions.
                $matched = $true
                break
            }
            '(?i)^(Workplace join prompts|Block Workplace Join Messages)$' {
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WorkplaceJoin' 'BlockAADWorkplaceJoin' 1 0 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Policies\Microsoft\Windows\WorkplaceJoin' 'BlockAADWorkplaceJoin' 1 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Automatic maintenance$' {
                & $addSetting 'zSOFTWARE' 'Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance' 'MaintenanceDisabled' 1 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Remote Assistance$' {
                & $addSetting 'zSYSTEM' 'ControlSet001\Control\Remote Assistance' 'fAllowToGetHelp' 0 1 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Windows Error Reporting$' {
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1 0 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)(apps run in the background|background activity)' {
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\AppPrivacy' 'LetAppsRunInBackground' 2 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)(telemetry|diagnostic data|diagnostic and usage|customer experience|sqm|windows feedback|feedback frequency|error reporting)' {
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0 3 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0 3 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 1 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)(activity history|activity feed|timeline|shared experiences)' {
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\System' 'PublishUserActivities' 0 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\System' 'UploadUserActivities' 0 1 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)(wi-?fi sense|hotspots?|hotspot 2\.0)' {
                & $addSetting 'zSOFTWARE' 'Microsoft\PolicyManager\default\WiFi\AllowWiFiHotSpotReporting' 'value' 0 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Microsoft\PolicyManager\default\WiFi\AllowAutoConnectToWiFiSenseHotspots' 'value' 0 1 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)(bing|web results|cloud search|search highlights|cortana|search history|cloud content search|search - allow cortana|search - cloud content|search - show search highlights)' {
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\Windows Search' 'DisableWebSearch' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\Windows Search' 'ConnectedSearchUseWeb' 0 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\Windows Search' 'EnableDynamicContentInWSB' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'CortanaConsent' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsDeviceSearchHistoryEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsDynamicSearchBoxEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsMSACloudSearchEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsAADCloudSearchEnabled' 0 1 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)(consumer features|sponsored apps|suggested apps|pre-installed apps|pre-installed oem apps|windows tips|welcome experience|suggested content|notifications in the settings app|settings app notifications|settings app suggestions|cloud-optimized content|windows spotlight|recommendations|content delivery|subscribed content|feature management|soft landing experiences|promotional content|ads, suggestions|silent app installation)' {
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1 0 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'ContentDeliveryAllowed' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'FeatureManagementEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SoftLandingEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'OemPreInstalledAppsEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEverEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338393Enabled' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-310093Enabled' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsSpotlightWindowsWelcomeExperience' 1 0 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'RotatingLockScreenEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'RotatingLockScreenOverlayEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_IrisRecommendations' 0 1 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)(show most used apps|track(?:ing)? app launches|app usage tracking|start menu:\s*most used apps|start menu:\s*track app launches)' {
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_TrackProgs' 0 1 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)(show recently used files in quick access|show frequently used folders in quick access|track opened documents|jump lists|quick access frequent folders|quick access recent files)' {
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'ShowRecent' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'ShowFrequent' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_TrackDocs' 0 1 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)(advertising id|ad customization)' {
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1 0 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0 1 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)(language list access for websites|locally relevant content by accessing.*language list)' {
                & $addSetting 'zNTUSER' 'Control Panel\International\User Profile' 'HttpAcceptLanguageOptOut' 1 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)(location services|disable location|windows location provider|location tracking|location scripting|device sensors)' {
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\LocationAndSensors' 'DisableLocation' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\LocationAndSensors' 'DisableLocationScripting' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\LocationAndSensors' 'DisableWindowsLocationProvider' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\LocationAndSensors' 'DisableSensors' 1 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)(disable onedrive automatic backups|onedrive automatic backups|known folder move)' {
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\OneDrive' 'KFMBlockOptIn' 1 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)(speech|typing|inking|handwriting|input insights|text and handwriting|narrator online services|narrator scripting support|custom inking and typing dictionary|online speech recognition)' {
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1 0 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 1 0 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Narrator\NoRoam' 'OnlineServicesEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Narrator\NoRoam' 'ScriptingEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Input\Settings' 'InsightsEnabled' 0 1 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)(clipboard history|cloud clipboard sync)' {
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Clipboard' 'EnableClipboardHistory' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Clipboard' 'EnableCloudClipboard' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Clipboard' 'CloudClipboardAutomaticUpload' 0 1 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^AI:\s*(Disable actions \(Click to Do\)|Disable Settings agent|Disable Copilot and Recall policies)$' {
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'AllowRecallEnablement' 0 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableClickToDo' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'TurnOffSavingSnapshots' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableSettingsAgent' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableAgentConnectors' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableAgentWorkspaces' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableRemoteAgentConnectors' 1 0 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\Shell\ClickToDo' 'DisableClickToDo' 1 0 'DWord' $hardened
                # FeatureManagement overrides from RemoveWindowsAI (build-dependent behavior).
                & $addSetting 'zSYSTEM' 'ControlSet001\Control\FeatureManagement\Overrides\8\1853569164' 'EnabledState' 1 0 'DWord' $hardened
                & $addSetting 'zSYSTEM' 'ControlSet001\Control\FeatureManagement\Overrides\8\4098520719' 'EnabledState' 1 0 'DWord' $hardened
                & $addSetting 'zSYSTEM' 'ControlSet001\Control\FeatureManagement\Overrides\8\929719951' 'EnabledState' 1 0 'DWord' $hardened
                & $addSetting 'zSYSTEM' 'ControlSet001\Control\FeatureManagement\Overrides\8\1646260367' 'EnabledState' 2 0 'DWord' $hardened
                & $addSetting 'zSYSTEM' 'ControlSet001\Control\FeatureManagement\Overrides\8\2283032206' 'EnabledState' 1 0 'DWord' $hardened
                & $addSetting 'zSYSTEM' 'ControlSet001\Control\FeatureManagement\Overrides\8\502943886' 'EnabledState' 1 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^AI:\s*Disable voice effects$' {
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\AppPrivacy' 'LetAppsAccessGenerativeAI' 2 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\AppPrivacy' 'LetAppsAccessSystemAIModels' 2 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\generativeAI' 'Value' 'Deny' 'Allow' 'String' $hardened
                & $addSetting 'zSOFTWARE' 'Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\systemAIModels' 'Value' 'Deny' 'Allow' 'String' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Speech_OneCore\Settings\VoiceActivation\UserPreferenceForAllApps' 'AgentActivationEnabled' 0 1 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^AI:\s*Disable Voice Access$' {
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\VoiceAccess' 'RunningState' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\VoiceAccess' 'TextCorrection' 1 2 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\AccessibilityTemp' '0' 0 1 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Paint:\s*Disable AI image features$' {
                & $addSetting 'zSOFTWARE' 'Microsoft\Windows\CurrentVersion\Policies\Paint' 'DisableImageCreator' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Microsoft\Windows\CurrentVersion\Policies\Paint' 'DisableCocreator' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Microsoft\Windows\CurrentVersion\Policies\Paint' 'DisableGenerativeFill' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Microsoft\Windows\CurrentVersion\Policies\Paint' 'DisableGenerativeErase' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Microsoft\Windows\CurrentVersion\Policies\Paint' 'DisableRemoveBackground' 1 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Notepad:\s*Disable AI features$' {
                & $addSetting 'zSOFTWARE' 'Policies\WindowsNotepad' 'DisableAIFeatures' 1 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^AI:\s*Disable Fabric service$' {
                & $addSetting 'zSYSTEM' 'ControlSet001\Services\WSAIFabricSvc' 'Start' 4 2 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^AI:\s*Prevent Copilot package reinstall$' {
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\Appx\RemoveDefaultMicrosoftStorePackages\Microsoft.Copilot_8wekyb3d8bbwe' 'RemovePackage' 1 0 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\AutoInstalledPWAs' 'CopilotPWAPreinstallCompleted' 1 0 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\AutoInstalledPWAs' 'Microsoft.Copilot_8wekyb3d8bbwe' 1 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^AI:\s*Hide Settings components pages$' {
                & $addSetting 'zSOFTWARE' 'Microsoft\Windows\CurrentVersion\Policies\Explorer' 'SettingsPageVisibility' 'hide:aicomponents;appactions;' '' 'String' $hardened
                $matched = $true
                break
            }
            '(?i)^Office:\s*Disable Copilot and AI features$' {
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\office\16.0\common\ai\training\general' 'disabletraining' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\office\16.0\common\ai\training\specific\adaptivefloatie' 'disabletrainingofadaptivefloatie' 1 0 'DWord' $hardened
                & $addSetting 'zNTUSER' 'Software\Policies\Microsoft\office\16.0\common\privacy' 'controllerconnectedservicesenabled' 2 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'Software\Policies\Microsoft\office\16.0\common\privacy' 'usercontentdisabled' 2 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'Software\Microsoft\Office\16.0\Word\Options' 'EnableCopilot' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'Software\Microsoft\Office\16.0\Excel\Options' 'EnableCopilot' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'Software\Microsoft\Office\16.0\OneNote\Options\Copilot' 'CopilotEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'Software\Microsoft\Office\16.0\OneNote\Options\Copilot' 'CopilotNotebooksEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zNTUSER' 'Software\Microsoft\Office\16.0\OneNote\Options\Copilot' 'CopilotSkittleEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\office\16.0\common\ai\contentsafety\general' 'disablecontentsafety' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\office\16.0\common\ai\contentsafety\specific\rewrite' 'disablecontentsafety' 1 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Gaming:\s*Disable Copilot widget$' {
                # Prefer policy-backed AI/Copilot controls here; WindowsRuntime ActivatableClassId
                # keys are ACL-protected in many images and frequently fail offline.
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1 0 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'AllowRecallEnablement' 0 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableClickToDo' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'TurnOffSavingSnapshots' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableSettingsAgent' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableAgentConnectors' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableAgentWorkspaces' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableRemoteAgentConnectors' 1 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^Edge:\s*Disable Copilot and AI features$' {
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'CopilotPageContext' 0 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'HubsSidebarEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'EdgeEntraCopilotPageContext' 0 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'EdgeHistoryAISearchEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'ComposeInlineEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'GenAILocalFoundationalModelSettings' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'BuiltInAIAPIsEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'AIGenThemesEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'DevToolsGenAiSettings' 2 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'ShareBrowsingHistoryWithCopilotSearchAllowed' 0 1 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)^AI:\s*(Remove Recall optional feature|Remove Recall scheduled tasks|Remove AI appx packages|Remove AI CBS packages|Remove AI files and folders|Install update cleanup checker task|Install classic Windows apps)$' {
                # These options are handled by first-startup runtime actions, not offline registry writes.
                $matched = $true
                break
            }
            '(?i)^Classic Apps:\s*(Replace Notepad|Replace Paint|Replace Snipping Tool|Replace Photo Viewer|Install Photos Legacy)$' {
                # Classic-app replacements are runtime actions and currently informational in this builder.
                $matched = $true
                break
            }
            '(?i)(copilot|recall)' {
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1 0 'DWord' $hardened
                & $addSetting 'zNTUSER' 'SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'AllowRecallEnablement' 0 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableClickToDo' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'TurnOffSavingSnapshots' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableSettingsAgent' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableAgentConnectors' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableAgentWorkspaces' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableRemoteAgentConnectors' 1 0 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)(edge tracking prevention|do not track|edge diagnostic|edge search and site suggestions|copilot in edge|edge bing suggestions)' {
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'ConfigureDoNotTrack' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'TrackingPrevention' 3 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'ShowSuggestionsEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'AddressBarTrendingSuggestEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'DiagnosticData' 0 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'CopilotPageContext' 0 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'HubsSidebarEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'EdgeEntraCopilotPageContext' 0 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'EdgeHistoryAISearchEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'ComposeInlineEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'GenAILocalFoundationalModelSettings' 1 0 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'BuiltInAIAPIsEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'AIGenThemesEnabled' 0 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'DevToolsGenAiSettings' 2 1 'DWord' $hardened
                & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'ShareBrowsingHistoryWithCopilotSearchAllowed' 0 1 'DWord' $hardened
                $matched = $true
                break
            }
            '(?i)(install classic apps|replace notepad|replace paint|replace snipping tool|replace photo viewer|install photos legacy|remove ai appx packages|remove ai packages in cbs|remove ai files|update cleanup check)' {
                # These labels are not registry toggles.
                $matched = $true
                break
            }
        }

        if ($matched) {
            if ($mappedSeen.Add($label)) { [void]$mappedLabels.Add($label) }
        }
        else {
            if ($unmappedSeen.Add($label)) { [void]$unmappedLabels.Add($label) }
        }
    }

    return [pscustomobject]@{
        Tweaks         = @($resultMap.Values)
        MappedLabels   = @($mappedLabels)
        UnmappedLabels = @($unmappedLabels)
    }
}

function Clear-CustomScheduledTaskEntries {
    $hasTasksUi = ($null -ne $sync.TasksBoxes -and $null -ne $sync.TasksFlow)

    if ($hasTasksUi) {
        foreach ($row in @($sync.CustomTaskRows)) {
            if ($null -eq $row) { continue }
            if ($null -ne $sync.TasksSelectors) {
                foreach ($sel in @($sync.TasksSelectors)) {
                    if ($null -ne $sel -and $sel.Parent -eq $row) {
                        [void]$sync.TasksSelectors.Remove($sel)
                    }
                }
            }
            if ($sync.TasksFlow.Controls.Contains($row)) {
                [void]$sync.TasksFlow.Controls.Remove($row)
            }
            $row.Dispose()
        }
        foreach ($combo in @($sync.CustomTaskBoxes)) {
            if ($null -ne $combo) {
                [void]$sync.TasksBoxes.Remove($combo)
                $combo.Dispose()
            }
        }
    }

    if ($null -ne $sync.CustomTaskBoxes) { $sync.CustomTaskBoxes.Clear() }
    if ($null -ne $sync.CustomTaskRows) { $sync.CustomTaskRows.Clear() }
    $sync.CustomTasks = @()
    $sync.TasksAllDef = @($sync.TasksBaseDef)
    $sync.TaskDetails = @{} + $sync.TaskDetailsBase
    $sync.LastSelectedTaskCombo = $null
    if ($sync.TaskDetailBox) {
        $sync.TaskDetailBox.Text = "Select an item to view its details."
    }
}

function Remove-SelectedCustomTask {
    $comboToRemove = $sync.LastSelectedTaskCombo
    if ($null -eq $comboToRemove) {
        [System.Windows.Forms.MessageBox]::Show("Please select a custom task to remove.", "No Selection", "OK", "Information") | Out-Null
        return
    }

    if (-not $sync.CustomTaskBoxes.Contains($comboToRemove)) {
        [System.Windows.Forms.MessageBox]::Show("Only custom-added tasks can be removed.", "Cannot Remove", "OK", "Information") | Out-Null
        return
    }

    $boxIndex = $sync.TasksBoxes.IndexOf($comboToRemove)
    if ($boxIndex -eq -1) { return }

    if ($boxIndex -ge $sync.TasksAllDef.Count) {
        Write-Log "Error: selected task index is out of range." -Color Red
        return
    }
    $taskPath = $sync.TasksAllDef[$boxIndex]
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Are you sure you want to remove this custom task?`n`n$taskPath",
        "Confirm Removal", "YesNo", "Warning")
    if ($confirm -ne 'Yes') { return }

    # Find custom entry
    $customEntryToRemove = $null
    foreach ($ct in $sync.CustomTasks) {
        if ($ct.Path -eq $taskPath) { $customEntryToRemove = $ct; break }
    }
    if ($customEntryToRemove) {
        $newCustom = [System.Collections.Generic.List[object]]::new()
        foreach ($c in $sync.CustomTasks) { if ($c.Path -ne $taskPath) { $newCustom.Add($c) } }
        $sync.CustomTasks = @($newCustom)
    }

    # Remove UI
    $rowToRemove = $comboToRemove.Parent
    $sync.TasksFlow.Controls.Remove($rowToRemove)
    $rowToRemove.Dispose()

    $sync.TasksBoxes.RemoveAt($boxIndex)
    if ($null -ne $sync.TasksSelectors -and $sync.TasksSelectors.Count -gt $boxIndex) {
        $sync.TasksSelectors.RemoveAt($boxIndex)
    }
    $sync.CustomTaskBoxes.Remove($comboToRemove)
    $sync.TasksAllDef = $sync.TasksAllDef | Where-Object { $_ -ne $taskPath }
    $sync.LastSelectedTaskCombo = $null
    Write-Log "Removed custom task: $taskPath" -Color Green
}

function Add-CustomScheduledTaskEntry {
    param(
        [Parameter(Mandatory)][string]$TaskPath,
        [string]$Detail = '',
        [bool]$Checked = $false,
        [switch]$Silent
    )

    $normalizedPath = Format-ScheduledTaskPath -TaskPath $TaskPath
    if ([string]::IsNullOrWhiteSpace($normalizedPath)) { return $false }
    if (-not (Test-ScheduledTaskPathIsSafe -TaskPath $normalizedPath)) {
        if (-not $Silent) {
            [System.Windows.Forms.MessageBox]::Show(
                "Task path contains unsupported characters.`nAvoid quotes, backticks, or line breaks.",
                "Invalid Task Path", "OK", "Warning") | Out-Null
        }
        return $false
    }

    if (@($sync.TasksAllDef | Where-Object { $_ -ieq $normalizedPath }).Count -gt 0) {
        if (-not $Silent) {
            [System.Windows.Forms.MessageBox]::Show(
                "Task already exists in the list:`n$normalizedPath",
                "Duplicate Task", "OK", "Information") | Out-Null
        }
        return $false
    }

    $detailText = if ([string]::IsNullOrWhiteSpace($Detail)) {
        'Disables custom scheduled task provided by the user.'
    }
    else {
        $Detail.Trim()
    }

    $sync.TasksAllDef = @($sync.TasksAllDef + $normalizedPath)
    $sync.TaskDetails[$normalizedPath] = $detailText

    $state = if ($Checked) { 'Disabled' } else { 'Default' }
    $beforeCount = $sync.TasksBoxes.Count
    $newRow = Add-TaskUiRow -Flow $sync.TasksFlow -Combos $sync.TasksBoxes -Rows $sync.CustomTaskRows -Selectors $sync.TasksSelectors -Label $normalizedPath -State $state -ItemDetails $sync.TaskDetails -DetailBox $sync.TaskDetailBox
    if ($sync.TasksBoxes.Count -le $beforeCount) {
        $sync.TasksAllDef = @($sync.TasksAllDef | Where-Object { $_ -ine $normalizedPath })
        if ($sync.TaskDetails.ContainsKey($normalizedPath)) {
            [void]$sync.TaskDetails.Remove($normalizedPath)
        }
        return $false
    }

    $newBox = $sync.TasksBoxes[$sync.TasksBoxes.Count - 1]
    if ($newRow) { Register-UiChangeLogging -Root $newRow -Recursive }
    if ($newBox) { Register-UiChangeLogging -Root $newBox }
    [void]$sync.CustomTaskBoxes.Add($newBox)
    $sync.CustomTasks = @($sync.CustomTasks + @([ordered]@{
                Path   = $normalizedPath
                Detail = $detailText
            }))
    Write-Log "Added custom scheduled task: $normalizedPath" -Color Cyan
    return $true
}

function Show-CustomTaskDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Add Custom Scheduled Task'
    $dlg.Size = New-Object System.Drawing.Size(560, 200)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = $clrBg
    $dlg.ForeColor = $clrText
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $lblPath = New-DarkLabel -Text 'Task Path:' -Width 100
    $lblPath.Left = 12; $lblPath.Top = 16
    $tbPath = New-DarkTextBox -Text '\Microsoft\Windows\' -Width 420
    $tbPath.Panel.Left = 120; $tbPath.Panel.Top = 12
    $tbPath.Panel.Height = 34

    $lblDetail = New-DarkLabel -Text 'Description:' -Width 100
    $lblDetail.Left = 12; $lblDetail.Top = 50
    $tbDetail = New-DarkTextBox -Text '' -Width 420
    $tbDetail.Panel.Left = 120; $tbDetail.Panel.Top = 46
    $tbDetail.Panel.Height = 34

    $btnOk = New-DarkButton -Text 'Add' -Width 90 -Height 34 -Role 'Accent'
    $btnOk.Left = 344; $btnOk.Top = 92
    $btnCancel = New-DarkButton -Text 'Cancel' -Width 90 -Height 34
    $btnCancel.Left = 450; $btnCancel.Top = 92

    $btnOk.Add_Click({
            if ([string]::IsNullOrWhiteSpace($tbPath.TextBox.Text)) {
                [System.Windows.Forms.MessageBox]::Show("Task path is required.", "Missing Value", "OK", "Warning") | Out-Null
                return
            }
            $dlg.DialogResult = 'OK'
            $dlg.Close()
        })
    $btnCancel.Add_Click({ $dlg.DialogResult = 'Cancel'; $dlg.Close() })

    $tbPathPanel = $tbPath.Panel
    $tbDetailPanel = $tbDetail.Panel

    $dlg.Controls.AddRange(@($lblPath, $tbPathPanel, $lblDetail, $tbDetailPanel, $btnOk, $btnCancel))
    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCancel

    try {
        if ($dlg.ShowDialog($form) -ne 'OK') { return $null }
        return [ordered]@{
            Path   = $tbPath.TextBox.Text.Trim()
            Detail = $tbDetail.TextBox.Text.Trim()
        }
    }
    finally {
        try { $dlg.Dispose() } catch {}
    }
}

function Get-CurrentConfiguration {
    $svcConfig = @{}
    $svcMax = [Math]::Min($sync.ServicesBoxes.Count, $sync.ServDef.Count)
    for ($i = 0; $i -lt $svcMax; $i++) {
        $val = $sync.ServicesBoxes[$i].SelectedItem
        if ($val -in @('Disabled', 'Manual')) {
            $svcConfig[$sync.ServDef[$i]] = $val
        }
    }

    $privacyConfig = @{}
    $privacyMax = [Math]::Min($sync.PrivacyBoxes.Count, $sync.PrivacyDef.Count)
    for ($i = 0; $i -lt $privacyMax; $i++) {
        $val = [string]$sync.PrivacyBoxes[$i].SelectedItem
        if ($val -in @('Enabled', 'Disabled')) {
            $privacyConfig[$sync.PrivacyDef[$i]] = $val
        }
    }

    $extraSecurityConfig = @{}
    $extraSecurityMax = [Math]::Min($sync.ExtraSecurityBoxes.Count, $sync.ExtraSecurityDef.Count)
    for ($i = 0; $i -lt $extraSecurityMax; $i++) {
        $val = [string]$sync.ExtraSecurityBoxes[$i].SelectedItem
        if ($val -in @('Enabled', 'Disabled')) {
            $extraSecurityConfig[$sync.ExtraSecurityDef[$i]] = $val
        }
    }

    $advancedOptionsConfig = @{}
    $advancedMax = [Math]::Min($sync.AdvancedOptionsBoxes.Count, $sync.AdvancedOptionsDef.Count)
    for ($i = 0; $i -lt $advancedMax; $i++) {
        $val = [string]$sync.AdvancedOptionsBoxes[$i].SelectedItem
        if ($val -in @('Enabled', 'Disabled')) {
            $advancedOptionsConfig[$sync.AdvancedOptionsDef[$i]] = $val
        }
    }

    return [ordered]@{
        schemaVersion = 2
        exportedAtUtc = [DateTime]::UtcNow.ToString('o')
        paths         = [ordered]@{
            SourceISO         = Get-PathTextBoxValue -Control $tbSourceISO
            OutputISO         = Get-PathTextBoxValue -Control $tbOutputISO
            ScratchDir        = Get-PathTextBoxValue -Control $tbScratch
            CustomUnattendXml = [string]$sync.CustomUnattendXml
            CustomRegFiles    = @($sync.CustomRegFiles)
            CustomBatFiles    = @($sync.CustomBatFiles)
            DriverSourceDir   = [string]$sync.DriverSourceDir
            DriverExtractDir  = [string]$sync.DriverExtractDir
        }
        drivers       = [ordered]@{
            InjectInstallWim = [bool]$sync.InjectDriversInstallWim
            Recurse          = [bool]$sync.DriverInjectRecurse
        }
        security      = [ordered]@{
            Preset = [string]$sync.SecurityPreset
        }
        custom        = [ordered]@{
            Tasks = @($sync.CustomTasks)
        }
        selections    = [ordered]@{
            AppxChecked             = @(Get-CheckedItemsByDefinition -Boxes $sync.AppxBoxes -Definition $sync.AppxDef)
            FeatureConfig           = $(
                $featConfig = @{}
                $featMax = [Math]::Min($sync.FeaturesBoxes.Count, $sync.FeatDef.Count)
                for ($i = 0; $i -lt $featMax; $i++) {
                    $val = $sync.FeaturesBoxes[$i].SelectedItem
                    if ([string]::IsNullOrWhiteSpace([string]$val)) { $val = 'Default' }
                    $featConfig[$sync.FeatDef[$i].Id] = [string]$val
                }
                $featConfig
            )
            TaskConfig              = $(
                $tConfig = @{}
                $tMax = [Math]::Min($sync.TasksBoxes.Count, $sync.TasksAllDef.Count)
                for ($i = 0; $i -lt $tMax; $i++) {
                    $val = $sync.TasksBoxes[$i].SelectedItem
                    if ([string]::IsNullOrWhiteSpace([string]$val)) { $val = 'Default' }
                    $tConfig[$sync.TasksAllDef[$i]] = [string]$val
                }
                $tConfig
            )
            ServiceConfig           = $svcConfig
            PrivacyConfig           = $privacyConfig
            ExtraSecurityConfig     = $extraSecurityConfig
            AdvancedOptionsConfig   = $advancedOptionsConfig
            AdvancedOptionsByLabel  = $(
                $advancedByLabel = @{}
                foreach ($entry in $advancedOptionsConfig.GetEnumerator()) {
                    $advId = [string]$entry.Key
                    $advMode = [string]$entry.Value
                    if ($advMode -notin @('Enabled', 'Disabled', 'Default')) { continue }
                    if ($null -eq $sync.AdvancedOptionsLabelById -or -not $sync.AdvancedOptionsLabelById.ContainsKey($advId)) { continue }
                    $advLabel = Normalize-AdvancedOptionLabel -Label ([string]$sync.AdvancedOptionsLabelById[$advId])
                    if ([string]::IsNullOrWhiteSpace($advLabel)) { continue }
                    $advancedByLabel[$advLabel] = $advMode
                }
                $advancedByLabel
            )
            CompactOsMode           = [string]$sync.CompactOsMode
            SingleLanguageInstaller = [bool]$sync.SingleLanguageInstaller
            InstallerLanguage       = [string]$sync.InstallerLanguage
        }
    }
}
# Do not pre-select privacy actions by default.
foreach ($item in $PrivacyToggleItems) {
    if ($null -ne $item.PSObject.Properties['Mode']) { $item.Mode = 'Default' }
}

function Import-ConfigurationToUi {
    param([Parameter(Mandatory)][object]$Config)

    $previousUiLogSuppressed = if ($sync.ContainsKey('SuppressUiChangeLog')) { [bool]$sync.SuppressUiChangeLog } else { $false }
    $sync.SuppressUiChangeLog = $true
    try {
    if ($null -ne $Config.paths) {
        if ($null -ne $Config.paths.PSObject.Properties['SourceISO']) { Set-PathTextBoxValue -Control $tbSourceISO -Value ([string]$Config.paths.SourceISO) }
        if ($null -ne $Config.paths.PSObject.Properties['OutputISO']) { Set-PathTextBoxValue -Control $tbOutputISO -Value ([string]$Config.paths.OutputISO) }
        if ($null -ne $Config.paths.PSObject.Properties['ScratchDir']) { Set-PathTextBoxValue -Control $tbScratch -Value ([string]$Config.paths.ScratchDir) }
        if ($null -ne $Config.paths.PSObject.Properties['CustomUnattendXml']) {
            $sync.CustomUnattendXml = [string]$Config.paths.CustomUnattendXml
            if ($updateCustomXmlDisplay) { & $updateCustomXmlDisplay }
        }
        if ($null -ne $Config.paths.PSObject.Properties['CustomRegFiles']) { $sync.CustomRegFiles = @($Config.paths.CustomRegFiles) }
        elseif ($null -ne $Config.paths.PSObject.Properties['CustomRegFile']) { $sync.CustomRegFiles = @([string]$Config.paths.CustomRegFile) }
        else { $sync.CustomRegFiles = @() }

        if ($null -ne $Config.paths.PSObject.Properties['CustomBatFiles']) { $sync.CustomBatFiles = @($Config.paths.CustomBatFiles) }
        elseif ($null -ne $Config.paths.PSObject.Properties['CustomBatFile']) { $sync.CustomBatFiles = @([string]$Config.paths.CustomBatFile) }
        else { $sync.CustomBatFiles = @() }

        if ($updateCustomRegDisplay) { & $updateCustomRegDisplay }
        if ($updateCustomBatDisplay) { & $updateCustomBatDisplay }

        if ($null -ne $Config.paths.PSObject.Properties['DriverSourceDir']) {
            $sync.DriverSourceDir = [string]$Config.paths.DriverSourceDir
            Set-PathTextBoxValue -Control $tbDriverSource -Value $sync.DriverSourceDir
        }
        if ($null -ne $Config.paths.PSObject.Properties['DriverExtractDir']) {
            $sync.DriverExtractDir = [string]$Config.paths.DriverExtractDir
            Set-PathTextBoxValue -Control $tbDriverExtract -Value $sync.DriverExtractDir
        }
    }

    if ($null -ne $Config.drivers) {
        if ($null -ne $Config.drivers.PSObject.Properties['InjectInstallWim']) {
            $sync.InjectDriversInstallWim = [bool]$Config.drivers.InjectInstallWim
            $cbInjectInstall.Checked = [bool]$sync.InjectDriversInstallWim
        }
        if ($null -ne $Config.drivers.PSObject.Properties['Recurse']) {
            $sync.DriverInjectRecurse = [bool]$Config.drivers.Recurse
            $cbDriverRecurse.Checked = [bool]$sync.DriverInjectRecurse
        }
    }
    if ($null -ne $Config.security -and $null -ne $Config.security.PSObject.Properties['Preset']) {
        $preset = [string]$Config.security.Preset
        if (@('Balanced', 'Hardened', 'Maximum') -contains $preset) {
            & $setSecurityPreset $preset
        }
        else {
            & $setSecurityPreset 'Balanced'
        }
    }

    Clear-CustomScheduledTaskEntries

    if ($null -ne $Config.custom) {
        $customTasks = @(Get-ConfigPropertyValue -Object $Config.custom -Name 'Tasks' -Default @())
        foreach ($entry in $customTasks) {
            $taskPath = ''
            $taskDetail = ''
            if ($entry -is [string]) {
                $taskPath = [string]$entry
            }
            else {
                $taskPath = [string](Get-ConfigPropertyValue -Object $entry -Name 'Path' -Default '')
                $taskDetail = [string](Get-ConfigPropertyValue -Object $entry -Name 'Detail' -Default '')
            }
            if (-not [string]::IsNullOrWhiteSpace($taskPath)) {
                [void](Add-CustomScheduledTaskEntry -TaskPath $taskPath -Detail $taskDetail -Checked $false -Silent)
            }
        }
    }

    if ($null -ne $Config.selections) {
        # Do not auto-select app removals during config import fallback.
        Set-CheckedItemsByDefinition -Boxes $sync.AppxBoxes -Definition $sync.AppxDef -SelectedItems @()
        if ($null -ne $Config.selections.PSObject.Properties['AppxChecked']) {
            $rawAppxChecked = @($Config.selections.AppxChecked)
            $appxSelectedItems = @()
            foreach ($entry in $rawAppxChecked) {
                if ($entry -is [string]) {
                    $appxSelectedItems += $entry
                }
                elseif ($entry -is [System.Collections.IEnumerable]) {
                    $appxSelectedItems += @($entry)
                }
                elseif ($null -ne $entry) {
                    $appxSelectedItems += [string]$entry
                }
            }
            $normalizedAppxSelected = [System.Collections.Generic.List[string]]::new()
            foreach ($entryId in $appxSelectedItems) {
                $candidateId = [string]$entryId
                if ([string]::IsNullOrWhiteSpace($candidateId)) { continue }
                if ($appxUiCollapsedIdMap.ContainsKey($candidateId)) {
                    $candidateId = [string]$appxUiCollapsedIdMap[$candidateId]
                }
                if (-not [string]::IsNullOrWhiteSpace($candidateId)) {
                    [void]$normalizedAppxSelected.Add($candidateId)
                }
            }
            $appxSelectedItems = @($normalizedAppxSelected | Select-Object -Unique)
            Set-CheckedItemsByDefinition -Boxes $sync.AppxBoxes -Definition $sync.AppxDef -SelectedItems $appxSelectedItems
        }
        if ($null -ne $Config.selections.PSObject.Properties['FeatureConfig']) {
            $fCfg = $Config.selections.FeatureConfig
            $featMax = [Math]::Min($sync.FeaturesBoxes.Count, $sync.FeatDef.Count)
            for ($i = 0; $i -lt $featMax; $i++) {
                $fId = $sync.FeatDef[$i].Id
                $featureDefaultMode = if ($null -ne $sync.FeatDef[$i].PSObject.Properties['Mode']) { [string]$sync.FeatDef[$i].Mode } else { 'Default' }
                if ($featureDefaultMode -notin @('Default', 'Enabled', 'Disabled')) { $featureDefaultMode = 'Default' }
                if (Test-ConfigPropertyExists -Object $fCfg -Name $fId) {
                    $importedFeatureMode = [string](Get-ConfigPropertyValue -Object $fCfg -Name $fId -Default $featureDefaultMode)
                    if ($importedFeatureMode -notin @('Default', 'Enabled', 'Disabled')) { $importedFeatureMode = $featureDefaultMode }
                    $sync.FeaturesBoxes[$i].SelectedItem = $importedFeatureMode
                }
                else {
                    $sync.FeaturesBoxes[$i].SelectedItem = $featureDefaultMode
                }
            }
        }
        if ($null -ne $Config.selections.PSObject.Properties['TaskConfig']) {
            $tCfg = $Config.selections.TaskConfig
            $tMax = [Math]::Min($sync.TasksBoxes.Count, $sync.TasksAllDef.Count)
            for ($i = 0; $i -lt $tMax; $i++) {
                $tId = $sync.TasksAllDef[$i]
                $taskDefaultMode = 'Default'
                if ($sync.TaskDefaultStateById -and $sync.TaskDefaultStateById.ContainsKey($tId)) {
                    $taskDefaultMode = [string]$sync.TaskDefaultStateById[$tId]
                }
                if ($taskDefaultMode -notin @('Default', 'Enabled', 'Disabled')) { $taskDefaultMode = 'Default' }
                if (Test-ConfigPropertyExists -Object $tCfg -Name $tId) {
                    $importedTaskMode = [string](Get-ConfigPropertyValue -Object $tCfg -Name $tId -Default $taskDefaultMode)
                    if ($importedTaskMode -notin @('Default', 'Enabled', 'Disabled')) { $importedTaskMode = $taskDefaultMode }
                    $sync.TasksBoxes[$i].SelectedItem = $importedTaskMode
                }
                else {
                    $sync.TasksBoxes[$i].SelectedItem = $taskDefaultMode
                }
            }
        }
        elseif ($null -ne $Config.selections.PSObject.Properties['TaskChecked']) {
            # Legacy support
            $checked = @($Config.selections.TaskChecked)
            for ($i = 0; $i -lt $sync.TasksBoxes.Count; $i++) {
                if ($checked -contains $sync.TasksAllDef[$i]) { $sync.TasksBoxes[$i].SelectedItem = 'Disabled' }
            }
        }
        if ($null -ne $Config.selections.PSObject.Properties['ServiceConfig']) {
            $sCfg = $Config.selections.ServiceConfig
            $svcMax = [Math]::Min($sync.ServicesBoxes.Count, $sync.ServDef.Count)
            for ($i = 0; $i -lt $svcMax; $i++) {
                $sId = $sync.ServDef[$i]
                $serviceDefaultMode = 'Automatic'
                if ($sync.ServiceDefaultModeById -and $sync.ServiceDefaultModeById.ContainsKey($sId)) {
                    $serviceDefaultMode = [string]$sync.ServiceDefaultModeById[$sId]
                }
                if ($serviceDefaultMode -notin @('Automatic', 'Manual', 'Disabled')) { $serviceDefaultMode = 'Automatic' }
                if (Test-ConfigPropertyExists -Object $sCfg -Name $sId) {
                    $svcMode = [string](Get-ConfigPropertyValue -Object $sCfg -Name $sId -Default $serviceDefaultMode)
                    if ($svcMode -notin @('Disabled', 'Automatic', 'Manual')) {
                        $svcMode = $serviceDefaultMode
                    }
                    $sync.ServicesBoxes[$i].SelectedItem = $svcMode
                }
                else {
                    $sync.ServicesBoxes[$i].SelectedItem = $serviceDefaultMode
                }
            }
        }
        elseif ($null -ne $Config.selections.PSObject.Properties['ServiceChecked']) {
            # Legacy config support
            $checkedServices = @($Config.selections.ServiceChecked)
            $svcMax = [Math]::Min($sync.ServicesBoxes.Count, $sync.ServDef.Count)
            for ($i = 0; $i -lt $svcMax; $i++) {
                $sId = $sync.ServDef[$i]
                $defaultMode = if ($sync.ServiceDefaultModeById -and $sync.ServiceDefaultModeById.ContainsKey($sId)) { [string]$sync.ServiceDefaultModeById[$sId] } else { 'Automatic' }
                if ($defaultMode -notin @('Automatic', 'Manual', 'Disabled')) { $defaultMode = 'Automatic' }
                $sync.ServicesBoxes[$i].SelectedItem = if ($checkedServices -contains $sId) { 'Disabled' } else { $defaultMode }
            }
        }
        if ($null -ne $Config.selections.PSObject.Properties['PrivacyConfig']) {
            $pCfg = $Config.selections.PrivacyConfig
            $pMax = [Math]::Min($sync.PrivacyBoxes.Count, $sync.PrivacyDef.Count)
            for ($i = 0; $i -lt $pMax; $i++) {
                $privacyId = $sync.PrivacyDef[$i]
                $privacyMode = [string](Get-ConfigPropertyValue -Object $pCfg -Name $privacyId -Default '')
                if ((Test-ConfigPropertyExists -Object $pCfg -Name $privacyId) -and $privacyMode -in @('Enabled', 'Disabled', 'Default')) {
                    $sync.PrivacyBoxes[$i].SelectedItem = $privacyMode
                }
                else {
                    $sync.PrivacyBoxes[$i].SelectedItem = 'Default'
                }
            }
        }
        if ($null -ne $Config.selections.PSObject.Properties['ExtraSecurityConfig']) {
            $xCfg = $Config.selections.ExtraSecurityConfig
            $xMax = [Math]::Min($sync.ExtraSecurityBoxes.Count, $sync.ExtraSecurityDef.Count)
            for ($i = 0; $i -lt $xMax; $i++) {
                $xId = $sync.ExtraSecurityDef[$i]
                $extraMode = [string](Get-ConfigPropertyValue -Object $xCfg -Name $xId -Default '')
                if ((Test-ConfigPropertyExists -Object $xCfg -Name $xId) -and $extraMode -in @('Enabled', 'Disabled', 'Default')) {
                    $sync.ExtraSecurityBoxes[$i].SelectedItem = $extraMode
                }
                else {
                    $sync.ExtraSecurityBoxes[$i].SelectedItem = 'Default'
                }
            }
        }
        if ($null -ne $Config.selections.PSObject.Properties['AdvancedOptionsConfig'] -or
            $null -ne $Config.selections.PSObject.Properties['AdvancedOptionsByLabel']) {

            $advancedModeByLabel = @{}
            $legacyAdvancedIdToLabel = @{
                'advanced.1'  = 'Diagnostics - ETW AutoLogger sessions'
                'advanced.2'  = 'Logging - Windows Event Log service'
                'advanced.3'  = 'UI - Windows Widgets'
                'advanced.4'  = 'UX - App suggestions (Content Delivery Manager)'
                'advanced.5'  = 'Troubleshooting - Detailed BSOD information'
                'advanced.6'  = 'Explorer - Show file name extensions'
                'advanced.7'  = 'Edge - Allow Microsoft Edge uninstall (Beta)'
                'advanced.8'  = 'Cleanup - Remove empty C:\Windows.old folder'
                'advanced.9'  = 'Encryption - Device encryption automatic enablement'
                'advanced.10' = 'Security - Core isolation (Memory integrity / VBS)'
                'advanced.11' = 'Security - Disable WPBT execution (Beta)'
                'advanced.12' = 'Accessibility - Sticky Keys shortcut'
                'advanced.13' = 'Setup - Bypass Windows 11 TPM/Secure Boot checks'
                'advanced.14' = 'Setup - Bypass Windows 11 TPM/Secure Boot checks'
                'advanced.15' = 'OOBE - Allow setup without internet'
                'advanced.16' = 'OOBE - Remove Microsoft account requirement'
                'advanced.17' = 'Media - Trim language and capability payloads'
                'advanced.18' = 'Encryption - BitLocker automatic device encryption'
                'advanced.19' = 'Setup - Hide PowerShell windows'
                'advanced.20' = 'Recovery - System Restore'
                'advanced.21' = 'PowerShell - Execution policy (RemoteSigned)'
            }

            if ($null -ne $Config.selections.PSObject.Properties['AdvancedOptionsByLabel']) {
                $aByLabel = $Config.selections.AdvancedOptionsByLabel
                if ($null -ne $aByLabel) {
                    foreach ($entry in $aByLabel.GetEnumerator()) {
                        $label = Normalize-AdvancedOptionLabel -Label ([string]$entry.Key)
                        $mode = [string]$entry.Value
                        if ([string]::IsNullOrWhiteSpace($label)) { continue }
                        if ($mode -in @('Enabled', 'Disabled', 'Default')) {
                            $advancedModeByLabel[$label] = $mode
                        }
                    }
                }
            }

            if ($null -ne $Config.selections.PSObject.Properties['AdvancedOptionsConfig']) {
                $aCfg = $Config.selections.AdvancedOptionsConfig
                if ($null -ne $aCfg) {
                    foreach ($entry in $aCfg.GetEnumerator()) {
                        $aId = [string]$entry.Key
                        $mode = [string]$entry.Value
                        if ($mode -notin @('Enabled', 'Disabled', 'Default')) { continue }

                        $resolvedLabel = ''
                        if ($null -ne $sync.AdvancedOptionsLabelById -and $sync.AdvancedOptionsLabelById.ContainsKey($aId)) {
                            $resolvedLabel = Normalize-AdvancedOptionLabel -Label ([string]$sync.AdvancedOptionsLabelById[$aId])
                        }
                        elseif ($legacyAdvancedIdToLabel.ContainsKey($aId)) {
                            $resolvedLabel = Normalize-AdvancedOptionLabel -Label ([string]$legacyAdvancedIdToLabel[$aId])
                        }

                        if (-not [string]::IsNullOrWhiteSpace($resolvedLabel)) {
                            $advancedModeByLabel[$resolvedLabel] = $mode
                        }
                    }
                }
            }

            $aMax = [Math]::Min($sync.AdvancedOptionsBoxes.Count, $sync.AdvancedOptionsDef.Count)
            for ($i = 0; $i -lt $aMax; $i++) {
                $aId = [string]$sync.AdvancedOptionsDef[$i]
                $currentLabel = ''
                if ($null -ne $sync.AdvancedOptionsLabelById -and $sync.AdvancedOptionsLabelById.ContainsKey($aId)) {
                    $currentLabel = Normalize-AdvancedOptionLabel -Label ([string]$sync.AdvancedOptionsLabelById[$aId])
                }
                if (-not [string]::IsNullOrWhiteSpace($currentLabel) -and $advancedModeByLabel.ContainsKey($currentLabel)) {
                    $sync.AdvancedOptionsBoxes[$i].SelectedItem = [string]$advancedModeByLabel[$currentLabel]
                }
                else {
                    $sync.AdvancedOptionsBoxes[$i].SelectedItem = 'Default'
                }
            }
        }
        if ($null -ne $Config.selections.PSObject.Properties['CompactOsMode']) {
            $mode = [string]$Config.selections.CompactOsMode
            if ($mode -notin @('Default', 'Enabled', 'Disabled')) { $mode = 'Default' }
            $sync.CompactOsMode = $mode
            if ($mode -eq 'Enabled') { $rbCompactOn.Checked = $true }
            elseif ($mode -eq 'Disabled') { $rbCompactOff.Checked = $true }
            else { $rbCompactDefault.Checked = $true }
        }
        if ($null -ne $Config.selections.PSObject.Properties['SingleLanguageInstaller']) {
            $sync.SingleLanguageInstaller = [bool]$Config.selections.SingleLanguageInstaller
            $cbSingleLang.Checked = [bool]$sync.SingleLanguageInstaller
        }
        if ($null -ne $Config.selections.PSObject.Properties['InstallerLanguage']) {
            $langVal = [string]$Config.selections.InstallerLanguage
            if ([string]::IsNullOrWhiteSpace($langVal)) { $langVal = 'System Default' }
            $sync.InstallerLanguage = $langVal
            if ($langCombo.Items.Contains($langVal)) {
                $langCombo.SelectedItem = $langVal
            }
            else {
                $langCombo.SelectedIndex = 0
            }
        }
        if ($updateSingleLanguageUiState) { & $updateSingleLanguageUiState }
    }

    # Keep sync values aligned with UI after import.
    $sync['Source ISO'] = Get-PathTextBoxValue -Control $tbSourceISO
    $sync['Output Folder'] = Get-PathTextBoxValue -Control $tbOutputISO
    $sync.ScratchDir = Get-PathTextBoxValue -Control $tbScratch
    $sync.CustomUnattendXml = [string]$sync.CustomUnattendXml
    $sync.CustomRegFiles = @($sync.CustomRegFiles)
    $sync.CustomBatFiles = @($sync.CustomBatFiles)
    $sync.DriverSourceDir = Get-PathTextBoxValue -Control $tbDriverSource
    $sync.DriverExtractDir = Get-PathTextBoxValue -Control $tbDriverExtract
    $sync.InjectDriversInstallWim = $cbInjectInstall.Checked
    $sync.DriverInjectRecurse = $cbDriverRecurse.Checked
    $sync.SecurityPreset = [string]$sync.SecurityPreset
    if ([string]::IsNullOrWhiteSpace($sync.SecurityPreset)) { $sync.SecurityPreset = 'Balanced' }
    }
    finally {
        $sync.SuppressUiChangeLog = $previousUiLogSuppressed
    }
}
#endregion

#region ── Config Import/Export Buttons ───────────────────────────────────────
function Invoke-ExportConfig {
    if ($sync.ProcessRunning) {
        [System.Windows.Forms.MessageBox]::Show(
            "Cannot export while processing is running.",
            "Busy", "OK", "Warning") | Out-Null
        return
    }
    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter = 'Oximize OS Config (*.ox)|*.ox'
    $sfd.Title = 'Export Configuration'
    $sfd.DefaultExt = 'ox'
    $sfd.AddExtension = $true
    $sfd.FileName = "OximizeOS_Config_$(Get-Date -Format 'yyyyMMdd_HHmmss').ox"
    if ($sfd.ShowDialog($form) -ne 'OK') { return }

    try {
        $cfg = Get-CurrentConfiguration
        $oxText = $cfg | ConvertTo-Json -Depth 8
        Set-Content -Path $sfd.FileName -Value $oxText -Encoding UTF8
        Write-Log "Configuration exported: $($sfd.FileName)" -Color Green
    }
    catch {
        Write-Log "Config export failed: $_" -Color Red
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to export configuration:`n$_",
            "Export Error", "OK", "Error") | Out-Null
    }
}

function Invoke-ImportConfig {
    if ($sync.ProcessRunning) {
        [System.Windows.Forms.MessageBox]::Show(
            "Cannot import while processing is running.",
            "Busy", "OK", "Warning") | Out-Null
        return
    }
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = 'Oximize OS Config (*.ox)|*.ox'
    $ofd.Title = 'Import Configuration'
    if ($ofd.ShowDialog($form) -ne 'OK') { return }

    try {
        $cfgRaw = Get-Content -Raw -Path $ofd.FileName
        $cfg = $cfgRaw | ConvertFrom-Json -ErrorAction Stop
        Import-ConfigurationToUi -Config $cfg
        Write-Log "Configuration imported: $($ofd.FileName)" -Color Green
        if ($null -ne $cfg.PSObject.Properties['schemaVersion']) {
            Write-Log "Imported config schema version: $($cfg.schemaVersion)" -Color White
        }
    }
    catch {
        Write-Log "Config import failed: $_" -Color Red
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to import configuration:`n$_",
            "Import Error", "OK", "Error") | Out-Null
    }
}

function Invoke-ApplyPrivacyPreset {
    if ($sync.ProcessRunning) {
        [System.Windows.Forms.MessageBox]::Show(
            "Cannot apply preset while processing is running.",
            "Busy", "OK", "Warning") | Out-Null
        return
    }

    Write-Log "Applying Recommended Preset (one-click)." -Color Cyan

    $bulkLayoutControls = @(
        $form,
        $panelMainUI,
        $contentPanel,
        $tabAppx,
        $tabFeatures,
        $tabTasks,
        $tabServices,
        $tabPrivacy,
        $tabExtraSecurity,
        $tabAdvanced
    )
    $bulkLayoutSuspended = New-Object System.Collections.Generic.List[System.Windows.Forms.Control]
    $previousUiLogSuppressed = if ($sync.ContainsKey('SuppressUiChangeLog')) { [bool]$sync.SuppressUiChangeLog } else { $false }
    $sync.SuppressUiChangeLog = $true
    foreach ($ctl in @($bulkLayoutControls)) {
        if ($null -eq $ctl -or $ctl.IsDisposed) { continue }
        try {
            $ctl.SuspendLayout()
            [void]$bulkLayoutSuspended.Add($ctl)
        }
        catch {}
    }

    try {
    $toKey = {
        param([string]$Value)
        if ([string]::IsNullOrWhiteSpace([string]$Value)) { return '' }
        return ([string]$Value).Trim().ToLowerInvariant()
    }.GetNewClosure()

    $appxApplied = 0
    $featureApplied = 0
    $taskApplied = 0
    $serviceApplied = 0
    $privacyApplied = 0
    $extraSecurityApplied = 0
    $advancedApplied = 0
    $missingEntries = 0

    $appxMax = [Math]::Min($sync.AppxBoxes.Count, $sync.AppxDef.Count)
    $appxIndexById = @{}
    for ($i = 0; $i -lt $appxMax; $i++) {
        $id = [string]$sync.AppxDef[$i]
        $k = & $toKey $id
        if (-not [string]::IsNullOrWhiteSpace($k) -and -not $appxIndexById.ContainsKey($k)) { $appxIndexById[$k] = $i }
        $sync.AppxBoxes[$i].Checked = $false
    }

    $featMax = [Math]::Min($sync.FeaturesBoxes.Count, $sync.FeatDef.Count)
    $featureIndexById = @{}
    for ($i = 0; $i -lt $featMax; $i++) {
        $def = $sync.FeatDef[$i]
        $id = if ($null -ne $def -and $null -ne $def.PSObject.Properties['Id']) { [string]$def.Id } else { [string]$def }
        $k = & $toKey $id
        if (-not [string]::IsNullOrWhiteSpace($k) -and -not $featureIndexById.ContainsKey($k)) { $featureIndexById[$k] = $i }
        $sync.FeaturesBoxes[$i].SelectedItem = 'Default'
    }

    $taskMax = [Math]::Min($sync.TasksBoxes.Count, $sync.TasksAllDef.Count)
    $taskIndexById = @{}
    for ($i = 0; $i -lt $taskMax; $i++) {
        $id = Format-ScheduledTaskPath -TaskPath ([string]$sync.TasksAllDef[$i])
        $k = & $toKey $id
        if (-not [string]::IsNullOrWhiteSpace($k) -and -not $taskIndexById.ContainsKey($k)) { $taskIndexById[$k] = $i }
        $sync.TasksBoxes[$i].SelectedItem = 'Default'
    }

    $svcMax = [Math]::Min($sync.ServicesBoxes.Count, $sync.ServDef.Count)
    $serviceIndexById = @{}
    for ($i = 0; $i -lt $svcMax; $i++) {
        $id = [string]$sync.ServDef[$i]
        $k = & $toKey $id
        if (-not [string]::IsNullOrWhiteSpace($k) -and -not $serviceIndexById.ContainsKey($k)) { $serviceIndexById[$k] = $i }
        $defaultMode = if ($sync.ServiceDefaultModeById -and $sync.ServiceDefaultModeById.ContainsKey($id)) { [string]$sync.ServiceDefaultModeById[$id] } else { 'Automatic' }
        if ($defaultMode -notin @('Automatic', 'Manual', 'Disabled')) { $defaultMode = 'Automatic' }
        $sync.ServicesBoxes[$i].SelectedItem = $defaultMode
    }

    $privacyMax = [Math]::Min($sync.PrivacyBoxes.Count, $sync.PrivacyDef.Count)
    $privacyIndexByLabel = @{}
    for ($i = 0; $i -lt $privacyMax; $i++) {
        $id = [string]$sync.PrivacyDef[$i]
        $label = if ($sync.PrivacyLabelById -and $sync.PrivacyLabelById.ContainsKey($id)) { [string]$sync.PrivacyLabelById[$id] } else { $id }
        $normalizedLabel = Normalize-PrivacyToggleLabel -Label $label
        $k = & $toKey $normalizedLabel
        if (-not [string]::IsNullOrWhiteSpace($k) -and -not $privacyIndexByLabel.ContainsKey($k)) { $privacyIndexByLabel[$k] = $i }
        $sync.PrivacyBoxes[$i].SelectedItem = 'Default'
    }

    $extraSecurityMax = [Math]::Min($sync.ExtraSecurityBoxes.Count, $sync.ExtraSecurityDef.Count)
    $extraSecurityIndexByLabel = @{}
    for ($i = 0; $i -lt $extraSecurityMax; $i++) {
        $id = [string]$sync.ExtraSecurityDef[$i]
        $label = if ($sync.ExtraSecurityLabelById -and $sync.ExtraSecurityLabelById.ContainsKey($id)) { [string]$sync.ExtraSecurityLabelById[$id] } else { $id }
        $k = & $toKey $label
        if (-not [string]::IsNullOrWhiteSpace($k) -and -not $extraSecurityIndexByLabel.ContainsKey($k)) { $extraSecurityIndexByLabel[$k] = $i }
        $sync.ExtraSecurityBoxes[$i].SelectedItem = 'Default'
    }

    $advancedMax = [Math]::Min($sync.AdvancedOptionsBoxes.Count, $sync.AdvancedOptionsDef.Count)
    $advancedIndexByLabel = @{}
    for ($i = 0; $i -lt $advancedMax; $i++) {
        $id = [string]$sync.AdvancedOptionsDef[$i]
        $label = if ($sync.AdvancedOptionsLabelById -and $sync.AdvancedOptionsLabelById.ContainsKey($id)) { [string]$sync.AdvancedOptionsLabelById[$id] } else { $id }
        $normalizedLabel = Normalize-AdvancedOptionLabel -Label $label
        $k = & $toKey $normalizedLabel
        if (-not [string]::IsNullOrWhiteSpace($k) -and -not $advancedIndexByLabel.ContainsKey($k)) { $advancedIndexByLabel[$k] = $i }
        $sync.AdvancedOptionsBoxes[$i].SelectedItem = 'Default'
    }

    if ($null -ne $setSecurityPreset) {
        & $setSecurityPreset 'Hardened'
    }

    $setAppxCheckedById = {
        param([string]$Id, [bool]$Checked = $true)
        $k = & $toKey $Id
        if ([string]::IsNullOrWhiteSpace($k) -or -not $appxIndexById.ContainsKey($k)) { return $false }
        $idx = [int]$appxIndexById[$k]
        if ($idx -ge 0 -and $idx -lt $sync.AppxBoxes.Count) {
            $sync.AppxBoxes[$idx].Checked = $Checked
            return $true
        }
        return $false
    }.GetNewClosure()

    $setFeatureModeById = {
        param([string]$Id, [string]$Mode)
        $k = & $toKey $Id
        if ([string]::IsNullOrWhiteSpace($k) -or -not $featureIndexById.ContainsKey($k)) { return $false }
        $idx = [int]$featureIndexById[$k]
        if ($idx -ge 0 -and $idx -lt $sync.FeaturesBoxes.Count) {
            $sync.FeaturesBoxes[$idx].SelectedItem = $Mode
            return $true
        }
        return $false
    }.GetNewClosure()

    $setTaskModeById = {
        param([string]$Id, [string]$Mode)
        $normalizedId = Format-ScheduledTaskPath -TaskPath $Id
        $k = & $toKey $normalizedId
        if ([string]::IsNullOrWhiteSpace($k) -or -not $taskIndexById.ContainsKey($k)) { return $false }
        $idx = [int]$taskIndexById[$k]
        if ($idx -ge 0 -and $idx -lt $sync.TasksBoxes.Count) {
            $sync.TasksBoxes[$idx].SelectedItem = $Mode
            return $true
        }
        return $false
    }.GetNewClosure()

    $setServiceModeById = {
        param([string]$Id, [string]$Mode)
        $k = & $toKey $Id
        if ([string]::IsNullOrWhiteSpace($k) -or -not $serviceIndexById.ContainsKey($k)) { return $false }
        $idx = [int]$serviceIndexById[$k]
        if ($idx -ge 0 -and $idx -lt $sync.ServicesBoxes.Count) {
            $sync.ServicesBoxes[$idx].SelectedItem = $Mode
            return $true
        }
        return $false
    }.GetNewClosure()

    $setPrivacyModeByLabel = {
        param([string]$Label, [string]$Mode)
        $k = & $toKey (Normalize-PrivacyToggleLabel -Label $Label)
        if ([string]::IsNullOrWhiteSpace($k) -or -not $privacyIndexByLabel.ContainsKey($k)) { return $false }
        $idx = [int]$privacyIndexByLabel[$k]
        if ($idx -ge 0 -and $idx -lt $sync.PrivacyBoxes.Count) {
            $sync.PrivacyBoxes[$idx].SelectedItem = $Mode
            return $true
        }
        return $false
    }.GetNewClosure()

    $setExtraSecurityModeByLabel = {
        param([string]$Label, [string]$Mode)
        $k = & $toKey $Label
        if ([string]::IsNullOrWhiteSpace($k) -or -not $extraSecurityIndexByLabel.ContainsKey($k)) { return $false }
        $idx = [int]$extraSecurityIndexByLabel[$k]
        if ($idx -ge 0 -and $idx -lt $sync.ExtraSecurityBoxes.Count) {
            $sync.ExtraSecurityBoxes[$idx].SelectedItem = $Mode
            return $true
        }
        return $false
    }.GetNewClosure()

    $setAdvancedModeByLabel = {
        param([string]$Label, [string]$Mode)
        $k = & $toKey (Normalize-AdvancedOptionLabel -Label $Label)
        if ([string]::IsNullOrWhiteSpace($k) -or -not $advancedIndexByLabel.ContainsKey($k)) { return $false }
        $idx = [int]$advancedIndexByLabel[$k]
        if ($idx -ge 0 -and $idx -lt $sync.AdvancedOptionsBoxes.Count) {
            $sync.AdvancedOptionsBoxes[$idx].SelectedItem = $Mode
            return $true
        }
        return $false
    }.GetNewClosure()

    $oobeProtectedAppxIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($criticalAppxId in @(
            'Microsoft.WindowsStore',
            'Microsoft.StorePurchaseApp',
            'Microsoft.WindowsAppRuntime.1.5',
            'Microsoft.WindowsAppRuntime.1.6',
            'MicrosoftWindows.Client.WebExperience',
            'Microsoft.MicrosoftEdge.Stable',
            'Microsoft.MicrosoftEdgeDevToolsClient',
            'Runtime.Remove.MicrosoftEdge.System',
            'Runtime.Remove.MicrosoftEdge.WebView2'
        )) {
        [void]$oobeProtectedAppxIds.Add([string]$criticalAppxId)
    }

    $microWinKeepKeywords = @(
        'AppInstaller',
        'Store',
        'WindowsAppRuntime',
        'WebExperience',
        'Edge',
        'WebView',
        'Notepad',
        'Printing',
        'YourPhone',
        'Xbox',
        'WindowsTerminal',
        'Calculator',
        'Photos',
        'VCLibs',
        'Paint',
        'Gaming',
        'Extension',
        'SecHealthUI',
        'ScreenSketch',
        'CrossDevice'
    )
    $getAppxPresetLabel = {
        param([string]$Id)
        if (-not [string]::IsNullOrWhiteSpace($Id) -and $AppxLabels -and $AppxLabels.ContainsKey($Id)) {
            return [string]$AppxLabels[$Id]
        }
        return [string]$Id
    }.GetNewClosure()
    $shouldRemoveByMicroWinProfile = {
        param([string]$Id)
        if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
        if ($oobeProtectedAppxIds.Contains([string]$Id)) { return $false }
        $candidateTexts = New-Object System.Collections.Generic.List[string]
        [void]$candidateTexts.Add([string]$Id)
        $label = & $getAppxPresetLabel $Id
        if (-not [string]::IsNullOrWhiteSpace($label) -and -not [string]::Equals($label, $Id, [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$candidateTexts.Add($label)
        }
        foreach ($candidate in $candidateTexts) {
            foreach ($keyword in $microWinKeepKeywords) {
                if ([string]::IsNullOrWhiteSpace($keyword)) { continue }
                if ($candidate.IndexOf($keyword, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    return $false
                }
            }
        }
        return $true
    }.GetNewClosure()
    $microWinRemovedAppLabels = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $appxMax; $i++) {
        $id = [string]$sync.AppxDef[$i]
        if (-not (& $shouldRemoveByMicroWinProfile $id)) { continue }
        $sync.AppxBoxes[$i].Checked = $true
        $appxApplied++
        $displayName = & $getAppxPresetLabel $id
        if (-not [string]::IsNullOrWhiteSpace($displayName)) {
            [void]$microWinRemovedAppLabels.Add($displayName)
        }
    }
    if ($microWinRemovedAppLabels.Count -gt 0) {
        $appxList = @($microWinRemovedAppLabels | Sort-Object -Unique)
        $appxPreviewMax = 20
        $appxPreview = if ($appxList.Count -gt $appxPreviewMax) {
            (($appxList[0..($appxPreviewMax - 1)] -join ', ') + ", ... (+$($appxList.Count - $appxPreviewMax) more)")
        }
        else {
            ($appxList -join ', ')
        }
        Write-Log ("Recommended preset App Packages (MicroWin profile): {0}" -f $appxPreview) -Color White
    }

    $featureDisableIds = @(
        'Client-ProjFS',
        'Containers',
        'Containers-DisposableClientVM',
        'Containers-Server-For-Application-Guard',
        'DataCenterBridging',
        'DirectoryServices-ADAM-Client',
        'HostGuardian',
        'IIS-HostableWebCore',
        'IIS-WebServerRole',
        'MSMQ-Server',
        'Microsoft-Hyper-V-All',
        'Microsoft-Windows-Subsystem-Linux',
        'MultiPoint-Connector',
        'Printing-XPSServices-Features',
        'ServicesForNFS-ClientOnly',
        'SimpleTCP',
        'SMB1Protocol',
        'TFTP',
        'TelnetClient',
        'VirtualMachinePlatform',
        'HypervisorPlatform',
        'WAS-WindowsActivationService',
        'Windows-Identity-Foundation',
        'WorkFolders-Client'
    )
    foreach ($id in $featureDisableIds) {
        if (& $setFeatureModeById $id 'Disabled') { $featureApplied++ } else { $missingEntries++ }
    }

    $taskDisableIds = @(
        '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
        '\Microsoft\Windows\Application Experience\AitAgent',
        '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
        '\Microsoft\Windows\Application Experience\StartupAppTask',
        '\Microsoft\Windows\Autochk\Proxy',
        '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
        '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
        '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector',
        '\Microsoft\Windows\Feedback\Siuf\DmClient',
        '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload',
        '\Microsoft\Windows\Windows Error Reporting\QueueReporting',
        '\Microsoft\Windows\PushToInstall\LoginCheck',
        '\Microsoft\Windows\PushToInstall\Registration',
        '\Microsoft\Windows\Device Information\Device',
        '\Microsoft\Windows\Device Information\Device User',
        '\Microsoft\Windows\Maps\MapsUpdateTask',
        '\Microsoft\Windows\Maps\MapsToastTask',
        '\OneDrive Reporting Task',
        '\Microsoft\Windows\WindowsAI\Recall\InitialConfiguration',
        '\Microsoft\Windows\WindowsAI\Recall\PolicyConfiguration',
        '\Microsoft\Office\Office Actions Server'
    )
    foreach ($id in $taskDisableIds) {
        if (& $setTaskModeById $id 'Disabled') { $taskApplied++ } else { $missingEntries++ }
    }

    $winutilServiceModeMap = [ordered]@{
        'ALG' = 'Manual'
        'Appinfo' = 'Manual'
        'AppMgmt' = 'Manual'
        'AppReadiness' = 'Manual'
        'AppVClient' = 'Disabled'
        'AssignedAccessManagerSvc' = 'Disabled'
        'autotimesvc' = 'Manual'
        'AxInstSV' = 'Manual'
        'BDESVC' = 'Manual'
        'BTAGService' = 'Manual'
        'bthserv' = 'Manual'
        'camsvc' = 'Manual'
        'CDPSvc' = 'Manual'
        'CertPropSvc' = 'Manual'
        'cloudidsvc' = 'Manual'
        'COMSysApp' = 'Manual'
        'CscService' = 'Manual'
        'dcsvc' = 'Manual'
        'defragsvc' = 'Manual'
        'DeviceAssociationService' = 'Manual'
        'DeviceInstall' = 'Manual'
        'DevQueryBroker' = 'Manual'
        'diagsvc' = 'Manual'
        'DiagTrack' = 'Disabled'
        'DialogBlockingService' = 'Disabled'
        'DisplayEnhancementService' = 'Manual'
        'dmwappushservice' = 'Manual'
        'dot3svc' = 'Manual'
        'EapHost' = 'Manual'
        'edgeupdate' = 'Manual'
        'edgeupdatem' = 'Manual'
        'EFS' = 'Manual'
        'fdPHost' = 'Manual'
        'FDResPub' = 'Manual'
        'fhsvc' = 'Manual'
        'FrameServer' = 'Manual'
        'FrameServerMonitor' = 'Manual'
        'GraphicsPerfSvc' = 'Manual'
        'hidserv' = 'Manual'
        'HvHost' = 'Manual'
        'icssvc' = 'Manual'
        'IKEEXT' = 'Manual'
        'InstallService' = 'Manual'
        'InventorySvc' = 'Manual'
        'IpxlatCfgSvc' = 'Manual'
        'KtmRm' = 'Manual'
        'lfsvc' = 'Manual'
        'LicenseManager' = 'Manual'
        'lltdsvc' = 'Manual'
        'lmhosts' = 'Manual'
        'LxpSvc' = 'Manual'
        'McpManagementService' = 'Manual'
        'MicrosoftEdgeElevationService' = 'Manual'
        'MSDTC' = 'Manual'
        'MSiSCSI' = 'Manual'
        'NaturalAuthentication' = 'Manual'
        'NcaSvc' = 'Manual'
        'NcbService' = 'Manual'
        'NcdAutoSetup' = 'Manual'
        'Netman' = 'Manual'
        'netprofm' = 'Manual'
        'NetSetupSvc' = 'Manual'
        'NetTcpPortSharing' = 'Disabled'
        'NlaSvc' = 'Manual'
        'PcaSvc' = 'Manual'
        'PeerDistSvc' = 'Manual'
        'perceptionsimulation' = 'Manual'
        'PerfHost' = 'Manual'
        'PhoneSvc' = 'Manual'
        'pla' = 'Manual'
        'PlugPlay' = 'Manual'
        'PolicyAgent' = 'Manual'
        'PrintNotify' = 'Manual'
        'PushToInstall' = 'Manual'
        'QWAVE' = 'Manual'
        'RasAuto' = 'Manual'
        'RasMan' = 'Manual'
        'RemoteAccess' = 'Disabled'
        'RemoteRegistry' = 'Disabled'
        'RetailDemo' = 'Manual'
        'RmSvc' = 'Manual'
        'RpcLocator' = 'Manual'
        'SCardSvr' = 'Manual'
        'ScDeviceEnum' = 'Manual'
        'SCPolicySvc' = 'Manual'
        'SDRSVC' = 'Manual'
        'seclogon' = 'Manual'
        'SEMgrSvc' = 'Manual'
        'SensorDataService' = 'Manual'
        'SensorService' = 'Manual'
        'SensrSvc' = 'Manual'
        'SessionEnv' = 'Manual'
        'SharedAccess' = 'Manual'
        'shpamsvc' = 'Disabled'
        'smphost' = 'Manual'
        'SmsRouter' = 'Manual'
        'SNMPTRAP' = 'Manual'
        'SSDPSRV' = 'Manual'
        'ssh-agent' = 'Disabled'
        'SstpSvc' = 'Manual'
        'StiSvc' = 'Manual'
        'StorSvc' = 'Manual'
        'svsvc' = 'Manual'
        'swprv' = 'Manual'
        'TapiSrv' = 'Manual'
        'TermService' = 'Manual'
        'TieringEngineService' = 'Manual'
        'TokenBroker' = 'Manual'
        'TroubleshootingSvc' = 'Manual'
        'TrustedInstaller' = 'Manual'
        'tzautoupdate' = 'Disabled'
        'UevAgentService' = 'Disabled'
        'UmRdpService' = 'Manual'
        'upnphost' = 'Manual'
        'UsoSvc' = 'Manual'
        'VaultSvc' = 'Manual'
        'vds' = 'Manual'
        'vmicguestinterface' = 'Manual'
        'vmicheartbeat' = 'Manual'
        'vmickvpexchange' = 'Manual'
        'vmicrdv' = 'Manual'
        'vmicshutdown' = 'Manual'
        'vmictimesync' = 'Manual'
        'vmicvmsession' = 'Manual'
        'vmicvss' = 'Manual'
        'VSS' = 'Manual'
        'W32Time' = 'Manual'
        'WalletService' = 'Manual'
        'WarpJITSvc' = 'Manual'
        'wbengine' = 'Manual'
        'WbioSrvc' = 'Manual'
        'wcncsvc' = 'Manual'
        'WdiServiceHost' = 'Manual'
        'WdiSystemHost' = 'Manual'
        'WebClient' = 'Manual'
        'webthreatdefsvc' = 'Manual'
        'Wecsvc' = 'Manual'
        'WEPHOSTSVC' = 'Manual'
        'wercplsupport' = 'Manual'
        'WerSvc' = 'Manual'
        'WFDSConMgrSvc' = 'Manual'
        'WiaRpc' = 'Manual'
        'WinRM' = 'Manual'
        'wisvc' = 'Manual'
        'wlidsvc' = 'Manual'
        'wlpasvc' = 'Manual'
        'WManSvc' = 'Manual'
        'wmiApSrv' = 'Manual'
        'WMPNetworkSvc' = 'Manual'
        'workfolderssvc' = 'Manual'
        'WpcMonSvc' = 'Manual'
        'WPDBusEnum' = 'Manual'
        'WpnService' = 'Manual'
        'WSAIFabricSvc' = 'Manual'
        'wuauserv' = 'Manual'
        'XblAuthManager' = 'Manual'
        'XblGameSave' = 'Manual'
        'XboxGipSvc' = 'Manual'
        'XboxNetApiSvc' = 'Manual'
    }
    $serviceModeMap = [ordered]@{}
    foreach ($entry in $winutilServiceModeMap.GetEnumerator()) {
        $serviceModeMap[[string]$entry.Key] = [string]$entry.Value
    }
    $servicePresetOverrides = [ordered]@{
        'DiagTrack' = 'Disabled'
        'wisvc' = 'Disabled'
        'XblAuthManager' = 'Disabled'
        'XblGameSave' = 'Disabled'
        'XboxGipSvc' = 'Disabled'
        'XboxNetApiSvc' = 'Disabled'
        'MixedRealityOpenXRSvc' = 'Disabled'
        'Fax' = 'Manual'
    }
    foreach ($entry in $servicePresetOverrides.GetEnumerator()) {
        $serviceModeMap[[string]$entry.Key] = [string]$entry.Value
    }
    $oobeProtectedServiceIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($criticalServiceId in @(
            'AppReadiness', 'AppXSvc', 'ClipSVC', 'StateRepository', 'InstallService',
            'TrustedInstaller', 'BITS', 'CryptSvc', 'wuauserv', 'UsoSvc', 'DoSvc', 'WaaSMedicSvc',
            'NlaSvc', 'nsi', 'Dhcp', 'Dnscache', 'LanmanWorkstation', 'Wcmsvc', 'WinHttpAutoProxySvc',
            'RpcEptMapper', 'RpcSs', 'DcomLaunch', 'PlugPlay', 'ProfSvc', 'UserManager', 'gpsvc',
            'EventLog', 'BrokerInfrastructure', 'LicenseManager'
        )) {
        [void]$oobeProtectedServiceIds.Add([string]$criticalServiceId)
    }
    $appliedServicePairs = New-Object System.Collections.Generic.List[string]
    $protectedServiceSkipped = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $serviceModeMap.GetEnumerator()) {
        $svcId = [string]$entry.Key
        $svcMode = [string]$entry.Value
        if ($oobeProtectedServiceIds.Contains($svcId)) {
            [void]$protectedServiceSkipped.Add($svcId)
            continue
        }
        $svcLookupKey = & $toKey $svcId
        if ([string]::IsNullOrWhiteSpace($svcLookupKey) -or -not $serviceIndexById.ContainsKey($svcLookupKey)) { continue }
        if (& $setServiceModeById $svcId $svcMode) {
            $serviceApplied++
            [void]$appliedServicePairs.Add("$svcId=$svcMode")
        }
        else {
            $missingEntries++
        }
    }
    if ($appliedServicePairs.Count -gt 0) {
        $serviceList = @($appliedServicePairs | Sort-Object -Unique)
        $servicePreviewMax = 30
        $servicePreview = if ($serviceList.Count -gt $servicePreviewMax) {
            (($serviceList[0..($servicePreviewMax - 1)] -join ', ') + ", ... (+$($serviceList.Count - $servicePreviewMax) more)")
        }
        else {
            ($serviceList -join ', ')
        }
        Write-Log ("Recommended preset Service modes: {0}" -f $servicePreview) -Color White
    }
    if ($protectedServiceSkipped.Count -gt 0) {
        $keptServiceList = @($protectedServiceSkipped | Sort-Object -Unique)
        Write-Log ("Recommended preset OOBE safety: kept critical services on image defaults ({0})." -f ($keptServiceList -join ', ')) -Color Yellow
    }

    $privacyModeMap = [ordered]@{
        'AI: Disable Copilot and Recall policies' = 'Enabled'
        'AI: Disable actions (Click to Do)' = 'Enabled'
        'AI: Disable Fabric service' = 'Enabled'
        'AI: Disable Settings agent' = 'Enabled'
        'AI: Disable Voice Access' = 'Enabled'
        'AI: Disable voice effects' = 'Enabled'
        'AI: Hide Settings components pages' = 'Enabled'
        'AI: Prevent Copilot package reinstall' = 'Enabled'
        'AI: Remove AI appx packages' = 'Disabled'
        'AI: Remove Recall optional feature' = 'Disabled'
        'AI: Remove Recall scheduled tasks' = 'Disabled'
        'Ads, suggestions, and promotional content' = 'Disabled'
        'Advertising ID personalization' = 'Disabled'
        'Clear Explorer folder view history (ShellBags)' = 'Disabled'
        'Clear package install-location registry logs' = 'Disabled'
        'Compatibility assistant (PCA)' = 'Disabled'
        'Compatibility telemetry: Application inventory' = 'Disabled'
        'Compatibility telemetry: Compatibility Appraiser task' = 'Disabled'
        'Cross-device resume' = 'Disabled'
        'Diagnostic data' = 'Disabled'
        'Edge: Disable Copilot and AI features' = 'Enabled'
        'Feedback frequency' = 'Disabled'
        'Inking and typing diagnostics' = 'Disabled'
        'Language list access for websites' = 'Disabled'
        'Let apps run in the background' = 'Disabled'
        'OOBE: Finish setting up your device (SCOOBE)' = 'Disabled'
        'OEM pre-installed apps' = 'Disabled'
        'Office: Disable Copilot and AI features' = 'Enabled'
        'Online Speech Recognition' = 'Disabled'
        'OneDrive automatic backups' = 'Disabled'
        'Paint: Disable AI image features' = 'Enabled'
        'Notepad: Disable AI features' = 'Enabled'
        'Personalized speech, typing, and inking input' = 'Disabled'
        'Pre-installed suggested apps' = 'Disabled'
        'Search: Bing web results in Start menu search' = 'Disabled'
        'Search: Cloud content (Microsoft account)' = 'Disabled'
        'Search: Cloud content (Work or School account)' = 'Disabled'
        'Search: Cloud content accounts' = 'Disabled'
        'Search: Device search history' = 'Disabled'
        'Search: Microsoft Store app results in Start menu' = 'Disabled'
        'Search: Search highlights' = 'Disabled'
        'Search: Web results in Windows Search' = 'Disabled'
        'Search: Web results in taskbar search' = 'Disabled'
        'Send typing and writing data to Microsoft' = 'Disabled'
        'Settings app suggestions' = 'Disabled'
        'Shared experiences across devices' = 'Disabled'
        'Shared experiences over Bluetooth' = 'Disabled'
        'Start menu suggestions' = 'Disabled'
        'Start menu: Most used apps' = 'Disabled'
        'Start menu: Track app launches' = 'Disabled'
        'Tailored experiences using diagnostic data' = 'Disabled'
        'Tips, shortcuts, and app recommendations' = 'Disabled'
        'Windows Copilot' = 'Disabled'
        'Windows Error Reporting' = 'Disabled'
        'Windows Recall (Copilot+ PCs)' = 'Disabled'
        'Windows welcome experience after updates' = 'Disabled'
        'Windows experimentation' = 'Disabled'
        'Windows tips and suggestions' = 'Disabled'
        'Windows Spotlight (tips and suggestions)' = 'Disabled'
        'Workplace join prompts' = 'Disabled'
        'Gaming: Disable Copilot widget' = 'Enabled'
    }
    foreach ($entry in $privacyModeMap.GetEnumerator()) {
        if (& $setPrivacyModeByLabel ([string]$entry.Key) ([string]$entry.Value)) { $privacyApplied++ } else { $missingEntries++ }
    }

    $extraSecurityModeMap = [ordered]@{
        '.NET strong crypto mode' = 'Enabled'
        '.NET use OS default TLS versions' = 'Enabled'
        'Block anonymous access to named pipes and shares' = 'Disabled'
        'Block anonymous SAM and share enumeration' = 'Disabled'
        'Diffie-Hellman minimum key length (2048-bit)' = 'Enabled'
        'Disable AutoPlay and AutoRun (all drives)' = 'Disabled'
        'Disable LM hash storage (NoLMHash)' = 'Disabled'
        'Disable PowerShell 7 telemetry' = 'Disabled'
        'Disable SMB 1.0 (SMBv1) protocol' = 'Disabled'
        'Disable Windows PowerShell 2.0' = 'Disabled'
        'Disable Windows Script Host (WSH)' = 'Disabled'
        'Disable WinRM Basic authentication' = 'Disabled'
        'DTLS 1.0 protocol (legacy)' = 'Disabled'
        'DTLS 1.1 protocol (legacy)' = 'Disabled'
        'DTLS 1.2 protocol' = 'Enabled'
        'Enable Defender and Edge PUA blocking' = 'Enabled'
        'Enable LSA protection (RunAsPPL)' = 'Enabled'
        'RSA minimum key length (2048-bit)' = 'Enabled'
        'Restrict LM and NTLM authentication' = 'Enabled'
        'SSL 2.0 protocol (legacy)' = 'Disabled'
        'SSL 3.0 protocol (legacy)' = 'Disabled'
        'Set Windows Time Service NTP server (pool.ntp.org)' = 'Enabled'
        'TLS 1.0 protocol (legacy)' = 'Disabled'
        'TLS 1.1 protocol (legacy)' = 'Disabled'
        'TLS 1.2 protocol' = 'Enabled'
        'TLS 1.3 protocol' = 'Enabled'
    }
    foreach ($entry in $extraSecurityModeMap.GetEnumerator()) {
        if (& $setExtraSecurityModeByLabel ([string]$entry.Key) ([string]$entry.Value)) { $extraSecurityApplied++ } else { $missingEntries++ }
    }

    $advancedModeMap = [ordered]@{
        'UI - Windows Widgets' = 'Disabled'
        'UX - App suggestions (Content Delivery Manager)' = 'Disabled'
        'Explorer - Show file name extensions' = 'Enabled'
        'Start - Recommendations in Start Menu' = 'Disabled'
        'Settings - Remove Home page' = 'Enabled'
        'Settings - Hide Windows Insider Program page' = 'Enabled'
        'Settings - Hide For developers page' = 'Enabled'
        'Settings - Hide Atlas recommended pages' = 'Enabled'
        'Explorer - Remove Gallery from navigation pane' = 'Enabled'
        'Explorer - Remove Home from navigation pane' = 'Enabled'
        'Encryption - Device encryption automatic enablement' = 'Enabled'
        'Encryption - BitLocker automatic device encryption' = 'Disabled'
        'Security - Disable WPBT execution (Beta)' = 'Disabled'
    }
    foreach ($entry in $advancedModeMap.GetEnumerator()) {
        if (& $setAdvancedModeByLabel ([string]$entry.Key) ([string]$entry.Value)) { $advancedApplied++ } else { $missingEntries++ }
    }

    $summary = "Safe High-Debloat preset applied to selections. Click 'Start Oximize Build' to write these changes into the ISO. Security baseline: Hardened. " +
    "Appx={0}, Features={1}, Tasks={2}, Services={3}, Privacy={4}, SecurityHardening={5}, Advanced={6}, Missing={7}" -f `
    $appxApplied, $featureApplied, $taskApplied, $serviceApplied, $privacyApplied, $extraSecurityApplied, $advancedApplied, $missingEntries

    Write-Log $summary -Color Green
    [System.Windows.Forms.MessageBox]::Show(
        $summary,
        "Safe High-Debloat Preset", "OK", "Information") | Out-Null
    }
    finally {
        for ($idx = $bulkLayoutSuspended.Count - 1; $idx -ge 0; $idx--) {
            $ctl = $bulkLayoutSuspended[$idx]
            if ($null -eq $ctl -or $ctl.IsDisposed) { continue }
            try { $ctl.ResumeLayout($true) } catch {}
        }
        $sync.SuppressUiChangeLog = $previousUiLogSuppressed
    }
}
#endregion

# ── Bottom Panel ────────────────────────────────────────────────────────────
$botPanel = New-Object System.Windows.Forms.Panel
$botPanel.Dock = 'Bottom'
$botPanel.Height = 120
$botPanel.BackColor = $clrPanelAlt
$botPanel.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 4)
Set-ModernPanelPaint -Control $botPanel
$btnStart = New-DarkButton -Text '▶  Start Oximize Build' -Width ($botPanel.Width - 16) -Height 42 -Role 'Accent'
$btnStart.Left = 8; $btnStart.Top = 8; $btnStart.Font = New-UiFont -Size 11 -Style ([System.Drawing.FontStyle]::Bold)
$btnStart.Anchor = 'Top, Left, Right'
$botPanel.Controls.Add($btnStart)
$sync.StartButton = $btnStart

$btnCancel = New-DarkButton -Text '✖  Cancel' -Width ($botPanel.Width - 16) -Height 34 -Role 'Danger'
$btnCancel.Left = 8; $btnCancel.Top = 58; $btnCancel.Enabled = $false
$btnCancel.Anchor = 'Top, Left, Right'
$botPanel.Controls.Add($btnCancel)
$sync.CancelButton = $btnCancel

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Left = 8; $progressBar.Top = 98
$progressBar.Width = ($botPanel.Width - 16); $progressBar.Height = 18
$progressBar.Minimum = 0; $progressBar.Maximum = 100
$progressBar.Style = 'Continuous'
$progressBar.BackColor = $clrPanel
$progressBar.ForeColor = $clrAccent
$progressBar.Anchor = 'Top, Left, Right'
$botPanel.Controls.Add($progressBar)
$sync.ProgressBar = $progressBar

$panelMainUI.Controls.Add($botPanel)

function Apply-Theme {
    param([ValidateSet('Dark', 'Light')][string]$Mode)
    Set-ThemePalette -Mode $Mode

    $form.SuspendLayout()
    try {
        $form.BackColor = $clrBg
        $form.ForeColor = $clrText
        $form.Font = New-UiFont -Size 9
        $topPanel.BackColor = $clrPanel
        $advancedPanel.BackColor = $clrPanelAlt
        $botPanel.BackColor = $clrPanelAlt
        $progressBar.BackColor = $clrPanel
        $progressBar.ForeColor = $clrAccent
        $logBox.BackColor = $clrLogBg
        $logBox.ForeColor = $clrLogText
        $logBox.Font = New-Object System.Drawing.Font('Consolas', 10)
        $logToolsPanel.BackColor = $clrPanel

        function local:Update-ControlTheme {
            param([System.Windows.Forms.Control]$Root)
            foreach ($c in $Root.Controls) {
                try {
                    if ($null -eq $c -or $c.IsDisposed) { continue }
                if ($c -is [System.Windows.Forms.Button]) {
                    $tagData = if ($c.Tag -is [hashtable]) { $c.Tag } else { @{ Role = 'Normal' } }
                    $role = $tagData.Role

                    if ($role -eq 'NavActive') {
                        $c.Font = $script:FontNavBold
                    }
                    elseif ($role -eq 'Nav') {
                        $c.Font = $script:FontNavReg
                    }
                    elseif ($c -eq $btnStart) {
                        $c.Font = New-UiFont -Size 11 -Style ([System.Drawing.FontStyle]::Bold)
                    }
                    else {
                        $c.Font = New-UiFont -Size 9.5 -Style ([System.Drawing.FontStyle]::Bold)
                    }
                    if (-not $script:UseCustomButtonPaint) {
                        Set-ButtonVisualStyle -Button $c
                    }
                    else {
                        $c.Invalidate()
                    }
                }
                elseif ($c -is [System.Windows.Forms.TextBox] -or $c -is [System.Windows.Forms.MaskedTextBox]) {
                    if ($c.Parent -is [System.Windows.Forms.Panel]) {
                        $c.Parent.BackColor = $clrInputBg
                        $c.BackColor = $clrInputBg
                        $c.Parent.Invalidate()
                    }
                    if ($c -eq $tbCustomXml -and [string]$c.Text -eq 'No custom unattend.xml selected') {
                        $c.ForeColor = $clrMutedText
                    }
                    elseif (-not $c.Enabled) {
                        $c.ForeColor = $clrDisabledText
                    }
                    elseif ($c.Tag -is [System.Collections.IDictionary] -and $c.Tag['IsPlaceholder']) {
                        $c.ForeColor = $clrMutedText
                    }
                    else {
                        $c.ForeColor = $clrText
                    }
                }
                elseif ($c -is [System.Windows.Forms.RichTextBox]) {
                    if ($c -eq $logBox) {
                        $c.BackColor = $clrLogBg
                        $c.ForeColor = $clrLogText
                    }
                    else {
                        $c.BackColor = if ($null -ne $c.Parent -and $c.Parent.Tag -eq 'DetailPanel') { $clrPanel } else { $clrPanelAlt }
                        $c.ForeColor = $clrText
                    }
                    $c.Font = New-UiFont -Size 9.5
                }
                elseif ($c -is [System.Windows.Forms.CheckBox]) {
                    $c.ForeColor = if ($c.Enabled) { $clrText } else { $clrDisabledText }
                    if ($c.Appearance -eq [System.Windows.Forms.Appearance]::Button) {
                        # Preserve custom button-like checkboxes used in selection rows.
                        $c.UseVisualStyleBackColor = $false
                        $c.FlatStyle = 'Flat'
                        $c.FlatAppearance.BorderColor = $clrBorder
                        $c.FlatAppearance.CheckedBackColor = Get-ShiftedColor -Color $clrNavActiveBg -Delta 6
                        $c.FlatAppearance.MouseOverBackColor = Get-ShiftedColor -Color $clrPanelAlt -Delta 8
                        $c.FlatAppearance.MouseDownBackColor = Get-ShiftedColor -Color $clrPanelAlt -Delta -4
                    }
                    else {
                        # Standard checkboxes for clear/visible checkmark glyph.
                        $c.UseVisualStyleBackColor = $true
                        $c.FlatStyle = 'Standard'
                    }
                    $checkStyle = if ($null -ne $c.Font -and $c.Font.Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
                    $c.Font = New-UiFont -Size 9.5 -Style $checkStyle
                    if ($c.Text -match "`r`n") {
                        $c.BackColor = $clrPanelAlt
                    }
                    else {
                        $c.BackColor = [System.Drawing.Color]::Transparent
                    }
                }
                elseif ($c -is [System.Windows.Forms.RadioButton]) {
                    $c.ForeColor = if ($c.Enabled) { $clrText } else { $clrDisabledText }
                    $c.BackColor = [System.Drawing.Color]::Transparent
                    $c.Font = New-UiFont -Size 9.5
                }
                elseif ($c -is [System.Windows.Forms.ComboBox]) {
                    if ($c -eq $langCombo) {
                        $c.BackColor = $clrInputBg
                        $c.ForeColor = if ($c.Enabled) { $clrText } else { $clrMutedText }
                    }
                    else {
                        $c.BackColor = $clrInputBg
                        $c.ForeColor = if ($c.Enabled) { $clrText } else { $clrDisabledText }
                    }
                    $c.Font = New-UiFont -Size 9.5
                }
                elseif ($c -is [System.Windows.Forms.Label]) {
                    $labelBackColor = if ($null -ne $c.Parent) { $c.Parent.BackColor } else { $clrPanelAlt }
                    if ($c.Tag -eq 'PathInfo') {
                        $c.ForeColor = $clrMutedText
                        $c.Font = New-UiFont -Size 8.5
                        $c.BackColor = $labelBackColor
                    }
                    elseif ($c.Tag -eq 'DetailHeader') {
                        $c.ForeColor = $clrMutedText
                        $c.Font = New-UiFont -Size 9 -Style ([System.Drawing.FontStyle]::Bold)
                        $c.BackColor = $labelBackColor
                    }
                    elseif ($c.Tag -eq 'PrivacyLabel') {
                        $c.ForeColor = $clrText
                        $c.Font = New-UiFont -Size 9.5 -Style ([System.Drawing.FontStyle]::Regular)
                        $c.BackColor = $labelBackColor
                    }
                    elseif ($c.Tag -eq 'SecurityDetailLabel') {
                        $c.ForeColor = $clrText
                        $c.BackColor = $clrPanelAlt
                        $c.Font = New-UiFont -Size 10 -Style ([System.Drawing.FontStyle]::Regular)
                    }
                    elseif ($c.Tag -eq 'WelcomeTitle') {
                        $c.ForeColor = $clrText
                        $c.BackColor = if ($null -ne $panelWelcome) { $panelWelcome.BackColor } else { $labelBackColor }
                        $c.Font = New-UiFont -Size 20 -Style ([System.Drawing.FontStyle]::Bold)
                    }
                    elseif ($c.Tag -eq 'WelcomeText') {
                        $c.ForeColor = $clrText
                        $c.BackColor = if ($null -ne $panelWelcome) { $panelWelcome.BackColor } else { $labelBackColor }
                        $c.Font = New-UiFont -Size 9.5
                    }
                    elseif ($c.Tag -eq 'WarningTitle') {
                        $c.ForeColor = $clrWarning
                        $c.BackColor = if ($null -ne $panelWelcome) { $panelWelcome.BackColor } else { $labelBackColor }
                        $c.Font = New-UiFont -Size 12 -Style ([System.Drawing.FontStyle]::Bold)
                    }
                    elseif ($c.Tag -eq 'PagePlaceholder') {
                        $c.ForeColor = $clrMutedText
                        $c.Font = New-UiFont -Size 10
                        $c.BackColor = if ($null -ne $c.Parent) { $c.Parent.BackColor } else { $clrPanelAlt }
                        $c.TextAlign = 'MiddleCenter'
                    }
                    else {
                        $c.ForeColor = $clrText
                        $c.BackColor = $labelBackColor
                        $labelSize = 9.5
                        if ($null -ne $c.Font) {
                            $labelSize = [Math]::Max(8.0, [double]$c.Font.Size)
                        }
                        $labelStyle = if ($null -ne $c.Font -and $c.Font.Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
                        $c.Font = New-UiFont -Size $labelSize -Style $labelStyle
                    }
                }
                elseif ($c -is [System.Windows.Forms.FlowLayoutPanel]) {
                    if ($c.Tag -eq 'NavFlow') {
                        $c.BackColor = $clrPanel
                    }
                    elseif ($c.Tag -eq 'OptionsFlow') {
                        if ($null -ne $c.Parent) {
                            $c.BackColor = $c.Parent.BackColor
                        }
                        else {
                            $c.BackColor = $clrPanel
                        }
                    }
                    else {
                        $c.BackColor = $clrPanelAlt
                    }
                }
                elseif ($c -is [System.Windows.Forms.Panel]) {
                    if ($c -eq $topPanel) {
                        $c.BackColor = $clrPanel
                    }
                    elseif ($c.Tag -eq 'OptionsHostPanel') {
                        if ($null -ne $c.Parent) {
                            $c.BackColor = $c.Parent.BackColor
                        }
                        else {
                            $c.BackColor = $clrPanel
                        }
                    }
                    elseif ($c.Tag -eq 'MicroPanel') {
                        $c.BackColor = $clrPanel
                    }
                    elseif ($c.Tag -eq 'PageBody') {
                        $c.BackColor = $clrPanelAlt
                    }
                    elseif ($c.Tag -eq 'DetailPanel') {
                        $c.BackColor = $clrPanel
                    }
                    elseif ($null -ne $c.Parent -and $c.Parent.Tag -eq 'DetailPanel') {
                        # RichTextBox inside DetailPanel
                        $c.BackColor = $clrPanel
                        $c.ForeColor = $clrText
                    }
                    elseif ($c.Tag -eq 'PathRowPanel') {
                        if ($null -ne $c.Parent) {
                            $c.BackColor = $c.Parent.BackColor
                        }
                        else {
                            $c.BackColor = $clrPanel
                        }
                    }
                    elseif ($c.Tag -eq 'PathInputPanel') {
                        if ($null -ne $c.Parent) {
                            $c.BackColor = $c.Parent.BackColor
                        }
                        else {
                            $c.BackColor = $clrPanel
                        }
                    }
                    elseif ($c -eq $advancedPanel -or $c -eq $botPanel -or $c -eq $contentPanel -or $c.Parent -eq $contentPanel) {
                        $c.BackColor = $clrPanelAlt
                    }
                    elseif ($c -eq $logToolsPanel) {
                        $c.BackColor = $clrPanel
                    }
                    elseif ($c -eq $navPanel) {
                        $c.BackColor = $clrPanel
                    }
                    elseif ($c.Parent -is [System.Windows.Forms.FlowLayoutPanel]) {
                        # Keep list rows (Privacy/Security/Features/Tasks/Services) synced with their themed flow background.
                        $c.BackColor = $c.Parent.BackColor
                    }
                    else {
                        $c.BackColor = $clrBg
                    }
                    $c.Invalidate()
                }
                elseif ($c -is [System.Windows.Forms.ListBox]) {
                    $c.BackColor = $clrInputBg
                    $c.ForeColor = if ($c.Enabled) { $clrText } else { $clrDisabledText }
                    $c.Font = New-UiFont -Size 9.5
                }

                if ($c.HasChildren) { Update-ControlTheme -Root $c }
                }
                catch {
                    try {
                        $ctrlType = if ($null -ne $c) { $c.GetType().Name } else { 'Unknown' }
                        Write-SessionLogLine -Message ("Theme control warning ({0}): {1}" -f $ctrlType, [string]$_) -Level 'WARN' -Source 'UI'
                    }
                    catch {}
                }
            }
        }

        Update-ControlTheme -Root $form

        foreach ($checkList in @($sync.AppxBoxes, $sync.FeaturesBoxes, $sync.TasksBoxes, $sync.ServicesBoxes)) {
            foreach ($cb in @($checkList)) {
                if ($null -eq $cb) { continue }
                if ($cb.Parent) { $cb.BackColor = $cb.Parent.BackColor }
                $cb.ForeColor = $clrText
                $cb.Font = New-UiFont -Size 9.5
                $isDetailedRow = ($cb.Text -match "`r`n")
                if ($isDetailedRow) {
                    $cb.Height = Get-CheckRowHeight -Text $cb.Text -Font $cb.Font -Width ([Math]::Max($cb.Width - 24, 120)) -MinHeight 36 -MaxHeight 46 -FastSingleLine
                }
                elseif ($cb.Height -ne 24) {
                    $cb.Height = 24
                }
            }
        }

        if ($btnThemeMode.Image) { $btnThemeMode.Image.Dispose() }
        $btnThemeMode.Image = Get-ThemeToggleIcon -Mode $Mode
        if ($btnThemeModeWelcome.Image) { $btnThemeModeWelcome.Image.Dispose() }
        $btnThemeModeWelcome.Image = Get-ThemeToggleIcon -Mode $Mode
        if ($btnSettings.Image) { $btnSettings.Image.Dispose() }
        $btnSettings.Image = Get-SettingsIcon -Mode $Mode
        $btnThemeMode.Text = ''
        if ($null -ne $uiToolTip) {
            $nextTheme = if ($Mode -eq 'Dark') { 'Light' } else { 'Dark' }
            $uiToolTip.SetToolTip($btnThemeMode, "Switch to $nextTheme theme")
            $uiToolTip.SetToolTip($btnThemeModeWelcome, "Switch to $nextTheme theme")
            $uiToolTip.SetToolTip($btnSettings, 'Settings (Recommended Preset / Import / Export)')
        }

        if ($settingsMenu) {
            $settingsMenu.BackColor = $clrPanel
            $settingsMenu.ForeColor = $clrText
            foreach ($menuItem in $settingsMenu.Items) {
                if ($menuItem -is [System.Windows.Forms.ToolStripSeparator]) {
                    $menuItem.BackColor = $clrPanel
                    continue
                }
                $menuItem.BackColor = $clrPanel
                $menuItem.ForeColor = $clrText
            }
        }
        if ($null -ne $setSecurityPreset) {
            $presetToApply = [string]$sync.SecurityPreset
            if ([string]::IsNullOrWhiteSpace($presetToApply)) { $presetToApply = 'Balanced' }
            & $setSecurityPreset $presetToApply
        }
        Update-SectionLayout
        Reset-HorizontalScrollRecursively -Root $form
        $form.Invalidate($true)
        Invoke-UiStabilizeRedraw -Root $form
    }
    catch {
        $themeErr = [string]$_
        Write-SessionLogLine -Message ("Theme apply warning ({0}): {1}" -f $Mode, $themeErr) -Level 'WARN' -Source 'UI'
        try {
            Write-Log ("Theme apply warning ({0}): {1}" -f $Mode, $themeErr) -Color Yellow
        }
        catch {}
    }
    finally {
        $form.ResumeLayout($true)
    }
}

$btnThemeMode.Add_Click({
        try {
            $nextMode = if ($script:ThemeMode -eq 'Dark') { 'Light' } else { 'Dark' }
            Apply-Theme -Mode $nextMode
            Write-Log "Theme changed to $nextMode mode." -Color Cyan
        }
        catch {
            $themeErr = [string]$_
            Write-SessionLogLine -Message ("Theme toggle warning: {0}" -f $themeErr) -Level 'WARN' -Source 'UI'
            try { Write-Log ("Theme toggle warning: {0}" -f $themeErr) -Color Yellow } catch {}
        }
    })

$settingsMenu = New-Object System.Windows.Forms.ContextMenuStrip
$settingsMenu.BackColor = $clrPanel
$settingsMenu.ForeColor = $clrText
$settingsMenu.RenderMode = 'Professional'
$settingsMenu.ShowImageMargin = $false
$privacyItem = $settingsMenu.Items.Add('Apply Recommended Preset')
[void]$settingsMenu.Items.Add('-')
$importItem = $settingsMenu.Items.Add('Import')
$exportItem = $settingsMenu.Items.Add('Export')
$privacyItem.Add_Click({ Invoke-ApplyPrivacyPreset })
$importItem.Add_Click({ Invoke-ImportConfig })
$exportItem.Add_Click({ Invoke-ExportConfig })

$btnSettings.Add_Click({
        $pt = New-Object System.Drawing.Point(0, $btnSettings.Height)
        $settingsMenu.Show($btnSettings, $pt)
    })

# Keep startup paint path simple/stable (no deep buffering pre-pass).

# ── Dynamic tab positioning (allow collapse panel to grow) ─────────────────
$resizeLayoutTimer = New-Object System.Windows.Forms.Timer
$resizeLayoutTimer.Interval = 60
$resizeLayoutTimer.Add_Tick({
        $resizeLayoutTimer.Stop()
        Update-SectionLayout
    })

$form.Add_Resize({
        if ($resizeLayoutTimer.Enabled) {
            $resizeLayoutTimer.Stop()
        }
        $resizeLayoutTimer.Start()
    })
#endregion

#region ── Edition Selector Modal ─────────────────────────────────────────────
function Show-EditionSelector {
    param([array]$Editions)

    if ($Editions.Count -eq 1) { return $Editions[0].ImageIndex }

    $edForm = New-Object System.Windows.Forms.Form
    $edForm.Text = 'Select Windows Edition'
    $edForm.ClientSize = New-Object System.Drawing.Size(620, 440)
    $edForm.StartPosition = 'CenterParent'
    $edForm.FormBorderStyle = 'FixedDialog'
    $edForm.BackColor = $clrBg
    $edForm.MaximizeBox = $false
    $edForm.MinimizeBox = $false

    $lbl = New-DarkLabel -Text 'Available Editions:' -Width 580
    $lbl.Top = 12; $lbl.Left = 14
    $edForm.Controls.Add($lbl)

    $lb = New-Object System.Windows.Forms.ListBox
    $lb.Top = 42; $lb.Left = 14; $lb.Width = 592; $lb.Height = 330
    $lb.BackColor = $clrInputBg
    $lb.ForeColor = $clrText
    $lb.Font = New-Object System.Drawing.Font('Consolas', 10)
    $lb.IntegralHeight = $false
    foreach ($ed in $Editions) {
        [void]$lb.Items.Add("[$($ed.ImageIndex)] $($ed.ImageName)")
    }
    $lb.SelectedIndex = 0
    $edForm.Controls.Add($lb)

    $btnOk = New-DarkButton -Text 'OK' -Width 120 -Height 28 -BgColor $clrAccent
    $btnOk.Top = 388; $btnOk.Left = 250
    $btnOk.Add_Click({ $edForm.DialogResult = 'OK'; $edForm.Close() })
    $edForm.Controls.Add($btnOk)
    $edForm.AcceptButton = $btnOk
    $lb.Add_DoubleClick({ $edForm.DialogResult = 'OK'; $edForm.Close() })

    try {
        if ($edForm.ShowDialog($form) -eq 'OK') {
            $sel = $lb.SelectedIndex
            return $Editions[$sel].ImageIndex
        }
        return $Editions[0].ImageIndex
    }
    finally {
        try { $edForm.Dispose() } catch {}
    }
}
#endregion

#region ── Version Compatibility Check ────────────────────────────────────────
function Test-WindowsVersion {
    param([string]$BuildString)
    # BuildString like "10.0.19041.1"
    try {
        $ver = [Version]$BuildString
    }
    catch {
        $ver = [Version]"0.0.0"
    }
    $sync.BuildVersion = $ver

    if ($ver -lt [Version]"10.0.10240") {
        Write-Log "ABORT: Unsupported Windows version ($BuildString)." -Color Red
        [System.Windows.Forms.MessageBox]::Show(
            "This ISO contains an unsupported Windows version ($BuildString).",
            "Unsupported Version", 'OK', 'Error') | Out-Null
        return $false
    }
    if ($ver -lt [Version]"10.0.21996") {
        Write-Log "ABORT: Windows 10 detected ($BuildString). Only Windows 11 ISOs are supported." -Color Red
        [System.Windows.Forms.MessageBox]::Show(
            "Detected Windows 10 ($BuildString).`n`nOnly Windows 11 ISO sources are supported.",
            "Windows 11 Required", 'OK', 'Error') | Out-Null
        return $false
    }
    if ($ver -ge [Version]"10.0.21996" -and $ver -lt [Version]"10.0.26100") {
        Write-Log "Windows 11 detected ($BuildString). Proceeding normally." -Color Green
    }
    if ($ver -ge [Version]"10.0.26100") {
        Write-Log "Windows 11 24H2+ detected ($BuildString). Expedited app key removal enabled." -Color Cyan
        $sync.Remove24H2Keys = $true
    }
    return $true
}
#endregion

#region ── Disk Space Validation ──────────────────────────────────────────────
function Test-DiskSpace {
    param([string]$IsoPath)
    try {
        $isoSize = (Get-Item $IsoPath).Length
        $drive = Split-Path $env:USERPROFILE -Qualifier
        $diskInfo = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -like "$drive*" } | Select-Object -First 1
        if ($null -eq $diskInfo) {
            Write-Log "Could not determine free disk space for drive $drive — skipping disk space check." -Color Yellow
            return $true
        }
        $freeBytes = $diskInfo.Free * 1MB  # PSDrive Free is in MB
        # Re-query via CIM for accuracy
        $wmiDisk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$drive'" -ErrorAction SilentlyContinue
        if ($wmiDisk) { $freeBytes = $wmiDisk.FreeSpace }

        if ($freeBytes -lt $isoSize) {
            Write-Log "ABORT: Insufficient disk space. Need at least $('{0:N2}' -f ($isoSize/1GB)) GB, have $('{0:N2}' -f ($freeBytes/1GB)) GB." -Color Red
            [System.Windows.Forms.MessageBox]::Show(
                "Insufficient disk space!`n`nRequired: $('{0:N2}' -f ($isoSize/1GB)) GB`nAvailable: $('{0:N2}' -f ($freeBytes/1GB)) GB",
                "Insufficient Disk Space", "OK", "Error") | Out-Null
            return $false
        }
        if ($freeBytes -lt ($isoSize * 2)) {
            Write-Log "WARNING: Less than 2× ISO size free. Processing may fail." -Color Yellow
            $ans = [System.Windows.Forms.MessageBox]::Show(
                "Low disk space warning!`n`nFree: $('{0:N2}' -f ($freeBytes/1GB)) GB`nRecommended: $('{0:N2}' -f (($isoSize*2)/1GB)) GB`n`nContinue anyway?",
                "Low Disk Space", "YesNo", "Warning")
            if ($ans -ne 'Yes') { return $false }
        }
        return $true
    }
    catch {
        Write-Log "Could not verify disk space: $_" -Color Yellow
        return $true  # non-fatal
    }
}
#endregion


#region ── Runspace Pipeline Scriptblock ──────────────────────────────────────
$pipelineScript = {
    param($sync)
    $ErrorActionPreference = 'Stop'

    #region helpers inside runspace
    function RS-Log {
        param([string]$Msg, [string]$Color = 'White')
        $lb = $sync.LogBox
        $colorObjects = @{
            Cyan   = [System.Drawing.ColorTranslator]::FromHtml('#00E5FF')
            Green  = [System.Drawing.ColorTranslator]::FromHtml('#22C55E')
            Yellow = [System.Drawing.ColorTranslator]::FromHtml('#F59E0B')
            Red    = [System.Drawing.ColorTranslator]::FromHtml('#EF4444')
            White  = [System.Drawing.ColorTranslator]::FromHtml('#E6EDF3')
        }
        $c = if ($colorObjects.ContainsKey($Color)) { $colorObjects[$Color] } else { [System.Drawing.ColorTranslator]::FromHtml('#E6EDF3') }
        $msgCopy = "[$(Get-Date -Format 'HH:mm:ss')] $Msg"
        if (-not [string]::IsNullOrWhiteSpace([string]$sync.SessionLogPath)) {
            try {
                $line = "[{0}] [INFO] [RUNSPACE] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Color, $Msg
                [System.IO.File]::AppendAllText([string]$sync.SessionLogPath, $line + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
            }
            catch {}
        }
        if ($null -eq $lb -or $lb.IsDisposed) { return }
        if (-not $lb.IsHandleCreated) { return }
        $uiColor = $c
        $uiMessage = $msgCopy
        $appendAction = [System.Action]({
                try {
                    if ($null -eq $lb -or $lb.IsDisposed -or -not $lb.IsHandleCreated) { return }
                    $lb.SelectionStart = $lb.TextLength
                    $lb.SelectionLength = 0
                    $lb.SelectionColor = $uiColor
                    $lb.AppendText("$uiMessage`n")
                    $lb.SelectionStart = $lb.TextLength
                    $lb.ScrollToCaret()
                }
                catch {}
            }.GetNewClosure())
        try {
            [void]$lb.BeginInvoke($appendAction)
        }
        catch {}
    }

    function RS-Progress {
        param([int]$Pct)
        $pb = $sync.ProgressBar
        if ($null -eq $pb -or $pb.IsDisposed) { return }
        if (-not $pb.IsHandleCreated) { return }
        $newValue = [Math]::Min([Math]::Max($Pct, 0), 100)
        $setProgressAction = [System.Action]({
                try {
                    if ($null -eq $pb -or $pb.IsDisposed -or -not $pb.IsHandleCreated) { return }
                    $pb.Value = $newValue
                }
                catch {}
            }.GetNewClosure())
        try {
            [void]$pb.BeginInvoke($setProgressAction)
        }
        catch {}
    }
    function RS-CheckCancel {
        if ($sync.CancelRequested) { throw [System.OperationCanceledException]"Cancelled" }
    }
    function RS-RunDism {
        param([string[]]$DismArgs)
        # Avoid nested quoting like /WimFile:\"X:\path\" under pwsh which DISM parses as invalid syntax.
        $normalizedArgs = @()
        foreach ($arg in @($DismArgs)) {
            $text = [string]$arg
            if ($text -match '^(\/[^:]+:)"(.+)"$') {
                $text = $Matches[1] + $Matches[2]
            }
            $normalizedArgs += $text
        }
        $stdoutAndErr = & dism.exe @normalizedArgs 2>&1
        $nativeSucceeded = $?
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode -or ($exitCode -is [string] -and [string]::IsNullOrWhiteSpace($exitCode))) {
            $exitCode = if ($nativeSucceeded) { 0 } else { -1 }
            try { RS-Log ("WARNING: DISM returned an empty exit code; inferred {0} from command success state." -f $exitCode) -Color Yellow } catch { try { Write-Host ("[{0}] WARNING: DISM returned an empty exit code; inferred {1} from command success state." -f (Get-Date -Format 'HH:mm:ss'), $exitCode) } catch {} }
        }
        if ($stdoutAndErr) {
            $dismText = ($stdoutAndErr -join "`n")
            try { RS-Log $dismText -Color White } catch { try { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $dismText) } catch {} }
        }
        if ($exitCode -notin @(0, 1641, 3010)) {
            throw ("DISM exited with code {0}. Args: {1}" -f $exitCode, ($normalizedArgs -join ' '))
        }
        return ($stdoutAndErr -join "`n")
    }
    function RS-RunReg {
        param(
            [string]$SubCmd,
            [string[]]$RegArgs,
            [bool]$LogOutputOnSuccess = $true,
            [bool]$LogOutputOnError = $false
        )
        $allArgs = @($SubCmd) + $RegArgs
        $out = & reg.exe @allArgs 2>&1
        $exitCode = $LASTEXITCODE
        $regText = if ($out) { ($out -join "`n") } else { '' }

        if ($exitCode -eq 0) {
            if ($LogOutputOnSuccess -and -not [string]::IsNullOrWhiteSpace($regText)) {
                try { RS-Log $regText -Color White } catch { try { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $regText) } catch {} }
            }
            return
        }

        if ($LogOutputOnError -and -not [string]::IsNullOrWhiteSpace($regText)) {
            try { RS-Log $regText -Color White } catch { try { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $regText) } catch {} }
        }

        if ([string]::IsNullOrWhiteSpace($regText)) {
            throw "reg.exe $SubCmd failed with exit code $exitCode."
        }
        throw ("reg.exe {0} failed with exit code {1}. {2}" -f $SubCmd, $exitCode, $regText)
    }
    function RS-SetReg {
        param([string]$Key, [string]$ValName, [object]$ValData, [string]$ValType = 'REG_DWORD')
        $typeMap = @{ DWord = 'REG_DWORD'; String = 'REG_SZ'; ExpandString = 'REG_EXPAND_SZ'; QWord = 'REG_QWORD' }
        $regType = if ($typeMap.ContainsKey($ValType)) { $typeMap[$ValType] } else { $ValType }
        RS-RunReg 'add' @("$Key", '/v', $ValName, '/t', $regType, '/d', "$ValData", '/f') $false $false
    }
    function RS-UnloadRegistryHiveMounts {
        param(
            [string[]]$HiveKeys,
            [string]$Context = 'cleanup',
            [int]$TimeoutMs = 20000,
            [int]$MaxAttempts = 3
        )

        if ($TimeoutMs -lt 5000) { $TimeoutMs = 5000 }
        if ($MaxAttempts -lt 1) { $MaxAttempts = 1 }

        $regExe = Join-Path $env:SystemRoot 'System32\reg.exe'
        if (-not (Test-Path -LiteralPath $regExe -PathType Leaf -ErrorAction SilentlyContinue)) {
            $regExe = 'reg.exe'
        }

        foreach ($hiveKey in @($HiveKeys)) {
            $hiveText = [string]$hiveKey
            if ([string]::IsNullOrWhiteSpace($hiveText)) { continue }
            if ($hiveText -notmatch '^HKLM\\') { continue }

            $providerPath = 'Registry::HKEY_LOCAL_MACHINE\' + ($hiveText -replace '^HKLM\\', '')
            if (-not (Test-Path -LiteralPath $providerPath -ErrorAction SilentlyContinue)) { continue }

            try { RS-Log ("Unloading registry hive mount: {0} ({1})..." -f $hiveText, $Context) -Color White } catch { try { Write-Host ("[{0}] Unloading registry hive mount: {1} ({2})..." -f (Get-Date -Format 'HH:mm:ss'), $hiveText, $Context) } catch {} }
            $unloaded = $false

            for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
                if (-not (Test-Path -LiteralPath $providerPath -ErrorAction SilentlyContinue)) {
                    $unloaded = $true
                    break
                }

                $stdOutPath = [System.IO.Path]::GetTempFileName()
                $stdErrPath = [System.IO.Path]::GetTempFileName()
                $timedOut = $false
                $unloadExit = $null

                try {
                    $proc = Start-Process -FilePath $regExe -ArgumentList @('unload', $hiveText) -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdOutPath -RedirectStandardError $stdErrPath -ErrorAction Stop
                    $didExit = $proc.WaitForExit($TimeoutMs)
                    if (-not $didExit) {
                        $timedOut = $true
                        try { $proc.Kill() } catch {}
                        try { [void]$proc.WaitForExit(2000) } catch {}
                    }
                    else {
                        $unloadExit = [int]$proc.ExitCode
                    }

                    $textParts = @()
                    if (Test-Path -LiteralPath $stdOutPath -PathType Leaf -ErrorAction SilentlyContinue) {
                        $stdOutText = [string](Get-Content -LiteralPath $stdOutPath -Raw -ErrorAction SilentlyContinue)
                        if (-not [string]::IsNullOrWhiteSpace($stdOutText)) { $textParts += $stdOutText.Trim() }
                    }
                    if (Test-Path -LiteralPath $stdErrPath -PathType Leaf -ErrorAction SilentlyContinue) {
                        $stdErrText = [string](Get-Content -LiteralPath $stdErrPath -Raw -ErrorAction SilentlyContinue)
                        if (-not [string]::IsNullOrWhiteSpace($stdErrText)) { $textParts += $stdErrText.Trim() }
                    }
                    if ($textParts.Count -gt 0) {
                        $unloadText = ($textParts -join "`n")
                        try { RS-Log $unloadText -Color White } catch { try { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $unloadText) } catch {} }
                    }

                    if (-not $timedOut -and $unloadExit -eq 0) {
                        $unloaded = $true
                        try { RS-Log ("Unloaded registry hive mount: {0} ({1}) on attempt {2}/{3}." -f $hiveText, $Context, $attempt, $MaxAttempts) -Color Yellow } catch { try { Write-Host ("[{0}] Unloaded registry hive mount: {1} ({2}) on attempt {3}/{4}." -f (Get-Date -Format 'HH:mm:ss'), $hiveText, $Context, $attempt, $MaxAttempts) } catch {} }
                        break
                    }

                    if ($timedOut) {
                        try { RS-Log ("Registry hive unload warning for {0} ({1}): timeout after {2} ms (attempt {3}/{4})." -f $hiveText, $Context, $TimeoutMs, $attempt, $MaxAttempts) -Color Yellow } catch { try { Write-Host ("[{0}] Registry hive unload warning for {1} ({2}): timeout after {3} ms (attempt {4}/{5})." -f (Get-Date -Format 'HH:mm:ss'), $hiveText, $Context, $TimeoutMs, $attempt, $MaxAttempts) } catch {} }
                    }
                    else {
                        $exitText = if ($null -eq $unloadExit) { '<null>' } else { [string]$unloadExit }
                        try { RS-Log ("Registry hive unload warning for {0} ({1}): reg.exe exit {2} (attempt {3}/{4})." -f $hiveText, $Context, $exitText, $attempt, $MaxAttempts) -Color Yellow } catch { try { Write-Host ("[{0}] Registry hive unload warning for {1} ({2}): reg.exe exit {3} (attempt {4}/{5})." -f (Get-Date -Format 'HH:mm:ss'), $hiveText, $Context, $exitText, $attempt, $MaxAttempts) } catch {} }
                    }
                }
                catch {
                    try { RS-Log ("Registry hive unload warning for {0} ({1}) on attempt {2}/{3}: {4}" -f $hiveText, $Context, $attempt, $MaxAttempts, [string]$_) -Color Yellow } catch { try { Write-Host ("[{0}] Registry hive unload warning for {1} ({2}) on attempt {3}/{4}: {5}" -f (Get-Date -Format 'HH:mm:ss'), $hiveText, $Context, $attempt, $MaxAttempts, [string]$_) } catch {} }
                }
                finally {
                    try { Remove-Item -LiteralPath $stdOutPath -Force -ErrorAction SilentlyContinue } catch {}
                    try { Remove-Item -LiteralPath $stdErrPath -Force -ErrorAction SilentlyContinue } catch {}
                }

                if (-not $unloaded -and $attempt -lt $MaxAttempts) {
                    [GC]::Collect()
                    [GC]::WaitForPendingFinalizers()
                    Start-Sleep -Milliseconds 300
                }
            }

            if (-not $unloaded -and (Test-Path -LiteralPath $providerPath -ErrorAction SilentlyContinue)) {
                try { RS-Log ("Registry hive unload warning for {0} ({1}): hive still mounted after {2} attempt(s). Build will continue." -f $hiveText, $Context, $MaxAttempts) -Color Yellow } catch { try { Write-Host ("[{0}] Registry hive unload warning for {1} ({2}): hive still mounted after {3} attempt(s). Build will continue." -f (Get-Date -Format 'HH:mm:ss'), $hiveText, $Context, $MaxAttempts) } catch {} }
            }
        }
    }
    function RS-TestSafeScratchCleanup {
        param(
            [string]$ScratchPath,
            [string]$MarkerFileName = '.oximize_scratch.marker'
        )

        if ([string]::IsNullOrWhiteSpace($ScratchPath)) { return $false }
        if ([string]::IsNullOrWhiteSpace($MarkerFileName)) { $MarkerFileName = '.oximize_scratch.marker' }

        try {
            $fullPath = [System.IO.Path]::GetFullPath([string]$ScratchPath)
        }
        catch {
            return $false
        }

        $rootPath = [System.IO.Path]::GetPathRoot($fullPath)
        $pathNorm = $fullPath.TrimEnd('\')
        $rootNorm = if ([string]::IsNullOrWhiteSpace($rootPath)) { '' } else { $rootPath.TrimEnd('\') }
        if ([string]::IsNullOrWhiteSpace($rootNorm) -or
            [string]::Equals($pathNorm, $rootNorm, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }

        if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) { return $false }
        $markerPath = Join-Path $fullPath $MarkerFileName
        return (Test-Path -LiteralPath $markerPath -PathType Leaf)
    }
    function RS-CleanupScratchDirectory {
        param(
            [string]$ScratchPath,
            [string]$MarkerFileName = '.oximize_scratch.marker',
            [string]$Context = 'build'
        )

        $contextLabel = if ([string]::IsNullOrWhiteSpace($Context)) { 'build' } else { $Context.Trim() }
        if ([string]::IsNullOrWhiteSpace($MarkerFileName)) { $MarkerFileName = '.oximize_scratch.marker' }

        if (RS-TestSafeScratchCleanup -ScratchPath $ScratchPath -MarkerFileName $MarkerFileName) {
            try {
                Remove-Item -Path $ScratchPath -Recurse -Force -ErrorAction SilentlyContinue
                RS-Log ("Scratch cleanup complete ({0})." -f $contextLabel) -Color Green
                return $true
            }
            catch {
                RS-Log ("Scratch cleanup warning ({0}): {1}" -f $contextLabel, $_) -Color Yellow
                return $false
            }
        }

        RS-Log ("Skipping scratch cleanup ({0}): path is not marked as an Oximize-managed scratch directory." -f $contextLabel) -Color Yellow
        return $false
    }

    function Get-PrivacySelectionIsHardened {
        param(
            [string]$Label,
            [string]$Mode
        )

        if ($Mode -notin @('Enabled', 'Disabled')) { return $null }

        $labelText = [string]$Label
        $isDisableStyle = $false
        $isEnableStyle = $false
        if ($labelText -match '^(?i)\s*(disable|block|prevent|remove|hide)\b') {
            $isDisableStyle = $true
        }
        elseif ($labelText -match '(?i)\bturn\s+off\b') {
            $isDisableStyle = $true
        }
        elseif ($labelText -match '(?i)\bdisable\b') {
            $isDisableStyle = $true
        }
        elseif ($labelText -match '^(?i)\s*enable\b') {
            $isEnableStyle = $true
        }

        if ($Mode -eq 'Enabled') { return ($isDisableStyle -or $isEnableStyle) }
        return (-not ($isDisableStyle -or $isEnableStyle))
    }

    function Normalize-PrivacyToggleLabel {
        param([string]$Label)

        if ([string]::IsNullOrWhiteSpace($Label)) { return '' }
        $value = $Label.Trim()
        $value = $value -replace '[\r\n\t]+', ' '
        $value = $value -replace '\s{2,}', ' '
        $value = $value -replace '\s*\(if installed\)\s*$', ''
        $value = $value -replace '\s*\(breaks[^)]*\)', ''
        $value = $value -replace '\s*\(shows random wallpapers on lock screen\)', ''
        $value = $value -replace '\s*\(text or MMS\)', ' (SMS/MMS)'
        $value = $value -replace '\s*\(BETA\)', ' (Beta)'
        $value = $value.Trim()

        switch -Regex ($value) {
            '^(?i)Remove Recall Optional Feature$' { return 'AI: Remove Recall optional feature' }
            '^(?i)Remove Recall Tasks$' { return 'AI: Remove Recall scheduled tasks' }
            '^(?i)Remove AI Appx Packages$' { return 'AI: Remove AI appx packages' }
            '^(?i)Clear Explorer folder view history \(ShellBags\)$' { return 'Clear Explorer folder view history (ShellBags)' }
            '^(?i)Remove registry logs of package install locations$' { return 'Clear package install-location registry logs' }
            default { return $value }
        }
    }

    function Get-PrivacyConsentCapabilityName {
        param([string]$PermissionText)

        if ([string]::IsNullOrWhiteSpace($PermissionText)) { return '' }
        $key = $PermissionText.Trim().ToLowerInvariant()
        $key = $key -replace '^(disable|allow)\s+', ''
        $key = $key -replace '\s*\(.*?\)\s*', ' '
        $key = ($key -replace '\s+', ' ').Trim()

        switch -Regex ($key) {
            '(appointments?|calendar)' { return 'appointments' }
            '^call history$' { return 'phoneCallHistory' }
            '^camera$' { return 'webcam' }
            '^contacts?$' { return 'contacts' }
            'diagnostic' { return 'appDiagnostics' }
            '^documents library$' { return 'documentsLibrary' }
            '^email$' { return 'email' }
            '^file system$' { return 'broadFileSystemAccess' }
            '(messages|messaging|sms|mms)' { return 'chat' }
            '^microphone$' { return 'microphone' }
            'notifications?' { return 'userNotificationListener' }
            '^phone calls?$' { return 'phoneCall' }
            '^pictures library$' { return 'picturesLibrary' }
            '^radios$' { return 'radios' }
            '(share and sync|unpaired bluetooth|non-explicitly paired wireless)' { return 'bluetoothSync' }
            '^tasks?$' { return 'userDataTasks' }
            '(user account info|account information|account info|name, and picture)' { return 'userAccountInformation' }
            '^videos library$' { return 'videosLibrary' }
            '^location$' { return 'location' }
            'voice activation' { return 'voiceActivation' }
            '(eye tracking|gaze)' { return 'gazeInput' }
            '(physical movement|motion activity|activity)' { return 'activity' }
            default { return '' }
        }
    }

    function Convert-PrivacySelectionsToRegistryTweaks {
        param(
            [System.Collections.IDictionary]$PrivacyConfig,
            [hashtable]$PrivacyLabelById
        )

        $resultMap = [ordered]@{}
        $mappedSeen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $unmappedSeen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $mappedLabels = [System.Collections.Generic.List[string]]::new()
        $unmappedLabels = [System.Collections.Generic.List[string]]::new()

        if ($null -eq $PrivacyConfig) {
            return [pscustomobject]@{
                Tweaks         = @()
                MappedLabels   = @()
                UnmappedLabels = @()
            }
        }

        $addSetting = {
            param(
                [string]$Hive,
                [string]$KeyPath,
                [string]$ValueName,
                [object]$HardenedData,
                [object]$RelaxedData,
                [string]$ValueType,
                [bool]$Hardened
            )
            $chosenData = if ($Hardened) { $HardenedData } else { $RelaxedData }
            $mapKey = "{0}\{1}|{2}" -f $Hive, $KeyPath, $ValueName
            $resultMap[$mapKey] = @($Hive, $KeyPath, $ValueName, $chosenData, $ValueType)
        }.GetNewClosure()

        foreach ($entry in $PrivacyConfig.GetEnumerator()) {
            $privacyId = [string]$entry.Key
            $mode = [string]$entry.Value
            if ($mode -notin @('Enabled', 'Disabled')) { continue }

            $label = if ($null -ne $PrivacyLabelById -and $PrivacyLabelById.ContainsKey($privacyId)) {
                [string]$PrivacyLabelById[$privacyId]
            }
            else {
                $privacyId
            }

            $hardened = Get-PrivacySelectionIsHardened -Label $label -Mode $mode
            if ($null -eq $hardened) { continue }
            $matched = $false

            switch -Regex ($label) {
                '(?i)^App permissions:\s*(.+)$' {
                    $permissionText = [string]$Matches[1]
                    $capabilityName = Get-PrivacyConsentCapabilityName -PermissionText $permissionText
                    if (-not [string]::IsNullOrWhiteSpace($capabilityName)) {
                        & $addSetting 'zSOFTWARE' "Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$capabilityName" 'Value' 'Deny' 'Allow' 'String' $hardened
                        & $addSetting 'zNTUSER' "SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$capabilityName" 'Value' 'Deny' 'Allow' 'String' $hardened
                        $matched = $true
                    }
                    break
                }
                '(?i)^Search:\s*Cloud content \(Microsoft account\)$' {
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsMSACloudSearchEnabled' 0 1 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Search:\s*Cloud content \(Work or School account\)$' {
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsAADCloudSearchEnabled' 0 1 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Search:\s*Cloud content accounts$' {
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsMSACloudSearchEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsAADCloudSearchEnabled' 0 1 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Search:\s*Device search history$' {
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsDeviceSearchHistoryEnabled' 0 1 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Search:\s*Search highlights$' {
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\Windows Search' 'EnableDynamicContentInWSB' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsDynamicSearchBoxEnabled' 0 1 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Search:\s*Find my files$' {
                    & $addSetting 'zSOFTWARE' 'Microsoft\Windows Search' 'EnableFindMyFiles' 0 1 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Recommendations and offers in Settings$' {
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338393Enabled' 0 1 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Personalized offers$' {
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\CloudContent' 'DisableTailoredExperiencesWithDiagnosticData' 1 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^View diagnostic data$' {
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\DataCollection' 'DisableDiagnosticDataViewer' 1 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Delete diagnostic data$' {
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\DataCollection' 'DisableDeleteDiagnosticData' 1 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^OOBE:\s*Finish setting up your device \(SCOOBE\)$' {
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsSpotlightWindowsWelcomeExperience' 1 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Settings app suggestions$' {
                    & $addSetting 'zNTUSER' 'SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsSpotlightOnSettings' 1 0 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338393Enabled' 0 1 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Start menu suggestions$' {
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_IrisRecommendations' 0 1 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Cross-device resume$' {
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\CrossDeviceResume\Configuration' 'IsResumeAllowed' 0 1 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Compatibility telemetry:\s*Application inventory$' {
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\AppCompat' 'DisableInventory' 1 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Compatibility telemetry:\s*Compatibility Appraiser task$' {
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\AppCompat' 'DisableInventory' 1 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Compatibility assistant \(PCA\)$' {
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\AppCompat' 'DisablePCA' 1 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Lock screen app notifications$' {
                    & $addSetting 'zNTUSER' 'SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications' 'NoToastApplicationNotificationOnLockScreen' 1 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Notification center and tray$' {
                    & $addSetting 'zNTUSER' 'SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableNotificationCenter' 1 0 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0 1 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Sync Settings:\s*All settings$' {
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\SettingSync' 'DisableSettingSync' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\SettingSync' 'DisableWindowsSettingSync' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\SettingSync' 'DisableCredentialsSettingSync' 1 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Sync Settings:\s*Credentials$' {
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\SettingSync' 'DisableCredentialsSettingSync' 1 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Sync Settings:\s*(Other Windows settings|Language)$' {
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\SettingSync' 'DisableWindowsSettingSync' 1 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^System cloud configuration downloads$' {
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\DataCollection' 'DisableOneSettingsDownloads' 1 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Edge network prediction$' {
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'NetworkPredictionOptions' 2 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^File Explorer search history$' {
                    & $addSetting 'zNTUSER' 'SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Windows experimentation$' {
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\PreviewBuilds' 'EnableExperimentation' 0 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\PreviewBuilds' 'EnableConfigFlighting' 0 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Microsoft\PolicyManager\default\System\AllowExperimentation' 'value' 0 1 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Disable internet access for Windows DRM$' {
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\WMDRM' 'DisableOnline' 1 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Autocorrect misspelled words$' {
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\TabletTip\1.7' 'EnableAutocorrection' 0 1 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Highlight misspelled words$' {
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\TabletTip\1.7' 'EnableSpellchecking' 0 1 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Display last user name in logon screen$' {
                    & $addSetting 'zSOFTWARE' 'Microsoft\Windows\CurrentVersion\Policies\System' 'DontDisplayLastUserName' 1 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Display locked user name in logon screen$' {
                    & $addSetting 'zSOFTWARE' 'Microsoft\Windows\CurrentVersion\Policies\System' 'DontDisplayLockedUserId' 3 2 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Enforce DCOM hardening changes$' {
                    & $addSetting 'zSOFTWARE' 'Microsoft\Ole\AppCompat' 'RequireIntegrityActivationAuthenticationLevel' 1 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Explorer automatic folder discovery$' {
                    & $addSetting 'zNTUSER' 'SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell' 'FolderType' 'NotSpecified' '' 'String' $hardened
                    $matched = $true
                    break
                }
                '(?i)^NVIDIA Experience Improvement Program$' {
                    & $addSetting 'zSOFTWARE' 'NVIDIA Corporation\NvControlPanel2\Client' 'OptInOrOutPreference' 0 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'NVIDIA Corporation\Global\FTS' 'EnableRID44231' 0 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'NVIDIA Corporation\Global\FTS' 'EnableRID64640' 0 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'NVIDIA Corporation\Global\FTS' 'EnableRID66610' 0 1 'DWord' $hardened
                    & $addSetting 'zSYSTEM' 'ControlSet001\Services\nvlddmkm\Global\Startup' 'SendTelemetryData' 0 1 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^(ShellBags|Clear Explorer folder view history \(ShellBags\)|Remove registry logs of package install locations|Clear package install-location registry logs)$' {
                    # Handled by first-startup cleanup actions.
                    $matched = $true
                    break
                }
                '(?i)^Search:\s*Microsoft Store app results in Start menu$' {
                    # Handled by first-startup runtime actions.
                    $matched = $true
                    break
                }
                '(?i)^(Workplace join prompts|Block Workplace Join Messages)$' {
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WorkplaceJoin' 'BlockAADWorkplaceJoin' 1 0 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Policies\Microsoft\Windows\WorkplaceJoin' 'BlockAADWorkplaceJoin' 1 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Automatic maintenance$' {
                    & $addSetting 'zSOFTWARE' 'Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance' 'MaintenanceDisabled' 1 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Remote Assistance$' {
                    & $addSetting 'zSYSTEM' 'ControlSet001\Control\Remote Assistance' 'fAllowToGetHelp' 0 1 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Windows Error Reporting$' {
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1 0 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)(apps run in the background|background activity)' {
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\AppPrivacy' 'LetAppsRunInBackground' 2 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)(telemetry|diagnostic data|diagnostic and usage|customer experience|sqm|windows feedback|feedback frequency|error reporting)' {
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0 3 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0 3 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 1 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)(activity history|activity feed|timeline|shared experiences)' {
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\System' 'PublishUserActivities' 0 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\System' 'UploadUserActivities' 0 1 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)(wi-?fi sense|hotspots?|hotspot 2\.0)' {
                    & $addSetting 'zSOFTWARE' 'Microsoft\PolicyManager\default\WiFi\AllowWiFiHotSpotReporting' 'value' 0 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Microsoft\PolicyManager\default\WiFi\AllowAutoConnectToWiFiSenseHotspots' 'value' 0 1 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)(bing|web results|cloud search|search highlights|cortana|search history|cloud content search|search - allow cortana|search - cloud content|search - show search highlights)' {
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\Windows Search' 'DisableWebSearch' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\Windows Search' 'ConnectedSearchUseWeb' 0 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\Windows Search' 'EnableDynamicContentInWSB' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'CortanaConsent' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsDeviceSearchHistoryEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsDynamicSearchBoxEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsMSACloudSearchEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsAADCloudSearchEnabled' 0 1 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)(consumer features|sponsored apps|suggested apps|pre-installed apps|pre-installed oem apps|windows tips|welcome experience|suggested content|notifications in the settings app|settings app notifications|settings app suggestions|cloud-optimized content|windows spotlight|recommendations|content delivery|subscribed content|feature management|soft landing experiences|promotional content|ads, suggestions|silent app installation)' {
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1 0 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'ContentDeliveryAllowed' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'FeatureManagementEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SoftLandingEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'OemPreInstalledAppsEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEverEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338393Enabled' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-310093Enabled' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsSpotlightWindowsWelcomeExperience' 1 0 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'RotatingLockScreenEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'RotatingLockScreenOverlayEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_IrisRecommendations' 0 1 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)(show most used apps|track(?:ing)? app launches|app usage tracking|start menu:\s*most used apps|start menu:\s*track app launches)' {
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_TrackProgs' 0 1 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)(show recently used files in quick access|show frequently used folders in quick access|track opened documents|jump lists|quick access frequent folders|quick access recent files)' {
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'ShowRecent' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'ShowFrequent' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_TrackDocs' 0 1 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)(advertising id|ad customization)' {
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1 0 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0 1 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)(language list access for websites|locally relevant content by accessing.*language list)' {
                    & $addSetting 'zNTUSER' 'Control Panel\International\User Profile' 'HttpAcceptLanguageOptOut' 1 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)(location services|disable location|windows location provider|location tracking|location scripting|device sensors)' {
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\LocationAndSensors' 'DisableLocation' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\LocationAndSensors' 'DisableLocationScripting' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\LocationAndSensors' 'DisableWindowsLocationProvider' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\LocationAndSensors' 'DisableSensors' 1 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)(disable onedrive automatic backups|onedrive automatic backups|known folder move)' {
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\OneDrive' 'KFMBlockOptIn' 1 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)(speech|typing|inking|handwriting|input insights|text and handwriting|narrator online services|narrator scripting support|custom inking and typing dictionary|online speech recognition)' {
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1 0 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 1 0 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Narrator\NoRoam' 'OnlineServicesEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Narrator\NoRoam' 'ScriptingEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Input\Settings' 'InsightsEnabled' 0 1 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)(clipboard history|cloud clipboard sync)' {
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Clipboard' 'EnableClipboardHistory' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Clipboard' 'EnableCloudClipboard' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Clipboard' 'CloudClipboardAutomaticUpload' 0 1 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^AI:\s*(Disable actions \(Click to Do\)|Disable Settings agent|Disable Copilot and Recall policies)$' {
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'AllowRecallEnablement' 0 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableClickToDo' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'TurnOffSavingSnapshots' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableSettingsAgent' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableAgentConnectors' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableAgentWorkspaces' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableRemoteAgentConnectors' 1 0 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\Shell\ClickToDo' 'DisableClickToDo' 1 0 'DWord' $hardened
                    # FeatureManagement overrides from RemoveWindowsAI (build-dependent behavior).
                    & $addSetting 'zSYSTEM' 'ControlSet001\Control\FeatureManagement\Overrides\8\1853569164' 'EnabledState' 1 0 'DWord' $hardened
                    & $addSetting 'zSYSTEM' 'ControlSet001\Control\FeatureManagement\Overrides\8\4098520719' 'EnabledState' 1 0 'DWord' $hardened
                    & $addSetting 'zSYSTEM' 'ControlSet001\Control\FeatureManagement\Overrides\8\929719951' 'EnabledState' 1 0 'DWord' $hardened
                    & $addSetting 'zSYSTEM' 'ControlSet001\Control\FeatureManagement\Overrides\8\1646260367' 'EnabledState' 2 0 'DWord' $hardened
                    & $addSetting 'zSYSTEM' 'ControlSet001\Control\FeatureManagement\Overrides\8\2283032206' 'EnabledState' 1 0 'DWord' $hardened
                    & $addSetting 'zSYSTEM' 'ControlSet001\Control\FeatureManagement\Overrides\8\502943886' 'EnabledState' 1 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^AI:\s*Disable voice effects$' {
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\AppPrivacy' 'LetAppsAccessGenerativeAI' 2 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\AppPrivacy' 'LetAppsAccessSystemAIModels' 2 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\generativeAI' 'Value' 'Deny' 'Allow' 'String' $hardened
                    & $addSetting 'zSOFTWARE' 'Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\systemAIModels' 'Value' 'Deny' 'Allow' 'String' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Speech_OneCore\Settings\VoiceActivation\UserPreferenceForAllApps' 'AgentActivationEnabled' 0 1 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^AI:\s*Disable Voice Access$' {
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\VoiceAccess' 'RunningState' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\VoiceAccess' 'TextCorrection' 1 2 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\AccessibilityTemp' '0' 0 1 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Paint:\s*Disable AI image features$' {
                    & $addSetting 'zSOFTWARE' 'Microsoft\Windows\CurrentVersion\Policies\Paint' 'DisableImageCreator' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Microsoft\Windows\CurrentVersion\Policies\Paint' 'DisableCocreator' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Microsoft\Windows\CurrentVersion\Policies\Paint' 'DisableGenerativeFill' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Microsoft\Windows\CurrentVersion\Policies\Paint' 'DisableGenerativeErase' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Microsoft\Windows\CurrentVersion\Policies\Paint' 'DisableRemoveBackground' 1 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Notepad:\s*Disable AI features$' {
                    & $addSetting 'zSOFTWARE' 'Policies\WindowsNotepad' 'DisableAIFeatures' 1 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^AI:\s*Disable Fabric service$' {
                    & $addSetting 'zSYSTEM' 'ControlSet001\Services\WSAIFabricSvc' 'Start' 4 2 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^AI:\s*Prevent Copilot package reinstall$' {
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\Appx\RemoveDefaultMicrosoftStorePackages\Microsoft.Copilot_8wekyb3d8bbwe' 'RemovePackage' 1 0 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\AutoInstalledPWAs' 'CopilotPWAPreinstallCompleted' 1 0 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\AutoInstalledPWAs' 'Microsoft.Copilot_8wekyb3d8bbwe' 1 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^AI:\s*Hide Settings components pages$' {
                    & $addSetting 'zSOFTWARE' 'Microsoft\Windows\CurrentVersion\Policies\Explorer' 'SettingsPageVisibility' 'hide:aicomponents;appactions;' '' 'String' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Office:\s*Disable Copilot and AI features$' {
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\office\16.0\common\ai\training\general' 'disabletraining' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\office\16.0\common\ai\training\specific\adaptivefloatie' 'disabletrainingofadaptivefloatie' 1 0 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'Software\Policies\Microsoft\office\16.0\common\privacy' 'controllerconnectedservicesenabled' 2 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'Software\Policies\Microsoft\office\16.0\common\privacy' 'usercontentdisabled' 2 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'Software\Microsoft\Office\16.0\Word\Options' 'EnableCopilot' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'Software\Microsoft\Office\16.0\Excel\Options' 'EnableCopilot' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'Software\Microsoft\Office\16.0\OneNote\Options\Copilot' 'CopilotEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'Software\Microsoft\Office\16.0\OneNote\Options\Copilot' 'CopilotNotebooksEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'Software\Microsoft\Office\16.0\OneNote\Options\Copilot' 'CopilotSkittleEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\office\16.0\common\ai\contentsafety\general' 'disablecontentsafety' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\office\16.0\common\ai\contentsafety\specific\rewrite' 'disablecontentsafety' 1 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Gaming:\s*Disable Copilot widget$' {
                    # Prefer policy-backed AI/Copilot controls here; WindowsRuntime ActivatableClassId
                    # keys are ACL-protected in many images and frequently fail offline.
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1 0 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'AllowRecallEnablement' 0 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableClickToDo' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'TurnOffSavingSnapshots' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableSettingsAgent' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableAgentConnectors' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableAgentWorkspaces' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableRemoteAgentConnectors' 1 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^Edge:\s*Disable Copilot and AI features$' {
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'CopilotPageContext' 0 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'HubsSidebarEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'EdgeEntraCopilotPageContext' 0 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'EdgeHistoryAISearchEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'ComposeInlineEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'GenAILocalFoundationalModelSettings' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'BuiltInAIAPIsEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'AIGenThemesEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'DevToolsGenAiSettings' 2 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'ShareBrowsingHistoryWithCopilotSearchAllowed' 0 1 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)^AI:\s*(Remove Recall optional feature|Remove Recall scheduled tasks|Remove AI appx packages|Remove AI CBS packages|Remove AI files and folders|Install update cleanup checker task|Install classic Windows apps)$' {
                    # These options are handled by first-startup runtime actions, not offline registry writes.
                    $matched = $true
                    break
                }
                '(?i)^Classic Apps:\s*(Replace Notepad|Replace Paint|Replace Snipping Tool|Replace Photo Viewer|Install Photos Legacy)$' {
                    # Classic-app replacements are runtime actions and currently informational in this builder.
                    $matched = $true
                    break
                }
                '(?i)(copilot|recall)' {
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1 0 'DWord' $hardened
                    & $addSetting 'zNTUSER' 'SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'AllowRecallEnablement' 0 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableClickToDo' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'TurnOffSavingSnapshots' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableSettingsAgent' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableAgentConnectors' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableAgentWorkspaces' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Windows\WindowsAI' 'DisableRemoteAgentConnectors' 1 0 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)(edge tracking prevention|do not track|edge diagnostic|edge search and site suggestions|copilot in edge|edge bing suggestions)' {
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'ConfigureDoNotTrack' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'TrackingPrevention' 3 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'ShowSuggestionsEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'AddressBarTrendingSuggestEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'DiagnosticData' 0 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'CopilotPageContext' 0 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'HubsSidebarEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'EdgeEntraCopilotPageContext' 0 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'EdgeHistoryAISearchEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'ComposeInlineEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'GenAILocalFoundationalModelSettings' 1 0 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'BuiltInAIAPIsEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'AIGenThemesEnabled' 0 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'DevToolsGenAiSettings' 2 1 'DWord' $hardened
                    & $addSetting 'zSOFTWARE' 'Policies\Microsoft\Edge' 'ShareBrowsingHistoryWithCopilotSearchAllowed' 0 1 'DWord' $hardened
                    $matched = $true
                    break
                }
                '(?i)(install classic apps|replace notepad|replace paint|replace snipping tool|replace photo viewer|install photos legacy|remove ai appx packages|remove ai packages in cbs|remove ai files|update cleanup check)' {
                    # These labels are not registry toggles.
                    $matched = $true
                    break
                }
            }

            if ($matched) {
                if ($mappedSeen.Add($label)) { [void]$mappedLabels.Add($label) }
            }
            else {
                if ($unmappedSeen.Add($label)) { [void]$unmappedLabels.Add($label) }
            }
        }

        return [pscustomobject]@{
            Tweaks         = @($resultMap.Values)
            MappedLabels   = @($mappedLabels)
            UnmappedLabels = @($unmappedLabels)
        }
    }

    function RS-StageCustomFile {
        param(
            [string]$SourcePath,
            [string]$TargetDir,
            [string[]]$AllowedExtensions
        )
        if ([string]::IsNullOrWhiteSpace($SourcePath)) { return $null }
        if (-not (Test-Path -LiteralPath $SourcePath)) {
            throw "Custom file not found: $SourcePath"
        }
        $ext = [System.IO.Path]::GetExtension($SourcePath).ToLowerInvariant()
        if ($AllowedExtensions -notcontains $ext) {
            throw "Unsupported custom file extension '$ext' for '$SourcePath'."
        }

        $fileName = [System.IO.Path]::GetFileName($SourcePath)
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
        $destPath = Join-Path $TargetDir $fileName
        $suffix = 1
        while (Test-Path -LiteralPath $destPath) {
            $destPath = Join-Path $TargetDir ("{0}_{1}{2}" -f $stem, $suffix, $ext)
            $suffix++
        }

        Copy-Item -LiteralPath $SourcePath -Destination $destPath -Force
        RS-Log "Added custom file to ISO payload: $destPath" -Color Green
        return $destPath
    }

    function RS-MergeUnattendXml {
        param([string]$BaseXmlText, [string]$CustomXmlPath)

        [xml]$baseDoc = $BaseXmlText
        [xml]$customDoc = Get-Content -Raw -Path $CustomXmlPath

        if ($null -eq $baseDoc.DocumentElement -or $baseDoc.DocumentElement.LocalName -ne 'unattend') {
            throw "Base generated unattend XML is invalid."
        }
        if ($null -eq $customDoc.DocumentElement -or $customDoc.DocumentElement.LocalName -ne 'unattend') {
            throw "Custom file is not a valid unattend/autounattend XML."
        }

        $nsUri = $baseDoc.DocumentElement.NamespaceURI
        if ([string]::IsNullOrWhiteSpace($nsUri)) {
            $nsUri = 'urn:schemas-microsoft-com:unattend'
        }

        $nsBase = New-Object System.Xml.XmlNamespaceManager($baseDoc.NameTable)
        $nsBase.AddNamespace('u', $nsUri)
        $nsCustom = New-Object System.Xml.XmlNamespaceManager($customDoc.NameTable)
        $nsCustom.AddNamespace('u', $nsUri)

        $baseRoot = $baseDoc.SelectSingleNode('/u:unattend', $nsBase)
        $customSettingsNodes = @($customDoc.SelectNodes('/u:unattend/u:settings', $nsCustom))
        if ($customSettingsNodes.Count -eq 0) {
            $customSettingsNodes = @($customDoc.SelectNodes('/unattend/settings'))
        }
        foreach ($customSettingsNode in $customSettingsNodes) {
            if ($null -eq $customSettingsNode) { continue }
            $passName = $customSettingsNode.GetAttribute('pass')
            if ([string]::IsNullOrWhiteSpace($passName)) { continue }

            $baseSettingsNode = $baseDoc.SelectSingleNode("/u:unattend/u:settings[@pass='$passName']", $nsBase)
            if ($null -eq $baseSettingsNode) {
                $baseSettingsNode = $baseDoc.CreateElement('settings', $nsUri)
                $baseSettingsNode.SetAttribute('pass', $passName)
                [void]$baseRoot.AppendChild($baseSettingsNode)
            }

            $customComponents = @($customSettingsNode.SelectNodes('u:component', $nsCustom))
            if ($customComponents.Count -eq 0) {
                $customComponents = @($customSettingsNode.SelectNodes('component'))
            }
            foreach ($customComp in $customComponents) {
                if ($null -eq $customComp) { continue }
                $compName = $customComp.GetAttribute('name')
                $compArch = $customComp.GetAttribute('processorArchitecture')
                if ([string]::IsNullOrWhiteSpace($compName)) { continue }

                $existingComp = $null
                foreach ($candidate in @($baseSettingsNode.SelectNodes('u:component', $nsBase))) {
                    if ($candidate.GetAttribute('name') -ne $compName) { continue }
                    if (-not [string]::IsNullOrWhiteSpace($compArch) -and
                        $candidate.GetAttribute('processorArchitecture') -ne $compArch) { continue }
                    $existingComp = $candidate
                    break
                }
                if ($null -ne $existingComp) { [void]$baseSettingsNode.RemoveChild($existingComp) }

                $importedComp = $baseDoc.ImportNode($customComp, $true)
                [void]$baseSettingsNode.AppendChild($importedComp)
            }
        }

        foreach ($customTop in @($customDoc.DocumentElement.ChildNodes)) {
            if ($customTop.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
            if ($customTop.LocalName -eq 'settings') { continue }

            $toRemove = @()
            foreach ($baseTop in @($baseDoc.DocumentElement.ChildNodes)) {
                if ($baseTop.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
                if ($baseTop.LocalName -eq $customTop.LocalName -and
                    $baseTop.NamespaceURI -eq $customTop.NamespaceURI) {
                    $toRemove += $baseTop
                }
            }
            foreach ($node in $toRemove) { [void]$baseDoc.DocumentElement.RemoveChild($node) }

            $importedTop = $baseDoc.ImportNode($customTop, $true)
            [void]$baseDoc.DocumentElement.AppendChild($importedTop)
        }

        $writerSettings = New-Object System.Xml.XmlWriterSettings
        $writerSettings.Indent = $true
        $writerSettings.OmitXmlDeclaration = $false
        $sw = New-Object System.IO.StringWriter
        $xw = [System.Xml.XmlWriter]::Create($sw, $writerSettings)
        $baseDoc.Save($xw)
        $xw.Flush()
        $xw.Dispose()
        return $sw.ToString()
    }

    function RS-GetArchDisplay {
        param([object]$ArchitectureCode)
        $code = [string]$ArchitectureCode
        switch ($code) {
            '0' { 'x86' }
            '5' { 'ARM' }
            '6' { 'Itanium' }
            '9' { 'x64 (AMD64)' }
            '12' { 'ARM64' }
            default { "Unknown ($code)" }
        }
    }

    function RS-NormalizeLangCode {
        param([string]$Code)
        if ([string]::IsNullOrWhiteSpace($Code)) { return $null }
        $text = [string]$Code
        $match = [regex]::Match($text, '(?i)\b([a-z]{2})-([a-z]{2})\b')
        if (-not $match.Success) { return $null }
        return ("{0}-{1}" -f $match.Groups[1].Value.ToLowerInvariant(), $match.Groups[2].Value.ToUpperInvariant())
    }

    function RS-ResolveInstallerLanguageCode {
        param(
            [bool]$SingleLanguageInstaller,
            [string]$InstallerLanguageRaw,
            [string]$FallbackCode = 'en-US'
        )

        $fallback = RS-NormalizeLangCode -Code $FallbackCode
        if ([string]::IsNullOrWhiteSpace($fallback)) { $fallback = 'en-US' }

        if ($SingleLanguageInstaller -and -not [string]::IsNullOrWhiteSpace($InstallerLanguageRaw) -and $InstallerLanguageRaw -ne 'System Default') {
            $resolved = RS-NormalizeLangCode -Code $InstallerLanguageRaw
            if (-not [string]::IsNullOrWhiteSpace($resolved)) { return $resolved }
            return $fallback
        }
        return $null
    }

    function RS-ResolveOscdimgPath {
        $cmd = Get-Command oscdimg.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
            return [string]$cmd.Source
        }

        $adkPaths = @(
            'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe',
            'C:\Program Files\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'
        )
        $scriptToolPaths = [System.Collections.Generic.List[string]]::new()
        if (-not [string]::IsNullOrWhiteSpace([string]$PSScriptRoot)) {
            [void]$scriptToolPaths.Add((Join-Path $PSScriptRoot 'tools\oscdimg.exe'))
            [void]$scriptToolPaths.Add((Join-Path $PSScriptRoot 'oscdimg.exe'))
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$PSCommandPath)) {
            $scriptDir = Split-Path -Parent $PSCommandPath
            if (-not [string]::IsNullOrWhiteSpace([string]$scriptDir)) {
                [void]$scriptToolPaths.Add((Join-Path $scriptDir 'tools\oscdimg.exe'))
                [void]$scriptToolPaths.Add((Join-Path $scriptDir 'oscdimg.exe'))
            }
        }
        $cachedPath = Join-Path (Join-Path $env:TEMP 'OximizeOS\Tools\Oscdimg') 'oscdimg.exe'
        $tempPath = Join-Path $env:TEMP 'oscdimg.exe'
        $localCandidates = @($adkPaths + @($scriptToolPaths | Select-Object -Unique) + @($cachedPath, $tempPath))
        foreach ($candidate in @($localCandidates)) {
            if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return [string]$candidate }
        }
        return $null
    }

    function RS-EnsureOscdimg {
        param(
            [bool]$AllowBootstrapInPhase1 = $false
        )

        $resolved = RS-ResolveOscdimgPath
        if (-not [string]::IsNullOrWhiteSpace($resolved)) { return $resolved }

        if (-not $AllowBootstrapInPhase1) {
            RS-Log "oscdimg.exe was not found locally. First-time bootstrap will be attempted in Phase 1 (official Microsoft ADK source)." -Color Yellow
            return $null
        }

        $bootstrapRoot = Join-Path $env:TEMP 'OximizeOS\Tools\ADK'
        $bootstrapInstaller = Join-Path $bootstrapRoot 'adksetup.exe'
        $bootstrapUrl = 'https://go.microsoft.com/fwlink/?linkid=2289980'
        $bootstrapAttempts = 2
        $retryDelaySeconds = 8

        New-Item -ItemType Directory -Path $bootstrapRoot -Force | Out-Null
        for ($attempt = 1; $attempt -le $bootstrapAttempts; $attempt++) {
            try {
                if (-not (Test-Path -LiteralPath $bootstrapInstaller -PathType Leaf) -or ((Get-Item -LiteralPath $bootstrapInstaller -ErrorAction SilentlyContinue).Length -lt 1024000)) {
                    RS-Log ("Phase 1: Downloading ADK installer from Microsoft ({0}/{1})..." -f $attempt, $bootstrapAttempts) -Color Yellow
                    Invoke-WebRequest -Uri $bootstrapUrl -OutFile $bootstrapInstaller -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop | Out-Null
                }

                $adkArgs = @('/quiet', '/norestart', '/features', 'OptionId.DeploymentTools')
                RS-Log ("Phase 1: Installing ADK Deployment Tools ({0}/{1})..." -f $attempt, $bootstrapAttempts) -Color Yellow
                $proc = Start-Process -FilePath $bootstrapInstaller -ArgumentList $adkArgs -PassThru -Wait -WindowStyle Hidden -ErrorAction Stop
                $exitCode = if ($null -ne $proc) { [int]$proc.ExitCode } else { -1 }
                if ($exitCode -notin @(0, 3010)) {
                    throw "adksetup.exe exited with code $exitCode"
                }

                $resolved = RS-ResolveOscdimgPath
                if (-not [string]::IsNullOrWhiteSpace($resolved) -and (Test-Path -LiteralPath $resolved -PathType Leaf)) {
                    RS-Log ("Phase 1: oscdimg bootstrap succeeded -> {0}" -f $resolved) -Color Green
                    return $resolved
                }

                throw "ADK install completed, but oscdimg.exe was still not found."
            }
            catch {
                RS-Log ("Phase 1: ADK bootstrap attempt {0}/{1} failed: {2}" -f $attempt, $bootstrapAttempts, $_) -Color Yellow
                if ($attempt -lt $bootstrapAttempts) {
                    RS-Log ("Phase 1: Retrying in {0} seconds..." -f $retryDelaySeconds) -Color Yellow
                    Start-Sleep -Seconds $retryDelaySeconds
                }
            }
        }

        RS-Log "Install Windows ADK Deployment Tools from Microsoft: https://learn.microsoft.com/windows-hardware/get-started/adk-install" -Color Yellow
        RS-Log "Alternative: place oscdimg.exe next to this script or in .\\tools\\oscdimg.exe." -Color Yellow
        return $null
    }

    function RS-ExtractLanguageCodeFromText {
        param([string]$Text)
        if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
        $match = [regex]::Match([string]$Text, '(?i)(?:~|\b)([a-z]{2}-[a-z]{2})(?:~|\b)')
        if (-not $match.Success) { return $null }
        return (RS-NormalizeLangCode -Code $match.Groups[1].Value)
    }
    #endregion

    try {
        # Collect UI selections before doing anything else (must happen on UI thread or read from sync)
        $srcISO = $sync['Source ISO']
        $outISO = $sync['Output Folder']
        $scrDir = $sync.ScratchDir
        $scratchMarkerName = [string]$sync.ScratchMarkerFileName
        if ([string]::IsNullOrWhiteSpace($scratchMarkerName)) { $scratchMarkerName = '.oximize_scratch.marker' }
        $customUnattendPath = $sync.CustomUnattendXml
        $customRegFiles = $sync.CustomRegFiles
        $customBatFiles = $sync.CustomBatFiles
        $driverSourceDir = [string]$sync.DriverSourceDir
        $injectInstallDrivers = [bool]$sync.InjectDriversInstallWim
        $driverRecurse = [bool]$sync.DriverInjectRecurse
        $fastMode = [bool]$sync.FastMode
        $skipPostUnmountVerify = if ($null -ne $sync.SkipPostUnmountVerify) { [bool]$sync.SkipPostUnmountVerify } else { $true }
        $wimCompression = [string]$sync.WimCompression
        if ([string]::IsNullOrWhiteSpace($wimCompression)) {
            $wimCompression = 'Fast'
        }
        if ($wimCompression -notin @('None', 'Fast', 'Max')) {
            $wimCompression = 'Fast'
        }
        $useIntegrityChecks = if ($null -ne $sync.UseIntegrityChecks) { [bool]$sync.UseIntegrityChecks } else { $false }
        $securityPreset = [string]$sync.SecurityPreset
        if ([string]::IsNullOrWhiteSpace($securityPreset)) { $securityPreset = 'Balanced' }
        $singleLanguageInstaller = [bool]$sync.SingleLanguageInstaller
        $installerLanguageRaw = [string]$sync.InstallerLanguage
        $installerLangCode = RS-ResolveInstallerLanguageCode -SingleLanguageInstaller $singleLanguageInstaller -InstallerLanguageRaw $installerLanguageRaw -FallbackCode 'en-US'
        $localAccountName = 'OximizeUser'
        $localAccountPassword = ''
        $localAccountAutoLogin = $false
        $oscdimgResolved = $null
        $exKeys = $sync.ExpeditedKeys
        $registryHiveMountKeys = @(
            'HKLM\zCOMPONENTS',
            'HKLM\zDEFAULT',
            'HKLM\zNTUSER',
            'HKLM\zSOFTWARE',
            'HKLM\zSYSTEM'
        )
        $scriptBuildStamp = [string]$sync.ScriptBuildStamp
        if (-not [string]::IsNullOrWhiteSpace($scriptBuildStamp)) {
            RS-Log ("Pipeline script build: {0}" -f $scriptBuildStamp) -Color Cyan
        }

        # Harvest checkbox selections via form Invoke
        $checkedAppx = $sync.Form.Invoke([System.Func[object]] {
                $list = @()
                $allPkg = $sync.AppxDef
                $boxes = $sync.AppxBoxes
                $max = [Math]::Min($boxes.Count, $allPkg.Count)
                for ($i = 0; $i -lt $max; $i++) {
                    if ($boxes[$i].Checked) { $list += $allPkg[$i] }
                }
                return , $list
            })
        if ($sync.AppxSelectionExpansions -and $sync.AppxSelectionExpansions.Count -gt 0) {
            $expandedAppx = [System.Collections.Generic.List[string]]::new()
            $expandedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($pkg in @($checkedAppx)) {
                $pkgId = [string]$pkg
                if ([string]::IsNullOrWhiteSpace($pkgId)) { continue }
                if ($expandedSet.Add($pkgId)) { [void]$expandedAppx.Add($pkgId) }
                if ($sync.AppxSelectionExpansions.ContainsKey($pkgId)) {
                    foreach ($memberId in @($sync.AppxSelectionExpansions[$pkgId])) {
                        $memberKey = [string]$memberId
                        if ([string]::IsNullOrWhiteSpace($memberKey)) { continue }
                        if ($expandedSet.Add($memberKey)) { [void]$expandedAppx.Add($memberKey) }
                    }
                }
            }
            $checkedAppx = @($expandedAppx)
        }
        $runtimeAppActionIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($runtimeId in @(
                'Runtime.Remove.MicrosoftEdge.System',
                'Runtime.Remove.MicrosoftEdge.WebView2',
                'Runtime.Remove.MicrosoftEdge.Shortcuts'
            )) {
            [void]$runtimeAppActionIds.Add([string]$runtimeId)
        }
        $checkedRuntimeAppActions = [System.Collections.Generic.List[string]]::new()
        $checkedAppxProvisioned = [System.Collections.Generic.List[string]]::new()
        foreach ($pkg in @($checkedAppx)) {
            $pkgId = [string]$pkg
            if ([string]::IsNullOrWhiteSpace($pkgId)) { continue }
            if ($runtimeAppActionIds.Contains($pkgId)) {
                [void]$checkedRuntimeAppActions.Add($pkgId)
            }
            else {
                [void]$checkedAppxProvisioned.Add($pkgId)
            }
        }
        $checkedRuntimeAppActions = @($checkedRuntimeAppActions | Select-Object -Unique)
        $checkedAppxProvisioned = @($checkedAppxProvisioned | Select-Object -Unique)
        $checkedFeats = $sync.Form.Invoke([System.Func[object]] {
                $config = [ordered]@{}
                $allF = $sync.FeatDef
                $combos = $sync.FeaturesBoxes
                $max = [Math]::Min($combos.Count, $allF.Count)
                for ($i = 0; $i -lt $max; $i++) {
                    $val = $combos[$i].Text
                    if ($val -ne 'Default') {
                        $fid = [string]$allF[$i].Id
                        # UI-only optional entries should not be sent to DISM feature/capability handlers.
                        if ($fid -like 'custom.optionalfeature.*') { continue }
                        $config[$fid] = $val
                    }
                }
                return $config
            })
        $taskConfig = $sync.Form.Invoke([System.Func[object]] {
                $config = @{}
                $allT = $sync.TasksAllDef
                $combos = $sync.TasksBoxes
                $max = [Math]::Min($combos.Count, $allT.Count)
                for ($i = 0; $i -lt $max; $i++) {
                    $val = [string]$combos[$i].SelectedItem
                    if ($val -ne 'Default') { $config[$allT[$i]] = $val }
                }
                return $config
            })
        $serviceConfig = $sync.Form.Invoke([System.Func[object]] {
                $config = @{}
                $allS = $sync.ServDef
                $boxes = $sync.ServicesBoxes
                $max = [Math]::Min($boxes.Count, $allS.Count)
                for ($i = 0; $i -lt $max; $i++) {
                    $val = $boxes[$i].Text
                    if ($val -in @('Disabled', 'Manual')) { $config[$allS[$i]] = $val }
                }
                return $config
            })
        $checkedReg = @()
        $privacyConfig = $sync.Form.Invoke([System.Func[object]] {
                $config = [ordered]@{}
                $allP = $sync.PrivacyDef
                $combos = $sync.PrivacyBoxes
                $max = [Math]::Min($combos.Count, $allP.Count)
                for ($i = 0; $i -lt $max; $i++) {
                    $val = [string]$combos[$i].Text
                    if ($val -in @('Enabled', 'Disabled')) { $config[$allP[$i]] = $val }
                }
                return $config
            })
        $extraSecurityConfig = $sync.Form.Invoke([System.Func[object]] {
                $config = [ordered]@{}
                $allX = $sync.ExtraSecurityDef
                $combos = $sync.ExtraSecurityBoxes
                $max = [Math]::Min($combos.Count, $allX.Count)
                for ($i = 0; $i -lt $max; $i++) {
                    $val = [string]$combos[$i].Text
                    if ($val -in @('Enabled', 'Disabled')) { $config[$allX[$i]] = $val }
                }
                return $config
            })
        $advancedOptionsConfig = $sync.Form.Invoke([System.Func[object]] {
                $config = [ordered]@{}
                $allA = $sync.AdvancedOptionsDef
                $combos = $sync.AdvancedOptionsBoxes
                $max = [Math]::Min($combos.Count, $allA.Count)
                for ($i = 0; $i -lt $max; $i++) {
                    $val = [string]$combos[$i].Text
                    if ($val -in @('Enabled', 'Disabled')) { $config[$allA[$i]] = $val }
                }
                return $config
            })

        $advancedOptionsByLabel = [ordered]@{}
        foreach ($aEntry in $advancedOptionsConfig.GetEnumerator()) {
            $optId = [string]$aEntry.Key
            $optLabel = if ($sync.AdvancedOptionsLabelById -and $sync.AdvancedOptionsLabelById.ContainsKey($optId)) {
                [string]$sync.AdvancedOptionsLabelById[$optId]
            }
            else {
                $optId
            }
            $advancedOptionsByLabel[$optLabel] = [string]$aEntry.Value
        }
        $extraSecurityByLabel = [ordered]@{}
        foreach ($xEntry in $extraSecurityConfig.GetEnumerator()) {
            $optId = [string]$xEntry.Key
            $optLabel = if ($sync.ExtraSecurityLabelById -and $sync.ExtraSecurityLabelById.ContainsKey($optId)) {
                [string]$sync.ExtraSecurityLabelById[$optId]
            }
            else {
                $optId
            }
            $extraSecurityByLabel[$optLabel] = [string]$xEntry.Value
        }

        # Resolve Advanced Setup selections using current labels while keeping import compatibility.
        $getAdvancedOptionModeByLabelPattern = {
            param(
                [System.Collections.IDictionary]$LabelMap,
                [string[]]$Patterns,
                [string]$DefaultValue
            )
            if ($null -eq $LabelMap) { return $DefaultValue }
            foreach ($entry in $LabelMap.GetEnumerator()) {
                $labelText = [string]$entry.Key
                foreach ($pattern in @($Patterns)) {
                    if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
                    if ($labelText -match $pattern) {
                        return [string]$entry.Value
                    }
                }
            }
            return $DefaultValue
        }.GetNewClosure()

        $autoLoggersMode = & $getAdvancedOptionModeByLabelPattern $advancedOptionsByLabel @(
            '(?i)^Diagnostics - ETW AutoLogger sessions$',
            '(?i)^ETW AutoLogger sessions$',
            '(?i)^Auto loggers$'
        ) 'Disabled'

        $eventViewerMode = & $getAdvancedOptionModeByLabelPattern $advancedOptionsByLabel @(
            '(?i)^Logging - Windows Event Log service$',
            '(?i)^Windows Event Log service$',
            '(?i)^Event viewer$'
        ) 'Default'

        $languagePayloadTrimMode = & $getAdvancedOptionModeByLabelPattern $advancedOptionsByLabel @(
            '(?i)^Media - Trim language and capability payloads$',
            '(?i)^Remove more language/capability payloads$'
        ) 'Disabled'

        $widgetsMode = & $getAdvancedOptionModeByLabelPattern $advancedOptionsByLabel @(
            '(?i)^UI - Windows Widgets$',
            '(?i)^Windows Widgets$'
        ) 'Default'
        $appSuggestionsMode = & $getAdvancedOptionModeByLabelPattern $advancedOptionsByLabel @(
            '(?i)^UX - App suggestions \(Content Delivery Manager\)$',
            '(?i)^App suggestions \(Content Delivery Manager\)$'
        ) 'Default'
        $detailedBsodMode = & $getAdvancedOptionModeByLabelPattern $advancedOptionsByLabel @(
            '(?i)^Troubleshooting - Detailed BSOD information$',
            '(?i)^Detailed BSOD information$'
        ) 'Default'
        $showExtensionsMode = & $getAdvancedOptionModeByLabelPattern $advancedOptionsByLabel @(
            '(?i)^Explorer - Show file name extensions$',
            '(?i)^Show file name extensions$'
        ) 'Default'
        $startRecommendationsMode = & $getAdvancedOptionModeByLabelPattern $advancedOptionsByLabel @(
            '(?i)^Start - Recommendations in Start Menu$',
            '(?i)^Recommendations in Start Menu$',
            '(?i)^Start menu suggestions$'
        ) 'Default'
        $settingsHomeMode = & $getAdvancedOptionModeByLabelPattern $advancedOptionsByLabel @(
            '(?i)^Settings - Remove Home page$',
            '(?i)^Remove Settings Home Page$'
        ) 'Default'
        $settingsInsiderProgramMode = & $getAdvancedOptionModeByLabelPattern $advancedOptionsByLabel @(
            '(?i)^Settings - Hide Windows Insider Program page$',
            '(?i)^Remove Windows Insider program in settings$',
            '(?i)^Hide Windows Insider Program in Settings$'
        ) 'Default'
        $settingsDevelopersPageMode = & $getAdvancedOptionModeByLabelPattern $advancedOptionsByLabel @(
            '(?i)^Settings - Hide For developers page$',
            '(?i)^Hide For developers page$',
            '(?i)^Remove For developers page$'
        ) 'Default'
        $settingsAtlasPagesMode = & $getAdvancedOptionModeByLabelPattern $advancedOptionsByLabel @(
            '(?i)^Settings - Hide Atlas recommended pages$',
            '(?i)^Hide Atlas recommended settings pages$',
            '(?i)^Atlas hidden settings pages$'
        ) 'Default'
        $removeGalleryMode = & $getAdvancedOptionModeByLabelPattern $advancedOptionsByLabel @(
            '(?i)^Explorer - Remove Gallery from navigation pane$',
            '(?i)^Remove Gallery from explorer$'
        ) 'Default'
        $removeExplorerHomeMode = & $getAdvancedOptionModeByLabelPattern $advancedOptionsByLabel @(
            '(?i)^Explorer - Remove Home from navigation pane$',
            '(?i)^Remove Home from Explorer$'
        ) 'Default'
        $preventDeviceEncryptionMode = & $getAdvancedOptionModeByLabelPattern $advancedOptionsByLabel @(
            '(?i)^Encryption - Device encryption automatic enablement$',
            '(?i)^Prevent automatic device encryption$'
        ) 'Default'
        $coreIsolationMode = & $getAdvancedOptionModeByLabelPattern $advancedOptionsByLabel @(
            '(?i)^Security - Core isolation \(Memory integrity / VBS\)$',
            '(?i)^Core isolation \(Memory integrity / VBS\)$'
        ) 'Default'
        $wpbtMode = & $getAdvancedOptionModeByLabelPattern $advancedOptionsByLabel @(
            '(?i)^Security - Disable WPBT execution \(Beta\)$',
            '(?i)^Disable Windows Platform Binary Table \(WPBT\) execution \(Beta\)$'
        ) 'Default'
        $stickyKeysMode = & $getAdvancedOptionModeByLabelPattern $advancedOptionsByLabel @(
            '(?i)^Accessibility - Sticky Keys shortcut$',
            '(?i)^Disable Sticky Keys shortcut$'
        ) 'Default'
        $bypassHwChecksMode = & $getAdvancedOptionModeByLabelPattern $advancedOptionsByLabel @(
            '(?i)^Setup - Bypass Windows 11 TPM/Secure Boot checks$',
            '(?i)^Bypass Windows 11 hardware requirement checks \(TPM, Secure Boot\)$'
        ) 'Default'
        $allowOfflineSetupMode = & $getAdvancedOptionModeByLabelPattern $advancedOptionsByLabel @(
            '(?i)^OOBE - Allow setup without internet$',
            '(?i)^Allow Windows 11 setup without internet$'
        ) 'Default'
        $removeMsaOobeMode = & $getAdvancedOptionModeByLabelPattern $advancedOptionsByLabel @(
            '(?i)^OOBE - Remove Microsoft account requirement$',
            '(?i)^Remove Microsoft account requirement \(OOBE\)$'
        ) 'Default'
        $bitlockerAutoMode = & $getAdvancedOptionModeByLabelPattern $advancedOptionsByLabel @(
            '(?i)^Encryption - BitLocker automatic device encryption$',
            '(?i)^Disable BitLocker automatic device encryption$'
        ) 'Default'
        $hidePowerShellSetupMode = & $getAdvancedOptionModeByLabelPattern $advancedOptionsByLabel @(
            '(?i)^Setup - Hide PowerShell windows$',
            '(?i)^Hide PowerShell windows during setup$'
        ) 'Default'
        $disableSystemProtectionMode = & $getAdvancedOptionModeByLabelPattern $advancedOptionsByLabel @(
            '(?i)^Recovery - System Restore$',
            '(?i)^Disable System Protection \(System Restore\)$'
        ) 'Default'
        $psExecutionPolicyMode = & $getAdvancedOptionModeByLabelPattern $advancedOptionsByLabel @(
            '(?i)^PowerShell - Execution policy \(RemoteSigned\)$',
            '(?i)^PowerShell script execution policy \(RemoteSigned\)$'
        ) 'Default'
        $deleteWindowsOldMode = & $getAdvancedOptionModeByLabelPattern $advancedOptionsByLabel @(
            '(?i)^Cleanup - Remove empty C:\\Windows.old folder$',
            '(?i)^Delete empty C:\\Windows.old folder$'
        ) 'Default'
        $edgeUninstallBetaMode = & $getAdvancedOptionModeByLabelPattern $advancedOptionsByLabel @(
            '(?i)^Edge - Allow Microsoft Edge uninstall \(Beta\)$',
            '(?i)^Allow Microsoft Edge uninstall \(Beta\)$'
        ) 'Default'

        # Advanced option execution flags
        $advancedBypassHwChecks = ($bypassHwChecksMode -eq 'Enabled')
        $advancedAllowOfflineSetup = if ($allowOfflineSetupMode -in @('Enabled', 'Disabled')) { $allowOfflineSetupMode -eq 'Enabled' } else { $false }
        $advancedRemoveMsaOobe = if ($removeMsaOobeMode -in @('Enabled', 'Disabled')) { $removeMsaOobeMode -eq 'Enabled' } else { $false }
        $advancedHidePowerShellSetup = if ($hidePowerShellSetupMode -in @('Enabled', 'Disabled')) { $hidePowerShellSetupMode -eq 'Enabled' } else { $false }
        $setupPowerShellWindowStyleArg = if ($advancedHidePowerShellSetup) { '-WindowStyle Hidden ' } else { '' }

        $advancedRegTweaks = [System.Collections.Generic.List[object[]]]::new()
        $addAdvancedReg = {
            param([string]$Hive, [string]$KeyPath, [string]$ValueName, [object]$ValueData, [string]$ValueType = 'DWord')
            [void]$advancedRegTweaks.Add(@($Hive, $KeyPath, $ValueName, $ValueData, $ValueType))
        }.GetNewClosure()

        if ($autoLoggersMode -in @('Enabled', 'Disabled')) {
            $autoLoggerOfflineStart = if ($autoLoggersMode -eq 'Enabled') { 1 } else { 0 }
            foreach ($loggerName in @($AutoLoggersForceDisabled)) {
                if ([string]::IsNullOrWhiteSpace([string]$loggerName)) { continue }
                & $addAdvancedReg 'zSYSTEM' ("ControlSet001\Control\WMI\Autologger\{0}" -f [string]$loggerName) 'Start' $autoLoggerOfflineStart 'DWord'
            }
        }
        if ($eventViewerMode -in @('Enabled', 'Disabled')) {
            & $addAdvancedReg 'zSYSTEM' 'ControlSet001\Services\EventLog' 'Start' $(if ($eventViewerMode -eq 'Enabled') { 2 } else { 4 }) 'DWord'
        }
        if ($widgetsMode -in @('Enabled', 'Disabled')) {
            $widgetsOff = ($widgetsMode -eq 'Disabled')
            & $addAdvancedReg 'zSOFTWARE' 'Policies\Microsoft\Dsh' 'AllowNewsAndInterests' $(if ($widgetsOff) { 0 } else { 1 }) 'DWord'
            # Apply TaskbarDa at first startup (HKCU live context). Offline Default User hive
            # writes can be ACL-protected on some builds and cause avoidable access-denied noise.
        }
        if ($appSuggestionsMode -in @('Enabled', 'Disabled')) {
            $blockSuggestions = ($appSuggestionsMode -eq 'Disabled')
            & $addAdvancedReg 'zSOFTWARE' 'Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' $(if ($blockSuggestions) { 1 } else { 0 }) 'DWord'
            & $addAdvancedReg 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'ContentDeliveryAllowed' $(if ($blockSuggestions) { 0 } else { 1 }) 'DWord'
            & $addAdvancedReg 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' $(if ($blockSuggestions) { 0 } else { 1 }) 'DWord'
            & $addAdvancedReg 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEnabled' $(if ($blockSuggestions) { 0 } else { 1 }) 'DWord'
        }
        if ($detailedBsodMode -in @('Enabled', 'Disabled')) {
            & $addAdvancedReg 'zSYSTEM' 'ControlSet001\Control\CrashControl' 'DisplayParameters' $(if ($detailedBsodMode -eq 'Enabled') { 1 } else { 0 }) 'DWord'
        }
        if ($showExtensionsMode -in @('Enabled', 'Disabled')) {
            & $addAdvancedReg 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' $(if ($showExtensionsMode -eq 'Enabled') { 0 } else { 1 }) 'DWord'
        }
        if ($startRecommendationsMode -in @('Enabled', 'Disabled')) {
            $hideRecommendations = ($startRecommendationsMode -eq 'Disabled')
            & $addAdvancedReg 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_IrisRecommendations' $(if ($hideRecommendations) { 0 } else { 1 }) 'DWord'
            & $addAdvancedReg 'zSOFTWARE' 'Policies\Microsoft\Windows\Explorer' 'HideRecommendedSection' $(if ($hideRecommendations) { 1 } else { 0 }) 'DWord'
            & $addAdvancedReg 'zNTUSER' 'SOFTWARE\Policies\Microsoft\Windows\Explorer' 'HideRecommendedSection' $(if ($hideRecommendations) { 1 } else { 0 }) 'DWord'
            & $addAdvancedReg 'zSOFTWARE' 'Microsoft\PolicyManager\current\device\Start' 'HideRecommendedSection' $(if ($hideRecommendations) { 1 } else { 0 }) 'DWord'
        }

        $settingsPagesToHide = [System.Collections.Generic.List[string]]::new()
        if ($settingsHomeMode -eq 'Enabled') {
            [void]$settingsPagesToHide.Add('home')
        }
        if ($settingsInsiderProgramMode -eq 'Enabled') {
            # page identifiers are based on ms-settings URIs without the prefix.
            [void]$settingsPagesToHide.Add('windowsinsider')
            [void]$settingsPagesToHide.Add('windowsinsider-optin')
        }
        if ($settingsDevelopersPageMode -eq 'Enabled') {
            [void]$settingsPagesToHide.Add('developers')
        }
        if ($settingsAtlasPagesMode -eq 'Enabled') {
            foreach ($atlasPageId in @(
                    'recovery',
                    'maps',
                    'maps-downloadmaps',
                    'privacy',
                    'privacy-feedback',
                    'privacy-activityhistory',
                    'search-permissions',
                    'privacy-general',
                    'sync',
                    'mobile-devices',
                    'mobile-devices-addphone',
                    'workplace',
                    'family-group',
                    'deviceusage',
                    'home'
                )) {
                [void]$settingsPagesToHide.Add($atlasPageId)
            }
        }
        $settingsVisibilityPages = @($settingsPagesToHide | Select-Object -Unique)
        if ($settingsVisibilityPages.Count -gt 0) {
            & $addAdvancedReg 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'SettingsPageVisibility' ("hide:{0}" -f ($settingsVisibilityPages -join ';')) 'String'
        }
        if ($settingsInsiderProgramMode -in @('Enabled', 'Disabled')) {
            & $addAdvancedReg 'zSOFTWARE' 'Microsoft\WindowsSelfHost\UI\Visibility' 'HideInsiderPage' $(if ($settingsInsiderProgramMode -eq 'Enabled') { 1 } else { 0 }) 'DWord'
        }
        $deviceEncryptionExplicit = ($preventDeviceEncryptionMode -in @('Enabled', 'Disabled')) -or ($bitlockerAutoMode -in @('Enabled', 'Disabled'))
        if ($deviceEncryptionExplicit) {
            $blockDeviceEncryption = (($preventDeviceEncryptionMode -eq 'Enabled') -or ($bitlockerAutoMode -eq 'Disabled'))
            & $addAdvancedReg 'zSOFTWARE' 'Policies\Microsoft\FVE' 'DisableAutomaticDeviceEncryption' $(if ($blockDeviceEncryption) { 1 } else { 0 }) 'DWord'
            & $addAdvancedReg 'zSYSTEM' 'ControlSet001\Control\BitLocker' 'PreventDeviceEncryption' $(if ($blockDeviceEncryption) { 1 } else { 0 }) 'DWord'
        }
        if ($coreIsolationMode -in @('Enabled', 'Disabled')) {
            $disableVbs = ($coreIsolationMode -eq 'Disabled')
            & $addAdvancedReg 'zSYSTEM' 'ControlSet001\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' $(if ($disableVbs) { 0 } else { 1 }) 'DWord'
            & $addAdvancedReg 'zSYSTEM' 'ControlSet001\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' $(if ($disableVbs) { 0 } else { 1 }) 'DWord'
            & $addAdvancedReg 'zSYSTEM' 'ControlSet001\Control\Lsa' 'LsaCfgFlags' $(if ($disableVbs) { 0 } else { 1 }) 'DWord'
        }
        if ($wpbtMode -in @('Enabled', 'Disabled')) {
            & $addAdvancedReg 'zSYSTEM' 'ControlSet001\Control\Session Manager' 'DisableWpbtExecution' $(if ($wpbtMode -eq 'Disabled') { 1 } else { 0 }) 'DWord'
        }
        if ($stickyKeysMode -in @('Enabled', 'Disabled')) {
            & $addAdvancedReg 'zNTUSER' 'Control Panel\Accessibility\StickyKeys' 'Flags' $(if ($stickyKeysMode -eq 'Disabled') { '506' } else { '510' }) 'String'
        }

        $restoreSettingsPageVisibility = (($settingsHomeMode -eq 'Disabled') -or ($settingsInsiderProgramMode -eq 'Disabled') -or ($settingsDevelopersPageMode -eq 'Disabled') -or ($settingsAtlasPagesMode -eq 'Disabled')) -and ($settingsVisibilityPages.Count -eq 0)
        $removeGalleryFromExplorer = ($removeGalleryMode -eq 'Enabled')
        $restoreGalleryInExplorer = ($removeGalleryMode -eq 'Disabled')
        $removeHomeFromExplorer = ($removeExplorerHomeMode -eq 'Enabled')
        $restoreHomeInExplorer = ($removeExplorerHomeMode -eq 'Disabled')

        $advancedFirstStartupLines = [System.Collections.Generic.List[string]]::new()
        if ($restoreSettingsPageVisibility) {
            [void]$advancedFirstStartupLines.Add("if (Test-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer') {")
            [void]$advancedFirstStartupLines.Add("  Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' -Name 'SettingsPageVisibility' -ErrorAction SilentlyContinue")
            [void]$advancedFirstStartupLines.Add("}")
        }
        if ($removeGalleryFromExplorer) {
            [void]$advancedFirstStartupLines.Add("Remove-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}' -Recurse -Force -ErrorAction SilentlyContinue")
        }
        elseif ($restoreGalleryInExplorer) {
            [void]$advancedFirstStartupLines.Add("New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}' -Force | Out-Null")
        }
        if ($removeHomeFromExplorer) {
            [void]$advancedFirstStartupLines.Add("Remove-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}' -Recurse -Force -ErrorAction SilentlyContinue")
            [void]$advancedFirstStartupLines.Add("New-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Force | Out-Null")
            [void]$advancedFirstStartupLines.Add("Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'LaunchTo' -Value 1 -Type DWord")
        }
        elseif ($restoreHomeInExplorer) {
            [void]$advancedFirstStartupLines.Add("New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}' -Force | Out-Null")
            [void]$advancedFirstStartupLines.Add("New-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Force | Out-Null")
            [void]$advancedFirstStartupLines.Add("Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'LaunchTo' -Value 0 -Type DWord")
        }
        if ($disableSystemProtectionMode -eq 'Disabled') {
            [void]$advancedFirstStartupLines.Add("New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' -Force | Out-Null")
            [void]$advancedFirstStartupLines.Add("Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' -Name 'DisableSR' -Value 1 -Type DWord")
            [void]$advancedFirstStartupLines.Add("Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' -Name 'DisableConfig' -Value 1 -Type DWord")
            [void]$advancedFirstStartupLines.Add("Disable-ComputerRestore -Drive 'C:\' -ErrorAction SilentlyContinue")
        }
        if ($psExecutionPolicyMode -eq 'Enabled') {
            [void]$advancedFirstStartupLines.Add("Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force")
        }
        if ($deleteWindowsOldMode -eq 'Enabled') {
            [void]$advancedFirstStartupLines.Add("if (Test-Path 'C:\Windows.old') {")
            [void]$advancedFirstStartupLines.Add("  if ((Get-ChildItem -LiteralPath 'C:\Windows.old' -Force -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0) {")
            [void]$advancedFirstStartupLines.Add("    Remove-Item -LiteralPath 'C:\Windows.old' -Force -Recurse -ErrorAction SilentlyContinue")
            [void]$advancedFirstStartupLines.Add("  }")
            [void]$advancedFirstStartupLines.Add("}")
        }

        $removeEdgeSystemRuntime = ($edgeUninstallBetaMode -eq 'Enabled') -or ($checkedRuntimeAppActions -contains 'Runtime.Remove.MicrosoftEdge.System')
        $removeEdgeWebViewRuntime = ($checkedRuntimeAppActions -contains 'Runtime.Remove.MicrosoftEdge.WebView2')
        $removeEdgeShortcutsRuntime = $removeEdgeSystemRuntime -or ($checkedRuntimeAppActions -contains 'Runtime.Remove.MicrosoftEdge.Shortcuts')
        $appRuntimeFirstStartupLines = [System.Collections.Generic.List[string]]::new()

        if ($removeEdgeSystemRuntime) {
            [void]$appRuntimeFirstStartupLines.Add("taskkill /im MicrosoftEdgeUpdate.exe /f /t 2>`$null | Out-Null")
            [void]$appRuntimeFirstStartupLines.Add("`$edgeInstallerCandidates = @()")
            [void]$appRuntimeFirstStartupLines.Add("`$edgeInstallerCandidates += Get-ChildItem -Path 'C:\Program Files (x86)\Microsoft\Edge\Application\*\Installer\setup.exe' -File -ErrorAction SilentlyContinue")
            [void]$appRuntimeFirstStartupLines.Add("`$edgeInstallerCandidates += Get-ChildItem -Path 'C:\Program Files\Microsoft\Edge\Application\*\Installer\setup.exe' -File -ErrorAction SilentlyContinue")
            [void]$appRuntimeFirstStartupLines.Add("foreach (`$setup in @(`$edgeInstallerCandidates | Sort-Object FullName -Descending | Select-Object -ExpandProperty FullName -Unique)) {")
            [void]$appRuntimeFirstStartupLines.Add("  Start-Process -FilePath `$setup -ArgumentList '--uninstall --system-level --force-uninstall' -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null")
            [void]$appRuntimeFirstStartupLines.Add("}")
            [void]$appRuntimeFirstStartupLines.Add("Get-AppxPackage -AllUsers | Where-Object { (`$_.Name -like '*MicrosoftEdge*') -or (`$_.PackageName -like '*MicrosoftEdge*') } | ForEach-Object { Remove-AppxPackage -AllUsers -Package `$_.PackageFullName -ErrorAction SilentlyContinue }")
            [void]$appRuntimeFirstStartupLines.Add("Get-AppxProvisionedPackage -Online | Where-Object { (`$_.DisplayName -like '*MicrosoftEdge*') -or (`$_.PackageName -like '*MicrosoftEdge*') } | ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName `$_.PackageName -AllUsers -ErrorAction SilentlyContinue | Out-Null }")
            [void]$appRuntimeFirstStartupLines.Add("foreach (`$svc in @('edgeupdate','edgeupdatem','MicrosoftEdgeElevationService')) {")
            [void]$appRuntimeFirstStartupLines.Add("  sc.exe stop `$svc | Out-Null")
            [void]$appRuntimeFirstStartupLines.Add("  sc.exe delete `$svc | Out-Null")
            [void]$appRuntimeFirstStartupLines.Add("}")
            [void]$appRuntimeFirstStartupLines.Add("foreach (`$tn in @('\Microsoft\EdgeUpdate\MicrosoftEdgeUpdateTaskMachineCore','\Microsoft\EdgeUpdate\MicrosoftEdgeUpdateTaskMachineUA')) {")
            [void]$appRuntimeFirstStartupLines.Add("  schtasks /Delete /TN `"`$tn`" /F 2>`$null | Out-Null")
            [void]$appRuntimeFirstStartupLines.Add("}")
        }
        if ($removeEdgeWebViewRuntime) {
            [void]$appRuntimeFirstStartupLines.Add("`$webViewInstallerCandidates = @()")
            [void]$appRuntimeFirstStartupLines.Add("`$webViewInstallerCandidates += Get-ChildItem -Path 'C:\Program Files (x86)\Microsoft\EdgeWebView\Application\*\Installer\setup.exe' -File -ErrorAction SilentlyContinue")
            [void]$appRuntimeFirstStartupLines.Add("`$webViewInstallerCandidates += Get-ChildItem -Path 'C:\Program Files\Microsoft\EdgeWebView\Application\*\Installer\setup.exe' -File -ErrorAction SilentlyContinue")
            [void]$appRuntimeFirstStartupLines.Add("foreach (`$setup in @(`$webViewInstallerCandidates | Sort-Object FullName -Descending | Select-Object -ExpandProperty FullName -Unique)) {")
            [void]$appRuntimeFirstStartupLines.Add("  Start-Process -FilePath `$setup -ArgumentList '--uninstall --msedgewebview --system-level --force-uninstall' -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null")
            [void]$appRuntimeFirstStartupLines.Add("}")
            [void]$appRuntimeFirstStartupLines.Add("foreach (`$setup in @(Get-ChildItem -Path `"`$env:LOCALAPPDATA\Microsoft\EdgeWebView\Application\*\Installer\setup.exe`" -File -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -ExpandProperty FullName -Unique)) {")
            [void]$appRuntimeFirstStartupLines.Add("  Start-Process -FilePath `$setup -ArgumentList '--uninstall --msedgewebview --force-uninstall' -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null")
            [void]$appRuntimeFirstStartupLines.Add("}")
            [void]$appRuntimeFirstStartupLines.Add("Get-AppxPackage -AllUsers | Where-Object { (`$_.Name -like '*WebView*') -or (`$_.Name -like '*Win32WebViewHost*') -or (`$_.PackageName -like '*WebView*') -or (`$_.PackageName -like '*Win32WebViewHost*') } | ForEach-Object { Remove-AppxPackage -AllUsers -Package `$_.PackageFullName -ErrorAction SilentlyContinue }")
            [void]$appRuntimeFirstStartupLines.Add("Get-AppxProvisionedPackage -Online | Where-Object { (`$_.DisplayName -like '*WebView*') -or (`$_.DisplayName -like '*Win32WebViewHost*') -or (`$_.PackageName -like '*WebView*') -or (`$_.PackageName -like '*Win32WebViewHost*') } | ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName `$_.PackageName -AllUsers -ErrorAction SilentlyContinue | Out-Null }")
        }
        if ($removeEdgeShortcutsRuntime) {
            [void]$appRuntimeFirstStartupLines.Add("Remove-Item -Path `"`$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk`" -Force -ErrorAction SilentlyContinue")
        }

        # Extra security backend mapping (core settings with direct registry/service impact).
        $extraSecurityRegTweaks = [System.Collections.Generic.List[object[]]]::new()
        $addExtraReg = {
            param([string]$Hive, [string]$KeyPath, [string]$ValueName, [object]$ValueData, [string]$ValueType = 'DWord')
            [void]$extraSecurityRegTweaks.Add(@($Hive, $KeyPath, $ValueName, $ValueData, $ValueType))
        }.GetNewClosure()
        $setExtraSchannelProtocolState = {
            param([string]$ProtocolName, [bool]$EnableProtocol)
            if ([string]::IsNullOrWhiteSpace($ProtocolName)) { return }
            $enabledValue = if ($EnableProtocol) { 1 } else { 0 }
            $disabledByDefaultValue = if ($EnableProtocol) { 0 } else { 1 }
            foreach ($scope in @('Client', 'Server')) {
                & $addExtraReg 'zSYSTEM' ("ControlSet001\Control\SecurityProviders\SCHANNEL\Protocols\{0}\{1}" -f $ProtocolName, $scope) 'Enabled' $enabledValue 'DWord'
                & $addExtraReg 'zSYSTEM' ("ControlSet001\Control\SecurityProviders\SCHANNEL\Protocols\{0}\{1}" -f $ProtocolName, $scope) 'DisabledByDefault' $disabledByDefaultValue 'DWord'
            }
        }.GetNewClosure()
        $setExtraDotNetTlsDefaults = {
            param([bool]$EnableDefaults)
            $value = if ($EnableDefaults) { 1 } else { 0 }
            foreach ($dotNetPath in @(
                    'Microsoft\.NETFramework\v2.0.50727',
                    'Microsoft\.NETFramework\v4.0.30319',
                    'WOW6432Node\Microsoft\.NETFramework\v2.0.50727',
                    'WOW6432Node\Microsoft\.NETFramework\v4.0.30319'
                )) {
                & $addExtraReg 'zSOFTWARE' $dotNetPath 'SystemDefaultTlsVersions' $value 'DWord'
            }
        }.GetNewClosure()
        $setExtraDotNetStrongCrypto = {
            param([bool]$EnableStrongCrypto)
            $value = if ($EnableStrongCrypto) { 1 } else { 0 }
            foreach ($dotNetPath in @(
                    'Microsoft\.NETFramework\v2.0.50727',
                    'Microsoft\.NETFramework\v4.0.30319',
                    'WOW6432Node\Microsoft\.NETFramework\v2.0.50727',
                    'WOW6432Node\Microsoft\.NETFramework\v4.0.30319'
                )) {
                & $addExtraReg 'zSOFTWARE' $dotNetPath 'SchUseStrongCrypto' $value 'DWord'
            }
        }.GetNewClosure()
        $setExtraSchannelCipherState = {
            param([string[]]$CipherNames, [bool]$DisableCipher)
            $enabledValue = if ($DisableCipher) { 0 } else { [uint32]0xffffffff }
            $disabledByDefaultValue = if ($DisableCipher) { 1 } else { 0 }
            foreach ($cipherName in @($CipherNames)) {
                if ([string]::IsNullOrWhiteSpace([string]$cipherName)) { continue }
                $cipherPath = ("ControlSet001\Control\SecurityProviders\SCHANNEL\Ciphers\{0}" -f [string]$cipherName)
                & $addExtraReg 'zSYSTEM' $cipherPath 'Enabled' $enabledValue 'DWord'
                & $addExtraReg 'zSYSTEM' $cipherPath 'DisabledByDefault' $disabledByDefaultValue 'DWord'
            }
        }.GetNewClosure()
        $setExtraSchannelHashState = {
            param([string[]]$HashNames, [bool]$DisableHash)
            $enabledValue = if ($DisableHash) { 0 } else { [uint32]0xffffffff }
            $disabledByDefaultValue = if ($DisableHash) { 1 } else { 0 }
            foreach ($hashName in @($HashNames)) {
                if ([string]::IsNullOrWhiteSpace([string]$hashName)) { continue }
                $hashPath = ("ControlSet001\Control\SecurityProviders\SCHANNEL\Hashes\{0}" -f [string]$hashName)
                & $addExtraReg 'zSYSTEM' $hashPath 'Enabled' $enabledValue 'DWord'
                & $addExtraReg 'zSYSTEM' $hashPath 'DisabledByDefault' $disabledByDefaultValue 'DWord'
            }
        }.GetNewClosure()
        $extraSecurityFirstStartupLines = [System.Collections.Generic.List[string]]::new()
        foreach ($xEntry in $extraSecurityByLabel.GetEnumerator()) {
            $xLabel = [string]$xEntry.Key
            $xMode = [string]$xEntry.Value
            switch -Regex ($xLabel) {
                '^(?i)Disable LM hash storage \(NoLMHash\)$' {
                    & $addExtraReg 'zSYSTEM' 'ControlSet001\Control\Lsa' 'NoLMHash' $(if ($xMode -eq 'Disabled') { 1 } else { 0 }) 'DWord'
                    continue
                }
                '^(?i)Disable AutoPlay and AutoRun \(all drives\)$' {
                    $disableAutorunAll = ($xMode -eq 'Disabled')
                    & $addExtraReg 'zSOFTWARE' 'Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoDriveTypeAutoRun' $(if ($disableAutorunAll) { 255 } else { 145 }) 'DWord'
                    & $addExtraReg 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoDriveTypeAutoRun' $(if ($disableAutorunAll) { 255 } else { 145 }) 'DWord'
                    & $addExtraReg 'zSOFTWARE' 'Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoAutorun' $(if ($disableAutorunAll) { 1 } else { 0 }) 'DWord'
                    & $addExtraReg 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoAutorun' $(if ($disableAutorunAll) { 1 } else { 0 }) 'DWord'
                    & $addExtraReg 'zSOFTWARE' 'Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers' 'DisableAutoplay' $(if ($disableAutorunAll) { 1 } else { 0 }) 'DWord'
                    & $addExtraReg 'zNTUSER' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers' 'DisableAutoplay' $(if ($disableAutorunAll) { 1 } else { 0 }) 'DWord'
                    continue
                }
                '^(?i)(Disable Windows Script Host \(WSH\)|Disable Windows Script Host|WSH)$' {
                    $disableWsh = ($xMode -eq 'Disabled')
                    & $addExtraReg 'zSOFTWARE' 'Microsoft\Windows Script Host\Settings' 'Enabled' $(if ($disableWsh) { 0 } else { 1 }) 'DWord'
                    & $addExtraReg 'zNTUSER' 'SOFTWARE\Microsoft\Windows Script Host\Settings' 'Enabled' $(if ($disableWsh) { 0 } else { 1 }) 'DWord'
                    continue
                }
                '^(?i)(Enable Defender and Edge PUA blocking|Enable Defender PUA protection|Defender PUA Protection)$' {
                    $enablePua = ($xMode -eq 'Enabled')
                    & $addExtraReg 'zSOFTWARE' 'Policies\Microsoft\Windows Defender' 'PUAProtection' $(if ($enablePua) { 1 } else { 0 }) 'DWord'
                    & $addExtraReg 'zSOFTWARE' 'Policies\Microsoft\Windows Defender\MpEngine' 'MpEnablePus' $(if ($enablePua) { 1 } else { 0 }) 'DWord'
                    & $addExtraReg 'zSOFTWARE' 'Policies\Microsoft\Edge' 'SmartScreenPuaEnabled' $(if ($enablePua) { 1 } else { 0 }) 'DWord'
                    continue
                }
                '^(?i)(Enable LSA protection \(RunAsPPL\)|Enable LSA protection|LSA Protection)$' {
                    & $addExtraReg 'zSYSTEM' 'ControlSet001\Control\Lsa' 'RunAsPPL' $(if ($xMode -eq 'Enabled') { 1 } else { 0 }) 'DWord'
                    continue
                }
                '^(?i)Disable cloud clipboard sync$' {
                    $disableClipboardSync = ($xMode -eq 'Disabled')
                    & $addExtraReg 'zNTUSER' 'SOFTWARE\Microsoft\Clipboard' 'EnableClipboardHistory' $(if ($disableClipboardSync) { 0 } else { 1 }) 'DWord'
                    & $addExtraReg 'zNTUSER' 'SOFTWARE\Microsoft\Clipboard' 'EnableCloudClipboard' $(if ($disableClipboardSync) { 0 } else { 1 }) 'DWord'
                    & $addExtraReg 'zNTUSER' 'SOFTWARE\Microsoft\Clipboard' 'CloudClipboardAutomaticUpload' $(if ($disableClipboardSync) { 0 } else { 1 }) 'DWord'
                    continue
                }
                '^(?i)Disable AlwaysInstallElevated policy \(Windows Installer\)$' {
                    $disableAlwaysInstallElevated = ($xMode -eq 'Disabled')
                    & $addExtraReg 'zSOFTWARE' 'Policies\Microsoft\Windows\Installer' 'AlwaysInstallElevated' $(if ($disableAlwaysInstallElevated) { 0 } else { 1 }) 'DWord'
                    & $addExtraReg 'zNTUSER' 'SOFTWARE\Policies\Microsoft\Windows\Installer' 'AlwaysInstallElevated' $(if ($disableAlwaysInstallElevated) { 0 } else { 1 }) 'DWord'
                    continue
                }
                '^(?i)Disable lock screen camera access$' {
                    & $addExtraReg 'zSOFTWARE' 'Policies\Microsoft\Windows\Personalization' 'NoLockScreenCamera' $(if ($xMode -eq 'Disabled') { 1 } else { 0 }) 'DWord'
                    continue
                }
                '^(?i)Disable anonymous share enumeration$' {
                    & $addExtraReg 'zSYSTEM' 'ControlSet001\Control\Lsa' 'RestrictAnonymous' $(if ($xMode -eq 'Disabled') { 1 } else { 0 }) 'DWord'
                    continue
                }
                '^(?i)Disable NetBIOS over TCP/IP \(NetBT\)$' {
                    $netbiosModeValue = if ($xMode -eq 'Disabled') { 2 } else { 0 }
                    [void]$extraSecurityFirstStartupLines.Add("Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter `"IPEnabled = TRUE`" | ForEach-Object { try { [void]`$_.SetTcpipNetbios($netbiosModeValue) } catch { } }")
                    continue
                }
                '^(?i)Enable DEP \(Data Execution Prevention\)$' {
                    $depMode = if ($xMode -eq 'Enabled') { 'OptOut' } else { 'OptIn' }
                    [void]$extraSecurityFirstStartupLines.Add(("bcdedit /set {{current}} nx {0} >`$null 2>&1" -f $depMode))
                    continue
                }
                '^(?i)Enable SEHOP \(Structured Exception Handling Overwrite Protection\)$' {
                    & $addExtraReg 'zSYSTEM' 'ControlSet001\Control\Session Manager\kernel' 'DisableExceptionChainValidation' $(if ($xMode -eq 'Enabled') { 0 } else { 1 }) 'DWord'
                    continue
                }
                '^(?i)Enable Spectre/Meltdown mitigations \(host OS\)$' {
                    $hostMitigationsEnabled = ($xMode -eq 'Enabled')
                    & $addExtraReg 'zSYSTEM' 'ControlSet001\Control\Session Manager\Memory Management' 'FeatureSettingsOverride' $(if ($hostMitigationsEnabled) { 0 } else { 3 }) 'DWord'
                    & $addExtraReg 'zSYSTEM' 'ControlSet001\Control\Session Manager\Memory Management' 'FeatureSettingsOverrideMask' 3 'DWord'
                    continue
                }
                '^(?i)Enable Spectre/Meltdown mitigations \(Hyper-V\)$' {
                    if ($xMode -eq 'Enabled') {
                        & $addExtraReg 'zSOFTWARE' 'Microsoft\Windows NT\CurrentVersion\Virtualization' 'MinVmVersionForCpuBasedMitigations' '1.0' 'String'
                    }
                    else {
                        & $addExtraReg 'zSOFTWARE' 'Microsoft\Windows NT\CurrentVersion\Virtualization' 'MinVmVersionForCpuBasedMitigations' '' 'String'
                    }
                    continue
                }
                '^(?i)Run DISM component cleanup \(/ResetBase\)$' {
                    if ($xMode -eq 'Enabled') {
                        [void]$extraSecurityFirstStartupLines.Add('dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase /Quiet /NoRestart | Out-Null')
                    }
                    continue
                }
                '^(?i)Disable Windows PowerShell 2\.0$' {
                    if ($xMode -eq 'Disabled') {
                        $checkedFeats['MicrosoftWindowsPowerShellV2'] = 'Disabled'
                        $checkedFeats['MicrosoftWindowsPowerShellV2Root'] = 'Disabled'
                    }
                    continue
                }
                '^(?i)Disable PowerShell 7 telemetry$' {
                    & $addExtraReg 'zSYSTEM' 'ControlSet001\Control\Session Manager\Environment' 'POWERSHELL_TELEMETRY_OPTOUT' $(if ($xMode -eq 'Disabled') { '1' } else { '' }) 'String'
                    continue
                }
                '^(?i)Disable SMB 1\.0 \(SMBv1\) protocol$' {
                    if ($xMode -eq 'Disabled') {
                        $checkedFeats['SMB1Protocol'] = 'Disabled'
                    }
                    continue
                }
                '^(?i)(Require strong Diffie-Hellman key exchange|Diffie-Hellman minimum key length \(2048-bit\))$' {
                    & $addExtraReg 'zSYSTEM' 'ControlSet001\Control\SecurityProviders\SCHANNEL\KeyExchangeAlgorithms\Diffie-Hellman' 'ClientMinKeyBitLength' $(if ($xMode -eq 'Enabled') { 2048 } else { 1024 }) 'DWord'
                    continue
                }
                '^(?i)(Require strong RSA key lengths|RSA minimum key length \(2048-bit\))$' {
                    & $addExtraReg 'zSYSTEM' 'ControlSet001\Control\SecurityProviders\SCHANNEL\KeyExchangeAlgorithms\PKCS' 'ClientMinKeyBitLength' $(if ($xMode -eq 'Enabled') { 2048 } else { 1024 }) 'DWord'
                    continue
                }
                '^(?i)(Restrict LM and NTLM authentication)$' {
                    & $addExtraReg 'zSYSTEM' 'ControlSet001\Control\Lsa' 'LmCompatibilityLevel' $(if ($xMode -eq 'Enabled') { 5 } else { 3 }) 'DWord'
                    continue
                }
                '^(?i)Disable Hibernation$' {
                    if ($xMode -eq 'Disabled') {
                        [void]$extraSecurityFirstStartupLines.Add('powercfg.exe /hibernate off')
                    }
                    continue
                }
                '^(?i)Delete volume shadow copies \(VSS\)$' {
                    if ($xMode -eq 'Disabled') {
                        [void]$extraSecurityFirstStartupLines.Add('vssadmin Delete Shadows /All /Quiet')
                    }
                    continue
                }
                '^(?i)Set Windows Time Service NTP server \(pool\.ntp\.org\)$' {
                    if ($xMode -eq 'Enabled') {
                        & $addExtraReg 'zSYSTEM' 'ControlSet001\Services\W32Time\Parameters' 'Type' 'NTP' 'String'
                        & $addExtraReg 'zSYSTEM' 'ControlSet001\Services\W32Time\Parameters' 'NtpServer' 'pool.ntp.org,0x9' 'String'
                    }
                    continue
                }
                '^(?i)Disable WinRM Basic authentication$' {
                    $disableBasic = ($xMode -eq 'Disabled')
                    & $addExtraReg 'zSOFTWARE' 'Policies\Microsoft\Windows\WinRM\Client' 'AllowBasic' $(if ($disableBasic) { 0 } else { 1 }) 'DWord'
                    & $addExtraReg 'zSOFTWARE' 'Policies\Microsoft\Windows\WinRM\Service' 'AllowBasic' $(if ($disableBasic) { 0 } else { 1 }) 'DWord'
                    continue
                }
                '^(?i)Block anonymous SAM and share enumeration$' {
                    & $addExtraReg 'zSYSTEM' 'ControlSet001\Control\Lsa' 'RestrictAnonymousSAM' $(if ($xMode -eq 'Disabled') { 1 } else { 0 }) 'DWord'
                    & $addExtraReg 'zSYSTEM' 'ControlSet001\Control\Lsa' 'RestrictAnonymous' $(if ($xMode -eq 'Disabled') { 1 } else { 0 }) 'DWord'
                    continue
                }
                '^(?i)Block anonymous access to named pipes and shares$' {
                    & $addExtraReg 'zSYSTEM' 'ControlSet001\Services\LanmanServer\Parameters' 'RestrictNullSessAccess' $(if ($xMode -eq 'Disabled') { 1 } else { 0 }) 'DWord'
                    continue
                }
                '^(?i)Disable administrative shares \(AutoShareWks/AutoShareServer\)$' {
                    & $addExtraReg 'zSYSTEM' 'ControlSet001\Services\LanmanServer\Parameters' 'AutoShareWks' $(if ($xMode -eq 'Disabled') { 0 } else { 1 }) 'DWord'
                    & $addExtraReg 'zSYSTEM' 'ControlSet001\Services\LanmanServer\Parameters' 'AutoShareServer' $(if ($xMode -eq 'Disabled') { 0 } else { 1 }) 'DWord'
                    continue
                }
                '^(?i)(Disable SSL 2\.0|SSL 2\.0 protocol \(legacy\))$' {
                    & $setExtraSchannelProtocolState 'SSL 2.0' ($xMode -eq 'Enabled')
                    continue
                }
                '^(?i)(Disable SSL 3\.0|SSL 3\.0 protocol \(legacy\))$' {
                    & $setExtraSchannelProtocolState 'SSL 3.0' ($xMode -eq 'Enabled')
                    continue
                }
                '^(?i)(Disable TLS 1\.0|TLS 1\.0 protocol \(legacy\))$' {
                    & $setExtraSchannelProtocolState 'TLS 1.0' ($xMode -eq 'Enabled')
                    continue
                }
                '^(?i)(Disable TLS 1\.1|TLS 1\.1 protocol \(legacy\))$' {
                    & $setExtraSchannelProtocolState 'TLS 1.1' ($xMode -eq 'Enabled')
                    continue
                }
                '^(?i)(Enable TLS 1\.2|TLS 1\.2 protocol)$' {
                    & $setExtraSchannelProtocolState 'TLS 1.2' ($xMode -eq 'Enabled')
                    continue
                }
                '^(?i)(Disable DTLS 1\.0|DTLS 1\.0 protocol \(legacy\))$' {
                    & $setExtraSchannelProtocolState 'DTLS 1.0' ($xMode -eq 'Enabled')
                    continue
                }
                '^(?i)(Disable DTLS 1\.1|DTLS 1\.1 protocol \(legacy\))$' {
                    & $setExtraSchannelProtocolState 'DTLS 1.1' ($xMode -eq 'Enabled')
                    continue
                }
                '^(?i)(Enable DTLS 1\.2|DTLS 1\.2 protocol)$' {
                    & $setExtraSchannelProtocolState 'DTLS 1.2' ($xMode -eq 'Enabled')
                    continue
                }
                '^(?i)(Enable TLS 1\.3|TLS 1\.3 protocol)$' {
                    & $setExtraSchannelProtocolState 'TLS 1.3' ($xMode -eq 'Enabled')
                    continue
                }
                '^(?i)(Enforce strong \.NET TLS defaults|\.NET use OS default TLS versions)$' {
                    & $setExtraDotNetTlsDefaults ($xMode -eq 'Enabled')
                    continue
                }
                '^(?i)(Enable strong cryptography for legacy \.NET|\.NET strong crypto mode)$' {
                    & $setExtraDotNetStrongCrypto ($xMode -eq 'Enabled')
                    continue
                }
                '^(?i)(Disable RC2 Ciphers|Disable RC4 Ciphers|Disable DES Ciphers|Disable 3DES Ciphers|Disable NULL Ciphers|Disable MD5 Hash Algorithms|Disable SHA-1 Hash Algorithms)$' {
                    $disableWeakAlgorithm = ($xMode -eq 'Disabled')
                    if ($xLabel -match '^(?i)Disable 3DES Ciphers$') {
                        & $setExtraSchannelCipherState @('Triple DES 168/168') $disableWeakAlgorithm
                    }
                    elseif ($xLabel -match '^(?i)Disable DES Ciphers$') {
                        & $setExtraSchannelCipherState @('DES 56/56') $disableWeakAlgorithm
                    }
                    elseif ($xLabel -match '^(?i)Disable RC2 Ciphers$') {
                        & $setExtraSchannelCipherState @('RC2 40/128', 'RC2 56/128', 'RC2 128/128') $disableWeakAlgorithm
                    }
                    elseif ($xLabel -match '^(?i)Disable RC4 Ciphers$') {
                        & $setExtraSchannelCipherState @('RC4 40/128', 'RC4 56/128', 'RC4 64/128', 'RC4 128/128') $disableWeakAlgorithm
                    }
                    elseif ($xLabel -match '^(?i)Disable NULL Ciphers$') {
                        & $setExtraSchannelCipherState @('NULL') $disableWeakAlgorithm
                    }
                    elseif ($xLabel -match '^(?i)Disable MD5 Hash Algorithms$') {
                        & $setExtraSchannelHashState @('MD5') $disableWeakAlgorithm
                    }
                    elseif ($xLabel -match '^(?i)Disable SHA-1 Hash Algorithms$') {
                        & $setExtraSchannelHashState @('SHA') $disableWeakAlgorithm
                    }
                    continue
                }
                '^(?i)(Disable Insecure TLS Renegotiation)$' {
                    $disableInsecureRenegotiation = ($xMode -eq 'Disabled')
                    & $addExtraReg 'zSYSTEM' 'ControlSet001\Control\SecurityProviders\SCHANNEL' 'AllowInsecureRenegoClients' $(if ($disableInsecureRenegotiation) { 0 } else { 1 }) 'DWord'
                    & $addExtraReg 'zSYSTEM' 'ControlSet001\Control\SecurityProviders\SCHANNEL' 'AllowInsecureRenegoServers' $(if ($disableInsecureRenegotiation) { 0 } else { 1 }) 'DWord'
                    continue
                }
                default {
                    RS-Log ("WARNING: Extra security option has no backend mapping yet: {0}" -f $xLabel) -Color Yellow
                    continue
                }
            }
        }

        $privacyLabelMap = @{}
        if ($null -ne $sync.PrivacyLabelById) {
            $privacyLabelMap = @{} + $sync.PrivacyLabelById
        }
        $privacyFirstStartupLines = [System.Collections.Generic.List[string]]::new()
        $privacyModeByLabel = @{}
        foreach ($pEntry in $privacyConfig.GetEnumerator()) {
            $privacyIdKey = [string]$pEntry.Key
            $pMode = [string]$pEntry.Value
            if ($pMode -notin @('Enabled', 'Disabled')) { continue }

            $resolvedLabel = if ($privacyLabelMap.ContainsKey($privacyIdKey)) { [string]$privacyLabelMap[$privacyIdKey] } else { $privacyIdKey }
            $normalizedLabel = Normalize-PrivacyToggleLabel -Label $resolvedLabel
            if ([string]::IsNullOrWhiteSpace($normalizedLabel)) { continue }
            $privacyModeByLabel[$normalizedLabel] = $pMode
        }
        if ($privacyModeByLabel.ContainsKey('AI: Remove Recall optional feature') -and [string]$privacyModeByLabel['AI: Remove Recall optional feature'] -eq 'Disabled') {
            [void]$privacyFirstStartupLines.Add("dism.exe /Online /Disable-Feature /FeatureName:Recall /Remove /NoRestart /Quiet | Out-Null")
        }
        if ($privacyModeByLabel.ContainsKey('AI: Remove Recall scheduled tasks') -and [string]$privacyModeByLabel['AI: Remove Recall scheduled tasks'] -eq 'Disabled') {
            [void]$privacyFirstStartupLines.Add("foreach (`$tn in @('\Microsoft\Windows\WindowsAI\Recall\InitialConfiguration','\Microsoft\Windows\WindowsAI\Recall\PolicyConfiguration','\Microsoft\Office\Office Actions Server')) {")
            [void]$privacyFirstStartupLines.Add("  schtasks /Change /TN `"`$tn`" /Disable 2>`$null")
            [void]$privacyFirstStartupLines.Add("  schtasks /Delete /TN `"`$tn`" /F 2>`$null")
            [void]$privacyFirstStartupLines.Add("}")
        }
        if ($privacyModeByLabel.ContainsKey('AI: Remove AI appx packages') -and [string]$privacyModeByLabel['AI: Remove AI appx packages'] -eq 'Disabled') {
            [void]$privacyFirstStartupLines.Add("`$aiPackagePatterns = @('MicrosoftWindows.Client.AIX','MicrosoftWindows.Client.CoPilot','Microsoft.Copilot','Microsoft.Windows.Ai.Copilot.Provider','MicrosoftWindows.Client.CoreAI','Microsoft.Edge.GameAssist','Microsoft.Office.ActionsServer','Microsoft.WritingAssistant','aimgr','WindowsWorkload')")
            [void]$privacyFirstStartupLines.Add("foreach (`$pattern in `$aiPackagePatterns) {")
            [void]$privacyFirstStartupLines.Add("  Get-AppxPackage -AllUsers | Where-Object { (`$_.Name -like ('*' + `$pattern + '*')) -or (`$_.PackageName -like ('*' + `$pattern + '*')) } | ForEach-Object { Remove-AppxPackage -AllUsers -Package `$_.PackageFullName -ErrorAction SilentlyContinue }")
            [void]$privacyFirstStartupLines.Add("  Get-AppxProvisionedPackage -Online | Where-Object { (`$_.DisplayName -like ('*' + `$pattern + '*')) -or (`$_.PackageName -like ('*' + `$pattern + '*')) } | ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName `$_.PackageName -AllUsers -ErrorAction SilentlyContinue | Out-Null }")
            [void]$privacyFirstStartupLines.Add("}")
        }
        if ($privacyModeByLabel.ContainsKey('Clear Explorer folder view history (ShellBags)') -and [string]$privacyModeByLabel['Clear Explorer folder view history (ShellBags)'] -eq 'Disabled') {
            [void]$privacyFirstStartupLines.Add("`$shellBagPaths = @(")
            [void]$privacyFirstStartupLines.Add("  'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags',")
            [void]$privacyFirstStartupLines.Add("  'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\BagMRU'")
            [void]$privacyFirstStartupLines.Add(")")
            [void]$privacyFirstStartupLines.Add("foreach (`$path in `$shellBagPaths) {")
            [void]$privacyFirstStartupLines.Add("  if (Test-Path -LiteralPath `$path) {")
            [void]$privacyFirstStartupLines.Add("    Remove-Item -LiteralPath `$path -Recurse -Force -ErrorAction SilentlyContinue")
            [void]$privacyFirstStartupLines.Add("  }")
            [void]$privacyFirstStartupLines.Add("}")
        }
        if ($privacyModeByLabel.ContainsKey('Clear package install-location registry logs') -and [string]$privacyModeByLabel['Clear package install-location registry logs'] -eq 'Disabled') {
            [void]$privacyFirstStartupLines.Add("`$installerFolderLogKeys = @(")
            [void]$privacyFirstStartupLines.Add("  'HKCU:\Software\Microsoft\Windows\CurrentVersion\Installer\Folders',")
            [void]$privacyFirstStartupLines.Add("  'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\Folders',")
            [void]$privacyFirstStartupLines.Add("  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Installer\Folders'")
            [void]$privacyFirstStartupLines.Add(")")
            [void]$privacyFirstStartupLines.Add("foreach (`$keyPath in `$installerFolderLogKeys) {")
            [void]$privacyFirstStartupLines.Add("  if (-not (Test-Path -LiteralPath `$keyPath)) { continue }")
            [void]$privacyFirstStartupLines.Add("  try {")
            [void]$privacyFirstStartupLines.Add("    `$item = Get-Item -LiteralPath `$keyPath -ErrorAction Stop")
            [void]$privacyFirstStartupLines.Add("    foreach (`$propName in @(`$item.Property)) {")
            [void]$privacyFirstStartupLines.Add("      Remove-ItemProperty -LiteralPath `$keyPath -Name `$propName -Force -ErrorAction SilentlyContinue")
            [void]$privacyFirstStartupLines.Add("    }")
            [void]$privacyFirstStartupLines.Add("  }")
            [void]$privacyFirstStartupLines.Add("  catch { }")
            [void]$privacyFirstStartupLines.Add("}")
        }
        if ($privacyModeByLabel.ContainsKey('Search: Microsoft Store app results in Start menu') -and [string]$privacyModeByLabel['Search: Microsoft Store app results in Start menu'] -eq 'Disabled') {
            [void]$privacyFirstStartupLines.Add("`$storeDbPath = Join-Path `$env:LOCALAPPDATA 'Packages\Microsoft.WindowsStore_8wekyb3d8bbwe\LocalState\store.db'")
            [void]$privacyFirstStartupLines.Add("if (Test-Path -LiteralPath `$storeDbPath) {")
            [void]$privacyFirstStartupLines.Add("  cmd.exe /c icacls `"`$storeDbPath`" /deny Everyone:F >nul 2>&1")
            [void]$privacyFirstStartupLines.Add("}")
        }
        $privacyRegResult = Convert-PrivacySelectionsToRegistryTweaks -PrivacyConfig $privacyConfig -PrivacyLabelById $privacyLabelMap
        $privacyRegTweaks = @($privacyRegResult.Tweaks)
        $privacyMappedLabels = @($privacyRegResult.MappedLabels)
        $privacyUnmappedLabels = @($privacyRegResult.UnmappedLabels)

        $allGeneratedTweaks = @($checkedReg + $privacyRegTweaks + @($advancedRegTweaks) + @($extraSecurityRegTweaks))
        if ($allGeneratedTweaks.Count -gt 0) {
            $mergedRegTweaks = [ordered]@{}
            foreach ($rt in $allGeneratedTweaks) {
                if ($null -eq $rt -or $rt.Count -lt 5) { continue }
                $rtKey = "{0}\{1}|{2}" -f [string]$rt[0], [string]$rt[1], [string]$rt[2]
                $mergedRegTweaks[$rtKey] = $rt
            }
            $checkedReg = @($mergedRegTweaks.Values)
        }

        #──────────────────────────────────────────────────────────────────────
        # PHASE 0: Log execution plan (every selected change)
        #──────────────────────────────────────────────────────────────────────
        RS-Log '═══════ PHASE 0: Execution Plan (Selected Changes) ═══════' -Color Cyan
        RS-Log ("Source ISO: {0}" -f $srcISO) -Color White
        RS-Log ("Output ISO: {0}" -f $outISO) -Color White
        RS-Log ("Scratch Dir: {0}" -f $scrDir) -Color White
        RS-Log ("Security baseline profile: {0}" -f $securityPreset) -Color White
        RS-Log ("Single language installer: {0} ({1})" -f $singleLanguageInstaller, $installerLanguageRaw) -Color White
        RS-Log ("Custom unattend.xml: {0}" -f $(if ([string]::IsNullOrWhiteSpace($customUnattendPath)) { 'None' } else { $customUnattendPath })) -Color White
        RS-Log ("Custom files: .reg={0}, .bat/cmd={1}" -f $customRegFiles.Count, $customBatFiles.Count) -Color White
        RS-Log ("Driver injection: install.wim={0}, recurse={1}, source='{2}'" -f $injectInstallDrivers, $driverRecurse, $driverSourceDir) -Color White
        RS-Log ("Performance profile: FastMode={0}, SkipVerify={1}, WIMCompression={2}, IntegrityChecks={3}" -f $fastMode, $skipPostUnmountVerify, $wimCompression, $useIntegrityChecks) -Color White
        if ($wimCompression -eq 'None') {
            RS-Log "WARNING: WIMCompression=None is fastest but usually produces a much larger ISO. Use Fast or Max for smaller output." -Color Yellow
        }

        foreach ($pkg in $checkedAppxProvisioned) { RS-Log ("PLAN Appx remove: {0}" -f $pkg) -Color White }
        foreach ($actionId in $checkedRuntimeAppActions) { RS-Log ("PLAN App runtime action: {0}" -f $actionId) -Color White }
        if ($checkedAppxProvisioned.Count -eq 0 -and $checkedRuntimeAppActions.Count -eq 0) {
            RS-Log "PLAN Appx/runtime: no package actions selected." -Color Yellow
        }
        $taskDisableWarningMap = if ($sync.TaskDisableWarnings -is [System.Collections.IDictionary]) { $sync.TaskDisableWarnings } else { @{} }
        foreach ($featEntry in $checkedFeats.GetEnumerator()) { RS-Log ("PLAN OptionalFeature: {0} => {1}" -f $featEntry.Key, $featEntry.Value) -Color White }
        foreach ($taskEntry in $taskConfig.GetEnumerator()) {
            $taskId = [string]$taskEntry.Key
            $taskMode = [string]$taskEntry.Value
            RS-Log ("PLAN ScheduledTask: {0} => {1}" -f $taskId, $taskMode) -Color White
            if ($taskMode -eq 'Disabled' -and $taskDisableWarningMap.ContainsKey($taskId)) {
                RS-Log ("PLAN ScheduledTask warning: {0}" -f [string]$taskDisableWarningMap[$taskId]) -Color Yellow
            }
        }
        foreach ($svcEntry in $serviceConfig.GetEnumerator()) { RS-Log ("PLAN Service: {0} => {1}" -f $svcEntry.Key, $svcEntry.Value) -Color White }
        foreach ($pEntry in $privacyConfig.GetEnumerator()) { RS-Log ("PLAN Privacy: {0} => {1}" -f $pEntry.Key, $pEntry.Value) -Color White }
        RS-Log ("PLAN Privacy mapped to registry: {0}" -f $privacyMappedLabels.Count) -Color Cyan
        if ($privacyUnmappedLabels.Count -gt 0) {
            RS-Log ("PLAN Privacy unmapped labels (no backend action yet): {0}" -f $privacyUnmappedLabels.Count) -Color Yellow
            foreach ($missingLabel in @($privacyUnmappedLabels | Select-Object -First 20)) {
                RS-Log ("PLAN Privacy unmapped: {0}" -f $missingLabel) -Color Yellow
            }
            if ($privacyUnmappedLabels.Count -gt 20) {
                RS-Log ("PLAN Privacy unmapped: ... and {0} more" -f ($privacyUnmappedLabels.Count - 20)) -Color Yellow
            }
        }
        foreach ($xEntry in $extraSecurityByLabel.GetEnumerator()) { RS-Log ("PLAN ExtraSecurity: {0} => {1}" -f $xEntry.Key, $xEntry.Value) -Color White }
        foreach ($aEntry in $advancedOptionsByLabel.GetEnumerator()) { RS-Log ("PLAN AdvancedOptions: {0} => {1}" -f $aEntry.Key, $aEntry.Value) -Color White }
        RS-Log ("PLAN AdvancedOptions effective: ETW AutoLogger sessions => {0}; Windows Event Log service => {1}; Remove language/capability payloads => {2}; Bypass HW checks => {3}; Setup without internet => {4}; Remove MSA in OOBE => {5}" -f $autoLoggersMode, $eventViewerMode, $languagePayloadTrimMode, $advancedBypassHwChecks, $advancedAllowOfflineSetup, $advancedRemoveMsaOobe) -Color White
        if ($edgeUninstallBetaMode -eq 'Enabled') {
            RS-Log "PLAN AdvancedOptions note: Edge uninstall (Beta) will run uninstall commands during first startup." -Color Yellow
        }
        if ($advancedBypassHwChecks) {
            RS-Log "PLAN AdvancedOptions warning: Bypassing TPM/Secure Boot checks reduces setup hardware guardrails." -Color Yellow
        }
        if ($advancedRemoveMsaOobe) {
            RS-Log "PLAN AdvancedOptions note: Microsoft account requirement will be removed during OOBE." -Color Yellow
        }
        foreach ($tweak in $checkedReg) {
            $tk = "{0}\{1} | {2}={3} ({4})" -f $tweak[0], $tweak[1], $tweak[2], $tweak[3], $tweak[4]
            RS-Log ("PLAN Registry: {0}" -f $tk) -Color White
        }
        RS-Log ("PLAN Summary: Appx={0}, AppRuntime={1}, Features={2}, Tasks={3}, Services={4}, Privacy={5}, ExtraSecurity={6}, AdvancedOptions={7}, Registry={8}" -f `
                $checkedAppxProvisioned.Count, $checkedRuntimeAppActions.Count, $checkedFeats.Count, $taskConfig.Count, $serviceConfig.Count, $privacyConfig.Count, $extraSecurityConfig.Count, $advancedOptionsByLabel.Count, $checkedReg.Count) -Color Cyan

        # Preflight: local oscdimg check. If missing, bootstrap is attempted in Phase 1.
        $oscdimgResolved = RS-ResolveOscdimgPath
        if ([string]::IsNullOrWhiteSpace($oscdimgResolved)) {
            [void](RS-EnsureOscdimg -AllowBootstrapInPhase1 $false)
            RS-Log "Preflight: oscdimg.exe not found locally. Phase 1 will try first-time official ADK bootstrap." -Color Yellow
        }
        else {
            RS-Log ("Preflight: oscdimg ready -> {0}" -f $oscdimgResolved) -Color Green
        }

        #──────────────────────────────────────────────────────────────────────
        # PHASE 1: Mount source ISO, copy contents, dismount, handle ESD
        #──────────────────────────────────────────────────────────────────────
        RS-Log '═══════ PHASE 1: Mounting Source ISO & Copying Contents ═══════' -Color Cyan
        RS-Progress 5
        RS-CheckCancel

        if ([string]::IsNullOrWhiteSpace($oscdimgResolved) -or -not (Test-Path -LiteralPath $oscdimgResolved -PathType Leaf)) {
            RS-Log "Phase 1: oscdimg.exe missing. Starting first-time bootstrap from official Microsoft ADK source..." -Color Yellow
            $oscdimgResolved = RS-EnsureOscdimg -AllowBootstrapInPhase1 $true
            if ([string]::IsNullOrWhiteSpace($oscdimgResolved) -or -not (Test-Path -LiteralPath $oscdimgResolved -PathType Leaf)) {
                throw "Phase 1 failed: unable to provision oscdimg.exe. Install Windows ADK Deployment Tools or place oscdimg.exe in .\tools\."
            }
            RS-Log ("Phase 1: oscdimg ready -> {0}" -f $oscdimgResolved) -Color Green
        }

        $mountDir = Join-Path $scrDir 'ISO'
        New-Item -ItemType Directory -Path $mountDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $scrDir 'WIM') -Force | Out-Null
        $wimMountDir = Join-Path $scrDir 'WIM'
        $scratchMarkerPath = Join-Path $scrDir $scratchMarkerName
        try {
            Set-Content -Path $scratchMarkerPath -Value ("Oximize scratch marker - {0}" -f (Get-Date -Format 'o')) -Encoding ASCII -Force
        }
        catch {
            RS-Log "Scratch marker warning: $_" -Color Yellow
        }
        $sync.MountDir = $mountDir
        $sync.WimMountDir = $wimMountDir

        RS-Log "Mounting ISO: $srcISO" -Color White
        try {
            $diskImg = Mount-DiskImage -ImagePath $srcISO -PassThru -ErrorAction Stop
        }
        catch [Microsoft.Management.Infrastructure.CimException] {
            $mountError = [string]$_.Exception.Message
            if ($mountError -match 'corrupted and unreadable') {
                throw ("Failed to mount source ISO: {0}`nWindows reported: {1}`nThis ISO appears corrupted or unreadable (commonly due to an interrupted/failed prior ISO build). Please select a known-good source ISO and retry." -f $srcISO, $mountError)
            }
            throw ("Failed to mount source ISO: {0}`nWindows reported: {1}" -f $srcISO, $mountError)
        }
        catch {
            throw ("Failed to mount source ISO: {0}`nError: {1}" -f $srcISO, $_.Exception.Message)
        }
        $sync.IsMounted = $true
        $driveLetter = ''
        for ($attempt = 1; $attempt -le 20; $attempt++) {
            Start-Sleep -Milliseconds 500
            try {
                $driveLetter = [string](($diskImg | Get-Volume | Select-Object -First 1).DriveLetter)
            }
            catch {
                $driveLetter = ''
            }
            if (-not [string]::IsNullOrWhiteSpace($driveLetter)) { break }
        }
        if ([string]::IsNullOrWhiteSpace($driveLetter)) {
            throw "ISO mounted but no drive letter was assigned."
        }
        RS-Log "ISO mounted at $driveLetter`:" -Color Green

        $robocopyCmd = Get-Command -Name robocopy.exe -ErrorAction SilentlyContinue
        if ($null -ne $robocopyCmd) {
            RS-Log "Using Robocopy engine for ISO file copy." -Color Cyan
            RS-Log "Copying ISO contents to $mountDir via Robocopy…" -Color White
            $robocopyArgs = @("${driveLetter}:\", $mountDir, '/E', '/COPYALL', '/R:2', '/W:1', '/NP')
            $robocopyOut = & robocopy.exe @robocopyArgs 2>&1
            $robocopyExit = $LASTEXITCODE
            if ($robocopyOut) {
                # Keep logs readable: show the first few lines of Robocopy output.
                @($robocopyOut | Select-Object -First 10) | ForEach-Object { RS-Log ("ROBOCOPY: " + $_) -Color White }
            }
            # Robocopy exit codes 0-7 are success/success-with-differences.
            if ($robocopyExit -le 7) {
                RS-Log "Robocopy completed successfully (exit $robocopyExit)." -Color Green
            }
            else {
                RS-Log "Robocopy failed (exit $robocopyExit). Attempting xcopy fallback." -Color Yellow
                & xcopy.exe "${driveLetter}:\" "$mountDir\" /E /H /Y /Q 2>&1 | ForEach-Object { RS-Log ("XCOPY: " + $_) -Color White }
                if ($LASTEXITCODE -notin @(0, 1)) {
                    throw "File copy failed: Robocopy exit $robocopyExit, XCopy exit $LASTEXITCODE"
                }
                RS-Log "Fallback copy via xcopy completed." -Color Green
            }
        }
        else {
            RS-Log "Robocopy not found. Using xcopy fallback." -Color Yellow
            & xcopy.exe "${driveLetter}:\" "$mountDir\" /E /H /Y /Q 2>&1 | ForEach-Object { RS-Log ("XCOPY: " + $_) -Color White }
            if ($LASTEXITCODE -notin @(0, 1)) {
                throw "File copy failed: xcopy exit $LASTEXITCODE"
            }
            RS-Log "ISO contents copied via xcopy." -Color Green
        }

        # Clear Read-Only attributes from copied files (crucial for DISM)
        # Some files can intermittently fail attribute updates (AV/race conditions);
        # do not fail the build for those isolated cases.
        RS-Log "Clearing Read-Only attributes..." -Color White
        $roClearedCount = 0
        $roFailed = New-Object System.Collections.Generic.List[string]
        Get-ChildItem -LiteralPath $mountDir -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object {
            $item = $_
            if (($item.Attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
                try {
                    $item.IsReadOnly = $false
                    $roClearedCount++
                }
                catch {
                    $roFailed.Add([string]$item.FullName)
                }
            }
        }
        if ($roFailed.Count -gt 0) {
            RS-Log ("Read-Only clear completed with warnings. Cleared={0}, Failed={1}" -f $roClearedCount, $roFailed.Count) -Color Yellow
            foreach ($failedPath in @($roFailed | Select-Object -First 5)) {
                RS-Log ("WARN Read-Only clear failed: {0}" -f $failedPath) -Color Yellow
            }
            if ($roFailed.Count -gt 5) {
                RS-Log ("WARN Read-Only clear: ... and {0} more file(s)" -f ($roFailed.Count - 5)) -Color Yellow
            }
        }
        else {
            RS-Log ("Read-Only attributes cleared. Updated files: {0}" -f $roClearedCount) -Color Green
        }
        foreach ($criticalImagePath in @(
                (Join-Path $mountDir 'sources\install.wim'),
                (Join-Path $mountDir 'sources\install.esd')
            )) {
            if (-not (Test-Path -LiteralPath $criticalImagePath)) { continue }
            try {
                $criticalItem = Get-Item -LiteralPath $criticalImagePath -Force -ErrorAction Stop
                if (($criticalItem.Attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
                    $criticalItem.IsReadOnly = $false
                }
            }
            catch {
                throw "Failed to clear Read-Only attribute on critical image file: $criticalImagePath"
            }
        }

        RS-Log "Dismounting source ISO…" -Color White
        Dismount-DiskImage -ImagePath $srcISO | Out-Null
        $sync.IsMounted = $false
        RS-CheckCancel

        # Detect WIM or ESD
        $wimPath = Join-Path $mountDir 'sources\install.wim'
        $esdPath = Join-Path $mountDir 'sources\install.esd'
        if (-not (Test-Path $wimPath)) {
            if (Test-Path $esdPath) {
                RS-Log "Found install.esd — converting to install.wim (all editions)..." -Color Yellow
                $convertedWim = Join-Path $scrDir 'install_converted.wim'
                if (Test-Path $convertedWim) {
                    Remove-Item -Path $convertedWim -Force -ErrorAction SilentlyContinue
                }

                $sourceEsdImages = @()
                try {
                    $sourceEsdImages = @(Get-WindowsImage -ImagePath $esdPath -ErrorAction Stop)
                }
                catch {
                    throw "Failed to read install.esd image indexes: $_"
                }
                if ($sourceEsdImages.Count -eq 0) {
                    throw "install.esd contains no readable image indexes."
                }

                $effectiveEsdCompression = if ($wimCompression -in @('None', 'Fast', 'Max')) { $wimCompression } else { 'Fast' }
                foreach ($esdImg in $sourceEsdImages) {
                    RS-CheckCancel
                    $srcIndex = [int]$esdImg.ImageIndex
                    try {
                        Export-WindowsImage -SourceImagePath $esdPath -SourceIndex $srcIndex -DestinationImagePath $convertedWim -CompressionType $effectiveEsdCompression -ErrorAction Stop | Out-Null
                        RS-Log "Converted ESD index $srcIndex -> WIM" -Color White
                    }
                    catch {
                        throw "ESD -> WIM export failed for index ${srcIndex}: $_"
                    }
                }

                Copy-Item $convertedWim -Destination $wimPath -Force
                Remove-Item -Path $convertedWim -Force -ErrorAction SilentlyContinue
                RS-Log ("ESD → WIM conversion complete. Preserved {0} edition(s)." -f $sourceEsdImages.Count) -Color Green
            }
            else {
                throw "No install.wim or install.esd found in ISO sources."
            }
        }
        $sync.WimPath = $wimPath
        RS-Log "PHASE 1 complete. WIM at: $wimPath" -Color Green
        RS-Progress 10
        RS-CheckCancel

        #──────────────────────────────────────────────────────────────────────
        # PHASE 2: Mount WIM, detect edition, log build info
        #──────────────────────────────────────────────────────────────────────
        RS-Log '═══════ PHASE 2: Mounting WIM ═══════' -Color Cyan
        RS-Progress 15

        $editions = @(Get-WindowsImage -ImagePath $wimPath)
        if ($editions.Count -eq 0) {
            throw "No edition indexes found in install.wim."
        }
        RS-Log "Found $($editions.Count) edition(s)." -Color White

        # Show edition selector on UI thread
        $sync.EditionsToSelect = $editions
        $selectedIndexes = @($editions | ForEach-Object { [int]$_.ImageIndex })
        $selIdxRaw = $sync.Form.Invoke([System.Func[Object]]$sync.ShowEditionSelector)
        $selIdx = 0
        if (-not [int]::TryParse([string]$selIdxRaw, [ref]$selIdx)) {
            $selIdx = $selectedIndexes[0]
        }
        if ($selectedIndexes -notcontains $selIdx) {
            RS-Log ("Edition selection '{0}' is invalid. Falling back to index {1}." -f $selIdxRaw, $selectedIndexes[0]) -Color Yellow
            $selIdx = $selectedIndexes[0]
        }
        $sync.SelectedIndex = $selIdx
        RS-Log "Selected edition index: $selIdx" -Color Green

        # Get build info from selected index
        $imgInfo = Get-WindowsImage -ImagePath $wimPath -Index $selIdx
        $buildStr = $imgInfo.Version
        RS-Log "Edition : $($imgInfo.ImageName)" -Color White
        RS-Log "Build   : $buildStr" -Color White
        RS-Log ("Arch    : {0}" -f (RS-GetArchDisplay -ArchitectureCode $imgInfo.Architecture)) -Color White

        # Hard gate: accept only Windows 11 editions.
        $editionName = [string]$imgInfo.ImageName
        if ([string]::IsNullOrWhiteSpace($editionName) -or ($editionName -notmatch '(?i)\bWindows\s*11\b')) {
            RS-Log "ABORT: Non-Windows 11 edition detected ($editionName)." -Color Red
            $sync.Form.Invoke([System.Action] {
                    [System.Windows.Forms.MessageBox]::Show(
                        "Detected edition:`n$editionName`n`nOnly Windows 11 ISO sources are supported.",
                        "Windows 11 Required", "OK", "Error") | Out-Null
                })
            throw "Windows 11 ISO required (edition name check)"
        }

        # Version check (runs on runspace thread, but MessageBox on UI)
        try {
            $ver = [Version]$buildStr
        }
        catch {
            $ver = [Version]'0.0.0'
        }
        $sync.BuildVersion = $ver
        if ($ver -lt [Version]'10.0.10240') {
            RS-Log "ABORT: Unsupported build $buildStr." -Color Red
            $sync.Form.Invoke([System.Action] {
                    [System.Windows.Forms.MessageBox]::Show(
                        "Unsupported Windows version: $buildStr", "Abort", "OK", "Error") | Out-Null
                })
            throw "Unsupported Windows build"
        }
        if ($ver -lt [Version]'10.0.21996') {
            RS-Log "ABORT: Windows 10 detected ($buildStr). Only Windows 11 ISOs are supported." -Color Red
            $sync.Form.Invoke([System.Action] {
                    [System.Windows.Forms.MessageBox]::Show(
                        "Detected Windows 10 ($buildStr).`n`nOnly Windows 11 ISO sources are supported.",
                        "Windows 11 Required", "OK", "Error") | Out-Null
                })
            throw "Windows 11 ISO required"
        }
        if ($ver -ge [Version]'10.0.26100') {
            RS-Log "24H2+ detected — Expedited App key removal will run." -Color Cyan
            $sync.Remove24H2Keys = $true
        }

        RS-Log "Mounting WIM (index $selIdx) to $wimMountDir…" -Color White
        $scrDir2 = $wimMountDir
        RS-RunDism @('/Mount-Wim', "/WimFile:$wimPath", "/Index:$selIdx", "/MountDir:$scrDir2")
        $sync.IsWimMounted = $true
        RS-Log "WIM mounted at $scrDir2" -Color Green
        RS-Progress 20
        RS-CheckCancel

        #──────────────────────────────────────────────────────────────────────
        # PHASE 3: Driver Package Injection (install.wim)
        #──────────────────────────────────────────────────────────────────────
        RS-Log '═══════ PHASE 3: Injecting Driver Packages ═══════' -Color Cyan
        if ([string]::IsNullOrWhiteSpace($driverSourceDir)) {
            RS-Log "No driver package source folder selected. Skipping driver package injection." -Color White
        }
        else {
            $driverInfFiles = if ($driverRecurse) {
                Get-ChildItem -Path $driverSourceDir -Filter '*.inf' -Recurse -File -ErrorAction SilentlyContinue
            }
            else {
                Get-ChildItem -Path $driverSourceDir -Filter '*.inf' -File -ErrorAction SilentlyContinue
            }
            if ($null -eq $driverInfFiles -or $driverInfFiles.Count -eq 0) {
                RS-Log "No .inf files found in driver package source folder ($driverSourceDir). Skipping driver package injection." -Color Yellow
            }
            else {
                $driverArg = "/Driver:$driverSourceDir"
                $recurseArg = if ($driverRecurse) { '/Recurse' } else { $null }
                RS-Log "Driver package source: $driverSourceDir" -Color White
                RS-Log "Discovered .inf files: $($driverInfFiles.Count)" -Color White

                if ($injectInstallDrivers) {
                    RS-Log "Adding driver packages to mounted install.wim image..." -Color White
                    $installArgs = @("/Image:$scrDir2", '/Add-Driver', $driverArg)
                    if ($recurseArg) { $installArgs += $recurseArg }
                    RS-RunDism $installArgs
                    RS-Log "install.wim driver package injection complete." -Color Green
                }
                else {
                    RS-Log "install.wim injection disabled." -Color White
                }

            }
        }
        RS-Progress 25
        RS-CheckCancel

        #──────────────────────────────────────────────────────────────────────
        # PHASE 4: Appx package removal
        #──────────────────────────────────────────────────────────────────────
        RS-Log '═══════ PHASE 4: Removing Appx Packages ═══════' -Color Cyan
        RS-Progress 33
        $provPackages = @()
        try {
            $provPackages = @(Get-AppxProvisionedPackage -Path $scrDir2 -ErrorAction Stop)
            RS-Log ("Discovered provisioned Appx packages in image: {0}" -f $provPackages.Count) -Color White
        }
        catch {
            RS-Log "ERROR reading provisioned Appx package list: $_" -Color Red
            throw
        }
        foreach ($pkg in $checkedAppxProvisioned) {
            RS-CheckCancel
            try {
                $found = @($provPackages | Where-Object {
                        ([string]$_.PackageName -like "*$pkg*") -or
                        ([string]$_.DisplayName -like "*$pkg*")
                    })
                if ($found.Count -gt 0) {
                    foreach ($entry in $found) {
                        $pkgName = [string]$entry.PackageName
                        if ([string]::IsNullOrWhiteSpace($pkgName)) { continue }
                        Remove-AppxProvisionedPackage -Path $scrDir2 -PackageName $pkgName -ErrorAction Stop | Out-Null
                        RS-Log ("Removed: {0} (requested by {1})" -f $pkgName, $pkg) -Color Green
                        $provPackages = @($provPackages | Where-Object { [string]$_.PackageName -ne $pkgName })
                    }
                }
                else {
                    RS-Log "Not found (skipped): $pkg" -Color Yellow
                }
            }
            catch {
                RS-Log "ERROR removing $pkg`: $_" -Color Red
            }
        }
        try {
            $postProvPackages = @(Get-AppxProvisionedPackage -Path $scrDir2 -ErrorAction Stop)
            $remainingRequested = [System.Collections.Generic.List[string]]::new()
            foreach ($pkg in $checkedAppxProvisioned) {
                RS-CheckCancel
                $stillPresent = @($postProvPackages | Where-Object {
                        ([string]$_.PackageName -like "*$pkg*") -or
                        ([string]$_.DisplayName -like "*$pkg*")
                    })
                if ($stillPresent.Count -gt 0) { [void]$remainingRequested.Add([string]$pkg) }
            }
            if ($remainingRequested.Count -gt 0) {
                RS-Log ("Appx verification: {0} requested package pattern(s) still provisioned in image." -f $remainingRequested.Count) -Color Yellow
                foreach ($left in @($remainingRequested | Select-Object -First 20)) {
                    RS-Log ("Appx still present: {0}" -f $left) -Color Yellow
                }
                if ($remainingRequested.Count -gt 20) {
                    RS-Log ("Appx still present: ... and {0} more" -f ($remainingRequested.Count - 20)) -Color Yellow
                }
            }
            else {
                RS-Log "Appx verification: all requested package patterns are removed from provisioned image list." -Color Green
            }
        }
        catch {
            RS-Log "Appx post-removal verification warning: $_" -Color Yellow
        }
        RS-Progress 40
        RS-CheckCancel

        #──────────────────────────────────────────────────────────────────────
        # PHASE 5: Optional feature removal
        #──────────────────────────────────────────────────────────────────────
        RS-Log '═══════ PHASE 5: Disabling Optional Features ═══════' -Color Cyan
        RS-Progress 43
        $availableOptionalFeatures = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        try {
            $optionalFeatureInventory = @(Get-WindowsOptionalFeature -Path $scrDir2 -ErrorAction Stop)
            foreach ($featureInfo in $optionalFeatureInventory) {
                $featureName = [string]$featureInfo.FeatureName
                if ([string]::IsNullOrWhiteSpace($featureName)) { continue }
                [void]$availableOptionalFeatures.Add($featureName)
            }
            RS-Log ("Optional feature inventory loaded: {0} feature name(s)." -f $availableOptionalFeatures.Count) -Color White
        }
        catch {
            RS-Log "Optional feature inventory warning: $_" -Color Yellow
        }
        $optionalFeatureAliasMap = @{
            'MicrosoftWindowsPowerShellV2'     = @('MicrosoftWindowsPowerShellV2', 'WindowsPowerShellV2')
            'MicrosoftWindowsPowerShellV2Root' = @('MicrosoftWindowsPowerShellV2Root', 'WindowsPowerShellV2Root')
        }
        foreach ($featEntry in $checkedFeats.GetEnumerator()) {
            RS-CheckCancel
            $feat = $featEntry.Name
            $state = $featEntry.Value
            $resolvedFeat = [string]$feat
            if ($resolvedFeat -notlike '*~~~~*' -and $availableOptionalFeatures.Count -gt 0) {
                if ($optionalFeatureAliasMap.ContainsKey($resolvedFeat)) {
                    $resolvedCandidate = @($optionalFeatureAliasMap[$resolvedFeat] | Where-Object { $availableOptionalFeatures.Contains([string]$_) } | Select-Object -First 1)
                    if ($resolvedCandidate.Count -gt 0) {
                        $resolvedFeat = [string]$resolvedCandidate[0]
                    }
                }
                if (-not $availableOptionalFeatures.Contains($resolvedFeat)) {
                    RS-Log ("Optional feature missing in image (skipped): {0}" -f $feat) -Color White
                    continue
                }
            }
            try {
                if ($state -eq 'Disabled') {
                    if ($resolvedFeat -like '*~~~~*') {
                        # Capability
                        Remove-WindowsCapability -Path $scrDir2 -Name $resolvedFeat -ErrorAction Stop | Out-Null
                        RS-Log "Removed capability: $resolvedFeat" -Color Green
                    }
                    else {
                        # Optional Feature
                        Disable-WindowsOptionalFeature -Path $scrDir2 -FeatureName $resolvedFeat -NoRestart -ErrorAction Stop | Out-Null
                        RS-Log "Disabled feature: $resolvedFeat" -Color Green
                    }
                }
                elseif ($state -eq 'Enabled') {
                    if ($resolvedFeat -like '*~~~~*') {
                        RS-RunDism @("/Image:$scrDir2", '/Add-Capability', "/CapabilityName:$resolvedFeat")
                        RS-Log "Enabled capability: $resolvedFeat" -Color Green
                    }
                    else {
                        Enable-WindowsOptionalFeature -Path $scrDir2 -FeatureName $resolvedFeat -NoRestart -ErrorAction Stop | Out-Null
                        RS-Log "Enabled feature: $resolvedFeat" -Color Green
                    }
                }
            }
            catch {
                RS-Log "WARNING processing optional component $resolvedFeat`: $_" -Color Yellow
            }
        }
        RS-Progress 48
        RS-CheckCancel

        #──────────────────────────────────────────────────────────────────────
        # PHASE 5.5: Optional language/capability payload trimming
        #──────────────────────────────────────────────────────────────────────
        if ($languagePayloadTrimMode -eq 'Enabled') {
            RS-Log '═══════ PHASE 5.5: Trimming Language & Capability Payloads ═══════' -Color Cyan
            RS-Progress 49

            $keepLanguageCodes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $primaryLang = RS-NormalizeLangCode -Code $installerLangCode
            if ([string]::IsNullOrWhiteSpace($primaryLang)) { $primaryLang = 'en-US' }
            [void]$keepLanguageCodes.Add($primaryLang)
            # Keep en-US as a safety fallback to reduce setup/runtime break risk.
            [void]$keepLanguageCodes.Add('en-US')
            RS-Log ("Keeping language resources for: {0}" -f ((@($keepLanguageCodes) | Sort-Object) -join ', ')) -Color White

            $removedLangCapabilities = 0
            $removedLangPackages = 0
            $removedLangFolders = 0
            $removedLangFiles = 0

            try {
                $languageCapabilities = @(Get-WindowsCapability -Path $scrDir2 -ErrorAction Stop | Where-Object {
                        ([string]$_.Name -match '^(?i)Language\.') -and ([string]$_.State -match 'Installed')
                    })
                foreach ($cap in $languageCapabilities) {
                    RS-CheckCancel
                    $capName = [string]$cap.Name
                    $capLang = RS-ExtractLanguageCodeFromText -Text $capName
                    if ([string]::IsNullOrWhiteSpace($capLang)) { continue }
                    if ($keepLanguageCodes.Contains($capLang)) { continue }
                    try {
                        Remove-WindowsCapability -Path $scrDir2 -Name $capName -ErrorAction Stop | Out-Null
                        $removedLangCapabilities++
                        RS-Log "Removed language capability: $capName" -Color Green
                    }
                    catch {
                        RS-Log "Language capability warning ($capName): $_" -Color Yellow
                    }
                }
            }
            catch {
                RS-Log "Language capability inventory warning: $_" -Color Yellow
            }

            try {
                $languagePackages = @(Get-WindowsPackage -Path $scrDir2 -ErrorAction Stop | Where-Object {
                        ([string]$_.PackageState -match 'Installed') -and
                        ([string]$_.PackageName -match '(?i)(LanguagePack|LanguageFeatures|LanguageExperiencePack|Client-LanguagePack|OCR|Speech|TextToSpeech|Handwriting)')
                    })
                foreach ($pkg in $languagePackages) {
                    RS-CheckCancel
                    $pkgName = [string]$pkg.PackageName
                    $pkgLang = RS-ExtractLanguageCodeFromText -Text $pkgName
                    if ([string]::IsNullOrWhiteSpace($pkgLang)) { continue }
                    if ($keepLanguageCodes.Contains($pkgLang)) { continue }
                    try {
                        Remove-WindowsPackage -Path $scrDir2 -PackageName $pkgName -NoRestart -ErrorAction Stop | Out-Null
                        $removedLangPackages++
                        RS-Log "Removed language package: $pkgName" -Color Green
                    }
                    catch {
                        RS-Log "Language package warning ($pkgName): $_" -Color Yellow
                    }
                }
            }
            catch {
                RS-Log "Language package inventory warning: $_" -Color Yellow
            }

            $languageFolderRoots = @(
                (Join-Path $mountDir 'sources'),
                (Join-Path $mountDir 'boot\resources'),
                (Join-Path $mountDir 'efi\microsoft\boot')
            )
            foreach ($root in $languageFolderRoots) {
                if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
                $langDirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object {
                        [string]$_.Name -match '^(?i)[a-z]{2}-[a-z]{2}$'
                    })
                foreach ($langDir in $langDirs) {
                    RS-CheckCancel
                    $dirLang = RS-NormalizeLangCode -Code $langDir.Name
                    if ([string]::IsNullOrWhiteSpace($dirLang)) { continue }
                    if ($keepLanguageCodes.Contains($dirLang)) { continue }
                    try {
                        Remove-Item -LiteralPath $langDir.FullName -Recurse -Force -ErrorAction Stop
                        $removedLangFolders++
                        RS-Log "Pruned ISO language folder: $($langDir.FullName)" -Color Green
                    }
                    catch {
                        RS-Log "Language folder prune warning ($($langDir.FullName)): $_" -Color Yellow
                    }
                }
            }

            $langPackRoot = Join-Path $mountDir 'sources\langpacks'
            if (Test-Path -LiteralPath $langPackRoot -PathType Container) {
                $langPackFiles = @(Get-ChildItem -LiteralPath $langPackRoot -Recurse -File -ErrorAction SilentlyContinue)
                foreach ($lpFile in $langPackFiles) {
                    RS-CheckCancel
                    $fileLang = RS-ExtractLanguageCodeFromText -Text $lpFile.Name
                    if ([string]::IsNullOrWhiteSpace($fileLang)) { continue }
                    if ($keepLanguageCodes.Contains($fileLang)) { continue }
                    try {
                        Remove-Item -LiteralPath $lpFile.FullName -Force -ErrorAction Stop
                        $removedLangFiles++
                        RS-Log "Pruned language payload file: $($lpFile.FullName)" -Color Green
                    }
                    catch {
                        RS-Log "Language payload file prune warning ($($lpFile.FullName)): $_" -Color Yellow
                    }
                }
            }

            RS-Log ("Language payload trim complete: capabilities removed={0}, packages removed={1}, folders pruned={2}, files pruned={3}" -f `
                    $removedLangCapabilities, $removedLangPackages, $removedLangFolders, $removedLangFiles) -Color Cyan
        }
        else {
            RS-Log "PHASE 5.5 skipped: Remove more language/capability payloads is Disabled." -Color White
        }
        RS-CheckCancel

        #──────────────────────────────────────────────────────────────────────
        # PHASE 6: Registry hive modifications
        #──────────────────────────────────────────────────────────────────────
        RS-Log '═══════ PHASE 6: Registry Hive Modifications ═══════' -Color Cyan
        RS-Progress 50

        # Load all hives
        RS-Log "Loading registry hives…" -Color White
        $hives = [ordered]@{
            'HKLM\zCOMPONENTS' = "$scrDir2\Windows\System32\config\COMPONENTS"
            'HKLM\zDEFAULT'    = "$scrDir2\Windows\System32\config\default"
            'HKLM\zNTUSER'     = "$scrDir2\Users\Default\NTUSER.DAT"
            'HKLM\zSOFTWARE'   = "$scrDir2\Windows\System32\config\SOFTWARE"
            'HKLM\zSYSTEM'     = "$scrDir2\Windows\System32\config\SYSTEM"
        }
        RS-Log "Checking for stale offline hive mounts from previous runs..." -Color White
        RS-UnloadRegistryHiveMounts -HiveKeys $registryHiveMountKeys -Context 'pre-load'
        Start-Sleep -Milliseconds 200
        foreach ($h in $hives.GetEnumerator()) {
            if (-not (Test-Path -LiteralPath $h.Value -PathType Leaf)) {
                throw ("Offline hive file not found: {0}" -f $h.Value)
            }
            try {
                RS-RunReg 'load' @($h.Key, $h.Value)
            }
            catch {
                throw ("Failed to load offline hive {0} from '{1}'. {2}" -f $h.Key, $h.Value, [string]$_)
            }
        }

        # Apply selected registry tweaks
        $registryApplyWarnings = 0
        foreach ($tweak in $checkedReg) {
            RS-CheckCancel
            $hive = $tweak[0]   # e.g. zSOFTWARE
            $keyPath = $tweak[1]
            $valName = $tweak[2]
            $valData = $tweak[3]
            $valType = $tweak[4]
            $fullKey = "HKLM\$hive\$keyPath"
            try {
                # RS-SetReg (reg add /v ...) creates the key path when possible.
                # Some offline hive paths can deny writes; those should not abort the whole build.
                RS-SetReg -Key $fullKey -ValName $valName -ValData $valData -ValType $valType
                RS-Log "SET $fullKey → $valName = $valData" -Color Green
            }
            catch {
                $regErr = [string]$_
                if ($regErr -match '(?i)Access is denied') {
                    RS-Log ("Registry tweak skipped (protected ACL): {0} | {1}={2} ({3})" -f $fullKey, $valName, $valData, $valType) -Color White
                }
                else {
                    $registryApplyWarnings++
                    RS-Log ("Registry tweak warning (skipped): {0} | {1}={2} ({3}) | {4}" -f $fullKey, $valName, $valData, $valType, $regErr) -Color Yellow
                }
                continue
            }
        }
        if ($registryApplyWarnings -gt 0) {
            RS-Log ("Registry phase completed with {0} warning(s). Build will continue." -f $registryApplyWarnings) -Color Yellow
        }

        # Windows 11 24H2+: delete Expedited App keys
        if ($sync.Remove24H2Keys) {
            RS-Log "Removing 24H2+ Expedited App scheduler keys…" -Color Cyan
            foreach ($k in $exKeys) {
                try {
                    $regProviderPath = if ($k -match '^HKLM\\') {
                        'Registry::HKEY_LOCAL_MACHINE\' + ($k -replace '^HKLM\\', '')
                    }
                    else {
                        $null
                    }

                    if ($regProviderPath -and (Test-Path -LiteralPath $regProviderPath)) {
                        RS-RunReg 'delete' @($k, '/f')
                        RS-Log "Deleted key: $k" -Color Green
                    }
                    else {
                        RS-Log "Key missing (skipped): $k" -Color Yellow
                    }
                }
                catch {
                    RS-Log "Failed deleting key: $k | $_" -Color Yellow
                }
            }
        }

        # Apply selected service startup modes directly in offline registry.
        # This guarantees service mode changes even if FirstStartup.ps1 is skipped by setup.
        RS-Log "Applying selected service startup modes to offline image..." -Color Cyan
        $svcStartMap = @{
            'Automatic' = 2
            'Manual'    = 3
            'Disabled'  = 4
        }
        $controlSets = @()
        try {
            $controlSets = @(
                Get-ChildItem -Path 'Registry::HKEY_LOCAL_MACHINE\zSYSTEM' -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -match '^ControlSet\d{3}$' } |
                ForEach-Object { [string]$_.PSChildName }
            )
        }
        catch {
            $controlSets = @()
        }
        if ($controlSets.Count -eq 0) { $controlSets = @('ControlSet001') }

        foreach ($svcEntry in $serviceConfig.GetEnumerator()) {
            $svcName = [string]$svcEntry.Key
            $svcMode = [string]$svcEntry.Value
            if (-not $svcStartMap.ContainsKey($svcMode)) { continue }
            $startVal = [string]$svcStartMap[$svcMode]
            $updatedSets = 0
            foreach ($cs in $controlSets) {
                $svcReg = "HKLM\zSYSTEM\$cs\Services\$svcName"
                $svcRegProvider = 'Registry::HKEY_LOCAL_MACHINE\zSYSTEM\' + $cs + '\Services\' + $svcName
                if (-not (Test-Path -LiteralPath $svcRegProvider)) { continue }
                try {
                    RS-RunReg 'add' @($svcReg, '/v', 'Start', '/t', 'REG_DWORD', '/d', $startVal, '/f') $false $false
                    $updatedSets++
                }
                catch {
                    $svcErr = [string]$_
                    if ($svcErr -match '(?i)Access is denied') {
                        RS-Log ("Service offline startup unchanged (protected ACL): {0} => {1} ({2})" -f $svcName, $svcMode, $cs) -Color White
                    }
                    else {
                        RS-Log ("Service offline update warning: {0} => {1} ({2}) | {3}" -f $svcName, $svcMode, $cs, $svcErr) -Color Yellow
                    }
                }
            }
            if ($updatedSets -gt 0) {
                RS-Log ("Service offline startup set: {0} => {1} ({2} control set(s))" -f $svcName, $svcMode, $updatedSets) -Color Green
            }
            else {
                RS-Log ("Service key missing offline (skipped): {0}" -f $svcName) -Color White
            }
        }

        # Unload hives (force GC first)
        [GC]::Collect(); [GC]::WaitForPendingFinalizers(); Start-Sleep -Milliseconds 500
        RS-UnloadRegistryHiveMounts -HiveKeys ($hives.Keys | Sort-Object -Descending) -Context 'phase 6 completion'
        RS-Log "Registry hives unloaded." -Color Green
        RS-Progress 55
        RS-CheckCancel

        #──────────────────────────────────────────────────────────────────────
        # PHASE 7: Write FirstStartup.ps1 into WIM
        #──────────────────────────────────────────────────────────────────────
        RS-Log '═══════ PHASE 7: Writing FirstStartup.ps1 ═══════' -Color Cyan
        RS-Progress 58

        $fsPath = "$scrDir2\Windows\FirstStartup.ps1"

        # Build schtasks and service disable lines for the first-startup script
        $taskLines = ($taskConfig.Keys | ForEach-Object {
                $mode = $taskConfig[$_]
                if ($mode -eq 'Disabled') { "  schtasks /Change /TN `"$_`" /Disable 2>`$null" }
                elseif ($mode -eq 'Enabled') { "  schtasks /Change /TN `"$_`" /Enable 2>`$null" }
            }) -join "`n"
        $svcLines = ($serviceConfig.Keys | ForEach-Object {
                $mode = $serviceConfig[$_]
                "  Set-Service -Name '$_' -StartupType $mode -ErrorAction SilentlyContinue"
            }) -join "`n"

        $asrSafeRules = @(
            'D4F940AB-401B-4EFC-AADC-AD5F3C50688A',
            '3B576869-A4EC-4529-8536-B80A7769E899',
            '75668C1F-73B5-4CF0-BB93-3ECF5CB7CC84',
            '92E97FA1-2EDF-4476-BDD6-9DD0B4DDDC7B',
            '26190899-1602-49E8-8B27-EB1D0A1CE869',
            'BE9BA2D9-53EA-4CDC-84E5-9B1EEEE46550'
        )
        $asrModerateRules = @(
            '5BEB7EFE-FD9A-4556-801D-275E5FFC04CC',
            'D3E037E1-3EB8-44C8-A917-57927947596D',
            '7674BA52-37EB-4A4F-A9A1-F0F9A1619A2C',
            '9E6C4E1F-7D60-472F-BA1A-A39EF669E4B2',
            'D1E49AAC-8F56-4280-B9BA-993A6D77406C'
        )
        $asrAggressiveRules = @(
            '01443614-CD74-433A-B99E-2ECDC07BFC25',
            'C1DB55AB-C21A-4637-BB3F-A12568109D35',
            'B2B3F03D-6A65-4F7B-A9C7-1C7EF74A9BA4'
        )
        $allAsrRules = @($asrSafeRules + $asrModerateRules + $asrAggressiveRules)

        $asrActionsFirst = @()
        $asrActionsAfter = $null
        $sampleConsent = 1
        # UAC: 5 = default notify level, 2 = always notify.
        $uacConsentPromptAdmin = 5
        switch ($securityPreset) {
            'Balanced' {
                foreach ($r in $asrSafeRules) { $asrActionsFirst += 1 }
                foreach ($r in $asrModerateRules) { $asrActionsFirst += 2 }
                foreach ($r in $asrAggressiveRules) { $asrActionsFirst += 0 }
                $sampleConsent = 1
                $uacConsentPromptAdmin = 5
            }
            'Hardened' {
                # First run safety mode
                foreach ($r in $asrSafeRules) { $asrActionsFirst += 1 }
                foreach ($r in $asrModerateRules) { $asrActionsFirst += 2 }
                foreach ($r in $asrAggressiveRules) { $asrActionsFirst += 0 }
                $sampleConsent = 1
                $uacConsentPromptAdmin = 2
                # After first successful login
                $asrActionsAfter = @()
                foreach ($r in $asrSafeRules) { $asrActionsAfter += 1 }
                foreach ($r in $asrModerateRules) { $asrActionsAfter += 1 }
                foreach ($r in $asrAggressiveRules) { $asrActionsAfter += 0 }
            }
            'Maximum' {
                foreach ($r in $allAsrRules) { $asrActionsFirst += 1 }
                $sampleConsent = 3
                $uacConsentPromptAdmin = 2
            }
            default {
                foreach ($r in $asrSafeRules) { $asrActionsFirst += 1 }
                foreach ($r in $asrModerateRules) { $asrActionsFirst += 2 }
                foreach ($r in $asrAggressiveRules) { $asrActionsFirst += 0 }
                $sampleConsent = 1
                $uacConsentPromptAdmin = 5
            }
        }

        $asrIdsLiteral = "@('" + ($allAsrRules -join "','") + "')"
        $asrFirstLiteral = "@(" + (($asrActionsFirst | ForEach-Object { [string]$_ }) -join ',') + ")"
        $asrAfterLiteral = if ($null -ne $asrActionsAfter) { "@(" + (($asrActionsAfter | ForEach-Object { [string]$_ }) -join ',') + ")" } else { $null }
        $removedPkgPatternsLiteral = "@('" + (($checkedAppxProvisioned | ForEach-Object { [string]$_ }) -join "','") + "')"
        $autoLoggersLiteral = "@('" + (($AutoLoggersForceDisabled | ForEach-Object { [string]$_ }) -join "','") + "')"
        $autoLoggerStartValue = if ($autoLoggersMode -eq 'Enabled') { 1 } else { 0 }
        $eventViewerScriptLines = ''
        switch ($eventViewerMode) {
            'Disabled' {
                $eventViewerScriptLines += "New-Item 'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog' -Force | Out-Null`n"
                $eventViewerScriptLines += "Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog' -Name 'Start' -Value 4 -Type DWord -ErrorAction SilentlyContinue`n"
                $eventViewerScriptLines += "Stop-Service -Name 'EventLog' -Force -ErrorAction SilentlyContinue`n"
                $eventViewerScriptLines += "Set-Service -Name 'EventLog' -StartupType Disabled -ErrorAction SilentlyContinue`n"
            }
            'Enabled' {
                $eventViewerScriptLines += "New-Item 'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog' -Force | Out-Null`n"
                $eventViewerScriptLines += "Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog' -Name 'Start' -Value 2 -Type DWord -ErrorAction SilentlyContinue`n"
                $eventViewerScriptLines += "Set-Service -Name 'EventLog' -StartupType Automatic -ErrorAction SilentlyContinue`n"
                $eventViewerScriptLines += "Start-Service -Name 'EventLog' -ErrorAction SilentlyContinue`n"
            }
        }
        $runtimeRegLines = ''
        foreach ($t in $checkedReg) {
            $hive = [string]$t[0]
            $keyPath = [string]$t[1]
            $valueName = [string]$t[2]
            $valueData = $t[3]
            $valueType = [string]$t[4]

            $psHive = switch ($hive) {
                'zSOFTWARE' { 'HKLM:' }
                'zNTUSER' { 'HKCU:' }
                default { $null }
            }
            if ([string]::IsNullOrWhiteSpace($psHive)) { continue }

            $keyLiteral = ($keyPath -replace "'", "''")
            $nameLiteral = ($valueName -replace "'", "''")
            $typeLiteral = switch -Regex ($valueType) {
                '^(REG_DWORD|DWORD)$' { 'DWord'; break }
                '^(REG_QWORD|QWORD)$' { 'QWord'; break }
                '^(REG_SZ|STRING)$' { 'String'; break }
                '^(REG_EXPAND_SZ|EXPAND.*)$' { 'ExpandString'; break }
                default { 'String' }
            }
            $dataLiteral = if ($typeLiteral -in @('DWord', 'QWord')) {
                [string]$valueData
            }
            else {
                "'{0}'" -f (([string]$valueData) -replace "'", "''")
            }

            $runtimeRegLines += "New-Item '{0}\{1}' -Force | Out-Null`n" -f $psHive, $keyLiteral
            $runtimeRegLines += "Set-ItemProperty '{0}\{1}' -Name '{2}' -Value {3} -Type {4} -ErrorAction SilentlyContinue`n" -f $psHive, $keyLiteral, $nameLiteral, $dataLiteral, $typeLiteral
        }
        $advancedStartupBlock = if ($advancedFirstStartupLines.Count -gt 0) { ($advancedFirstStartupLines -join "`n") + "`n" } else { '' }
        $appRuntimeStartupBlock = if ($appRuntimeFirstStartupLines.Count -gt 0) { ($appRuntimeFirstStartupLines -join "`n") + "`n" } else { '' }
        $extraSecurityStartupBlock = if ($extraSecurityFirstStartupLines.Count -gt 0) { ($extraSecurityFirstStartupLines -join "`n") + "`n" } else { '' }
        $privacyStartupBlock = if ($privacyFirstStartupLines.Count -gt 0) { ($privacyFirstStartupLines -join "`n") + "`n" } else { '' }
        $taskbarWidgetsValue = if ($widgetsMode -eq 'Enabled') { 1 } else { 0 }


        $fsContent = "# Oximize OS FirstStartup.ps1 — runs once at first logon, then self-deletes`n"
        $fsContent += "`$ErrorActionPreference = 'SilentlyContinue'`n`n"
        $fsContent += "# Remove taskbar pins`n"
        $fsContent += "`$regKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband'`n"
        $fsContent += "Remove-Item -Path `$regKey -Recurse -Force -ErrorAction SilentlyContinue`n`n"
        $fsContent += "# Delete Edge desktop shortcuts`n"
        $fsContent += "Remove-Item -Path `"`$env:PUBLIC\Desktop\Microsoft Edge.lnk`" -Force -ErrorAction SilentlyContinue`n"
        $fsContent += "Remove-Item -Path `"`$env:USERPROFILE\Desktop\Microsoft Edge.lnk`" -Force -ErrorAction SilentlyContinue`n`n"
        $fsContent += "# Disable Recall if present`n"
        $fsContent += "`$recallSvc = Get-Service -Name 'RecallService' -ErrorAction SilentlyContinue`n"
        $fsContent += "if (`$recallSvc) { Set-Service -Name RecallService -StartupType Disabled -ErrorAction SilentlyContinue }`n`n"
        $fsContent += "# Apply Start Menu / notification registry keys`n"
        $fsContent += "New-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Force | Out-Null`n"
        $fsContent += "Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarMn'           -Value 0 -Type DWord`n"
        $fsContent += "Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarDa'           -Value $taskbarWidgetsValue -Type DWord`n"
        $fsContent += "Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowTaskViewButton'   -Value 0 -Type DWord`n"
        $fsContent += "Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'Start_ShowRecentList' -Value 0 -Type DWord`n"
        $fsContent += "New-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Force | Out-Null`n"
        $fsContent += "Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -Value 0 -Type DWord`n`n"
        $fsContent += "# Re-apply selected registry tweaks to live HKLM/HKCU at first logon (ensures both machine and current-user contexts)`n$runtimeRegLines`n"
        if (-not [string]::IsNullOrWhiteSpace($appRuntimeStartupBlock)) {
            $fsContent += "# App package runtime actions`n$appRuntimeStartupBlock`n"
        }
        if (-not [string]::IsNullOrWhiteSpace($privacyStartupBlock)) {
            $fsContent += "# Privacy runtime actions`n$privacyStartupBlock`n"
        }
        $fsContent += "# Disable selected Scheduled Tasks`n$taskLines`n`n"
        $fsContent += "# Disable selected Services`n$svcLines`n`n"
        $fsContent += "# Auto loggers mode: $autoLoggersMode`n"
        $fsContent += "`$autoLoggers = $autoLoggersLiteral`n"
        $fsContent += "foreach (`$name in `$autoLoggers) {`n"
        $fsContent += "  `$k = 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\' + `$name`n"
        $fsContent += "  if (Test-Path `$k) { Set-ItemProperty -Path `$k -Name 'Start' -Value $autoLoggerStartValue -Type DWord -ErrorAction SilentlyContinue }`n"
        $fsContent += "}`n`n"
        if (-not [string]::IsNullOrWhiteSpace($eventViewerScriptLines)) {
            $fsContent += "# Event viewer mode: $eventViewerMode`n$eventViewerScriptLines`n"
        }
        if (-not [string]::IsNullOrWhiteSpace($advancedStartupBlock)) {
            $fsContent += "# Advanced setup runtime actions`n$advancedStartupBlock`n"
        }
        if (-not [string]::IsNullOrWhiteSpace($extraSecurityStartupBlock)) {
            $fsContent += "# Security hardening runtime actions`n$extraSecurityStartupBlock`n"
        }
        $fsContent += "# Prevent removed apps from silently returning (manual install still possible)`n"
        $fsContent += "New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Force | Out-Null`n"
        $fsContent += "Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableWindowsConsumerFeatures' -Value 1 -Type DWord`n"
        $fsContent += "New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -Force | Out-Null`n"
        $fsContent += "Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -Name 'AutoDownload' -Value 2 -Type DWord`n"
        $fsContent += "New-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Force | Out-Null`n"
        $fsContent += "Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'ContentDeliveryAllowed' -Value 0 -Type DWord`n"
        $fsContent += "Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'OemPreInstalledAppsEnabled' -Value 0 -Type DWord`n"
        $fsContent += "Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'PreInstalledAppsEnabled' -Value 0 -Type DWord`n"
        $fsContent += "Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SilentInstalledAppsEnabled' -Value 0 -Type DWord`n"
        $fsContent += "`$removedAppPatterns = $removedPkgPatternsLiteral`n"
        $fsContent += "foreach (`$pattern in `$removedAppPatterns) {`n"
        $fsContent += "  Get-AppxPackage -AllUsers | Where-Object { `$_.PackageName -like ('*' + `$pattern + '*') } | ForEach-Object { Remove-AppxPackage -AllUsers -Package `$_.PackageFullName -ErrorAction SilentlyContinue }`n"
        $fsContent += "  Get-AppxProvisionedPackage -Online | Where-Object { (`$_.DisplayName -like ('*' + `$pattern + '*')) -or (`$_.PackageName -like ('*' + `$pattern + '*')) } | ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName `$_.PackageName -AllUsers -ErrorAction SilentlyContinue | Out-Null }`n"
        $fsContent += "}`n`n"
        $fsContent += "# Security baseline profile: $securityPreset`n"
        $fsContent += "`$asrIds = $asrIdsLiteral`n"
        $fsContent += "`$asrActions = $asrFirstLiteral`n"
        $fsContent += "New-Item 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Force | Out-Null`n"
        $fsContent += "Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableLUA' -Value 1 -Type DWord`n"
        $fsContent += "Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'PromptOnSecureDesktop' -Value 1 -Type DWord`n"
        $fsContent += "Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'ConsentPromptBehaviorAdmin' -Value $uacConsentPromptAdmin -Type DWord`n"
        $fsContent += "Set-MpPreference -MAPSReporting Advanced -ErrorAction SilentlyContinue`n"
        $fsContent += "Set-MpPreference -SubmitSamplesConsent $sampleConsent -ErrorAction SilentlyContinue`n"
        $fsContent += "Set-MpPreference -DisableEnhancedNotifications `$false -ErrorAction SilentlyContinue`n"
        $fsContent += "Set-MpPreference -AttackSurfaceReductionRules_Ids `$asrIds -AttackSurfaceReductionRules_Actions `$asrActions -ErrorAction SilentlyContinue`n"
        if ($securityPreset -eq 'Hardened' -and -not [string]::IsNullOrWhiteSpace($asrAfterLiteral)) {
            $fsContent += "`$finalizerPath = 'C:\Windows\OximizeSecurityFinalize.ps1'`n"
            $fsContent += "`$finalizer = @'`n"
            $fsContent += "`$ids = $asrIdsLiteral`n"
            $fsContent += "`$actions = $asrAfterLiteral`n"
            $fsContent += "Set-MpPreference -AttackSurfaceReductionRules_Ids `$ids -AttackSurfaceReductionRules_Actions `$actions -ErrorAction SilentlyContinue`n"
            $fsContent += "Remove-Item -Path `$MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue`n"
            $fsContent += "'@`n"
            $fsContent += "Set-Content -Path `$finalizerPath -Value `$finalizer -Encoding UTF8`n"
            $fsContent += "New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Force | Out-Null`n"
            $fsContent += "Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'OximizeSecurityFinalize' -Value 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Windows\OximizeSecurityFinalize.ps1' -Type String`n"
        }
        $fsContent += "`n"
        $fsContent += "# Self-delete this script`n"
        $fsContent += "Remove-Item -Path `$MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue`n"


        Set-Content -Path $fsPath -Value $fsContent -Encoding UTF8
        RS-Log "FirstStartup.ps1 written to $fsPath" -Color Green

        # Fail-safe: run package cleanup once during SetupComplete as SYSTEM.
        # This covers installations where FirstLogonCommands may be skipped.
        if ($checkedAppxProvisioned.Count -gt 0) {
            try {
                $setupScriptsDir = Join-Path $scrDir2 'Windows\Setup\Scripts'
                New-Item -ItemType Directory -Path $setupScriptsDir -Force | Out-Null
                $postSetupPsPath = Join-Path $scrDir2 'Windows\Oximize_PostSetup.ps1'
                $postSetupCmdPath = Join-Path $setupScriptsDir 'SetupComplete.cmd'
                $postSetupPatternsLiteral = "@('" + (($checkedAppxProvisioned | ForEach-Object { [string]$_ }) -join "','") + "')"

                $postSetupContent = ''
                $postSetupContent += "`$ErrorActionPreference = 'SilentlyContinue'`r`n"
                $postSetupContent += "New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Force | Out-Null`r`n"
                $postSetupContent += "Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableWindowsConsumerFeatures' -Value 1 -Type DWord`r`n"
                $postSetupContent += "New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -Force | Out-Null`r`n"
                $postSetupContent += "Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -Name 'AutoDownload' -Value 2 -Type DWord`r`n"
                $postSetupContent += "`$removedAppPatterns = $postSetupPatternsLiteral`r`n"
                $postSetupContent += "foreach (`$pattern in `$removedAppPatterns) {`r`n"
                $postSetupContent += "  Get-AppxProvisionedPackage -Online | Where-Object { (`$_.DisplayName -like ('*' + `$pattern + '*')) -or (`$_.PackageName -like ('*' + `$pattern + '*')) } | ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName `$_.PackageName -AllUsers -ErrorAction SilentlyContinue | Out-Null }`r`n"
                $postSetupContent += "  Get-AppxPackage -AllUsers | Where-Object { (`$_.Name -like ('*' + `$pattern + '*')) -or (`$_.PackageFamilyName -like ('*' + `$pattern + '*')) -or (`$_.PackageFullName -like ('*' + `$pattern + '*')) } | ForEach-Object { Remove-AppxPackage -AllUsers -Package `$_.PackageFullName -ErrorAction SilentlyContinue }`r`n"
                $postSetupContent += "}`r`n"
                Set-Content -Path $postSetupPsPath -Value $postSetupContent -Encoding UTF8

                $setupCompleteCmd = "@echo off`r`n"
                $setupCompleteCmd += "setlocal`r`n"
                $setupCompleteCmd += "powershell.exe -NoProfile -ExecutionPolicy Bypass $setupPowerShellWindowStyleArg-File `"C:\Windows\Oximize_PostSetup.ps1`" > `"%WINDIR%\Temp\Oximize_PostSetup.log`" 2>&1`r`n"
                $setupCompleteCmd += "endlocal`r`n"
                $setupCompleteCmd += "exit /b 0`r`n"
                Set-Content -Path $postSetupCmdPath -Value $setupCompleteCmd -Encoding ASCII
                RS-Log "SetupComplete app-removal enforcement staged (Windows\\Setup\\Scripts\\SetupComplete.cmd)." -Color Green
            }
            catch {
                RS-Log "WARNING staging SetupComplete app-removal enforcement: $_" -Color Yellow
            }
        }

        RS-Progress 62
        RS-CheckCancel

        #──────────────────────────────────────────────────────────────────────
        # PHASE 8: Write unattend.xml
        #──────────────────────────────────────────────────────────────────────
        RS-Log '═══════ PHASE 8: Writing unattend.xml ═══════' -Color Cyan
        RS-Progress 65

        $autoLoginXml = ''
        if ($localAccountAutoLogin -and $localAccountName) {
            $autoLoginXml = "            <AutoLogon>`n"
            $autoLoginXml += "                <Password><Value>$localAccountPassword</Value><PlainText>true</PlainText></Password>`n"
            $autoLoginXml += "                <Enabled>true</Enabled>`n"
            $autoLoginXml += "                <Username>$localAccountName</Username>`n"
            $autoLoginXml += "                <LogonCount>1</LogonCount>`n"
            $autoLoginXml += "            </AutoLogon>"
        }
        RS-Log "Configuring default local account '$localAccountName' in unattend.xml." -Color White

        $forceInstallerLanguage = $singleLanguageInstaller -and -not [string]::IsNullOrWhiteSpace($installerLanguageRaw) -and $installerLanguageRaw -ne 'System Default' -and -not [string]::IsNullOrWhiteSpace($installerLangCode)
        if ($forceInstallerLanguage) {
            RS-Log "Single language installer enabled. Using language: $installerLangCode" -Color Cyan
        }
        else {
            RS-Log "Single language installer disabled (or System Default). Setup language selection will be shown at boot." -Color White
        }

        # Build unattend.xml as concatenated string (avoids here-string column-1 restriction inside runspace block)
        $nl = "`n"
        $oobeHideOnlineAccountScreens = if ($advancedRemoveMsaOobe) { 'true' } else { 'false' }
        $oobeHideWirelessSetup = if ($advancedAllowOfflineSetup) { 'true' } else { 'false' }
        $oobeSkipMachine = if ($advancedRemoveMsaOobe) { 'true' } else { 'false' }
        $oobeSkipUser = if ($advancedRemoveMsaOobe) { 'true' } else { 'false' }
        $firstLogonWindowStyleSegment = if ($advancedHidePowerShellSetup) { ' -WindowStyle Hidden' } else { '' }
        $windowsPeSetupCommandsXml = ''
        if ($advancedBypassHwChecks) {
            $labConfigCommands = @(
                'reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f',
                'reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f',
                'reg add HKLM\SYSTEM\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f',
                'reg add HKLM\SYSTEM\Setup\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f',
                'reg add HKLM\SYSTEM\Setup\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f'
            )
            $windowsPeSetupCommandsXml += "      <RunSynchronous>$nl"
            $order = 1
            foreach ($cmd in $labConfigCommands) {
                $windowsPeSetupCommandsXml += "        <RunSynchronousCommand wcm:action='add'>$nl"
                $windowsPeSetupCommandsXml += "          <Order>$order</Order>$nl"
                $windowsPeSetupCommandsXml += "          <Path>$cmd</Path>$nl"
                $windowsPeSetupCommandsXml += "        </RunSynchronousCommand>$nl"
                $order++
            }
            $windowsPeSetupCommandsXml += "      </RunSynchronous>$nl"
        }
        $unattendXml = "<?xml version='1.0' encoding='utf-8'?>$nl"
        $unattendXml += "<unattend xmlns='urn:schemas-microsoft-com:unattend'>$nl"
        $unattendXml += "  <settings pass='windowsPE'>$nl"
        if ($forceInstallerLanguage) {
            $unattendXml += "    <component name='Microsoft-Windows-International-Core-WinPE' processorArchitecture='amd64' publicKeyToken='31bf3856ad364e35' language='neutral' versionScope='nonSxS' xmlns:wcm='http://schemas.microsoft.com/WMIConfig/2002/State'>$nl"
            $unattendXml += "      <SetupUILanguage><UILanguage>$installerLangCode</UILanguage></SetupUILanguage>$nl"
            $unattendXml += "      <InputLocale>$installerLangCode</InputLocale><SystemLocale>$installerLangCode</SystemLocale>$nl"
            $unattendXml += "      <UILanguage>$installerLangCode</UILanguage><UserLocale>$installerLangCode</UserLocale>$nl"
            $unattendXml += "    </component>$nl"
        }
        $unattendXml += "    <component name='Microsoft-Windows-Setup' processorArchitecture='amd64' publicKeyToken='31bf3856ad364e35' language='neutral' versionScope='nonSxS' xmlns:wcm='http://schemas.microsoft.com/WMIConfig/2002/State'>$nl"
        $unattendXml += "      <UserData>$nl"
        $unattendXml += "        <AcceptEula>true</AcceptEula>$nl"
        $unattendXml += "        <ProductKey><WillShowUI>Always</WillShowUI></ProductKey>$nl"
        $unattendXml += "      </UserData>$nl"
        $unattendXml += "      <EnableFirewall>true</EnableFirewall>$nl"
        if (-not [string]::IsNullOrWhiteSpace($windowsPeSetupCommandsXml)) {
            $unattendXml += $windowsPeSetupCommandsXml
        }
        $unattendXml += "    </component>$nl"
        $unattendXml += "  </settings>$nl"
        $unattendXml += "  <settings pass='specialize'>$nl"
        $unattendXml += "    <component name='Microsoft-Windows-Shell-Setup' processorArchitecture='amd64' publicKeyToken='31bf3856ad364e35' language='neutral' versionScope='nonSxS' xmlns:wcm='http://schemas.microsoft.com/WMIConfig/2002/State'>$nl"
        $unattendXml += "      <ComputerName>*</ComputerName><TimeZone>UTC</TimeZone>$nl"
        $unattendXml += "    </component>$nl"
        $unattendXml += "  </settings>$nl"
        $unattendXml += "  <settings pass='oobeSystem'>$nl"
        $unattendXml += "    <component name='Microsoft-Windows-Shell-Setup' processorArchitecture='amd64' publicKeyToken='31bf3856ad364e35' language='neutral' versionScope='nonSxS' xmlns:wcm='http://schemas.microsoft.com/WMIConfig/2002/State'>$nl"
        $unattendXml += "      <OOBE>$nl"
        $unattendXml += "        <HideEULAPage>true</HideEULAPage>$nl"
        $unattendXml += "        <HideLocalAccountScreen>false</HideLocalAccountScreen>$nl"
        $unattendXml += "        <HideOnlineAccountScreens>$oobeHideOnlineAccountScreens</HideOnlineAccountScreens>$nl"
        $unattendXml += "        <HideWirelessSetupInOOBE>$oobeHideWirelessSetup</HideWirelessSetupInOOBE>$nl"
        $unattendXml += "        <NetworkLocation>Home</NetworkLocation>$nl"
        $unattendXml += "        <ProtectYourPC>3</ProtectYourPC>$nl"
        $unattendXml += "        <SkipMachineOOBE>$oobeSkipMachine</SkipMachineOOBE>$nl"
        $unattendXml += "        <SkipUserOOBE>$oobeSkipUser</SkipUserOOBE>$nl"
        $unattendXml += "      </OOBE>$nl"
        $unattendXml += "      $autoLoginXml$nl"
        $unattendXml += "      <UserAccounts><LocalAccounts>$nl"
        $unattendXml += "        <LocalAccount wcm:action='add'>$nl"
        $unattendXml += "          <Password><Value>$localAccountPassword</Value><PlainText>true</PlainText></Password>$nl"
        $unattendXml += "          <Description>Local User Account</Description>$nl"
        $unattendXml += "          <DisplayName>$localAccountName</DisplayName>$nl"
        $unattendXml += "          <Group>Administrators</Group>$nl"
        $unattendXml += "          <Name>$localAccountName</Name>$nl"
        $unattendXml += "        </LocalAccount>$nl"
        $unattendXml += "      </LocalAccounts></UserAccounts>$nl"
        $unattendXml += "      <FirstLogonCommands>$nl"
        $unattendXml += "        <SynchronousCommand wcm:action='add'>$nl"
        $unattendXml += "          <CommandLine>powershell.exe -NoProfile -ExecutionPolicy Bypass$firstLogonWindowStyleSegment -File 'C:\Windows\FirstStartup.ps1'</CommandLine>$nl"
        $unattendXml += "          <Description>Oximize OS FirstStartup</Description>$nl"
        $unattendXml += "          <Order>1</Order>$nl"
        $unattendXml += "          <RequiresUserInput>false</RequiresUserInput>$nl"
        $unattendXml += "        </SynchronousCommand>$nl"
        $unattendXml += "      </FirstLogonCommands>$nl"
        $unattendXml += "    </component>$nl"
        if ($forceInstallerLanguage) {
            $unattendXml += "    <component name='Microsoft-Windows-International-Core' processorArchitecture='amd64' publicKeyToken='31bf3856ad364e35' language='neutral' versionScope='nonSxS' xmlns:wcm='http://schemas.microsoft.com/WMIConfig/2002/State'>$nl"
            $unattendXml += "      <InputLocale>$installerLangCode</InputLocale><SystemLocale>$installerLangCode</SystemLocale>$nl"
            $unattendXml += "      <UILanguage>$installerLangCode</UILanguage><UserLocale>$installerLangCode</UserLocale>$nl"
            $unattendXml += "    </component>$nl"
        }
        $unattendXml += "  </settings>$nl"
        $unattendXml += "</unattend>$nl"

        if (-not [string]::IsNullOrWhiteSpace($customUnattendPath)) {
            RS-Log "Merging custom autounattend.xml: $customUnattendPath" -Color White
            $unattendXml = RS-MergeUnattendXml -BaseXmlText $unattendXml -CustomXmlPath $customUnattendPath
            RS-Log "Custom autounattend.xml merged with generated customizations." -Color Green
        }

        $pantherDir = "$scrDir2\Windows\Panther"
        $sysprepDir = "$scrDir2\Windows\System32\Sysprep"
        New-Item -ItemType Directory -Path $pantherDir -Force | Out-Null
        New-Item -ItemType Directory -Path $sysprepDir -Force | Out-Null
        Set-Content -Path "$pantherDir\unattend.xml" -Value $unattendXml -Encoding UTF8
        Set-Content -Path "$sysprepDir\unattend.xml" -Value $unattendXml -Encoding UTF8
        $mediaUnattendPath = Join-Path $mountDir 'autounattend.xml'
        Set-Content -Path $mediaUnattendPath -Value $unattendXml -Encoding UTF8
        RS-Log "unattend.xml written to Panther, Sysprep, and ISO root (autounattend.xml)." -Color Green
        RS-Progress 68
        RS-CheckCancel


        #──────────────────────────────────────────────────────────────────────
        # PHASE 9: Unmount and commit WIM
        #──────────────────────────────────────────────────────────────────────
        RS-Log '═══════ PHASE 9: Unmounting WIM (Commit) ═══════' -Color Cyan
        RS-Progress 75
        RS-RunDism @('/Unmount-Wim', "/MountDir:$scrDir2", '/Commit')
        $sync.IsWimMounted = $false
        RS-RunDism @('/Cleanup-MountPoints')
        RS-Log "WIM unmounted and committed." -Color Green
        RS-Progress 78
        RS-CheckCancel

        #──────────────────────────────────────────────────────────────────────
        # PHASE 10: Post-unmount verification (read-only remount)
        #──────────────────────────────────────────────────────────────────────
        if ($skipPostUnmountVerify) {
            RS-Log '═══════ PHASE 10: Post-Unmount Verification ═══════' -Color Cyan
            RS-Log "Skipping post-unmount verification for faster processing." -Color Yellow
        }
        else {
            RS-Log '═══════ PHASE 10: Post-Unmount Verification ═══════' -Color Cyan
            RS-Progress 80
            try {
                $verifyMountDir = Join-Path $scrDir 'WIM_verify'
                New-Item -ItemType Directory -Path $verifyMountDir -Force | Out-Null
                RS-RunDism @('/Mount-Wim', "/WimFile:$wimPath", "/Index:$selIdx", "/MountDir:$verifyMountDir", '/ReadOnly')
                $info = Get-WindowsImage -ImagePath $wimPath -Index $selIdx
                RS-Log "Verified edition : $($info.ImageName)" -Color Green
                RS-Log "Verified build   : $($info.Version)" -Color Green
                RS-Log ("Verified arch    : {0}" -f (RS-GetArchDisplay -ArchitectureCode $info.Architecture)) -Color Green
                RS-RunDism @('/Unmount-Wim', "/MountDir:$verifyMountDir", '/Discard')
                Remove-Item $verifyMountDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            catch {
                RS-Log "Verification warning: $_" -Color Yellow
            }
        }
        RS-Progress 82
        RS-CheckCancel

        #──────────────────────────────────────────────────────────────────────
        # PHASE 11: Export WIM with configured compression profile
        #──────────────────────────────────────────────────────────────────────
        RS-Log '═══════ PHASE 11: Exporting Optimised WIM ═══════' -Color Cyan
        RS-Progress 89
        $exportedWim = Join-Path $scrDir 'install_export.wim'
        try {
            if (Test-Path $exportedWim) {
                Remove-Item -Path $exportedWim -Force -ErrorAction SilentlyContinue
            }
            $effectiveWimCompression = if ($wimCompression -in @('None', 'Fast', 'Max')) { $wimCompression } else { 'Fast' }
            RS-Log ("Exporting selected edition index {0} to single-index install.wim (compression: {1})..." -f $selIdx, $effectiveWimCompression) -Color White
            $exportArgs = @{
                SourceImagePath      = $wimPath
                SourceIndex          = $selIdx
                DestinationImagePath = $exportedWim
                CompressionType      = $effectiveWimCompression
            }
            if ($useIntegrityChecks) {
                $exportArgs.CheckIntegrity = $true
            }
            Export-WindowsImage @exportArgs
            Copy-Item $exportedWim -Destination $wimPath -Force
            Remove-Item $exportedWim -Force -ErrorAction SilentlyContinue
            RS-Log "WIM export complete (single edition prepared)." -Color Green
            $postExportImages = @(Get-WindowsImage -ImagePath $wimPath -ErrorAction Stop)
            RS-Log ("Post-export install.wim index count: {0}" -f $postExportImages.Count) -Color White
            if ($postExportImages.Count -ne 1) {
                throw "Edition pruning failed: install.wim still has $($postExportImages.Count) indexes after selection."
            }
            if ($null -ne $imgInfo -and -not [string]::IsNullOrWhiteSpace([string]$imgInfo.ImageName)) {
                RS-Log ("Locked edition: {0}" -f [string]$imgInfo.ImageName) -Color Green
            }
        }
        catch {
            RS-Log "WIM export failed: $_" -Color Red
            throw
        }
        RS-Log "Skipping install.wim to install.esd conversion. Keeping standard install.wim for normal ISO export." -Color White

        $sourceEsdInIso = Join-Path $mountDir 'sources\install.esd'
        if (Test-Path $sourceEsdInIso) {
            try {
                Remove-Item -Path $sourceEsdInIso -Force -ErrorAction Stop
                RS-Log "Removed sources\\install.esd to prevent edition selection prompt in Setup." -Color Green
            }
            catch {
                RS-Log "WARNING removing sources\\install.esd: $_" -Color Yellow
            }
        }
        try {
            $editionIdForSetup = ''
            try { $editionIdForSetup = [string]$imgInfo.EditionId } catch { $editionIdForSetup = '' }
            if ([string]::IsNullOrWhiteSpace($editionIdForSetup)) {
                try {
                    $postExportIndexInfo = Get-WindowsImage -ImagePath $wimPath -Index 1 -ErrorAction Stop
                    $editionIdForSetup = [string]$postExportIndexInfo.EditionId
                }
                catch {
                    $editionIdForSetup = ''
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($editionIdForSetup)) {
                $eiCfgPath = Join-Path $mountDir 'sources\ei.cfg'
                $eiCfgContent = "[EditionID]`r`n{0}`r`n[Channel]`r`nRetail`r`n[VL]`r`n0`r`n" -f $editionIdForSetup
                Set-Content -Path $eiCfgPath -Value $eiCfgContent -Encoding ASCII
                RS-Log ("Wrote sources\\ei.cfg to lock Setup edition: {0}" -f $editionIdForSetup) -Color Green
            }
            else {
                RS-Log "Edition lock note: unable to resolve EditionID for ei.cfg; relying on single-index install.wim." -Color Yellow
            }
        }
        catch {
            RS-Log "WARNING writing sources\\ei.cfg: $_" -Color Yellow
        }
        RS-Progress 92
        RS-CheckCancel

        #──────────────────────────────────────────────────────────────────────
        # PHASE 11.5: Stage user custom files into ISO payload
        #──────────────────────────────────────────────────────────────────────
        RS-Log '═══════ PHASE 11.5: Staging Custom Files ═══════' -Color Cyan
        $hasCustomFiles = ($customRegFiles.Count -gt 0) -or ($customBatFiles.Count -gt 0)
        if ($hasCustomFiles) {
            $customIsoDir = Join-Path $mountDir 'OximizeOS\CustomFiles'
            New-Item -ItemType Directory -Path $customIsoDir -Force | Out-Null
            foreach ($f in $customRegFiles) { [void](RS-StageCustomFile -SourcePath $f -TargetDir $customIsoDir -AllowedExtensions @('.reg')) }
            foreach ($f in $customBatFiles) { [void](RS-StageCustomFile -SourcePath $f -TargetDir $customIsoDir -AllowedExtensions @('.bat', '.cmd')) }
        }
        else {
            RS-Log "No custom files selected for ISO staging." -Color White
        }
        RS-Progress 93
        RS-CheckCancel

        #──────────────────────────────────────────────────────────────────────
        # PHASE 12: Build bootable ISO with oscdimg
        #──────────────────────────────────────────────────────────────────────
        RS-Log '═══════ PHASE 12: Building Bootable ISO ═══════' -Color Cyan
        RS-Progress 94

        # Locate oscdimg.exe and auto-acquire when missing.
        $oscdimg = $oscdimgResolved
        if ([string]::IsNullOrWhiteSpace($oscdimg) -or -not (Test-Path -LiteralPath $oscdimg -PathType Leaf)) {
            $oscdimg = RS-ResolveOscdimgPath
        }
        if ([string]::IsNullOrWhiteSpace($oscdimg)) {
            RS-Log "oscdimg.exe not found locally. Third-party auto-download is disabled; retrying official Microsoft ADK bootstrap." -Color Yellow
            $oscdimg = RS-EnsureOscdimg -AllowBootstrapInPhase1 $true
        }

        if ([string]::IsNullOrWhiteSpace($oscdimg) -or -not (Test-Path -LiteralPath $oscdimg -PathType Leaf)) {
            RS-Log "ERROR: oscdimg.exe not available. Cannot build ISO." -Color Red
            RS-Log "Third-party automatic download/install is disabled. Install Windows ADK Deployment Tools (Oscdimg) or place oscdimg.exe in .\tools\ and re-run." -Color Yellow
            throw "oscdimg.exe not found."
        }
        else {
            RS-Log "Using oscdimg executable: $oscdimg" -Color White
            $etfsboot = Join-Path $mountDir 'boot\etfsboot.com'
            $efisys = Join-Path $mountDir 'efi\microsoft\boot\efisys.bin'
            if (-not (Test-Path -LiteralPath $etfsboot)) {
                throw "Boot sector file missing: $etfsboot"
            }
            if (-not (Test-Path -LiteralPath $efisys)) {
                throw "UEFI boot image missing: $efisys"
            }
            # Avoid nested quote escaping under pwsh which can become ""path"" in oscdimg.
            $bootDataStr = "2#p0,e,b$etfsboot#pEF,e,b$efisys"
            $oscdArgs = @('-m', '-o', '-u2', '-udfver102', "-bootdata:$bootDataStr", $mountDir, $outISO)
            RS-Log "Running: $oscdimg $($oscdArgs -join ' ')" -Color White
            $oscdStdOutPath = Join-Path $scrDir 'oscdimg.stdout.log'
            $oscdStdErrPath = Join-Path $scrDir 'oscdimg.stderr.log'
            try { Remove-Item -LiteralPath $oscdStdOutPath -Force -ErrorAction SilentlyContinue } catch {}
            try { Remove-Item -LiteralPath $oscdStdErrPath -Force -ErrorAction SilentlyContinue } catch {}
            $oscdProc = Start-Process -FilePath $oscdimg -ArgumentList $oscdArgs -PassThru -Wait -NoNewWindow -RedirectStandardOutput $oscdStdOutPath -RedirectStandardError $oscdStdErrPath
            $oscdExit = 0
            try { $oscdExit = [int]$oscdProc.ExitCode } catch { $oscdExit = -1 }
            $oscdStdOut = @()
            $oscdStdErr = @()
            if (Test-Path -LiteralPath $oscdStdOutPath) {
                try { $oscdStdOut = Get-Content -LiteralPath $oscdStdOutPath -ErrorAction SilentlyContinue } catch {}
            }
            if (Test-Path -LiteralPath $oscdStdErrPath) {
                try { $oscdStdErr = Get-Content -LiteralPath $oscdStdErrPath -ErrorAction SilentlyContinue } catch {}
            }
            if ($oscdStdOut -and $oscdStdOut.Count -gt 0) { RS-Log ($oscdStdOut -join "`n") }
            if ($oscdStdErr -and $oscdStdErr.Count -gt 0) { RS-Log ($oscdStdErr -join "`n") -Color Yellow }
            if ($oscdExit -eq 0) {
                RS-Log "ISO created: $outISO" -Color Green
            }
            else {
                RS-Log "oscdimg exited with code $oscdExit" -Color Red
                throw "oscdimg failed with exit code $oscdExit."
            }
        }
        RS-Progress 98
        RS-CheckCancel

        #──────────────────────────────────────────────────────────────────────
        # PHASE 13: Completion — cleanup, report, restore sleep state
        #──────────────────────────────────────────────────────────────────────
        RS-Log '═══════ PHASE 13: Completion ═══════' -Color Cyan
        RS-Progress 100

        $isoExists = Test-Path $outISO
        $isoResult = if ($isoExists) {
            $sz = (Get-Item $outISO).Length
            $srcSize = $null
            try { $srcSize = (Get-Item -LiteralPath $srcISO).Length } catch {}
            if ($null -ne $srcSize -and $srcSize -gt 0) {
                $delta = $sz - $srcSize
                $deltaGb = [Math]::Abs($delta / 1GB)
                $deltaPct = [Math]::Abs(($delta / [double]$srcSize) * 100.0)
                $trend = if ($delta -lt 0) { 'smaller' } elseif ($delta -gt 0) { 'larger' } else { 'same size' }
                "Output ISO: $outISO`nSize: $('{0:N2}' -f ($sz/1GB)) GB`nCompared to source: $trend by $('{0:N2}' -f $deltaGb) GB ($('{0:N1}' -f $deltaPct)%)"
            }
            else {
                "Output ISO: $outISO`nSize: $('{0:N2}' -f ($sz/1GB)) GB"
            }
        }
        else {
            "Output ISO not found at $outISO"
        }
        if ($isoExists) {
            RS-Log "All phases complete!" -Color Green
            RS-Log $isoResult -Color Green
        }
        else {
            RS-Log "Build did not produce an ISO." -Color Red
            RS-Log $isoResult -Color Red
            throw $isoResult
        }

        # Clean up scratch directory and temp files (marker-gated safety)
        [void](RS-CleanupScratchDirectory -ScratchPath $scrDir -MarkerFileName $scratchMarkerName -Context 'success')

        # Show completion dialog on UI thread
        $sync.Form.Invoke([System.Action] {
                [System.Windows.Forms.MessageBox]::Show(
                    "Oximize build complete!`n`n$isoResult",
                    "Oximize OS Complete", "OK", "Information") | Out-Null
                $sync.StartButton.Enabled = $true
                $sync.CancelButton.Enabled = $false
            })
    }
    catch [System.OperationCanceledException], [System.Management.Automation.PipelineStoppedException] {
        #──────────────────────────────────────────────────────────────────────
        # CANCELLATION / USER ABORT
        #──────────────────────────────────────────────────────────────────────
        RS-Log "Cancelled by user — cleaning up…" -Color Yellow
        # Discard WIM mount if open
        if ($sync.IsWimMounted) {
            try {
                $wmd = $sync.WimMountDir
                RS-Log "Discarding WIM mount…" -Color Yellow
                & dism.exe '/Unmount-Wim' "/MountDir:$wmd" '/Discard' 2>&1 | ForEach-Object { RS-Log $_ }
                $sync.IsWimMounted = $false
            }
            catch { RS-Log "WIM discard error: $_" -Color Red }
        }
        # Dismount ISO if still mounted
        if ($sync.IsMounted) {
            try {
                Dismount-DiskImage -ImagePath $sync['Source ISO'] -ErrorAction SilentlyContinue | Out-Null
                $sync.IsMounted = $false
            }
            catch {}
        }
        try { RS-UnloadRegistryHiveMounts -HiveKeys $registryHiveMountKeys -Context 'cancel cleanup' } catch {}
        # Delete temp dir only when marker confirms Oximize ownership
        [void](RS-CleanupScratchDirectory -ScratchPath $sync.ScratchDir -MarkerFileName $scratchMarkerName -Context 'cancel')
        RS-Log "Cancel cleanup complete." -Color Yellow
        $sync.Form.Invoke([System.Action] {
                $sync.CancelButton.Enabled = $false
                $sync.StartButton.Enabled = $true
            })
    }
    catch {
        #──────────────────────────────────────────────────────────────────────
        # UNEXPECTED ERROR — graceful abort
        #──────────────────────────────────────────────────────────────────────
        $errRecord = $_
        $exType = ''
        $exMessage = ''
        try { $exType = [string]$errRecord.Exception.GetType().FullName } catch { $exType = '' }
        try { $exMessage = [string]$errRecord.Exception.Message } catch { $exMessage = '' }
        if ([string]::IsNullOrWhiteSpace($exMessage)) {
            RS-Log "FATAL ERROR: $errRecord" -Color Red
        }
        elseif ([string]::IsNullOrWhiteSpace($exType)) {
            RS-Log "FATAL ERROR: $exMessage" -Color Red
        }
        else {
            RS-Log ("FATAL ERROR: [{0}] {1}" -f $exType, $exMessage) -Color Red
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$errRecord.ScriptStackTrace)) {
            RS-Log "Stack: $($errRecord.ScriptStackTrace)" -Color Red
        }
        elseif ($errRecord.Exception -and -not [string]::IsNullOrWhiteSpace([string]$errRecord.Exception.StackTrace)) {
            RS-Log "Stack: $($errRecord.Exception.StackTrace)" -Color Red
        }
        $fatalDetails = if (-not [string]::IsNullOrWhiteSpace($exMessage)) { $exMessage } else { [string]$errRecord }
        # Emergency cleanup
        if ($sync.IsWimMounted) {
            try {
                & dism.exe '/Unmount-Wim' "/MountDir:$($sync.WimMountDir)" '/Discard' 2>&1 | Out-Null
                $sync.IsWimMounted = $false
            }
            catch {}
        }
        if ($sync.IsMounted) {
            try {
                Dismount-DiskImage -ImagePath $sync['Source ISO'] -ErrorAction SilentlyContinue | Out-Null
                $sync.IsMounted = $false
            }
            catch {}
        }
        try { RS-UnloadRegistryHiveMounts -HiveKeys $registryHiveMountKeys -Context 'fatal cleanup' } catch {}
        $failureMarker = [string]$sync.ScratchMarkerFileName
        if ([string]::IsNullOrWhiteSpace($failureMarker)) { $failureMarker = '.oximize_scratch.marker' }
        [void](RS-CleanupScratchDirectory -ScratchPath $sync.ScratchDir -MarkerFileName $failureMarker -Context 'failure')
        try { & dism.exe /Cleanup-MountPoints 2>&1 | Out-Null } catch {}
        $showFatalAction = [System.Action]({
                [System.Windows.Forms.MessageBox]::Show(
                    "Processing failed:`n$fatalDetails", "Error", "OK", "Error") | Out-Null
                $sync.CancelButton.Enabled = $false
                $sync.StartButton.Enabled = $true
            }.GetNewClosure())
        $sync.Form.Invoke($showFatalAction)
    }
    finally {
        # Always restore sleep state and mark process done
        try { RS-UnloadRegistryHiveMounts -HiveKeys $registryHiveMountKeys -Context 'finalizer' } catch {}
        [void][PowerMgmt]::SetThreadExecutionState([PowerMgmt]::ES_CONTINUOUS)
        $sync.ProcessRunning = $false
        $sync.CancelRequested = $false
    }
} # end $pipelineScript
#endregion

#region ── Start Button Click Handler ─────────────────────────────────────────
$btnStart.Add_Click({
        # Guard against re-entry
        if ($sync.ProcessRunning) { return }

        # Harvest current textbox values into sync
        $sourceIsoValue = Get-PathTextBoxValue -Control $tbSourceISO
        $outputIsoValue = Get-PathTextBoxValue -Control $tbOutputISO
        $scratchDirValue = Get-PathTextBoxValue -Control $tbScratch

        $sync['Source ISO'] = $sourceIsoValue
        $sync['Output Folder'] = Resolve-OutputIsoPath -CandidatePath $outputIsoValue -SourceIsoPath $sourceIsoValue
        $sync.ScratchDir = $scratchDirValue
        $sync.CustomUnattendXml = [string]$sync.CustomUnattendXml
        $sync.CustomRegFiles = @($sync.CustomRegFiles)
        $sync.CustomBatFiles = @($sync.CustomBatFiles)
        $sync.DriverSourceDir = Get-PathTextBoxValue -Control $tbDriverSource
        $sync.DriverExtractDir = Get-PathTextBoxValue -Control $tbDriverExtract
        $sync.InjectDriversInstallWim = $cbInjectInstall.Checked
        $sync.DriverInjectRecurse = $cbDriverRecurse.Checked
        $sync.Remove24H2Keys = $false

        # Validate required fields
        if (-not (Test-Path -LiteralPath $sync['Source ISO'] -PathType Leaf)) {
            [System.Windows.Forms.MessageBox]::Show("Please select a valid Source ISO file.", "Missing Input", "OK", "Warning") | Out-Null
            return
        }
        if ([System.IO.Path]::GetExtension([string]$sync['Source ISO']).ToLowerInvariant() -ne '.iso') {
            [System.Windows.Forms.MessageBox]::Show("Source file must be a .iso image.", "Invalid Input", "OK", "Warning") | Out-Null
            return
        }
        if ([string]::IsNullOrWhiteSpace($sync['Output Folder'])) {
            [System.Windows.Forms.MessageBox]::Show("Please specify an Output ISO path.", "Missing Input", "OK", "Warning") | Out-Null
            return
        }
        Set-PathTextBoxValue -Control $tbOutputISO -Value $sync['Output Folder']
        try {
            Ensure-ParentDirectory -FilePath $sync['Output Folder']
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Could not create the Output ISO folder.`n`n$_", "Output Path Error", "OK", "Error") | Out-Null
            return
        }
        try {
            $sourceIsoFull = [System.IO.Path]::GetFullPath($sync['Source ISO'])
            if ($sourceIsoFull -eq $sync['Output Folder']) {
                [System.Windows.Forms.MessageBox]::Show("Output ISO cannot overwrite the selected Source ISO.", "Invalid Output Path", "OK", "Warning") | Out-Null
                return
            }
        }
        catch {}
        if ([string]::IsNullOrWhiteSpace($sync.ScratchDir)) {
            $sync.ScratchDir = "$env:TEMP\OximizeOS_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            Set-PathTextBoxValue -Control $tbScratch -Value $sync.ScratchDir
        }
        $scratchSafety = Test-ScratchDirectorySafety -ScratchPath $sync.ScratchDir -MarkerFileName $sync.ScratchMarkerFileName
        if (-not $scratchSafety.IsValid) {
            [System.Windows.Forms.MessageBox]::Show(
                "Invalid TempBuildDirectory.`n`n$($scratchSafety.Reason)`n`nChoose a dedicated empty folder (or one previously used by Oximize OS).",
                "Invalid TempBuildDirectory", "OK", "Warning") | Out-Null
            return
        }
        $sync.ScratchDir = [string]$scratchSafety.Path
        Set-PathTextBoxValue -Control $tbScratch -Value $sync.ScratchDir
        try {
            $outputIsoFull = [System.IO.Path]::GetFullPath($sync['Output Folder'])
            $scratchDirFull = [System.IO.Path]::GetFullPath($sync.ScratchDir)
            $scratchRoot = $scratchDirFull.TrimEnd('\')
            $outputInsideScratch = $outputIsoFull.StartsWith(($scratchRoot + '\'), [System.StringComparison]::OrdinalIgnoreCase)

            if ($outputInsideScratch) {
                [System.Windows.Forms.MessageBox]::Show(
                    "Output ISO path is inside TempBuildDirectory.`n`nThe temp directory is cleaned automatically after build, which would delete the ISO.`n`nChoose an Output ISO path outside TempBuildDirectory.",
                    "Invalid Output Path", "OK", "Warning") | Out-Null
                return
            }
        }
        catch {}
        if (-not [string]::IsNullOrWhiteSpace($sync.CustomUnattendXml) -and -not (Test-Path $sync.CustomUnattendXml)) {
            [System.Windows.Forms.MessageBox]::Show("Custom autounattend.xml path is invalid.", "Missing Input", "OK", "Warning") | Out-Null
            return
        }
        foreach ($f in $sync.CustomRegFiles) {
            if (-not (Test-Path $f)) {
                [System.Windows.Forms.MessageBox]::Show("Invalid .reg file path: $f", "Missing Input", "OK", "Warning") | Out-Null
                return
            }
            if ([System.IO.Path]::GetExtension($f).ToLowerInvariant() -ne '.reg') {
                [System.Windows.Forms.MessageBox]::Show("File must have .reg extension: $f", "Invalid Input", "OK", "Warning") | Out-Null
                return
            }
        }
        foreach ($f in $sync.CustomBatFiles) {
            if (-not (Test-Path $f)) {
                [System.Windows.Forms.MessageBox]::Show("Invalid batch file path: $f", "Missing Input", "OK", "Warning") | Out-Null
                return
            }
            $batExt = [System.IO.Path]::GetExtension($f).ToLowerInvariant()
            if ($batExt -notin @('.bat', '.cmd')) {
                [System.Windows.Forms.MessageBox]::Show("File must have .bat or .cmd extension: $f", "Invalid Input", "OK", "Warning") | Out-Null
                return
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($sync.DriverSourceDir)) {
            if (-not (Test-Path $sync.DriverSourceDir -PathType Container)) {
                [System.Windows.Forms.MessageBox]::Show("Driver package source folder is invalid: $($sync.DriverSourceDir)", "Invalid Input", "OK", "Warning") | Out-Null
                return
            }
            $infFiles = if ([bool]$sync.DriverInjectRecurse) {
                Get-ChildItem -Path $sync.DriverSourceDir -Filter '*.inf' -Recurse -File -ErrorAction SilentlyContinue
            }
            else {
                Get-ChildItem -Path $sync.DriverSourceDir -Filter '*.inf' -File -ErrorAction SilentlyContinue
            }
            if ($null -eq $infFiles -or $infFiles.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show("No .inf files were found in the selected driver package folder.", "Invalid Input", "OK", "Warning") | Out-Null
                return
            }
            if (-not $sync.InjectDriversInstallWim) {
                [System.Windows.Forms.MessageBox]::Show("Enable install.wim driver package injection to apply selected .inf packages.", "Invalid Input", "OK", "Warning") | Out-Null
                return
            }
        }
        # Disk space check
        if (-not (Test-DiskSpace -IsoPath $sync['Source ISO'])) { return }

        # Capture UI-thread delegates for the background runspace
        $sync.ShowEditionSelector = {
            return Show-EditionSelector -Editions $sync.EditionsToSelect
        }.GetNewClosure()

        # Reset state
        try {
            $resolvedScript = $null
            if (-not [string]::IsNullOrWhiteSpace([string]$sync.ScriptPath)) {
                $resolvedScript = Resolve-Path -LiteralPath ([string]$sync.ScriptPath) -ErrorAction SilentlyContinue | Select-Object -First 1
            }
            if ($null -ne $resolvedScript) {
                $scriptItem = Get-Item -LiteralPath $resolvedScript.Path -ErrorAction SilentlyContinue
                if ($null -ne $scriptItem) {
                    $sync.ScriptBuildStamp = "{0} | LastWrite={1:yyyy-MM-dd HH:mm:ss} | Size={2}" -f [string]$scriptItem.FullName, $scriptItem.LastWriteTime, [string]$scriptItem.Length
                }
            }
        }
        catch {}

        $sync.ProcessRunning = $true
        $sync.CancelRequested = $false
        $sync.IsMounted = $false
        $sync.IsWimMounted = $false
        $progressBar.Value = 0
        $logBox.Clear()
        $btnStart.Enabled = $false
        $btnCancel.Enabled = $true

        # Open standalone Logs page as soon as build starts.
        Show-StandaloneLogsPage
        Write-Log "Build started. Standalone Logs page opened for live output." -Color Cyan

        # Prevent sleep
        Invoke-KeepAwake

        # Create and start runspace
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.ThreadOptions = 'ReuseThread'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('sync', $sync)

        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($pipelineScript).AddArgument($sync)
        $sync.PowerShellInstance = $ps

        # Async invocation — completion callback
        $iaResult = $ps.BeginInvoke()
        $runspaceCleanupDone = $false
        $finalizeRunspace = {
            param([bool]$AttemptEndInvoke = $true)
            if ($runspaceCleanupDone) { return }
            $runspaceCleanupDone = $true

            if ($AttemptEndInvoke -and $null -ne $iaResult) {
                try { $ps.EndInvoke($iaResult) } catch { Write-Log ("Runspace EndInvoke warning: {0}" -f $_.Exception.Message) -Color Yellow }
            }

            try { $ps.Dispose() } catch { Write-Log ("Runspace dispose warning: {0}" -f $_.Exception.Message) -Color Yellow }

            $rsState = ''
            try { $rsState = [string]$rs.RunspaceStateInfo.State } catch { $rsState = '' }
            if ($rsState -notin @('Closed', 'BeforeOpen')) {
                try { $rs.Close() } catch {
                    $closeMsg = [string]$_.Exception.Message
                    if ($closeMsg -match '(?i)Global scope cannot be removed') {
                        Write-Log "Runspace close note: engine scope was already at global during teardown; continuing." -Color Yellow
                    }
                    else {
                        Write-Log ("Runspace close warning: {0}" -f $closeMsg) -Color Yellow
                    }
                }
            }
            try { $rs.Dispose() } catch { Write-Log ("Runspace final dispose warning: {0}" -f $_.Exception.Message) -Color Yellow }
            $sync.PowerShellInstance = $null
            try {
                if ($null -ne $sync.BuildPollTimer) {
                    $sync.BuildPollTimer.Stop()
                    $sync.BuildPollTimer.Dispose()
                    $sync.BuildPollTimer = $null
                }
            }
            catch {}
        }.GetNewClosure()

        # Poll for completion without blocking the GUI message pump
        $timer = New-Object System.Windows.Forms.Timer
        $sync.BuildPollTimer = $timer
        $timer.Interval = 500
        $timer.Add_Tick({
                try {
                    if ($iaResult.IsCompleted) {
                        $timer.Stop()
                        & $finalizeRunspace $true
                        return
                    }

                    # Check for pipeline errors surfaced to sync.
                    $hadErrors = $false
                    try { $hadErrors = [bool]$ps.HadErrors } catch { $hadErrors = $false }
                    if ($hadErrors) {
                        try { $ps.Streams.Error | ForEach-Object { Write-Log "RS error: $_" -Color Red } } catch {}
                    }
                }
                catch {
                    try { $timer.Stop() } catch {}
                    Write-Log ("UI timer exception while monitoring runspace: {0}" -f $_.Exception.Message) -Color Red
                    & $finalizeRunspace $false
                }
            })
        $timer.Start()
    })
#endregion

#region ── Cancel Button Click Handler ────────────────────────────────────────
$btnCancel.Add_Click({
        if (-not $sync.ProcessRunning) { return }
        $sync.CancelRequested = $true
        Write-Log "Cancel requested — stopping pipeline..." -Color Yellow
        $btnCancel.Enabled = $false
        if ($null -ne $sync.PowerShellInstance) {
            try { $sync.PowerShellInstance.Stop() } catch {}
        }
        Show-StandaloneLogsPage
    })
#endregion

#region ── Form Closing Handler ───────────────────────────────────────────────
$form.Add_FormClosing({
        if ($sync.ProcessRunning) {
            $sync.CancelRequested = $true
            Start-Sleep -Milliseconds 800
        }
        try {
            if ($null -ne $sync.BuildPollTimer) {
                $sync.BuildPollTimer.Stop()
                $sync.BuildPollTimer.Dispose()
                $sync.BuildPollTimer = $null
            }
        }
        catch {}
        # Attempt cleanup on exit
        if ($sync.IsWimMounted) {
            try { & dism.exe '/Unmount-Wim' "/MountDir:$($sync.WimMountDir)" '/Discard' 2>&1 | Out-Null } catch {}
        }
        if ($sync.IsMounted) {
            try { Dismount-DiskImage -ImagePath $sync['Source ISO'] -ErrorAction SilentlyContinue | Out-Null } catch {}
        }
        Invoke-RestoreSleep
    })

$form.Add_Deactivate({
        Close-AllComboDropDowns -Root $form
    })
#endregion

#region ── Launch the GUI ─────────────────────────────────────────────────────
$script:UiDeferredInitDone = $false
$form.Add_Shown({
        if ($script:UiDeferredInitDone) { return }
        $script:UiDeferredInitDone = $true
        try {
            Apply-Theme -Mode $script:ThemeMode
            if ($null -ne $panelWelcome -and -not $panelWelcome.IsDisposed) {
                Enable-ControlDoubleBuffer -Control $panelWelcome -Recursive
                Set-DarkScrollbar -Control $panelWelcome -Recursive
            }
            if ($null -ne $panelMainUI -and -not $panelMainUI.IsDisposed) {
                Enable-ControlDoubleBuffer -Control $panelMainUI -Recursive
            }
            if ($null -ne $contentPanel -and -not $contentPanel.IsDisposed) {
                Enable-ControlDoubleBuffer -Control $contentPanel -Recursive
            }
            Register-UiChangeLogging -Root $form -Recursive
            if (-not $script:ShowWelcomeScreen) {
                Show-MainUi
            }
            $form.PerformLayout()
            $form.Invalidate($true)
            $form.Update()
            Invoke-UiStabilizeRedraw -Root $form
            try {
                $postInitThemeTimer = New-Object System.Windows.Forms.Timer
                $postInitThemeTimer.Interval = 220
                $postInitThemeTimer.Add_Tick({
                        $postInitThemeTimer.Stop()
                        try {
                            Apply-Theme -Mode $script:ThemeMode
                            Update-SectionLayout
                            Reset-HorizontalScrollRecursively -Root $form
                            Invoke-UiStabilizeRedraw -Root $form
                        }
                        catch {}
                        finally {
                            try { $postInitThemeTimer.Dispose() } catch {}
                        }
                    }.GetNewClosure())
                $postInitThemeTimer.Start()
            }
            catch {}
            Write-Log ("Session log file: {0}" -f $script:SessionLogPath) -Color Cyan
            Write-Log "Oximize OS ISO Builder ready. Select a source ISO and click ▶ Start Oximize Build." -Color Cyan
        }
        catch {
            Write-Log "Deferred UI init warning: $_" -Color Yellow
        }
        finally {
            # Reveal the form now that all controls are fully themed — no white flash possible
            try { if ($form.Opacity -lt 1.0) { $form.Opacity = 1.0 } } catch {}
        }
    })
[System.Windows.Forms.Application]::Run($form)
#endregion
