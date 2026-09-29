#requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
try {
    $expected = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'SoftRouter'
    if ($PSScriptRoot -ine $expected) { throw 'Double-click Install.cmd before starting SoftRouter.' }
    Import-Module (Join-Path $PSScriptRoot 'SoftRouter.Core.psm1') -Force
    Assert-WindowsHost
    Assert-InstalledPayload $PSScriptRoot
} catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'SoftRouter'); exit 1 }
$script:inventory = @()
$form = New-Object Windows.Forms.Form
$form.Text = 'SoftRouter - Windows community test'
$form.Size = New-Object Drawing.Size(840, 660)
$form.MinimumSize = $form.Size
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Segoe UI', 10)
$title = New-Object Windows.Forms.Label
$title.Text = 'Share a connection with a dedicated Ethernet router'
$title.AutoSize = $true; $title.Location = New-Object Drawing.Point(24, 24)
$title.Font = New-Object Drawing.Font('Segoe UI', 16, [Drawing.FontStyle]::Bold)
$form.Controls.Add($title)
$hint = New-Object Windows.Forms.Label
$hint.Text = 'TEST EDITION: no live network validation. Installation does not enable sharing.'
$hint.AutoSize = $true; $hint.Location = New-Object Drawing.Point(24, 66)
$form.Controls.Add($hint)
function Add-Label([string]$Text, [int]$Y) {
    $label = New-Object Windows.Forms.Label
    $label.Text = $Text; $label.AutoSize = $true; $label.Location = New-Object Drawing.Point(24, $Y)
    $form.Controls.Add($label)
}
Add-Label 'Upstream: connected physical Wi-Fi or Ethernet' 112
$up = New-Object Windows.Forms.ComboBox
$up.Location = New-Object Drawing.Point(24, 138); $up.Size = New-Object Drawing.Size(774, 30); $up.DropDownStyle = 'DropDownList'
$form.Controls.Add($up)
Add-Label 'Downstream: dedicated physical Ethernet; unplug its cable before enabling' 188
$down = New-Object Windows.Forms.ComboBox
$down.Location = New-Object Drawing.Point(24, 214); $down.Size = New-Object Drawing.Size(774, 30); $down.DropDownStyle = 'DropDownList'
$form.Controls.Add($down)
$details = New-Object Windows.Forms.TextBox
$details.Location = New-Object Drawing.Point(24, 330); $details.Size = New-Object Drawing.Size(774, 230)
$details.Multiline = $true; $details.ReadOnly = $true; $details.ScrollBars = 'Vertical'
$details.Text = 'Refresh adapters, choose both GUIDs, then review and enable. Existing ICS, NAT, hotspot and bridge configurations are never replaced. ICS chooses its own subnet. Set the router WAN to DHCP after activation. Closing this window does not disable sharing.'
$form.Controls.Add($details)
function Refresh-Adapters {
    $script:inventory = @(Get-AdapterInventory | Where-Object { $_.Hardware -and -not $_.Virtual -and $_.Type -in @(6, 71) })
    $up.Items.Clear(); $down.Items.Clear()
    foreach ($adapter in $script:inventory) {
        $label = $adapter.Name + ' | ' + $adapter.Status + ' | ' + $adapter.Guid
        [void]$up.Items.Add($label)
        if ($adapter.Type -eq 6) { [void]$down.Items.Add($label) }
    }
    # No automatic selection: a current default route is not user intent.
}
function Start-Controller([string]$Action, [string[]]$Extra = @()) {
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $path = Join-Path $PSScriptRoot 'Controller.ps1'
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $path + '"'), '-Action', $Action, '-ShowResult') + $Extra
    Start-Process -FilePath $exe -ArgumentList $args -Verb RunAs -Wait
}
function Add-Button([string]$Text, [int]$X, [int]$Width, [scriptblock]$Action) {
    $button = New-Object Windows.Forms.Button
    $button.Text = $Text; $button.Location = New-Object Drawing.Point($X, 274); $button.Size = New-Object Drawing.Size($Width, 38)
    $button.Add_Click($Action); $form.Controls.Add($button)
}
Add-Button 'Refresh' 24 110 {
    try { Refresh-Adapters; $details.Text = 'Choose adapters by their names and GUIDs. No adapter has been selected automatically.' }
    catch { $details.Text = $_.Exception.Message }
}
Add-Button 'Review and enable' 146 188 {
    try {
        if ($null -eq $up.SelectedItem -or $null -eq $down.SelectedItem) { throw 'Select both adapters explicitly.' }
        $upGuid = ([string]$up.SelectedItem -split ' \| ')[-1]
        $downGuid = ([string]$down.SelectedItem -split ' \| ')[-1]
        $config = New-GatewayConfig $upGuid $downGuid
        $pair = Resolve-AdapterPair $config $script:inventory
        $review = 'Share ' + $pair.Upstream.Name + ' [' + $upGuid + '] with ' + $pair.Downstream.Name + ' [' + $downGuid + '].' + [Environment]::NewLine + [Environment]::NewLine + 'Windows ICS will change downstream IPv4, DHCP/NAT and possibly firewall settings. Downstream must already use DHCP and automatic DNS, with its cable unplugged. Existing sharing, NetNat, hotspot or bridge resources cause refusal. After activation, connect router WAN and use DHCP. Recovery affects only acknowledged sharing and the eligible downstream baseline. It leaves OS-managed firewall policies in place. No power changes. Internet access and reboot persistence remain unverified.' + [Environment]::NewLine + [Environment]::NewLine + 'Continue to administrator approval?'
        $details.Text = $review
        if ([Windows.Forms.MessageBox]::Show($review, 'Review network changes', 'YesNo', 'Warning') -ne 'Yes') { return }
        Start-Controller 'Enable' @('-UpstreamGuid', $upGuid, '-DownstreamGuid', $downGuid, '-Approved')
    } catch { $details.Text = $_.Exception.Message }
}
Add-Button 'Status / inspect' 346 158 {
    try { Start-Controller 'Status' } catch { $details.Text = $_.Exception.Message }
}
Add-Button 'Disable / recover' 516 168 {
    try {
        $review = 'Disable only sharing recorded by this installation and restore its eligible downstream DHCP baseline. If ownership changed, recovery stops and retains the journal. Existing connections through this gateway will be interrupted. Continue?'
        if ([Windows.Forms.MessageBox]::Show($review, 'Review recovery', 'YesNo', 'Warning') -eq 'Yes') { Start-Controller 'Disable' @('-Approved') }
    } catch { $details.Text = $_.Exception.Message }
}
$footer = New-Object Windows.Forms.Label
$footer.Text = 'No automatic startup, network switching, proxy configuration, or sleep suppression.'
$footer.AutoSize = $true; $footer.Location = New-Object Drawing.Point(24, 582)
$form.Controls.Add($footer)
try { Refresh-Adapters } catch { $details.Text = $_.Exception.Message }
[void]$form.ShowDialog()
$form.Dispose()
