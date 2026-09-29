#requires -Version 5.1
# Offline only. All host/network calls are replaced before workflow tests.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$count = 0
function Assert-True([bool]$Value, [string]$Message) {
    if (-not $Value) { throw ('FAILED: ' + $Message) }
    $script:count++
}
function Assert-Throws([scriptblock]$Body, [string]$Message) {
    $failed = $false
    try { & $Body | Out-Null } catch { $failed = $true }
    Assert-True $failed $Message
}
foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') }) {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    Assert-True (@($errors).Count -eq 0) ('PowerShell syntax: ' + $file.Name + ' ' + ($errors | Out-String))
}
$module = Import-Module (Join-Path $root 'SoftRouter.Core.psm1') -Force -PassThru
$upGuid = '11111111-1111-1111-1111-111111111111'
$downGuid = '22222222-2222-2222-2222-222222222222'
$otherGuid = '33333333-3333-3333-3333-333333333333'
$json = '{"schemaVersion":1,"upstreamGuid":"' + $upGuid + '","downstreamGuid":"' + $downGuid + '"}'
$config = ConvertFrom-GatewayJson $json
Assert-True ($config.upstreamGuid -eq $upGuid) 'Valid JSON data accepted'
Assert-Throws { ConvertFrom-GatewayJson ($json -replace 'schemaVersion', 'unknown') } 'Unknown key rejected'
Assert-Throws { ConvertFrom-GatewayJson ($json -replace '"schemaVersion":1', '"schemaVersion":"1"') } 'Version string rejected'
Assert-Throws { ConvertFrom-GatewayJson ('{"schemaVersion":1,"schemaVersion":1,"downstreamGuid":"' + $downGuid + '"}') } 'Duplicate keys rejected'
Assert-Throws { New-GatewayConfig $upGuid $upGuid } 'Same adapter rejected'
Assert-Throws { New-GatewayConfig ('{' + $upGuid + '}') $downGuid } 'Non-canonical GUID rejected'
Assert-Throws { New-GatewayConfig '00000000-0000-0000-0000-000000000000' $downGuid } 'Empty GUID rejected'
Assert-Throws { ConvertFrom-GatewayJson '{"schemaVersion":1,"upstreamGuid":"$(Stop-Computer)","downstreamGuid":"x"}' } 'Executable-looking data rejected'
$up = [pscustomobject]@{ Guid = $upGuid; Name = 'Upstream'; Index = 4; Mac = '00-00-00-00-00-01'; Hardware = $true; Virtual = $false; Type = 71; Status = 'Up' }
$down = [pscustomobject]@{ Guid = $downGuid; Name = 'Downstream'; Index = 9; Mac = '00-00-00-00-00-02'; Hardware = $true; Virtual = $false; Type = 6; Status = 'Disconnected' }
$pair = Resolve-AdapterPair $config @($up, $down)
Assert-True ($pair.Downstream.Index -eq 9) 'Pair resolved by GUID'
Assert-Throws { Resolve-AdapterPair $config @($up) } 'Missing adapter rejected'
$down.Virtual = $true
Assert-Throws { Resolve-AdapterPair $config @($up, $down) } 'Virtual adapter rejected'
$down.Virtual = $false
$baseline = [pscustomobject]@{ Guid = $downGuid; Mac = $down.Mac; Dhcp = 'Enabled'; StaticDns = ''; Addresses = @(); ManualRoutes = @() }
$defaults = @([pscustomobject]@{ InterfaceIndex = 4 })
Assert-EligibleDownstream $pair $baseline $defaults
Assert-True $true 'Eligible dedicated DHCP adapter accepted'
$baseline.StaticDns = '192.0.2.53'
Assert-Throws { Assert-EligibleDownstream $pair $baseline $defaults } 'Static DNS refused'
$baseline.StaticDns = ''
$down.Status = 'Up'
Assert-Throws { Assert-EligibleDownstream $pair $baseline $defaults } 'Connected downstream refused'
$down.Status = 'Disconnected'
$emptyRows = @([pscustomobject]@{ Guid = $upGuid; Enabled = $false; Role = -1; MappingCount = 0 }, [pscustomobject]@{ Guid = $downGuid; Enabled = $false; Role = -1; MappingCount = 0 })
Assert-EmptySharing $emptyRows $config
Assert-True $true 'Unused ICS pair accepted'
$emptyRows[0].Enabled = $true
Assert-Throws { Assert-EmptySharing $emptyRows $config } 'Existing sharing refused'
$emptyRows[0].Enabled = $false
$emptyRows[0].MappingCount = 1
Assert-Throws { Assert-EmptySharing $emptyRows $config } 'Existing mapping refused even when sharing is off'
$emptyRows[0].MappingCount = 0
$owned = [pscustomobject]@{ Config = $config; PublicCompleted = $true; PrivateCompleted = $true }
$ownedRows = @([pscustomobject]@{ Guid = $upGuid; Enabled = $true; Role = 0; MappingCount = 0 }, [pscustomobject]@{ Guid = $downGuid; Enabled = $true; Role = 1; MappingCount = 0 })
Assert-OwnedSharing $owned $ownedRows
Assert-True $true 'Exact owned sharing roles accepted'
Assert-Throws { Assert-OwnedSharing $owned ($ownedRows + [pscustomobject]@{ Guid = $otherGuid; Enabled = $true; Role = 0; MappingCount = 0 }) } 'Foreign sharing blocks recovery'
$owned.PublicCompleted = $false
Assert-Throws { Assert-OwnedSharing $owned $ownedRows } 'Interrupted unacknowledged sharing blocks takeover'
$owned.PublicCompleted = $true
$ownedRows[1].Role = 0
Assert-Throws { Assert-OwnedSharing $owned $ownedRows } 'Role drift blocks recovery'
$ownedRows[1].Role = 1

