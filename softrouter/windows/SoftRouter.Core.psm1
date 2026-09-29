Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-InstallRoot { Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'SoftRouter' }
function Get-StateRoot { Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'SoftRouter' }
function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Assert-WindowsHost {
    if ([Environment]::OSVersion.Platform -ne 'Win32NT' -or -not [Environment]::Is64BitProcess) {
        throw 'Use 64-bit Windows PowerShell 5.1 on Windows 10 or 11.'
    }
    if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) {
        throw 'Use Windows PowerShell 5.1, not PowerShell 7.'
    }
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    if ($os.ProductType -ne 1 -or [int]$os.BuildNumber -lt 19041) {
        throw 'This test edition requires Windows 10 build 19041 or later, or Windows 11. Windows Server is excluded.'
    }
}
function Assert-NoReparsePoint([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    while ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Reparse points are not accepted.' }
        if ($item -is [IO.FileInfo]) { $item = $item.Directory } else { $item = $item.Parent }
    }
}
function Set-ProtectedDirectory([string]$Path, [switch]$Readable) {
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $admin = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $acl.SetOwner($admin)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $id = New-Object Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($id, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    if ($Readable) {
        $id = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($id, 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Set-ProtectedFile([string]$Path, [switch]$Readable) {
    $acl = New-Object Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $id = New-Object Security.Principal.SecurityIdentifier($sid)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($id, 'FullControl', 'Allow')))
    }
    if ($Readable) {
        $id = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($id, 'ReadAndExecute', 'Allow')))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Assert-ProtectedPath([string]$Path) {
    Assert-NoReparsePoint $Path
    $acl = Get-Acl -LiteralPath $Path
    $trusted = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    if ($trusted -notcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value) { throw 'Untrusted file owner.' }
    $write = [Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership
    foreach ($ace in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if (($ace.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
        if ($ace.AccessControlType -eq 'Allow' -and ($ace.FileSystemRights -band $write) -ne 0 -and $trusted -notcontains $ace.IdentityReference.Value) {
            throw 'A non-administrator can modify the application or state.'
        }
    }
}
function Assert-InstalledPayload([string]$Directory) {
    if ([IO.Path]::GetFullPath($Directory).TrimEnd('\') -ine (Get-InstallRoot)) { throw 'Run the installed application from Program Files.' }
    Assert-ProtectedPath $Directory
    $manifestPath = Join-Path $Directory 'installed-hashes.json'
    Assert-ProtectedPath $manifestPath
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $required = @('SoftRouter.Core.psm1', 'SoftRouter.ps1', 'Controller.ps1', 'Uninstall.ps1', 'Start.cmd', 'Uninstall.cmd')
    foreach ($name in $required) {
        $entry = @($manifest.PSObject.Properties | Where-Object { $_.Name -ceq $name })
        if ($entry.Count -ne 1 -or [string]$entry[0].Value -notmatch '\A[0-9A-Fa-f]{64}\z') { throw 'Installed payload manifest is incomplete.' }
        $path = Join-Path $Directory $name
        Assert-ProtectedPath $path
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $entry[0].Value) { throw ('Installed file integrity check failed: ' + $name) }
    }
}
function ConvertTo-AdapterGuid([object]$Value) {
    if ($Value -isnot [string] -or $Value -notmatch '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z') {
        throw 'Adapter identity must be a canonical GUID without braces.'
    }
    $guid = [Guid]$Value
    if ($guid -eq [Guid]::Empty) { throw 'The empty GUID is not an adapter.' }
    $guid.ToString('D')
}
function ConvertFrom-GatewayJson([string]$Json) {
    # Only these three scalar fields are accepted. Reject duplicates before ConvertFrom-Json.
    $pair = '"(?:schemaVersion|upstreamGuid|downstreamGuid)"\s*:\s*(?:1|"[0-9a-fA-F-]+")'
    if ($Json.Length -gt 4096 -or $Json -notmatch ('\A\s*\{\s*' + $pair + '\s*,\s*' + $pair + '\s*,\s*' + $pair + '\s*\}\s*\z')) { throw 'Configuration must contain exactly schemaVersion, upstreamGuid and downstreamGuid.' }
    $keys = @([regex]::Matches($Json, '"(schemaVersion|upstreamGuid|downstreamGuid)"\s*:') | ForEach-Object { $_.Groups[1].Value })
    foreach ($key in @('schemaVersion', 'upstreamGuid', 'downstreamGuid')) {
        if (@($keys | Where-Object { $_ -ceq $key }).Count -ne 1) { throw 'Duplicate or missing configuration field.' }
    }
    $config = $Json | ConvertFrom-Json
    if (($config.schemaVersion -isnot [int] -and $config.schemaVersion -isnot [long]) -or $config.schemaVersion -ne 1) { throw 'Unsupported configuration version.' }
    New-GatewayConfig $config.upstreamGuid $config.downstreamGuid
}
function New-GatewayConfig([object]$UpstreamGuid, [object]$DownstreamGuid) {
    $up = ConvertTo-AdapterGuid $UpstreamGuid
    $down = ConvertTo-AdapterGuid $DownstreamGuid
    if ($up -eq $down) { throw 'Upstream and downstream must be different adapters.' }
    [pscustomobject]@{ schemaVersion = 1; upstreamGuid = $up; downstreamGuid = $down }
}
function Read-GatewayConfig([string]$Path) {
    Assert-NoReparsePoint $Path
    if ((Get-Item -LiteralPath $Path).Length -gt 4096) { throw 'Configuration is too large.' }
    ConvertFrom-GatewayJson (Get-Content -LiteralPath $Path -Raw)
}
function Get-AdapterInventory {
    @(Get-NetAdapter -IncludeHidden -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{ Guid = ([Guid]$_.InterfaceGuid).ToString('D'); Name = [string]$_.Name; Description = [string]$_.InterfaceDescription; Index = [int]$_.ifIndex; Mac = [string]$_.MacAddress; Hardware = [bool]$_.HardwareInterface; Virtual = [bool]$_.Virtual; Type = [int]$_.InterfaceType; Status = [string]$_.Status }
    })
}
function Resolve-AdapterPair($Config, [object[]]$Adapters) {
    $up = @($Adapters | Where-Object { $_.Guid -eq $Config.upstreamGuid })
    $down = @($Adapters | Where-Object { $_.Guid -eq $Config.downstreamGuid })
    if ($up.Count -ne 1 -or $down.Count -ne 1) { throw 'Selected adapter is missing or ambiguous.' }
    foreach ($adapter in @($up[0], $down[0])) {
        if (-not $adapter.Hardware -or $adapter.Virtual -or $adapter.Type -notin @(6, 71)) { throw 'Only physical Ethernet or Wi-Fi adapters are supported.' }
    }
    if ($down[0].Type -ne 6) { throw 'Downstream must be a dedicated physical Ethernet adapter.' }
    [pscustomobject]@{ Upstream = $up[0]; Downstream = $down[0] }
}
function Get-IcsConnections {
    $manager = New-Object -ComObject HNetCfg.HNetShare
    $rows = @()
    foreach ($connection in $manager.EnumEveryConnection) {
        $props = $manager.NetConnectionProps($connection)
        $config = $manager.INetSharingConfigurationForINetConnection($connection)
        $enabled = [bool]$config.SharingEnabled
        $role = -1
        if ($enabled) { $role = [int]$config.SharingConnectionType }
        $rows += [pscustomobject]@{ Guid = ([Guid]$props.Guid).ToString('D'); Enabled = $enabled; Role = $role; MappingCount = @($config.EnumPortMappings(0)).Count; Handle = $config }
    }
    $rows
}
function Get-IcsSnapshot {
    @(Get-IcsConnections | ForEach-Object { [pscustomobject]@{ Guid = $_.Guid; Enabled = $_.Enabled; Role = $_.Role; MappingCount = $_.MappingCount } })
}
function Set-IcsRole([string]$Guid, [int]$Role) {
    $rows = @(Get-IcsConnections | Where-Object { $_.Guid -eq $Guid })
    if ($rows.Count -ne 1) { throw 'ICS connection identity is missing or ambiguous.' }
    if ($Role -eq -1) { $rows[0].Handle.DisableSharing() } else { $rows[0].Handle.EnableSharing($Role) }
}
function Assert-NoCompetingServices {
    # Failure to inspect is not absence. Never stop these services or remove another NAT.
    if (@(Get-NetNat -ErrorAction Stop).Count -gt 0) { throw 'An existing NetNat configuration prevents activation.' }
    foreach ($name in @('icssvc', 'RemoteAccess')) {
        $service = Get-Service -Name $name -ErrorAction Stop
        if ($service.Status -ne 'Stopped') { throw ('Mobile Hotspot or routing service is active or transitioning: ' + $name) }
    }
    $bridges = @(Get-NetAdapterBinding -Name '*' -IncludeHidden -AllBindings -ErrorAction Stop | Where-Object { $_.ComponentID -eq 'ms_bridge' -and $_.Enabled })
    if ($bridges.Count -gt 0) { throw 'An enabled network bridge binding prevents activation.' }
}
function Get-DownstreamSnapshot($Adapter) {
    $iface = @(Get-NetIPInterface -InterfaceIndex $Adapter.Index -AddressFamily IPv4 -ErrorAction Stop)
    if ($iface.Count -ne 1) { throw 'Cannot identify downstream IPv4 configuration.' }
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{' + $Adapter.Guid + '}'
    $dns = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
    $staticDns = ''
    if ($null -ne $dns.PSObject.Properties['NameServer']) { $staticDns = [string]$dns.NameServer }
    # Query the table before filtering: an unused/disconnected adapter can have no row.
    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.InterfaceIndex -eq $Adapter.Index } | ForEach-Object {
        [pscustomobject]@{ Address = [string]$_.IPAddress; Prefix = [int]$_.PrefixLength; Origin = [string]$_.PrefixOrigin }
    } | Sort-Object Address)
    $routes = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.InterfaceIndex -eq $Adapter.Index -and $_.Protocol -eq 'NetMgmt' } | ForEach-Object {
        [pscustomobject]@{ Destination = [string]$_.DestinationPrefix; NextHop = [string]$_.NextHop; Metric = [int]$_.RouteMetric }
    } | Sort-Object Destination, NextHop)
    [pscustomobject]@{ Guid = $Adapter.Guid; Mac = $Adapter.Mac; Dhcp = [string]$iface[0].Dhcp; StaticDns = $staticDns; Addresses = $addresses; ManualRoutes = $routes }
}
function Get-SnapshotSignature($Snapshot) {
    # Index and DHCP lease lifetimes are not ownership identities.
    $Snapshot | ConvertTo-Json -Depth 8 -Compress
}
function Assert-EligibleDownstream($Pair, $Snapshot, [object[]]$DefaultRoutes) {
    if ($Pair.Upstream.Status -ne 'Up') { throw 'Upstream must be connected before activation.' }
    if ($Pair.Downstream.Status -ne 'Disconnected') { throw 'Unplug the downstream Ethernet cable before activation; do not disable upstream Wi-Fi.' }
    if ($Snapshot.Dhcp -ne 'Enabled' -or $Snapshot.StaticDns -ne '' -or @($Snapshot.ManualRoutes).Count -ne 0) { throw 'Downstream must already use DHCP and automatic DNS, without static routes.' }
    if (@($Snapshot.Addresses | Where-Object { $_.Origin -eq 'Manual' }).Count -gt 0) { throw 'Downstream has a static IPv4 address.' }
    if (@($DefaultRoutes | Where-Object { $_.InterfaceIndex -eq $Pair.Downstream.Index }).Count -gt 0) { throw 'Downstream currently carries a default route.' }
    if (@($DefaultRoutes | Where-Object { $_.InterfaceIndex -eq $Pair.Upstream.Index }).Count -eq 0) { throw 'Selected upstream is not a current IPv4 default route.' }
}
function Assert-EmptySharing([object[]]$Rows, $Config) {
    if (@($Rows | Where-Object { $_.Enabled }).Count -gt 0) { throw 'Existing Internet Connection Sharing prevents activation; it will not be replaced.' }
    foreach ($guid in @($Config.upstreamGuid, $Config.downstreamGuid)) {
        $selected = @($Rows | Where-Object { $_.Guid -eq $guid })
        if ($selected.Count -ne 1 -or $selected[0].MappingCount -ne 0) { throw 'Selected ICS connection is unavailable or has pre-existing port mappings.' }
    }
}
function Assert-OwnedSharing($State, [object[]]$Rows) {
    foreach ($row in $Rows) {
        if (-not $row.Enabled) { continue }
        $allowed = ($row.Guid -eq $State.Config.upstreamGuid -and $row.Role -eq 0 -and $State.PublicCompleted) -or ($row.Guid -eq $State.Config.downstreamGuid -and $row.Role -eq 1 -and $State.PrivateCompleted)
        if (-not $allowed) { throw 'Sharing ownership changed or a previous operation was interrupted before acknowledgement. State is retained.' }
    }
    foreach ($guid in @($State.Config.upstreamGuid, $State.Config.downstreamGuid)) {
        $selected = @($Rows | Where-Object { $_.Guid -eq $guid })
        if ($selected.Count -ne 1 -or $selected[0].MappingCount -ne 0) { throw 'Connection missing or port mappings changed; recovery will not overwrite it.' }
    }
}
function Initialize-StateDirectory {
    $root = Get-StateRoot
    if (-not (Test-Path -LiteralPath $root)) {
        New-Item -ItemType Directory -Path $root | Out-Null
        Set-ProtectedDirectory $root
    }
    Assert-ProtectedPath $root
}
function Read-GatewayState {
    $path = Join-Path (Get-StateRoot) 'state.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    Assert-ProtectedPath (Get-StateRoot)
    Assert-ProtectedPath $path
    if ((Get-Item -LiteralPath $path).Length -gt 65536) { throw 'Recovery state is unexpectedly large.' }
    $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($state.Version -ne 1 -or $state.Owner -ne 'SoftRouter.Windows.ICS') { throw 'Unknown recovery state. No takeover.' }
    $state.Config = New-GatewayConfig $state.Config.upstreamGuid $state.Config.downstreamGuid
    $state
}
function Write-GatewayState($State) {
    $root = Get-StateRoot
    $temp = Join-Path $root 'state.pending.json'
    $path = Join-Path $root 'state.json'
    if (Test-Path -LiteralPath $temp) { Assert-ProtectedPath $temp }
    $json = $State | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($temp, $json, (New-Object Text.UTF8Encoding($true)))
    Set-ProtectedFile $temp
    if (Test-Path -LiteralPath $path) { [IO.File]::Replace($temp, $path, $null) } else { [IO.File]::Move($temp, $path) }
}
function Get-GatewayPlan($Config) {
    Assert-NoCompetingServices
    $pair = Resolve-AdapterPair $Config @(Get-AdapterInventory)
    $sharing = @(Get-IcsSnapshot)
    Assert-EmptySharing $sharing $Config
    $baseline = Get-DownstreamSnapshot $pair.Downstream
    $defaults = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction Stop)
    Assert-EligibleDownstream $pair $baseline $defaults
    [pscustomobject]@{ Pair = $pair; Baseline = $baseline; Config = $Config; Summary = ('Share ' + $pair.Upstream.Name + ' (' + $Config.upstreamGuid + ') to ' + $pair.Downstream.Name + ' (' + $Config.downstreamGuid + '). Windows ICS will choose the downstream IPv4 subnet, run its DHCP/NAT service, and may change firewall settings. Connect the router WAN only after activation and set it to DHCP. Recovery disables only acknowledged sharing on these adapters and restores the eligible downstream DHCP/automatic-DNS baseline. No sleep settings are changed. Closing the app does not stop ICS.') }
}
function Invoke-EnableGateway($Config) {
    if (-not (Test-Administrator)) { throw 'Administrator approval is required.' }
    Initialize-StateDirectory
    if ($null -ne (Read-GatewayState)) { throw 'A recovery state already exists. Inspect or disable it before a new activation.' }
    $plan = Get-GatewayPlan $Config
    $state = [pscustomobject]@{ Version = 1; Owner = 'SoftRouter.Windows.ICS'; Phase = 'PREPARED'; FailedPhase = ''; LastOperation = ''; Created = [DateTime]::UtcNow.ToString('o'); Config = $Config; Baseline = $plan.Baseline; UpstreamMac = $plan.Pair.Upstream.Mac; PublicCompleted = $false; PrivateCompleted = $false; ExpectedDownstream = $null; LastError = ''; DownstreamVerified = $false }
    Write-GatewayState $state
    try {
        Assert-NoCompetingServices
        Assert-EmptySharing @(Get-IcsSnapshot) $Config
        $state.Phase = 'ENABLING_PUBLIC'; $state.LastOperation = 'EnablePublic'; Write-GatewayState $state
        Set-IcsRole $Config.upstreamGuid 0
        $state.PublicCompleted = $true; $state.Phase = 'PUBLIC_ENABLED'; Write-GatewayState $state
        Assert-OwnedSharing $state @(Get-IcsSnapshot)
        if ((Get-SnapshotSignature (Get-DownstreamSnapshot $plan.Pair.Downstream)) -cne (Get-SnapshotSignature $state.Baseline)) { throw 'Downstream changed before private sharing.' }
        $state.Phase = 'ENABLING_PRIVATE'; $state.LastOperation = 'EnablePrivate'; Write-GatewayState $state
        Set-IcsRole $Config.downstreamGuid 1
        $state.PrivateCompleted = $true
        $state.ExpectedDownstream = Get-DownstreamSnapshot $plan.Pair.Downstream
        $state.Phase = 'VERIFYING'; Write-GatewayState $state
        Assert-OwnedSharing $state @(Get-IcsSnapshot)
        $roles = @(Get-IcsSnapshot | Where-Object { $_.Enabled })
        if ($roles.Count -ne 2) { throw 'ICS did not establish both selected roles.' }
        # The OS may apply the private address after the COM call returns.
        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            $state.ExpectedDownstream = Get-DownstreamSnapshot $plan.Pair.Downstream
            if (@($state.ExpectedDownstream.Addresses | Where-Object { $_.Origin -eq 'Manual' -and $_.Address -notlike '169.254.*' }).Count -gt 0) { break }
            Start-Sleep -Milliseconds 500
        }
        if (@($state.ExpectedDownstream.Addresses | Where-Object { $_.Origin -eq 'Manual' -and $_.Address -notlike '169.254.*' }).Count -eq 0) { throw 'ICS private IPv4 address was not observed; inspect before connecting the router.' }
        $state.Phase = 'ACTIVE'; Write-GatewayState $state
        Get-GatewayStatus
    } catch {
        $state.LastError = $_.Exception.Message
        $state.FailedPhase = $state.Phase
        $state.Phase = 'ATTENTION'; Write-GatewayState $state
        throw ('Activation did not complete. State retained for Disable / recover: ' + $state.LastError)
    }
}
function Restore-DownstreamDhcp($Adapter, $Expected) {
    $current = Get-DownstreamSnapshot $Adapter
    if ((Get-SnapshotSignature $current) -cne (Get-SnapshotSignature $Expected)) { throw 'Downstream changed after sharing was disabled; restoration stopped.' }
    $dns = @(Get-DnsClientServerAddress -InterfaceIndex $Adapter.Index -AddressFamily IPv4 -ErrorAction Stop)
    if ($dns.Count -ne 1) { throw 'Cannot identify the owned IPv4 DNS configuration.' }
    # Remove only the exact ICS-owned static addresses recorded before DisableSharing.
    foreach ($address in @($Expected.Addresses | Where-Object { $_.Origin -eq 'Manual' })) {
        Remove-NetIPAddress -InterfaceIndex $Adapter.Index -AddressFamily IPv4 -IPAddress $address.Address -PrefixLength $address.Prefix -Confirm:$false -ErrorAction Stop
    }
    Set-NetIPInterface -InterfaceIndex $Adapter.Index -AddressFamily IPv4 -Dhcp Enabled -ErrorAction Stop
    Set-DnsClientServerAddress -InputObject $dns[0] -ResetServerAddresses -ErrorAction Stop
}
function Invoke-DisableGateway {
    if (-not (Test-Administrator)) { throw 'Administrator approval is required.' }
    $state = Read-GatewayState
    if ($null -eq $state) { throw 'No owned sharing state exists. Nothing will be disabled.' }
    $pair = Resolve-AdapterPair $state.Config @(Get-AdapterInventory)
    if ($pair.Upstream.Mac -ne $state.UpstreamMac -or $pair.Downstream.Mac -ne $state.Baseline.Mac) { throw 'Adapter hardware identity changed; recovery stopped.' }
    Assert-NoCompetingServices
    $sharingBefore = @(Get-IcsSnapshot)
    Assert-OwnedSharing $state $sharingBefore
    $before = Get-DownstreamSnapshot $pair.Downstream
    $privateStillEnabled = @($sharingBefore | Where-Object { $_.Guid -eq $state.Config.downstreamGuid -and $_.Enabled }).Count -gt 0
    $alreadyRestored = -not $privateStillEnabled -and $before.Dhcp -eq 'Enabled' -and $before.StaticDns -eq '' -and @($before.Addresses | Where-Object { $_.Origin -eq 'Manual' }).Count -eq 0 -and @($before.ManualRoutes).Count -eq 0
    if ($state.PrivateCompleted) {
        if (-not $alreadyRestored -and ($null -eq $state.ExpectedDownstream -or (Get-SnapshotSignature $before) -cne (Get-SnapshotSignature $state.ExpectedDownstream))) { throw 'Downstream configuration changed; refusing automatic restoration.' }
    } elseif ((Get-SnapshotSignature $before) -cne (Get-SnapshotSignature $state.Baseline)) { throw 'Unacknowledged downstream mutation; state retained for local review.' }
    try {
        $state.Phase = 'DISABLING'; Write-GatewayState $state
        foreach ($guid in @($state.Config.downstreamGuid, $state.Config.upstreamGuid)) {
            Assert-OwnedSharing $state @(Get-IcsSnapshot)
            $enabled = @(Get-IcsSnapshot | Where-Object { $_.Guid -eq $guid -and $_.Enabled })
            if ($enabled.Count -eq 1) {
                $state.LastOperation = 'Disable:' + $guid; Write-GatewayState $state
                Set-IcsRole $guid -1
            }
        }
        Assert-EmptySharing @(Get-IcsSnapshot) $state.Config
        $after = Get-DownstreamSnapshot $pair.Downstream
        if ($state.PrivateCompleted) {
            if ($after.Dhcp -eq 'Enabled' -and $after.StaticDns -eq '' -and @($after.Addresses | Where-Object { $_.Origin -eq 'Manual' }).Count -eq 0 -and @($after.ManualRoutes).Count -eq 0) {
                # ICS already restored the eligible baseline itself.
            } elseif ((Get-SnapshotSignature $after) -ceq (Get-SnapshotSignature $state.ExpectedDownstream)) {
                $state.Phase = 'RESTORING_DHCP'; $state.LastOperation = 'RestoreDownstreamDhcp'; Write-GatewayState $state
                Restore-DownstreamDhcp $pair.Downstream $state.ExpectedDownstream
            } else { throw 'ICS changed downstream to an unexpected configuration; automatic restoration stopped.' }
        }
        $restored = Get-DownstreamSnapshot $pair.Downstream
        if ($restored.Dhcp -ne 'Enabled' -or $restored.StaticDns -ne '' -or @($restored.Addresses | Where-Object { $_.Origin -eq 'Manual' }).Count -ne 0 -or @($restored.ManualRoutes).Count -ne 0) { throw 'Downstream DHCP baseline could not be confirmed.' }
        $state.Phase = 'STOPPED'; $state.LastError = ''; Write-GatewayState $state
        $archive = 'last-stopped-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfff') + '-' + [Guid]::NewGuid().ToString('N') + '.json'
        Move-Item -LiteralPath (Join-Path (Get-StateRoot) 'state.json') -Destination (Join-Path (Get-StateRoot) $archive)
        [pscustomobject]@{ State = 'STOPPED'; Detail = 'Owned ICS roles removed; downstream DHCP and automatic DNS confirmed. Windows firewall and service policies remain OS-managed.'; DownstreamVerified = $false }
    } catch {
        $state.FailedPhase = $state.Phase; $state.Phase = 'ATTENTION'; $state.LastError = $_.Exception.Message; Write-GatewayState $state
        throw ('Recovery incomplete; state retained: ' + $state.LastError)
    }
}
function Get-GatewayStatus {
    $state = Read-GatewayState
    $rows = @(Get-IcsSnapshot)
    if ($null -eq $state) { return [pscustomobject]@{ State = 'UNMANAGED'; Sharing = @($rows | Where-Object { $_.Enabled }); DownstreamVerified = $false; Detail = 'No owned state. Existing sharing, if any, belongs to another owner.' } }
    $pair = Resolve-AdapterPair $state.Config @(Get-AdapterInventory)
    $current = Get-DownstreamSnapshot $pair.Downstream
    $status = $state.Phase
    try {
        Assert-OwnedSharing $state $rows
        if ($status -eq 'ACTIVE' -and (@($rows | Where-Object { $_.Enabled }).Count -ne 2 -or (Get-SnapshotSignature $current) -cne (Get-SnapshotSignature $state.ExpectedDownstream))) { $status = 'ATTENTION' }
    } catch { $status = 'ATTENTION' }
    [pscustomobject]@{ State = $status; Config = $state.Config; DownstreamIPv4 = @($current.Addresses); FailedPhase = $state.FailedPhase; LastOperation = $state.LastOperation; LastError = $state.LastError; DownstreamVerified = $false; Detail = 'ICS role/configuration observation only. Router WAN must use DHCP. This does not verify downstream internet, reboot persistence or closed-lid operation.' }
}
Export-ModuleMember -Function *
