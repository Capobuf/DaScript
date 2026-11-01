#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$AllowServerReboot,
    [switch]$NoMonitor,
    [ValidateSet('Ask', 'Allow', 'Skip')]
    [string]$Windows11Upgrade = 'Ask'
)

$ErrorActionPreference = 'Stop'
# Follow the latest worker published on main at each new launch.
$workerUrl = 'https://raw.githubusercontent.com/Capobuf/DaScript/main/windows/windows-update/MSP-WindowsUpdate.ps1'

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Open Windows PowerShell as Administrator.'
}
if (-not $AllowServerReboot) {
    $productType = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).ProductType
    if ($productType -notin 1, 2, 3) { throw 'Unable to determine whether this computer is a Windows client or server.' }
    if ($productType -in 2, 3) {
        if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected -or
            [Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {
            throw 'Unattended start on Windows Server requires -AllowServerReboot.'
        }
        Write-Warning 'Automatic restarts interrupt services and forcibly close applications. Save all work before continuing.'
        try { $answer = Read-Host 'Autorizzi i riavvii automatici del server? [s/N]' }
        catch { throw 'Cannot read the initial choice. Specify -AllowServerReboot to authorize unattended server restarts.' }
        if (([string]$answer).Trim() -ine 's') {
            throw 'Server restarts were not authorized. No updates were started.'
        }
        $AllowServerReboot = $true
    }
}
$uri = [Uri]$workerUrl
if ($uri.Scheme -ne 'https') { throw 'HTTPS is required.' }
$download = Join-Path $env:TEMP ('MSP-WindowsUpdate-' + [Guid]::NewGuid().ToString('N') + '.ps1')
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $uri -UseBasicParsing -OutFile $download

    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $download, '-Action', 'Start', '-Windows11Upgrade', $Windows11Upgrade)
    if ($AllowServerReboot) { $arguments += '-AllowServerReboot' }
    if ($NoMonitor) { $arguments += '-NoMonitor' }
    & $powershell @arguments
    if ($LASTEXITCODE -ne 0) { throw "MSP Windows Update returned exit code $LASTEXITCODE." }
} finally {
    if (Test-Path -LiteralPath $download) {
        Remove-Item -LiteralPath $download -Force
    }
}
