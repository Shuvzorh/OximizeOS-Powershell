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

$repoScriptUrl = 'https://raw.githubusercontent.com/Shuvzorh/OximizeOS-Powershell/main/OximizeOS.ps1'
$tempFile = Join-Path $env:TEMP ("OximizeOS_bootstrap_{0}.ps1" -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))

try {
    Invoke-DownloadFile -Url $repoScriptUrl -OutFile $tempFile
}
catch {
    throw "Failed to download OximizeOS.ps1 from '$repoScriptUrl'. Error: $($_.Exception.Message)"
}

if (-not (Test-Path -LiteralPath $tempFile)) {
    throw "Downloaded script not found at '$tempFile'."
}

$psExe = Get-WindowsPowerShellPath
$startArgs = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-STA',
    '-File', "`"$tempFile`""
)

Start-Process -FilePath $psExe -ArgumentList $startArgs | Out-Null
