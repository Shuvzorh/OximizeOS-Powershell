$ErrorActionPreference = 'Stop'

function Get-WindowsPowerShellPath {
    $defaultPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $defaultPath) { return $defaultPath }
    return 'powershell.exe'
}

function Invoke-DownloadFile {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile
    )

    $params = @{
        Uri     = $Url
        OutFile = $OutFile
    }
    if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey('UseBasicParsing')) {
        $params.UseBasicParsing = $true
    }
    Invoke-WebRequest @params | Out-Null
}

$tempFile = Join-Path $env:TEMP ("OximizeOS_bootstrap_{0}.ps1" -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

function Ensure-Utf8Bom {
    param([Parameter(Mandatory)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return
    }

    $newBytes = New-Object byte[] ($bytes.Length + 3)
    $newBytes[0] = 0xEF
    $newBytes[1] = 0xBB
    $newBytes[2] = 0xBF
    [System.Array]::Copy($bytes, 0, $newBytes, 3, $bytes.Length)
    [System.IO.File]::WriteAllBytes($Path, $newBytes)
}

function Test-ScriptSyntax {
    param([Parameter(Mandatory)][string]$Path)

    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    return ($null -eq $errors -or $errors.Count -eq 0)
}

$cacheBuster = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$downloadUrls = @(
    "https://raw.githubusercontent.com/Shuvzorh/OximizeOS-Powershell/main/OximizeOS.ps1?cb=$cacheBuster",
    "https://cdn.jsdelivr.net/gh/Shuvzorh/OximizeOS-Powershell@main/OximizeOS.ps1?cb=$cacheBuster"
)

$downloaded = $false
$downloadErrors = New-Object System.Collections.Generic.List[string]
foreach ($url in $downloadUrls) {
    try {
        Invoke-DownloadFile -Url $url -OutFile $tempFile
        if (-not (Test-Path -LiteralPath $tempFile)) {
            throw "Downloaded file not found at '$tempFile'."
        }

        Ensure-Utf8Bom -Path $tempFile
        if (-not (Test-ScriptSyntax -Path $tempFile)) {
            throw "Downloaded script failed syntax validation."
        }

        $downloaded = $true
        break
    }
    catch {
        $downloadErrors.Add(("URL '{0}' failed: {1}" -f $url, $_.Exception.Message))
    }
}

if (-not $downloaded) {
    $detail = ($downloadErrors -join ' | ')
    throw "Failed to download a valid OximizeOS.ps1 bootstrap payload. $detail"
}

$psExe = Get-WindowsPowerShellPath
$documentsPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
if ([string]::IsNullOrWhiteSpace([string]$documentsPath) -and -not [string]::IsNullOrWhiteSpace([string]$env:USERPROFILE)) {
    $documentsPath = Join-Path $env:USERPROFILE 'Documents'
}
if (-not [string]::IsNullOrWhiteSpace([string]$documentsPath)) {
    $env:OXIMIZE_LOG_DIR = Join-Path $documentsPath 'OximizeOS\Logs'
}
$startArgs = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-STA',
    '-File', "`"$tempFile`""
)

Start-Process -FilePath $psExe -ArgumentList $startArgs | Out-Null
