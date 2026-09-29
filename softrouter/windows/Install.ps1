#requires -Version 5.1
[CmdletBinding()]
param([switch]$Elevated)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'SoftRouter.Core.psm1') -Force
    Assert-WindowsHost
    if (-not (Test-Administrator)) {
        if ($Elevated) { throw 'Administrator approval did not succeed.' }
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'), '-Elevated')
        $process = Start-Process -FilePath $exe -ArgumentList $arguments -Verb RunAs -Wait -PassThru
        exit $process.ExitCode
    }
    $root = Get-InstallRoot
    if (Test-Path -LiteralPath $root) { throw 'SoftRouter is already installed. This test installer does not overwrite an existing installation.' }
    if (Test-Path -LiteralPath (Get-StateRoot)) { throw 'Existing SoftRouter state or recovery records found. No automatic takeover.' }
    Assert-NoReparsePoint $PSScriptRoot
    Assert-ProtectedPath ([Environment]::GetFolderPath('ProgramFiles'))
    $payload = @('SoftRouter.Core.psm1', 'SoftRouter.ps1', 'Controller.ps1', 'Uninstall.ps1', 'Start.cmd', 'Uninstall.cmd', 'gateway.example.json', 'README.md')
    $hashes = [ordered]@{}
    foreach ($name in $payload) {
        $source = Join-Path $PSScriptRoot $name
        Assert-NoReparsePoint $source
        $hashes[$name] = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    }
    Add-Type -AssemblyName System.Windows.Forms
    $review = 'Install this unsigned community test edition in Program Files and add a Start Menu shortcut. No sharing, network, firewall, startup or power setting will be changed. The downloaded installer is the trust boundary; use a release from the project source. Continue?'
    if ([Windows.Forms.MessageBox]::Show($review, 'Install SoftRouter', 'YesNo', 'Information') -ne 'Yes') { exit 0 }
    New-Item -ItemType Directory -Path $root | Out-Null
    Set-ProtectedDirectory $root -Readable
    foreach ($name in $payload) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $root $name)
        Set-ProtectedFile (Join-Path $root $name) -Readable
        if ((Get-FileHash -LiteralPath (Join-Path $root $name) -Algorithm SHA256).Hash -cne $hashes[$name]) { throw 'Source changed during installation; installed files were retained for review.' }
    }
    $manifest = $hashes | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $root 'installed-hashes.json'), $manifest, (New-Object Text.UTF8Encoding($true)))
    Set-ProtectedFile (Join-Path $root 'installed-hashes.json') -Readable
    foreach ($name in @('LICENSE', 'VERSION', 'SoftRouterIcon.png')) {
        $source = Join-Path $PSScriptRoot $name
        if (Test-Path -LiteralPath $source) { Assert-NoReparsePoint $source; Copy-Item -LiteralPath $source -Destination (Join-Path $root $name); Set-ProtectedFile (Join-Path $root $name) -Readable }
    }
    Assert-InstalledPayload $root
    $menu = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'SoftRouter.lnk'
    if (Test-Path -LiteralPath $menu) { throw 'An existing Start Menu shortcut was not overwritten. Use Start.cmd in Program Files.' }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($menu)
    $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $shortcut.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "' + (Join-Path $root 'SoftRouter.ps1') + '"'
    $shortcut.WorkingDirectory = $root
    $shortcut.Description = 'SoftRouter Windows community test - configure sharing explicitly'
    $shortcut.Save()
    [void][Windows.Forms.MessageBox]::Show('Installed. Open SoftRouter from the Start Menu. Sharing is still disabled by this installer.', 'SoftRouter')
} catch { Write-Error $_.Exception.Message -ErrorAction Continue; exit 1 }
