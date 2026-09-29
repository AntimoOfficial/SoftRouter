#requires -Version 5.1
[CmdletBinding()]
param([switch]$Elevated)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$mutex = $null
$locked = $false
try {
    $expected = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'SoftRouter'
    if ($PSScriptRoot -ine $expected) { throw 'Use the installed uninstaller.' }
    Import-Module (Join-Path $PSScriptRoot 'SoftRouter.Core.psm1') -Force
    Assert-WindowsHost
    Assert-InstalledPayload $PSScriptRoot
    if (-not (Test-Administrator)) {
        if ($Elevated) { throw 'Administrator approval did not succeed.' }
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $process = Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'), '-Elevated') -Verb RunAs -Wait -PassThru
        exit $process.ExitCode
    }
    $mutex = New-Object Threading.Mutex($false, 'Global\SoftRouter.Windows.ICS')
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another SoftRouter operation is in progress.' }
    if ($null -ne (Read-GatewayState)) { throw 'An active or incomplete state exists. Use Disable / recover first. The uninstaller does not change sharing.' }
    Add-Type -AssemblyName System.Windows.Forms
    if ([Windows.Forms.MessageBox]::Show('Remove the application and its Start Menu shortcut? Protected recovery history is retained in ProgramData. No network changes will be made.', 'Uninstall SoftRouter', 'YesNo', 'Question') -ne 'Yes') { exit 0 }
    $menu = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'SoftRouter.lnk'
    if (Test-Path -LiteralPath $menu) {
        Assert-NoReparsePoint $menu
        $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($menu)
        if ($shortcut.WorkingDirectory -ieq $PSScriptRoot -and $shortcut.Arguments.Contains((Join-Path $PSScriptRoot 'SoftRouter.ps1'))) { Remove-Item -LiteralPath $menu }
    }
    # Do not recursively erase unexpected files, configurations or user material.
    $names = @('SoftRouter.Core.psm1', 'SoftRouter.ps1', 'Controller.ps1', 'Uninstall.ps1', 'Start.cmd', 'Uninstall.cmd', 'gateway.example.json', 'README.md', 'installed-hashes.json', 'LICENSE', 'VERSION', 'SoftRouterIcon.png')
    foreach ($name in $names) {
        $path = Join-Path $PSScriptRoot $name
        if (Test-Path -LiteralPath $path) { Assert-ProtectedPath $path; Remove-Item -LiteralPath $path }
    }
    if (@(Get-ChildItem -LiteralPath $PSScriptRoot -Force).Count -eq 0) { Remove-Item -LiteralPath $PSScriptRoot }
    [void][Windows.Forms.MessageBox]::Show('Application removed. Any recovery history remains in ProgramData.', 'SoftRouter')
} catch { Write-Error $_.Exception.Message -ErrorAction Continue; exit 1 }
finally {
    if ($locked) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
