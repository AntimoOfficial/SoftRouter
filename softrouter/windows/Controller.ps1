#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Inspect', 'Plan', 'Enable', 'Disable', 'Status')][string]$Action = 'Inspect',
    [string]$UpstreamGuid,
    [string]$DownstreamGuid,
    [string]$ConfigPath,
    [switch]$Approved,
    [switch]$ShowResult
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$exitCode = 0
$mutex = $null
$locked = $false
try {
    $expected = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'SoftRouter'
    if ($PSScriptRoot -ine $expected) { throw 'Install first, then use the controller in Program Files.' }
    Import-Module (Join-Path $PSScriptRoot 'SoftRouter.Core.psm1') -Force
    Assert-WindowsHost
    Assert-InstalledPayload $PSScriptRoot
    if ($Action -in @('Plan', 'Enable')) {
        if ($ConfigPath) {
            if ($UpstreamGuid -or $DownstreamGuid) { throw 'Use either a JSON config or explicit GUIDs, not both.' }
            $config = Read-GatewayConfig $ConfigPath
        } else { $config = New-GatewayConfig $UpstreamGuid $DownstreamGuid }
    }
    if ($Action -in @('Enable', 'Disable')) {
        if (-not (Test-Administrator)) { throw 'Run the installed GUI and approve UAC, or use an elevated Windows PowerShell terminal.' }
        $mutex = New-Object Threading.Mutex($false, 'Global\SoftRouter.Windows.ICS')
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another SoftRouter operation is in progress.' }
    }
    switch ($Action) {
        'Inspect' {
            $result = [pscustomobject]@{ Adapters = @(Get-AdapterInventory); Sharing = @(Get-IcsSnapshot); Detail = 'Read-only inventory. No network or power setting was changed.' }
        }
        'Plan' { $result = Get-GatewayPlan $config }
        'Status' { $result = Get-GatewayStatus }
        'Enable' {
            $plan = Get-GatewayPlan $config
            if (-not $Approved) {
                $plan.Summary | Write-Host
                if ((Read-Host 'Type ENABLE to apply this plan') -cne 'ENABLE') { throw 'Activation was not approved.' }
            }
            $result = Invoke-EnableGateway $config
        }
        'Disable' {
            if (-not $Approved -and (Read-Host 'Type DISABLE to restore owned sharing') -cne 'DISABLE') { throw 'Recovery was not approved.' }
            $result = Invoke-DisableGateway
        }
    }
    $text = $result | ConvertTo-Json -Depth 12
    Write-Output $text
} catch {
    $exitCode = 1
    $text = $_.Exception.Message
    Write-Error -Message $text -ErrorAction Continue
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
if ($ShowResult) {
    Add-Type -AssemblyName System.Windows.Forms
    $window = New-Object Windows.Forms.Form
    $window.Text = 'SoftRouter - operation result'
    $window.Size = New-Object Drawing.Size(760, 560)
    $window.StartPosition = 'CenterScreen'
    $box = New-Object Windows.Forms.TextBox
    $box.Multiline = $true; $box.ReadOnly = $true; $box.ScrollBars = 'Both'; $box.Dock = 'Fill'
    $box.Font = New-Object Drawing.Font('Consolas', 10)
    $box.Text = $text -replace '(?<!\r)\n', "`r`n"
    $window.Controls.Add($box)
    [void]$window.ShowDialog()
    $window.Dispose()
}
exit $exitCode