# Exercise the real restoration function with only its system dependencies mocked.
$restoreExpected = [pscustomobject]@{ Guid = $downGuid; Mac = $down.Mac; Dhcp = 'Disabled'; StaticDns = ''; Addresses = @([pscustomobject]@{ Address = '192.0.2.1'; Prefix = 24; Origin = 'Manual' }); ManualRoutes = @() }
& $module {
    param($Expected)
    $script:RestoreCurrent = $Expected | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $script:RestoreCalls = New-Object Collections.Generic.List[string]
    function script:Get-DownstreamSnapshot($Adapter) { $script:RestoreCurrent }
    function script:Get-DnsClientServerAddress($InterfaceIndex, $AddressFamily) {
        if ($InterfaceIndex -ne 9 -or $AddressFamily -ne 'IPv4') { throw 'DNS lookup escaped selected IPv4 adapter' }
        [pscustomobject]@{ InterfaceIndex = $InterfaceIndex; Family = $AddressFamily }
    }
    function script:Remove-NetIPAddress($InterfaceIndex, $AddressFamily, $IPAddress, $PrefixLength, $Confirm) {
        $script:RestoreCalls.Add(('Remove:' + $InterfaceIndex + ':' + $AddressFamily + ':' + $IPAddress + '/' + $PrefixLength))
    }
    function script:Set-NetIPInterface($InterfaceIndex, $AddressFamily, $Dhcp) {
        $script:RestoreCalls.Add(('Dhcp:' + $InterfaceIndex + ':' + $AddressFamily + ':' + $Dhcp))
    }
    function script:Set-DnsClientServerAddress($InputObject, [switch]$ResetServerAddresses) {
        if ($InputObject.InterfaceIndex -ne 9 -or $InputObject.Family -ne 'IPv4' -or -not $ResetServerAddresses) { throw 'DNS reset escaped selected IPv4 adapter' }
        $script:RestoreCalls.Add('Dns:9:IPv4')
    }
} $restoreExpected
Restore-DownstreamDhcp $down $restoreExpected
$restoreCalls = @(& $module { $script:RestoreCalls.ToArray() })
Assert-True ($restoreCalls.Count -eq 3 -and $restoreCalls[0] -eq 'Remove:9:IPv4:192.0.2.1/24' -and $restoreCalls[1] -eq 'Dhcp:9:IPv4:Enabled' -and $restoreCalls[2] -eq 'Dns:9:IPv4') 'Restoration touches only the recorded IPv4 address and DNS object'
& $module { $script:RestoreCurrent.StaticDns = '192.0.2.99'; $script:RestoreCalls.Clear() }
Assert-Throws { Restore-DownstreamDhcp $down $restoreExpected } 'Downstream drift prevents restoration'
Assert-True ((@(& $module { $script:RestoreCalls.ToArray() })).Count -eq 0) 'No restoration mutation after drift'

# Replace every externally acting dependency used by the workflow. No COM, adapter,
# DNS, route, PF, service, power, or administrator operation is run in these tests.
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('softrouter-win-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $ordinaryFile = Join-Path $testRoot 'ordinary.txt'
    [IO.File]::WriteAllText($ordinaryFile, 'synthetic file')
    Assert-NoReparsePoint $ordinaryFile
    Assert-NoReparsePoint $testRoot
    Assert-True $true 'FileInfo and DirectoryInfo ancestor traversal'
    & $module {
        param($TestRoot, $Config, $Pair, $Baseline)
        $script:FakeRoot = $TestRoot
        $script:FakeState = $null
        $script:FakeConfig = $Config
        $script:FakePair = $Pair
        $script:FakeBaseline = $Baseline
        $script:FakeCurrent = $Baseline
        $script:FakePublic = $false
        $script:FakePrivate = $false
        $script:FakeCalls = New-Object Collections.Generic.List[string]
        $script:FakeFailPrivate = $false
        $script:FakeConflict = $false
        function script:Test-Administrator { $true }
        function script:Initialize-StateDirectory {}
        function script:Get-StateRoot { $script:FakeRoot }
        function script:Read-GatewayState { $script:FakeState }
        function script:Write-GatewayState($State) {
            $script:FakeState = $State
            [IO.File]::WriteAllText((Join-Path $script:FakeRoot 'state.json'), ($State | ConvertTo-Json -Depth 12))
        }
        function script:Get-GatewayPlan($Config) { [pscustomobject]@{ Pair = $script:FakePair; Baseline = $script:FakeBaseline; Config = $Config } }
        function script:Assert-NoCompetingServices { if ($script:FakeConflict) { throw 'Simulated competing NAT' } }
        function script:Get-AdapterInventory { @($script:FakePair.Upstream, $script:FakePair.Downstream) }
        function script:Get-DownstreamSnapshot($Adapter) { $script:FakeCurrent }
        function script:Get-IcsSnapshot {
            @([pscustomobject]@{ Guid = $script:FakeConfig.upstreamGuid; Enabled = $script:FakePublic; Role = 0; MappingCount = 0 }, [pscustomobject]@{ Guid = $script:FakeConfig.downstreamGuid; Enabled = $script:FakePrivate; Role = 1; MappingCount = 0 })
        }
        function script:Set-IcsRole([string]$Guid, [int]$Role) {
            $script:FakeCalls.Add($Guid + ':' + $Role)
            if ($Guid -eq $script:FakeConfig.upstreamGuid) { $script:FakePublic = $Role -eq 0 }
            else {
                if ($script:FakeFailPrivate -and $Role -eq 1) { throw 'Simulated private-sharing failure' }
                $script:FakePrivate = $Role -eq 1
                if ($script:FakePrivate) {
                    $script:FakeCurrent = [pscustomobject]@{ Guid = $Guid; Mac = $script:FakePair.Downstream.Mac; Dhcp = 'Disabled'; StaticDns = ''; Addresses = @([pscustomobject]@{ Address = '192.0.2.1'; Prefix = 24; Origin = 'Manual' }); ManualRoutes = @() }
                }
            }
        }
        function script:Restore-DownstreamDhcp($Adapter, $Expected) { $script:FakeCalls.Add('RestoreDhcp'); $script:FakeCurrent = $script:FakeBaseline }
        function script:Start-Sleep { throw 'Unexpected delayed readiness in mock' }
    } $testRoot $config $pair $baseline
    $result = Invoke-EnableGateway $config
    Assert-True ($result.State -eq 'ACTIVE') 'Mock ICS activation read back'
    Assert-True (-not $result.DownstreamVerified) 'Activation never claims downstream connectivity'
    $calls = @(& $module { $script:FakeCalls.ToArray() })
    Assert-True ($calls.Count -eq 2 -and $calls[0] -eq ($upGuid + ':0') -and $calls[1] -eq ($downGuid + ':1')) 'Only exact selected roles enabled'
    Assert-Throws { Invoke-EnableGateway $config } 'Existing state refuses new activation'
    $result = Invoke-DisableGateway
    Assert-True ($result.State -eq 'STOPPED') 'Mock recovery completes'
    $calls = @(& $module { $script:FakeCalls.ToArray() })
    Assert-True ($calls[2] -eq ($downGuid + ':-1') -and $calls[3] -eq ($upGuid + ':-1') -and $calls[4] -eq 'RestoreDhcp') 'Only owned roles disabled before DHCP restore'
    & $module { $script:FakeState = $null; $script:FakeFailPrivate = $true; $script:FakeCalls.Clear() }
    Assert-Throws { Invoke-EnableGateway $config } 'Private role failure surfaces'
    $partial = & $module { $script:FakeState }
    Assert-True ($partial.Phase -eq 'ATTENTION' -and $partial.FailedPhase -eq 'ENABLING_PRIVATE' -and $partial.LastOperation -eq 'EnablePrivate' -and $partial.PublicCompleted -and -not $partial.PrivateCompleted) 'Partial mutation and failed phase retained in recoverable journal'
    $result = Invoke-DisableGateway
    Assert-True ($result.State -eq 'STOPPED') 'Acknowledged partial activation recovered'
    & $module { $script:FakeState = $null; $script:FakeFailPrivate = $false }
    Invoke-EnableGateway $config | Out-Null
    & $module { $script:FakePrivate = $false; $script:FakeCurrent = $script:FakeBaseline; $script:FakeCalls.Clear() }
    $result = Invoke-DisableGateway
    $calls = @(& $module { $script:FakeCalls.ToArray() })
    Assert-True ($result.State -eq 'STOPPED' -and $calls.Count -eq 1 -and $calls[0] -eq ($upGuid + ':-1')) 'Recovery resumes when private role and downstream baseline already restored'
    & $module { $script:FakeState = $null; $script:FakeFailPrivate = $false; $script:FakeConflict = $true; $script:FakeCalls.Clear() }
    Assert-Throws { Invoke-EnableGateway $config } 'Last-moment competing NAT blocks mutation'
    $calls = @(& $module { $script:FakeCalls.ToArray() })
    Assert-True ($calls.Count -eq 0) 'No mutation after conflict'
} finally {
    Remove-Module $module
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
Write-Output ('PASS: ' + $count + ' offline checks. No live networking or power operations were performed.')
