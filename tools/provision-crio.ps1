# Provisions an NI cRIO over the USB device port.
#
# Checks the host NI packages and installs any that are missing after a
# prompt. Opens SSH to 172.22.11.2, asks which feed version to install,
# and installs that driver set on the controller. Extra packages can be
# added from the same feed. CompactRIO Support, NI-RIO, and NI-RIO Server
# are always included. NI-RIO IO Scan is not installed: on this generation
# it blocks bitfile download.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\provision-crio.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\provision-crio.ps1 -SelfTest
#
# Requires Windows OpenSSH (OpenSSH 8.4 or newer). If NI Package Manager is
# missing, the tool asks to install the 2026 Q4 online installer from ni.com.
# The cRIO USB device port is the type-B port. The host adapter should be
# 172.22.11.1 and the controller 172.22.11.2. This chassis has no SAFE MODE
# DIP switch.

#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$TargetIp = "172.22.11.2",
    [string]$User = "admin",
    [string]$FeedVersion,
    [string]$LabviewYear,
    [string[]]$Package,
    [int]$FeedPort = 9100,
    [switch]$SelfTest,
    [switch]$AssumeYes,
    [switch]$InstallMissing,
    [switch]$Reboot
)

$ErrorActionPreference = "Stop"

$script:Nipkg = "C:\Program Files\National Instruments\NI Package Manager\nipkg.exe"
$script:PackageManagerUrl = "https://download.ni.com/support/nipkg/products/ni-package-manager/installers/NIPackageManager26.8.0_online.exe"
$script:PackageManagerPage = "https://www.ni.com/en/support/downloads/software-products/download.package-manager.html"
$script:FeedRoot = "C:\Program Files\National Instruments\RT Feeds"
$script:Ssh = Join-Path $env:SystemRoot "System32\OpenSSH\ssh.exe"
$script:AskPass = Join-Path $PSScriptRoot ".crio-askpass.cmd"
$script:KnownHosts = Join-Path $PSScriptRoot ".crio-known-hosts"
$script:TargetPassword = $null
$script:FeedJob = $null
$script:FeedListenPort = 0

$script:HostPackages = @(
    @{ Name = "ni-usblan"; Title = "NI-USBLAN" }
    @{ Name = "ni-compactrio"; Title = "NI CompactRIO" }
    @{ Name = "ni-rio-fpga-driver"; Title = "NI-RIO" }
    @{ Name = "ni-controllerdriver"; Title = "NI Controller Driver" }
)

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host $Message
}

function Read-Yes {
    param(
        [string]$Prompt,
        [switch]$DefaultYes
    )
    $hint = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
    $answer = Read-Host "$Prompt $hint"
    if ([string]::IsNullOrWhiteSpace($answer)) {
        return [bool]$DefaultYes
    }
    return $answer -match '^[Yy]'
}

function Get-NiPackage {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not (Test-Path -LiteralPath $script:Nipkg)) {
        return $null
    }
    $lines = @(& $script:Nipkg list-installed $Name 2>&1 | ForEach-Object { "$_" })
    foreach ($line in $lines) {
        $parts = $line -split "`t", 4
        if ($parts.Count -ge 2 -and $parts[0] -eq $Name) {
            return [pscustomobject]@{
                Name    = $parts[0]
                Version = $parts[1]
                Arch    = $(if ($parts.Count -ge 3) { $parts[2] } else { "" })
            }
        }
    }
    return $null
}

function Get-HostDriverReport {
    $rows = @()
    foreach ($item in $script:HostPackages) {
        $found = Get-NiPackage -Name $item.Name
        $rows += [pscustomobject]@{
            Name      = $item.Name
            Title     = $item.Title
            Installed = [bool]$found
            Version   = $(if ($found) { $found.Version } else { "" })
        }
    }
    return $rows
}

function Install-PackageManager {
    Write-Step "Some NI software is required to provision the cRIO."
    Write-Host "NI Package Manager is not installed. The other NI software is installed with it."
    $doInstall = $InstallMissing -or (Read-Yes -Prompt "Is it OK to install NI Package Manager?" -DefaultYes)
    if (-not $doInstall) {
        throw "Stopped. Install NI Package Manager from $($script:PackageManagerPage), then run this tool again."
    }
    $dest = Join-Path $env:TEMP "NIPackageManager26.8.0_online.exe"
    $previousProgress = $null
    Write-Host "Downloading NI Package Manager 2026 Q4 from ni.com."
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $previousProgress = $ProgressPreference
        $ProgressPreference = "SilentlyContinue"
        Invoke-WebRequest -Uri $script:PackageManagerUrl -OutFile $dest -UseBasicParsing
    }
    catch {
        throw "The NI Package Manager download failed. Install it from $($script:PackageManagerPage), then run this tool again."
    }
    finally {
        if ($null -ne $previousProgress) {
            $ProgressPreference = $previousProgress
        }
    }
    Write-Host "Windows will ask for administrator approval. The installer also downloads files from ni.com."
    try {
        $proc = Start-Process -FilePath $dest -ArgumentList @("--quiet", "--accept-eulas", "--prevent-reboot") -Verb RunAs -Wait -PassThru
    }
    catch {
        throw "Windows did not approve the NI Package Manager install."
    }
    finally {
        Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
    }
    $code = if ($proc) { $proc.ExitCode } else { $null }
    $rebootRequired = ($code -eq -125071 -or $code -eq 3010)
    if ($code -ne 0 -and -not $rebootRequired) {
        $shown = if ($null -eq $code) { "cancelled" } else { $code }
        throw "NI Package Manager exited with code $shown. Install it from $($script:PackageManagerPage), then run this tool again."
    }
    if (-not (Test-Path -LiteralPath $script:Nipkg)) {
        throw "NI Package Manager is still not installed. Restart Windows if the installer asked for one, then run this tool again."
    }
    if ($rebootRequired) {
        throw "NI Package Manager is installed. Restart Windows, then run this tool again."
    }
    Write-Host "NI Package Manager is installed."
}

function Install-HostDrivers {
    param([Parameter(Mandatory = $true)]$Missing)
    Write-Step "Some NI software is required to provision the cRIO."
    foreach ($row in $Missing) {
        Write-Host ("  {0}  ({1}) is not installed." -f $row.Title, $row.Name)
    }
    $doInstall = $InstallMissing -or (Read-Yes -Prompt "Is it OK to install the missing NI software?" -DefaultYes)
    if (-not $doInstall) {
        throw "Stopped. Install the missing NI packages, then run this tool again."
    }
    $names = @($Missing | ForEach-Object { $_.Name })
    Write-Host "NI Package Manager will ask for administrator approval."
    $argList = @("install", "--accept-eulas", "--yes") + $names
    try {
        $proc = Start-Process -FilePath $script:Nipkg -ArgumentList $argList -Verb RunAs -Wait -PassThru
    }
    catch {
        throw "Windows did not approve the NI Package Manager install. The missing packages are still required."
    }
    if (-not $proc -or $null -eq $proc.ExitCode -or $proc.ExitCode -ne 0) {
        $code = if ($proc) { $proc.ExitCode } else { "cancelled" }
        throw "NI Package Manager exited with code $code. The missing packages are still required."
    }
    $again = @(Get-HostDriverReport | Where-Object { -not $_.Installed })
    if ($again.Count -gt 0) {
        $still = ($again | ForEach-Object { $_.Title }) -join ", "
        throw "These packages are still missing after install: $still. A Windows restart may be required, then run this tool again."
    }
    Write-Host "The required NI packages are installed."
}

function Install-OpenSshClient {
    Write-Step "The Windows OpenSSH Client is not installed. SSH to the controller needs it."
    $doInstall = $InstallMissing -or (Read-Yes -Prompt "Install the OpenSSH Client on this PC?" -DefaultYes)
    if (-not $doInstall) {
        throw "Stopped. Install the OpenSSH Client, then run this tool again."
    }
    Write-Host "Windows will ask for administrator approval."
    $ssh = $script:Ssh.Replace("'", "''")
    $command = "Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0; if (-not (Test-Path -LiteralPath '$ssh')) { exit 1 }"
    try {
        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-Command", $command) -Verb RunAs -Wait -PassThru
    }
    catch {
        throw "Windows did not approve the OpenSSH Client install."
    }
    if (-not (Test-Path -LiteralPath $script:Ssh) -or -not $proc -or $proc.ExitCode -ne 0) {
        throw "The OpenSSH Client is still not installed. Restart Windows if the optional feature was added, then run this tool again."
    }
    Write-Host "The OpenSSH Client is installed."
}

function Get-UsbAdapter {
    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
            $_.InterfaceDescription -match 'USBLAN|USB LAN' -or
            $_.Name -match 'USBLAN' -or
            $_.DriverDescription -match 'USBLAN|USB LAN'
        })
    return $adapters
}

function Get-AdapterIpv4 {
    param([string]$Alias)
    $addr = Get-NetIPAddress -InterfaceAlias $Alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike "169.254.*" } |
        Select-Object -First 1
    if ($addr) { return $addr.IPAddress }
    return $null
}

function Test-TargetPing {
    param([string]$Ip)
    & ping.exe -n 1 -w 1000 $Ip | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Get-FeedCatalog {
    if (-not (Test-Path -LiteralPath $script:FeedRoot)) {
        return @()
    }
    $items = @()
    foreach ($dir in @(Get-ChildItem -LiteralPath $script:FeedRoot -Directory)) {
        $display = ""
        $packages = Join-Path $dir.FullName "ni\Packages"
        if (Test-Path -LiteralPath $packages) {
            $match = Select-String -LiteralPath $packages -Pattern '^DisplayName: CompactRIO Support$' -Context 1, 0 | Select-Object -First 1
            if ($match -and $match.Context.PreContext[0] -match '^DisplayVersion: (.+)$') {
                $display = $Matches[1].Trim()
            }
        }
        $years = @()
        foreach ($sub in @(Get-ChildItem -LiteralPath $dir.FullName -Directory -ErrorAction SilentlyContinue)) {
            if ($sub.Name -match '^ni-labview-(\d{4})$' -and (Test-Path -LiteralPath (Join-Path $sub.FullName "Packages"))) {
                $years += $Matches[1]
            }
        }
        $items += [pscustomobject]@{
            Version        = $dir.Name
            DisplayVersion = $display
            Path           = $dir.FullName
            LabviewYears   = @($years | Sort-Object -Unique)
        }
    }
    return @($items | Sort-Object Version)
}

function Get-FeedPackageSuffix {
    param([string]$Version)
    $parts = $Version -split '\.'
    if ($parts.Count -ge 2) {
        return ($parts[0] + "." + $parts[1])
    }
    return $Version
}

function Test-FeedFiles {
    param(
        $CatalogItem,
        [string]$CpuFamily,
        [string]$Year
    )
    $missing = @()
    $cpuRoot = Join-Path $CatalogItem.Path $CpuFamily
    if (-not (Test-Path -LiteralPath $cpuRoot)) {
        $missing += $cpuRoot
    }
    $ni = Join-Path $CatalogItem.Path "ni\Packages"
    if (-not (Test-Path -LiteralPath $ni)) {
        $missing += $ni
    }
    if ($Year -and $Year -ne "none") {
        $lv = Join-Path $CatalogItem.Path ("ni-labview-{0}\Packages" -f $Year)
        if (-not (Test-Path -LiteralPath $lv)) {
            $missing += $lv
        }
    }
    return $missing
}

function Install-FeedPackages {
    param(
        [string]$Version,
        [string]$Year
    )
    $suffix = Get-FeedPackageSuffix -Version $Version
    $wanted = @(
        "ni-linux-rt-offline-main-feed-$suffix"
        "ni-linux-rt-offline-ni-feed-$suffix"
    )
    if ($Year -and $Year -ne "none") {
        $wanted += "ni-linux-rt-offline-labview-$Year-feed-$suffix"
    }
    $missing = @()
    foreach ($name in $wanted) {
        if (-not (Get-NiPackage -Name $name)) {
            $missing += $name
        }
    }
    if ($missing.Count -eq 0) {
        return
    }
    Write-Step "Some NI software is required to provision the cRIO."
    Write-Host "The selected version is not fully present in the local RT feeds."
    foreach ($name in $missing) {
        Write-Host "  $name is not installed."
    }
    $doInstall = $InstallMissing -or (Read-Yes -Prompt "Is it OK to install the missing feed software?" -DefaultYes)
    if (-not $doInstall) {
        throw "Stopped. The controller install needs those feed packages on this PC."
    }
    Write-Host "NI Package Manager will ask for administrator approval. Feed installs are large."
    $argList = @("install", "--accept-eulas", "--yes") + $missing
    try {
        $proc = Start-Process -FilePath $script:Nipkg -ArgumentList $argList -Verb RunAs -Wait -PassThru
    }
    catch {
        throw "Windows did not approve the feed install. The controller install needs those feeds on this PC."
    }
    if (-not $proc -or $null -eq $proc.ExitCode -or $proc.ExitCode -ne 0) {
        $code = if ($proc) { $proc.ExitCode } else { "cancelled" }
        throw "NI Package Manager exited with code $code."
    }
}

function Get-ArchRank {
    param(
        [string]$ArchText,
        [string]$CpuFamily
    )
    $rank = @{}
    foreach ($line in ($ArchText -split "`r?`n")) {
        if ($line -match '^\s*arch\s+(\S+)\s+(\d+)\s*$') {
            $rank[$Matches[1]] = [int]$Matches[2]
        }
    }
    if ($rank.Count -gt 0) {
        return $rank
    }
    $rank["all"] = 1
    if ($CpuFamily -eq "x64") {
        $rank["core2-64"] = 20
        $rank["x64"] = 15
        $rank["x64-cRIO"] = 30
        $rank["x64-cRIO-Smasher"] = 40
    }
    else {
        $rank["cortexa9-vfpv3"] = 20
        $rank["ARM-cRIO"] = 30
    }
    return $rank
}

function Import-OpkgPackageFile {
    param(
        [string]$Path,
        $ArchRank,
        $Into
    )
    $reader = New-Object System.IO.StreamReader $Path
    try {
        $name = $null
        $arch = $null
        $version = $null
        $display = $null
        $visible = $null
        $flush = {
            if ($name -and -not [string]::IsNullOrWhiteSpace($arch) -and $ArchRank.ContainsKey($arch)) {
                $score = [int]$ArchRank[$arch]
                if (-not ($Into.ContainsKey($name) -and $Into[$name].Rank -ge $score)) {
                    $Into[$name] = [pscustomobject]@{
                        Name         = $name
                        Architecture = $arch
                        Version      = $version
                        DisplayName  = $display
                        UserVisible  = $visible
                        Rank         = $score
                    }
                }
            }
        }
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($line.Length -eq 0) {
                . $flush
                $name = $null
                $arch = $null
                $version = $null
                $display = $null
                $visible = $null
                continue
            }
            if ($line.StartsWith("Package: ")) { $name = $line.Substring(9).Trim() }
            elseif ($line.StartsWith("Architecture: ")) { $arch = $line.Substring(14).Trim() }
            elseif ($line.StartsWith("Version: ")) { $version = $line.Substring(9).Trim() }
            elseif ($line.StartsWith("DisplayName: ")) { $display = $line.Substring(13).Trim() }
            elseif ($line.StartsWith("UserVisible: ")) { $visible = $line.Substring(13).Trim() }
        }
        . $flush
    }
    finally {
        $reader.Dispose()
    }
}

function Get-FeedPackageIndex {
    param(
        $CatalogItem,
        [string]$CpuFamily,
        [string]$Year,
        $ArchRank
    )
    $index = @{}
    $files = @()
    $ni = Join-Path $CatalogItem.Path "ni\Packages"
    if (Test-Path -LiteralPath $ni) { $files += $ni }
    $cpuRoot = Join-Path $CatalogItem.Path $CpuFamily
    if (Test-Path -LiteralPath $cpuRoot) {
        foreach ($sub in @(Get-ChildItem -LiteralPath $cpuRoot -Directory)) {
            $packages = Join-Path $sub.FullName "Packages"
            if (Test-Path -LiteralPath $packages) { $files += $packages }
        }
    }
    if ($Year -and $Year -ne "none") {
        $lv = Join-Path $CatalogItem.Path ("ni-labview-{0}\Packages" -f $Year)
        if (Test-Path -LiteralPath $lv) { $files += $lv }
    }
    foreach ($file in $files) {
        Import-OpkgPackageFile -Path $file -ArchRank $ArchRank -Into $index
    }
    return $index
}

function Resolve-RequestedPackages {
    param(
        $Index,
        [string[]]$Requested
    )
    $accepted = @()
    $rejected = @()
    foreach ($token in @($Requested)) {
        if ([string]::IsNullOrWhiteSpace($token)) { continue }
        $name = $token.Trim()
        if ($name -match '(?i)ioscan') {
            $rejected += "$name is NI-RIO IO Scan. It is not installed because it blocks bitfile download on this controller."
            continue
        }
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9.+-]*$') {
            $rejected += "$name is not a package name."
            continue
        }
        if (-not $Index.ContainsKey($name)) {
            $rejected += "$name is not in this feed for this controller."
            continue
        }
        if ($accepted -notcontains $name) {
            $accepted += $name
        }
    }
    return [pscustomobject]@{
        Accepted = @($accepted)
        Rejected = @($rejected)
    }
}

function Write-PackageHits {
    param($Hits)
    foreach ($item in @($Hits)) {
        $label = if ($item.DisplayName) { $item.DisplayName } else { $item.Version }
        Write-Host ("  {0,-36} {1}" -f $item.Name, $label)
    }
}

function Read-ExtraPackages {
    param($Index)
    $chosen = @()
    Write-Step "Additional packages"
    Write-Host "CompactRIO Support, NI-RIO, and NI-RIO Server are always installed."
    Write-Host "Type a package name to add it. Commands: list, search <text>, done."
    while ($true) {
        $answer = Read-Host "Package"
        if ([string]::IsNullOrWhiteSpace($answer) -or $answer -eq "done") {
            break
        }
        if ($answer -eq "list") {
            $visible = @($Index.Values | Where-Object { $_.UserVisible -eq "yes" } | Sort-Object DisplayName, Name)
            if ($visible.Count -eq 0) {
                Write-Host "  No user-visible packages were found. Use search to look up a name."
            }
            elseif ($visible.Count -gt 80) {
                Write-Host "  Showing 80 of $($visible.Count) user-visible packages. Use search to narrow the list."
                Write-PackageHits -Hits ($visible | Select-Object -First 80)
            }
            else {
                Write-PackageHits -Hits $visible
            }
            continue
        }
        if ($answer -like "search *") {
            $query = $answer.Substring(7).Trim()
            if (-not $query) {
                Write-Host "  Type search followed by text, for example: search visa"
                continue
            }
            $hits = @($Index.Values | Where-Object {
                    ($_.Name -and $_.Name.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                    ($_.DisplayName -and $_.DisplayName.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0)
                } | Sort-Object Name | Select-Object -First 40)
            if ($hits.Count -eq 0) {
                Write-Host "  No packages match '$query'."
            }
            else {
                Write-PackageHits -Hits $hits
            }
            continue
        }
        $result = Resolve-RequestedPackages -Index $Index -Requested ($answer -split '[,\s]+')
        foreach ($message in $result.Rejected) {
            Write-Host "  $message"
        }
        foreach ($name in $result.Accepted) {
            if ($chosen -notcontains $name) {
                $chosen += $name
                $item = $Index[$name]
                $label = if ($item.DisplayName) { $item.DisplayName } else { $name }
                Write-Host "  Added $name ($label)."
            }
        }
    }
    return @($chosen)
}

function Read-Menu {
    param(
        [string]$Title,
        [array]$Labels
    )
    Write-Step $Title
    for ($i = 0; $i -lt $Labels.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $Labels[$i])
    }
    while ($true) {
        $answer = Read-Host "Enter a number"
        $n = 0
        if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $Labels.Count) {
            return ($n - 1)
        }
        Write-Host "Enter a number from the list."
    }
}

function Initialize-LinePump {
    if ("CrioLinePump" -as [type]) { return }
    Add-Type -TypeDefinition @"
using System.Collections.Concurrent;
using System.IO;
using System.Threading;
public class CrioLinePump {
  public readonly ConcurrentQueue<string> Lines = new ConcurrentQueue<string>();
  public void Start(StreamReader reader) {
    var thread = new Thread(() => {
      try {
        string line;
        while ((line = reader.ReadLine()) != null) Lines.Enqueue(line);
      } catch { }
    });
    thread.IsBackground = true;
    thread.Start();
  }
  public string Take() {
    string line;
    return Lines.TryDequeue(out line) ? line : null;
  }
}
"@
}

function Initialize-AskPass {
    $dir = Split-Path -Parent $script:AskPass
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }
    $cmd = @"
@echo off
powershell.exe -NoProfile -NonInteractive -Command "[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding `$false; [Console]::Out.WriteLine([string]`$env:CRIO_SSH_PASSWORD)"
"@
    Set-Content -LiteralPath $script:AskPass -Value $cmd -Encoding ASCII
}

function Invoke-CrioSsh {
    param(
        [Parameter(Mandatory = $true)][string]$RemoteCommand,
        [string]$StdinText = "",
        [switch]$Live
    )
    if (-not (Test-Path -LiteralPath $script:Ssh)) {
        throw "Windows OpenSSH client was not found at $($script:Ssh)."
    }
    Initialize-AskPass
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:Ssh
    $dest = "{0}@{1}" -f $User, $TargetIp
    $psi.Arguments = "-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=""$($script:KnownHosts)"" -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=240 -o PreferredAuthentications=keyboard-interactive,password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 -o UpdateHostKeys=no $dest `"$RemoteCommand`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
    $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding $false
    $psi.EnvironmentVariables["SSH_ASKPASS"] = $script:AskPass
    $psi.EnvironmentVariables["SSH_ASKPASS_REQUIRE"] = "force"
    $psi.EnvironmentVariables["DISPLAY"] = "localhost:0"
    if ($null -eq $script:TargetPassword) {
        $psi.EnvironmentVariables["CRIO_SSH_PASSWORD"] = ""
    }
    else {
        $psi.EnvironmentVariables["CRIO_SSH_PASSWORD"] = $script:TargetPassword
    }

    Initialize-LinePump
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $outLines = New-Object System.Collections.Generic.List[string]
    $errLines = New-Object System.Collections.Generic.List[string]
    try {
        if (-not $proc.Start()) {
            throw "Could not start ssh."
        }
        $outPump = New-Object CrioLinePump
        $errPump = New-Object CrioLinePump
        $outPump.Start($proc.StandardOutput)
        $errPump.Start($proc.StandardError)
        if ($StdinText.Length -gt 0) {
            $proc.StandardInput.Write($StdinText)
        }
        $proc.StandardInput.Close()
        $drain = {
            while ($null -ne ($line = $outPump.Take())) {
                $outLines.Add($line)
                if ($Live) { Write-Host $line }
            }
            while ($null -ne ($line = $errPump.Take())) {
                $errLines.Add($line)
                if ($Live) { Write-Host $line }
            }
        }
        while (-not $proc.HasExited) {
            . $drain
            Start-Sleep -Milliseconds 100
        }
        $proc.WaitForExit()
        Start-Sleep -Milliseconds 200
        . $drain
        return [pscustomobject]@{
            ExitCode = $proc.ExitCode
            Stdout   = ($outLines -join "`n")
            Stderr   = ($errLines -join "`n")
        }
    }
    finally {
        try {
            if (-not $proc.HasExited) { $proc.Kill() }
        }
        catch { }
        try { $proc.Dispose() } catch { }
    }
}

function Read-TargetPassword {
    # An empty value is the default blank admin password. Only prompt when the
    # variable is unset, so an agent can run without a console.
    $set = [Environment]::GetEnvironmentVariable("CRIO_SSH_PASSWORD", "Process")
    if ($null -ne $set) {
        $script:TargetPassword = $set
        return
    }
    $secure = Read-Host "SSH password for $User@$TargetIp (press Enter if it is blank)" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $script:TargetPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Get-CrioIdentity {
    $remote = "echo '===UNAME==='; uname -srm; echo '===HOST==='; hostname; echo '===OS==='; cat /etc/os-release 2>/dev/null || true; echo '===ARCH==='; cat /etc/opkg/arch.conf 2>/dev/null || true; echo '===PKGS==='; opkg list-installed 2>/dev/null | grep -e '^ni-crio -' -e '^ni-rio -' -e '^ni-rio-server -' -e '^ni-labview-realtime -' -e 'ioscan -' || true; echo '===END==='"
    $result = Invoke-CrioSsh -RemoteCommand $remote
    if ($result.ExitCode -ne 0 -or $result.Stdout -notmatch '===END===') {
        $detail = ($result.Stderr + $result.Stdout).Trim()
        if ($detail -match 'Permission denied') {
            throw "SSH reached $TargetIp but rejected the password for $User."
        }
        if ($detail -match 'Connection refused|Connection timed out|No route to host') {
            throw "SSH to ${User}@${TargetIp} failed. Enable Secure Shell Server (sshd) on the controller. In NI MAX that setting is under Startup Settings. The default user is admin and the default password is blank."
        }
        throw "SSH to ${User}@${TargetIp} failed. $detail"
    }
    return $result.Stdout
}

function Get-IdentityField {
    param([string]$Text, [string]$Name)
    $pattern = "(?s)===$Name===\r?\n(.*?)(?:\r?\n===|\z)"
    $m = [regex]::Match($Text, $pattern)
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return ""
}

function Get-CpuFamily {
    param([string]$UnameText)
    if ($UnameText -match 'x86_64') { return "x64" }
    if ($UnameText -match 'aarch64|armv7|arm') { return "arm" }
    return ""
}

function Get-SudoMode {
    $remote = "if test -w /etc/opkg; then echo WRITABLE; elif sudo -n true >/dev/null 2>&1; then echo NOPASSWD; else echo NEEDPASS; fi"
    $result = Invoke-CrioSsh -RemoteCommand $remote
    $mode = ($result.Stdout | Select-String -Pattern 'WRITABLE|NOPASSWD|NEEDPASS' | Select-Object -Last 1)
    if (-not $mode) {
        throw "Could not tell whether $User can write /etc/opkg. SSH said: $($result.Stderr)"
    }
    return $mode.Matches[0].Value
}

function Get-FeedSources {
    param(
        $CatalogItem,
        [string]$CpuFamily,
        [string]$Year,
        [string]$HostIp,
        [int]$Port
    )
    $sources = @()
    $roots = @()
    $ni = Join-Path $CatalogItem.Path "ni"
    if (Test-Path -LiteralPath (Join-Path $ni "Packages")) {
        $roots += $ni
    }
    $cpuRoot = Join-Path $CatalogItem.Path $CpuFamily
    if (Test-Path -LiteralPath $cpuRoot) {
        foreach ($sub in @(Get-ChildItem -LiteralPath $cpuRoot -Directory)) {
            if (Test-Path -LiteralPath (Join-Path $sub.FullName "Packages")) {
                $roots += $sub.FullName
            }
        }
    }
    if ($Year -and $Year -ne "none") {
        $lv = Join-Path $CatalogItem.Path ("ni-labview-{0}" -f $Year)
        if (Test-Path -LiteralPath (Join-Path $lv "Packages")) {
            $roots += $lv
        }
    }
    foreach ($path in $roots) {
        $rel = $path.Substring($CatalogItem.Path.Length).TrimStart('\', '/')
        $relUrl = ($rel -replace '\\', '/')
        $name = "provision-" + ($relUrl -replace '[^A-Za-z0-9]+', '-').Trim('-')
        $url = "http://{0}:{1}/{2}/{3}" -f $HostIp, $Port, $CatalogItem.Version, $relUrl
        $sources += [pscustomobject]@{ Name = $name; Url = $url; Line = ("src/gz {0} {1}" -f $name, $url) }
    }
    return $sources
}

function New-TargetScript {
    param(
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][string]$FeedLines,
        [Parameter(Mandatory = $true)][string]$Packages,
        [string]$IoscanAlready = "0"
    )
    $body = @'
#!/bin/sh
bak=/var/lib/provision-crio-opkg-bak
restore() {
  if [ -d "$bak" ]; then
    for f in "$bak"/*; do
      [ -f "$f" ] || continue
      cp -a "$f" /etc/opkg/
    done
    rm -rf "$bak"
  fi
  rm -f /etc/opkg/provision-crio.conf
}
trap restore EXIT
restore
if [ "__MODE__" = "repair" ]; then
  echo PROVISION_STATUS:repaired
  exit 0
fi
mkdir -p "$bak"
for f in /etc/opkg/*.conf; do
  [ -f "$f" ] || continue
  base=$(basename "$f")
  case "$base" in
    provision-crio.conf) continue ;;
  esac
  if grep -q '^src' "$f"; then
    cp -a "$f" "$bak/"
    grep -v '^src' "$f" > "$f.filtered"
    mv "$f.filtered" "$f"
  fi
done
cat > /etc/opkg/provision-crio.conf << 'EOF'
__FEEDS__
EOF
opkg update
upd=$?
if [ "$upd" -ne 0 ]; then
  echo PROVISION_STATUS:update_failed
  exit 1
fi
if [ "__MODE__" = "plan" ]; then
  if opkg --help 2>&1 | grep -q noaction; then
    opkg --noaction install __PACKAGES__
    plan=$?
    if [ "$plan" -ne 0 ]; then
      echo PROVISION_STATUS:plan_failed
      exit 1
    fi
  else
    echo "This opkg has no --noaction. Dependencies will be resolved during install."
  fi
  echo PROVISION_STATUS:planned
  exit 0
fi
opkg install __PACKAGES__
ins=$?
if [ "$ins" -ne 0 ]; then
  echo "PROVISION_STATUS:$ins"
  exit "$ins"
fi
if [ "__IOSCAN__" = "0" ]; then
  : > /tmp/provision-ioscan.txt
  opkg list-installed | while read line; do
    name=${line%% - *}
    case "$name" in
      *ioscan*) echo "$name" ;;
    esac
  done > /tmp/provision-ioscan.txt
  if [ -s /tmp/provision-ioscan.txt ]; then
    while read name; do
      echo "Removing $name. NI-RIO IO Scan blocks bitfile download on this controller."
      opkg remove "$name" || echo "Could not remove $name"
    done < /tmp/provision-ioscan.txt
  fi
  : > /tmp/provision-ioscan.txt
  opkg list-installed | while read line; do
    name=${line%% - *}
    case "$name" in
      *ioscan*) echo "$name" ;;
    esac
  done > /tmp/provision-ioscan.txt
  if [ -s /tmp/provision-ioscan.txt ]; then
    rm -f /tmp/provision-ioscan.txt
    echo PROVISION_STATUS:ioscan_present
    exit 2
  fi
  rm -f /tmp/provision-ioscan.txt
fi
echo PROVISION_STATUS:0
exit 0
'@
    $body = $body.Replace("__MODE__", $Mode)
    $body = $body.Replace("__FEEDS__", $FeedLines.TrimEnd())
    $body = $body.Replace("__PACKAGES__", $Packages)
    $body = $body.Replace("__IOSCAN__", $IoscanAlready)
    return ($body -replace "`r", "")
}

function Invoke-RemoteRoot {
    param(
        [string]$ScriptText,
        [string]$SudoMode,
        [switch]$Live
    )
    $payload = $ScriptText -replace "`r", ""
    if (-not $payload.EndsWith("`n")) {
        $payload += "`n"
    }
    if ($SudoMode -eq "NEEDPASS") {
        $stdin = $script:TargetPassword + "`n" + $payload
        $command = "sudo -S -p '' sh -s"
    }
    elseif ($SudoMode -eq "NOPASSWD") {
        $stdin = $payload
        $command = "sudo -n sh -s"
    }
    else {
        $stdin = $payload
        $command = "sh -s"
    }
    return Invoke-CrioSsh -RemoteCommand $command -StdinText $stdin -Live:$Live
}

function Start-FeedServer {
    param(
        [string]$Root,
        [string]$Address,
        [int]$Port,
        [string]$LogPath
    )
    $scriptBlock = {
        param($Root, $Address, $Port, $LogPath)
        $ErrorActionPreference = "Continue"
        try {
            $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Parse($Address), $Port)
            $listener.Start()
            $actual = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
            Write-Output "LISTENING $actual"
        }
        catch {
            Write-Output ("BIND_FAIL " + $_.Exception.Message)
            return
        }
        $rootFull = [System.IO.Path]::GetFullPath($Root)
        if (-not $rootFull.EndsWith("\")) { $rootFull = $rootFull + "\" }
        while ($true) {
            if (-not $listener.Pending()) {
                Start-Sleep -Milliseconds 200
                continue
            }
            $client = $null
            try {
                $client = $listener.AcceptTcpClient()
                $client.ReceiveTimeout = 30000
                $client.SendTimeout = 120000
                $stream = $client.GetStream()
                $accum = New-Object System.Collections.Generic.List[byte]
                $tmp = New-Object byte[] 1024
                $header = ""
                while ($accum.Count -lt 16384) {
                    $n = $stream.Read($tmp, 0, $tmp.Length)
                    if ($n -le 0) { break }
                    for ($i = 0; $i -lt $n; $i++) { $accum.Add($tmp[$i]) }
                    $header = [System.Text.Encoding]::ASCII.GetString($accum.ToArray())
                    if ($header.Contains("`r`n`r`n")) { break }
                }
                $requestLine = ($header -split "`r`n", 2)[0]
                $bits = $requestLine -split " "
                $method = $(if ($bits.Length -ge 1) { $bits[0] } else { "" })
                $rawPath = $(if ($bits.Length -ge 2) { $bits[1] } else { "/" })
                $rawPath = ($rawPath -split "\?", 2)[0]
                $status = 200
                $file = $null
                if ($method -ne "GET" -and $method -ne "HEAD") {
                    $status = 405
                }
                elseif ($rawPath -eq "/" -or $rawPath -eq "") {
                    $file = $null
                    $status = 200
                }
                elseif ($rawPath.Contains("..") -or $rawPath.Contains("\") -or $rawPath.Contains(":")) {
                    $status = 400
                }
                else {
                    $rel = [Uri]::UnescapeDataString($rawPath.TrimStart("/"))
                    $rel = $rel -replace "/", "\"
                    $full = [System.IO.Path]::GetFullPath((Join-Path $rootFull $rel))
                    if (-not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $status = 400
                    }
                    elseif (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
                        $status = 404
                    }
                    else {
                        $file = $full
                    }
                }
                if ($status -eq 200 -and -not $file -and ($rawPath -eq "/" -or $rawPath -eq "")) {
                    $body = [System.Text.Encoding]::ASCII.GetBytes("cRIO feed`n")
                    $head = "HTTP/1.1 200 OK`r`nContent-Length: $($body.Length)`r`nContent-Type: text/plain`r`nConnection: close`r`n`r`n"
                    $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
                    $stream.Write($hb, 0, $hb.Length)
                    if ($method -ne "HEAD") { $stream.Write($body, 0, $body.Length) }
                }
                elseif ($status -eq 200) {
                    $len = (Get-Item -LiteralPath $file).Length
                    $head = "HTTP/1.1 200 OK`r`nContent-Length: $len`r`nContent-Type: application/octet-stream`r`nConnection: close`r`n`r`n"
                    $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
                    $stream.Write($hb, 0, $hb.Length)
                    if ($method -ne "HEAD") {
                        $in = [System.IO.File]::Open($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
                        try { $in.CopyTo($stream) } finally { $in.Dispose() }
                    }
                }
                else {
                    $reason = switch ($status) { 400 { "Bad Request" } 404 { "Not Found" } 405 { "Method Not Allowed" } default { "Error" } }
                    $head = "HTTP/1.1 $status $reason`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
                    $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
                    $stream.Write($hb, 0, $hb.Length)
                }
                Add-Content -LiteralPath $LogPath -Value ("{0} {1} {2}" -f $status, $method, $rawPath)
            }
            catch {
                Add-Content -LiteralPath $LogPath -Value ("ERR " + $_.Exception.Message)
            }
            finally {
                if ($client) { $client.Close() }
            }
        }
    }
    if (Test-Path -LiteralPath $LogPath) {
        Remove-Item -LiteralPath $LogPath -Force
    }
    New-Item -ItemType File -Path $LogPath -Force | Out-Null
    $job = Start-Job -ScriptBlock $scriptBlock -ArgumentList $Root, $Address, $Port, $LogPath
    $deadline = (Get-Date).AddSeconds(20)
    $heard = ""
    do {
        Start-Sleep -Milliseconds 200
        $heard += (Receive-Job -Job $job | Out-String)
        if ($heard -match 'BIND_FAIL') {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            throw "The feed server could not listen on ${Address}:$Port. $heard"
        }
        if ($heard -match 'LISTENING\s+(\d+)') {
            $script:FeedJob = $job
            return [int]$Matches[1]
        }
    } while ((Get-Date) -lt $deadline -and $job.State -eq "Running")
    $more = Receive-Job -Job $job | Out-String
    Stop-Job -Job $job -ErrorAction SilentlyContinue
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    throw "The feed server did not start. $heard $more"
}

function Stop-FeedServer {
    if (-not $script:FeedJob) { return }
    $job = $script:FeedJob
    $script:FeedJob = $null
    Stop-Job -Job $job -ErrorAction SilentlyContinue
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
}

function Enable-FeedFirewall {
    param(
        [int]$Port,
        [string]$LocalAddress,
        [string]$RemoteAddress
    )
    $name = "cRIO USB feed $Port"
    $script = "Import-Module NetSecurity -ErrorAction Stop; Get-NetFirewallRule -DisplayName '$name' -ErrorAction SilentlyContinue | Remove-NetFirewallRule; New-NetFirewallRule -DisplayName '$name' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -LocalAddress $LocalAddress -RemoteAddress $RemoteAddress -Profile Any | Out-Null"
    try {
        Import-Module NetSecurity -ErrorAction Stop
        Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        New-NetFirewallRule -DisplayName $name -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -LocalAddress $LocalAddress -RemoteAddress $RemoteAddress -Profile Any | Out-Null
        return $true
    }
    catch {
        Write-Host "Windows needs administrator approval to allow the cRIO to read the feed."
        try {
            $proc = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-Command", $script) -Verb RunAs -Wait -PassThru
        }
        catch {
            return $false
        }
        if (-not $proc -or $null -eq $proc.ExitCode) { return $false }
        return ($proc.ExitCode -eq 0)
    }
}

function Disable-FeedFirewall {
    param([int]$Port)
    if ($Port -le 0) { return }
    $name = "cRIO USB feed $Port"
    $script = "Import-Module NetSecurity -ErrorAction SilentlyContinue; Get-NetFirewallRule -DisplayName '$name' -ErrorAction SilentlyContinue | Remove-NetFirewallRule"
    try {
        Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    }
    catch {
        try {
            Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-Command", $script) -Verb RunAs -Wait | Out-Null
        }
        catch { }
    }
}

function Receive-Http {
    param([string]$Url)
    $uri = [Uri]$Url
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.Connect($uri.Host, $uri.Port)
        $stream = $client.GetStream()
        $stream.ReadTimeout = 15000
        $req = "GET $($uri.PathAndQuery) HTTP/1.0`r`nHost: $($uri.Host)`r`nConnection: close`r`n`r`n"
        $bytes = [Text.Encoding]::ASCII.GetBytes($req)
        $stream.Write($bytes, 0, $bytes.Length)
        $ms = New-Object System.IO.MemoryStream
        $buf = New-Object byte[] 8192
        while ($true) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $ms.Write($buf, 0, $n)
            if ($ms.Length -gt 1MB) { break }
        }
        return $ms.ToArray()
    }
    finally {
        $client.Close()
    }
}

function Test-FeedReachable {
    param([string]$Url)
    $remote = "wget -q -T 5 -O /dev/null '$Url' && echo FEED_REACHABLE || echo FEED_BLOCKED"
    $result = Invoke-CrioSsh -RemoteCommand $remote
    return ($result.Stdout -match 'FEED_REACHABLE')
}

function Get-TargetPackages {
    param([string[]]$Names)
    $patterns = @("-e '^ni-crio -'", "-e '^ni-rio -'", "-e '^ni-rio-server -'", "-e '^ni-labview-realtime -'", "-e 'ioscan -'")
    foreach ($name in @($Names)) {
        if ($name -and $name -match '^[A-Za-z0-9][A-Za-z0-9.+-]*$') {
            $patterns += "-e '^$name -'"
        }
    }
    $patternText = ($patterns | Select-Object -Unique) -join " "
    $remote = "opkg list-installed | grep $patternText || true; echo '===DEV==='; ls -l /dev/ni 2>/dev/null || echo 'no /dev/ni'; echo '===MOD==='; lsmod | grep -e nikal -e nibds -e atomicchinch -e chinch || true; echo '===END==='"
    $result = Invoke-CrioSsh -RemoteCommand $remote
    return $result.Stdout
}

function Wait-TargetSsh {
    param([int]$Seconds = 180)
    $deadline = (Get-Date).AddSeconds($Seconds)
    Write-Host "Waiting for the controller to answer SSH again."
    while ((Get-Date) -lt $deadline) {
        if (Test-TargetPing -Ip $TargetIp) {
            $probe = Invoke-CrioSsh -RemoteCommand "echo SSH_OK"
            if ($probe.ExitCode -eq 0 -and $probe.Stdout -match 'SSH_OK') {
                return $true
            }
        }
        Start-Sleep -Seconds 5
    }
    return $false
}

function Invoke-SelfTest {
    $failed = $false
    Write-Step "Host packages"
    try {
        Initialize-LinePump
        Write-Host "OK    output reader compiled"
    }
    catch {
        Write-Host ("FAIL  output reader: {0}" -f $_.Exception.Message)
        $failed = $true
    }
    if (-not (Test-Path -LiteralPath $script:Nipkg)) {
        Write-Host "FAIL  NI Package Manager was not found."
        $failed = $true
    }
    else {
        $report = @(Get-HostDriverReport)
        foreach ($row in $report) {
            if ($row.Installed) {
                Write-Host ("OK    {0}  {1}" -f $row.Title, $row.Version)
            }
            else {
                Write-Host ("FAIL  {0} is not installed." -f $row.Title)
                $failed = $true
            }
        }
    }

    Write-Step "Feed catalog"
    $catalog = @(Get-FeedCatalog)
    $feed = $catalog | Where-Object { $_.Version -eq "26.8.0" } | Select-Object -First 1
    if (-not $feed) {
        Write-Host "FAIL  RT feed 26.8.0 was not found."
        $failed = $true
    }
    else {
        Write-Host ("OK    feed {0}  {1}" -f $feed.Version, $feed.DisplayVersion)
        $expectedYears = @("2023", "2024", "2025", "2026")
        foreach ($year in $expectedYears) {
            if ($feed.LabviewYears -contains $year) {
                Write-Host "OK    LabVIEW $year feed"
            }
            else {
                Write-Host "FAIL  LabVIEW $year feed is missing."
                $failed = $true
            }
        }
        $sources = @(Get-FeedSources -CatalogItem $feed -CpuFamily "x64" -Year "none" -HostIp "172.22.11.1" -Port 9100)
        $joined = ($sources | ForEach-Object { $_.Line }) -join "`n"
        if ($joined -notmatch 'src/gz provision-ni http://172.22.11.1:9100/26.8.0/ni') {
            Write-Host "FAIL  the ni feed URL was not built."
            $failed = $true
        }
        elseif ($joined -notmatch 'main-core2-64') {
            Write-Host "FAIL  the core2-64 feed URL was not built."
            $failed = $true
        }
        elseif ($joined -match 'ni-labview-') {
            Write-Host "FAIL  a LabVIEW feed was included for a drivers-only selection."
            $failed = $true
        }
        else {
            Write-Host ("OK    {0} feed URLs for a drivers-only x64 install." -f $sources.Count)
        }
        $withLv = @(Get-FeedSources -CatalogItem $feed -CpuFamily "x64" -Year "2026" -HostIp "172.22.11.1" -Port 9100)
        $lvLine = ($withLv | ForEach-Object { $_.Line }) -join "`n"
        if ($lvLine -notmatch 'ni-labview-2026') {
            Write-Host "FAIL  the LabVIEW 2026 feed URL was not built."
            $failed = $true
        }
        else {
            Write-Host "OK    LabVIEW 2026 feed URL"
        }
        $scriptText = New-TargetScript -Mode "install" -FeedLines $joined -Packages "ni-crio ni-rio ni-rio-server" -IoscanAlready "0"
        if ($scriptText -notmatch 'opkg install ni-crio ni-rio ni-rio-server') {
            Write-Host "FAIL  the install script does not install the cRIO driver set."
            $failed = $true
        }
        elseif ($scriptText -match 'opkg install[^\n]*ioscan') {
            Write-Host "FAIL  the install script installs IO Scan."
            $failed = $true
        }
        elseif ($scriptText -notmatch 'opkg remove') {
            Write-Host "FAIL  the install script does not remove IO Scan if it appears."
            $failed = $true
        }
        else {
            Write-Host "OK    install script names the driver set and removes IO Scan."
        }
        $rank = Get-ArchRank -ArchText "" -CpuFamily "x64"
        $index = Get-FeedPackageIndex -CatalogItem $feed -CpuFamily "x64" -Year "none" -ArchRank $rank
        if (-not $index.ContainsKey("ni-crio") -or -not $index.ContainsKey("ni-rio") -or -not $index.ContainsKey("ni-rio-server")) {
            Write-Host "FAIL  the feed index is missing the cRIO driver set."
            $failed = $true
        }
        elseif (-not $index.ContainsKey("ni-visa")) {
            Write-Host "FAIL  the feed index did not include ni-visa."
            $failed = $true
        }
        else {
            Write-Host ("OK    feed index has {0} packages for this controller, including ni-visa." -f $index.Count)
        }
        $picked = Resolve-RequestedPackages -Index $index -Requested @("ni-visa", "ni-crio-ioscan", "not a package")
        $pickedText = ($picked.Accepted -join " ") + " | " + ($picked.Rejected -join " ")
        if ($picked.Accepted.Count -ne 1 -or $picked.Accepted[0] -ne "ni-visa" -or $pickedText -notmatch "IO Scan" -or $pickedText -notmatch "not a package name") {
            Write-Host "FAIL  package selection did not accept ni-visa and reject IO Scan."
            $failed = $true
        }
        else {
            Write-Host "OK    ni-visa can be added, and IO Scan is refused."
        }
        $withExtra = New-TargetScript -Mode "install" -FeedLines $joined -Packages "ni-crio ni-rio ni-rio-server ni-visa" -IoscanAlready "0"
        if ($withExtra -notmatch 'opkg install ni-crio ni-rio ni-rio-server ni-visa') {
            Write-Host "FAIL  the install script did not include the extra package."
            $failed = $true
        }
        elseif ($withExtra -match 'opkg install[^\n]*ioscan') {
            Write-Host "FAIL  the extra-package install script installs IO Scan."
            $failed = $true
        }
        else {
            Write-Host "OK    install script includes the extra package."
        }
    }

    Write-Step "Feed server"
    $log = Join-Path $env:TEMP "crio-feed-selftest.log"
    $port = $null
    try {
        $port = Start-FeedServer -Root $script:FeedRoot -Address "127.0.0.1" -Port 0 -LogPath $log
        $gz = Receive-Http -Url ("http://127.0.0.1:{0}/26.8.0/ni/Packages.gz" -f $port)
        $headerEnd = [Text.Encoding]::ASCII.GetString($gz).IndexOf("`r`n`r`n")
        if ($headerEnd -lt 0) {
            Write-Host "FAIL  the feed server response had no header."
            $failed = $true
        }
        else {
            $head = [Text.Encoding]::ASCII.GetString($gz, 0, $headerEnd)
            $magicAt = $headerEnd + 4
            $magicOk = ($gz.Length -gt ($magicAt + 1) -and $gz[$magicAt] -eq 0x1f -and $gz[$magicAt + 1] -eq 0x8b)
            if ($head -notmatch '200' -or -not $magicOk) {
                Write-Host "FAIL  Packages.gz was not served as gzip."
                $failed = $true
            }
            else {
                Write-Host "OK    served Packages.gz on 127.0.0.1:$port"
            }
        }
        $evil = Receive-Http -Url ("http://127.0.0.1:{0}/26.8.0/ni/../../../../Windows/win.ini" -f $port)
        $evilHead = [Text.Encoding]::ASCII.GetString($evil)
        if ($evilHead -match '200 OK') {
            Write-Host "FAIL  the feed server followed a path outside the feed."
            $failed = $true
        }
        else {
            Write-Host "OK    rejected a path outside the feed."
        }
    }
    catch {
        Write-Host ("FAIL  feed server: {0}" -f $_.Exception.Message)
        $failed = $true
    }
    finally {
        Stop-FeedServer
    }

    Write-Step $(if ($failed) { "Self-test failed." } else { "Self-test passed." })
    if ($failed) { return 1 }
    return 0
}

function Invoke-Provision {
    Write-Step "cRIO USB provision"
    if (-not (Test-Path -LiteralPath $script:Nipkg)) {
        Install-PackageManager
    }
    if (-not (Test-Path -LiteralPath $script:Ssh)) {
        Install-OpenSshClient
    }

    Write-Step "Host software"
    $report = @(Get-HostDriverReport)
    foreach ($row in $report) {
        if ($row.Installed) {
            Write-Host ("  {0,-24} installed  {1}" -f $row.Title, $row.Version)
        }
        else {
            Write-Host ("  {0,-24} missing" -f $row.Title)
        }
    }
    $missing = @($report | Where-Object { -not $_.Installed })
    if ($missing.Count -gt 0) {
        Install-HostDrivers -Missing $missing
    }

    Write-Step "USB"
    $adapters = @(Get-UsbAdapter)
    if ($adapters.Count -eq 0) {
        Write-Host "No NI-USBLAN adapter is present."
        Write-Host "Connect the PC to the cRIO USB device port (the type-B port), and power the controller."
        Write-Host "The adapter DHCP setting must be enabled. The controller then answers at $TargetIp."
    }
    else {
        foreach ($adapter in $adapters) {
            $ipv4 = Get-AdapterIpv4 -Alias $adapter.Name
            $shown = if ($ipv4) { $ipv4 } else { "no IPv4 address" }
            Write-Host ("  {0}  {1}  {2}" -f $adapter.Name, $adapter.Status, $shown)
            if (-not $ipv4 -and ($AssumeYes -or (Read-Yes -Prompt "Turn DHCP on for $($adapter.Name)?" -DefaultYes))) {
                Write-Host "Windows will ask for administrator approval."
                $alias = $adapter.Name.Replace("'", "''")
                Start-Process -FilePath "powershell.exe" -Verb RunAs -Wait -ArgumentList @(
                    "-NoProfile", "-Command",
                    "Set-NetIPInterface -InterfaceAlias '$alias' -AddressFamily IPv4 -Dhcp Enabled"
                ) | Out-Null
            }
        }
    }
    $reachable = Test-TargetPing -Ip $TargetIp
    if (-not $reachable) {
        Start-Sleep -Seconds 3
        $reachable = Test-TargetPing -Ip $TargetIp
    }
    if (-not $reachable) {
        throw "The controller did not answer a ping at $TargetIp. Use the USB device port, keep DHCP enabled on NI-USBLAN, and confirm the controller is powered. This tool does not use the Ethernet address."
    }
    $hostIp = $null
    foreach ($adapter in @(Get-UsbAdapter)) {
        $ipv4 = Get-AdapterIpv4 -Alias $adapter.Name
        if ($ipv4) { $hostIp = $ipv4; break }
    }
    if (-not $hostIp) {
        $onLink = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -eq "172.22.11.1" } |
            Select-Object -First 1
        if ($onLink) { $hostIp = $onLink.IPAddress }
    }
    if (-not $hostIp) {
        throw "The controller answered at $TargetIp, but this PC has no NI-USBLAN IPv4 address to serve the feeds from. Enable DHCP on the NI-USBLAN adapter so it receives 172.22.11.1."
    }
    Write-Host "  Controller $TargetIp answered. This PC will serve feeds at $hostIp."

    Write-Step "SSH"
    Read-TargetPassword
    $identity = Get-CrioIdentity
    $uname = Get-IdentityField -Text $identity -Name "UNAME"
    $hostname = Get-IdentityField -Text $identity -Name "HOST"
    $os = Get-IdentityField -Text $identity -Name "OS"
    $pkgs = Get-IdentityField -Text $identity -Name "PKGS"
    $cpu = Get-CpuFamily -UnameText $uname
    if (-not $cpu) {
        throw "SSH works, but the controller architecture was not recognized: $uname"
    }
    $pretty = ""
    if ($os -match '(?m)^PRETTY_NAME="?([^"\r\n]+)') { $pretty = $Matches[1] }
    Write-Host "  SSH to ${User}@${TargetIp} works."
    Write-Host "  Host name: $hostname"
    Write-Host "  System: $(if ($pretty) { $pretty } else { $uname })"
    Write-Host "  Kernel: $uname"
    $arch = Get-IdentityField -Text $identity -Name "ARCH"
    $archLines = @($arch -split "`r?`n" | Where-Object { $_ -match '^\s*arch\s+' })
    if ($archLines.Count -gt 0) {
        Write-Host "  Target arch: $($archLines[-1].Trim())"
    }
    if ($pkgs) {
        Write-Host "  Packages already on the controller:"
        foreach ($line in ($pkgs -split "`r?`n")) {
            if ($line.Trim()) { Write-Host "    $($line.Trim())" }
        }
    }
    else {
        Write-Host "  CompactRIO Support, NI-RIO, and NI-RIO Server are not installed."
    }
    if ($cpu -eq "arm") {
        Write-Host "  This controller is ARM. The 9038 is x64. The tool will install the ARM CompactRIO set for the connected target."
    }

    $catalog = @(Get-FeedCatalog)
    if ($catalog.Count -eq 0) {
        throw "No NI Linux RT feeds were found under $($script:FeedRoot)."
    }

    $selected = $null
    if ($FeedVersion) {
        $selected = $catalog | Where-Object { $_.Version -eq $FeedVersion } | Select-Object -First 1
        if (-not $selected) {
            throw "Feed version $FeedVersion is not on this PC."
        }
    }
    elseif ($catalog.Count -eq 1) {
        $only = $catalog[0]
        $label = if ($only.DisplayVersion) { "{0} ({1})" -f $only.Version, $only.DisplayVersion } else { $only.Version }
        Write-Step "Software version"
        if (-not $AssumeYes -and -not (Read-Yes -Prompt "Install version $label on $hostname?" -DefaultYes)) {
            throw "Stopped before installing software."
        }
        $selected = $only
    }
    else {
        $labels = @($catalog | ForEach-Object {
                if ($_.DisplayVersion) { "{0} ({1})" -f $_.Version, $_.DisplayVersion } else { $_.Version }
            })
        $index = Read-Menu -Title "Which version do you want on $hostname?" -Labels $labels
        $selected = $catalog[$index]
    }

    $year = $LabviewYear
    if (-not $year) {
        $labels = @("Drivers only. CompactRIO Support, NI-RIO, and NI-RIO Server.")
        foreach ($item in $selected.LabviewYears) {
            $labels += "LabVIEW $item Real-Time, plus those drivers."
        }
        if ($labels.Count -eq 1) {
            $year = "none"
            Write-Host "No LabVIEW Real-Time feed is installed for $($selected.Version). The driver set will be installed."
        }
        else {
            $index = Read-Menu -Title "Which code runtime do you want with version $($selected.Version)?" -Labels $labels
            if ($index -eq 0) { $year = "none" } else { $year = $selected.LabviewYears[$index - 1] }
        }
    }
    if ($year -ne "none" -and $selected.LabviewYears -notcontains $year) {
        throw "LabVIEW $year is not in the $($selected.Version) feed on this PC."
    }

    $absent = @(Test-FeedFiles -CatalogItem $selected -CpuFamily $cpu -Year $year)
        if ($absent.Count -gt 0) {
            $wantedVersion = $selected.Version
            Install-FeedPackages -Version $wantedVersion -Year $year
            $catalog = @(Get-FeedCatalog)
            $selected = $catalog | Where-Object { $_.Version -eq $wantedVersion } | Select-Object -First 1
            if (-not $selected) {
                throw "Feed $wantedVersion is still not on disk after the package install."
            }
        $absent = @(Test-FeedFiles -CatalogItem $selected -CpuFamily $cpu -Year $year)
        if ($absent.Count -gt 0) {
            throw "These feed files are still missing: $($absent -join ', ')"
        }
    }

    $archRank = Get-ArchRank -ArchText $arch -CpuFamily $cpu
    Write-Host "  Reading packages in feed $($selected.Version)."
    $packageIndex = Get-FeedPackageIndex -CatalogItem $selected -CpuFamily $cpu -Year $year -ArchRank $archRank
    $basePackages = @("ni-crio", "ni-rio", "ni-rio-server")
    if ($year -ne "none") {
        $basePackages += "ni-labview-realtime"
    }
    $extraPackages = @()
    if ($Package) {
        $requested = Resolve-RequestedPackages -Index $packageIndex -Requested $Package
        foreach ($message in $requested.Rejected) {
            throw $message
        }
        $extraPackages = @($requested.Accepted)
    }
    elseif (-not $AssumeYes) {
        $extraPackages = @(Read-ExtraPackages -Index $packageIndex)
    }
    $baseSet = Resolve-RequestedPackages -Index $packageIndex -Requested $basePackages
    foreach ($message in $baseSet.Rejected) {
        throw $message
    }
    $packageNames = @($baseSet.Accepted + $extraPackages | Where-Object { $_ } | Select-Object -Unique)
    $packages = $packageNames -join " "

    $sudo = Get-SudoMode
    Write-Host "  Controller file access: $sudo"
    $ioscanAlready = "0"
    if ($pkgs -match 'ioscan -') { $ioscanAlready = "1" }

    $log = Join-Path $env:TEMP "crio-feed-server.log"
    $port = Start-FeedServer -Root $script:FeedRoot -Address $hostIp -Port $FeedPort -LogPath $log
    $script:FeedListenPort = $port
    Write-Host "  Feed server is listening on ${hostIp}:$port"
    $openedFirewall = Enable-FeedFirewall -Port $port -LocalAddress $hostIp -RemoteAddress $TargetIp
    $probeUrl = "http://{0}:{1}/{2}/ni/Packages.gz" -f $hostIp, $port, $selected.Version
    if (-not (Test-FeedReachable -Url $probeUrl)) {
        if (-not $openedFirewall) {
            Write-Host "The controller cannot read the feed. Allow TCP $port from $TargetIp when Windows asks."
            $openedFirewall = Enable-FeedFirewall -Port $port -LocalAddress $hostIp -RemoteAddress $TargetIp
        }
        if (-not (Test-FeedReachable -Url $probeUrl)) {
            throw "The controller cannot download from $probeUrl. Windows Firewall is still blocking that port, or the USB adapter is not $hostIp."
        }
    }
    Write-Host "  The controller can read the feed."

    $sources = @(Get-FeedSources -CatalogItem $selected -CpuFamily $cpu -Year $year -HostIp $hostIp -Port $port)
    $feedLines = ($sources | ForEach-Object { $_.Line }) -join "`n"
    $planScript = New-TargetScript -Mode "plan" -FeedLines $feedLines -Packages $packages -IoscanAlready $ioscanAlready
    Write-Step "Packages opkg will install"
    $plan = Invoke-RemoteRoot -ScriptText $planScript -SudoMode $sudo -Live
    if ($plan.Stdout -notmatch 'PROVISION_STATUS:planned') {
        $detail = ($plan.Stdout + "`n" + $plan.Stderr).Trim()
        throw "Could not resolve the driver set. The controller feeds were restored. $detail"
    }

    $versionLabel = if ($selected.DisplayVersion) { "{0} ({1})" -f $selected.Version, $selected.DisplayVersion } else { $selected.Version }
    $runtimeLabel = if ($year -eq "none") { "drivers only" } else { "LabVIEW $year Real-Time" }
    if ($extraPackages.Count -gt 0) {
        $runtimeLabel = "$runtimeLabel, plus $($extraPackages -join ', ')"
    }
    Write-Step "Ready to install $versionLabel ($runtimeLabel) on $hostname."
    Write-Host "  Packages: $packages"
    Write-Host "  IO Scan will not be left installed by this install."
    if (-not $AssumeYes) {
        $confirm = Read-Host "Type yes to install this software on the controller"
        if ($confirm -ne "yes") {
            throw "Stopped before installing software. Nothing was left changed on the controller feeds."
        }
    }

    Write-Step "Installing on the controller. Kernel modules can take several minutes to build."
    $installScript = New-TargetScript -Mode "install" -FeedLines $feedLines -Packages $packages -IoscanAlready $ioscanAlready
    $installed = Invoke-RemoteRoot -ScriptText $installScript -SudoMode $sudo -Live
    if ($installed.Stdout -notmatch 'PROVISION_STATUS:0') {
        $detail = ($installed.Stdout + "`n" + $installed.Stderr).Trim()
        throw "The controller install did not finish. Existing opkg feeds were restored. $detail"
    }

    Write-Step "Installed packages"
    $after = Get-TargetPackages -Names $packageNames
    Write-Host $after.Trim()
    foreach ($name in $packageNames) {
        if ($after -notmatch ("(?m)^" + [regex]::Escape($name) + " -")) {
            throw "Install reported success, but $name is not installed."
        }
    }
    if ($ioscanAlready -eq "0" -and $after -match 'ioscan -') {
        throw "NI-RIO IO Scan is installed. It blocks bitfile download on this controller. Remove it with opkg on the controller."
    }

    $doReboot = $Reboot
    if (-not $doReboot -and -not $AssumeYes) {
        $doReboot = Read-Yes -Prompt "Reboot $hostname so the new kernel modules load?"
    }
    if ($doReboot) {
        Write-Host "Rebooting $hostname."
        if ($sudo -eq "WRITABLE") {
            Invoke-CrioSsh -RemoteCommand "reboot" | Out-Null
        }
        else {
            Invoke-RemoteRoot -ScriptText "reboot`n" -SudoMode $sudo | Out-Null
        }
        $downDeadline = (Get-Date).AddSeconds(45)
        while ((Get-Date) -lt $downDeadline) {
            if (-not (Test-TargetPing -Ip $TargetIp)) { break }
            Start-Sleep -Seconds 2
        }
        if (-not (Wait-TargetSsh -Seconds 180)) {
            throw "The controller did not answer SSH after the reboot. Check power and the USB cable, then run this tool again. It will see the packages that are already installed."
        }
        Write-Step "Controller is back"
        $final = Get-TargetPackages -Names $packageNames
        Write-Host $final.Trim()
    }
    else {
        Write-Host "The packages are installed. Reboot the controller before using the FPGA drivers. The kernel modules load during boot."
    }

    Write-Step "Provision finished for $hostname."
    Write-Host "  Version: $versionLabel"
    Write-Host "  Runtime: $runtimeLabel"
    Write-Host "  SSH: ${User}@${TargetIp}"
}

if ($SelfTest) {
    $code = Invoke-SelfTest
    exit $code
}

try {
    Invoke-Provision
}
catch {
    Write-Host ""
    Write-Host $_.Exception.Message
    exit 1
}
finally {
    Stop-FeedServer
    if ($script:FeedListenPort) {
        Disable-FeedFirewall -Port $script:FeedListenPort
    }
    if (Test-Path -LiteralPath $script:AskPass) {
        Remove-Item -LiteralPath $script:AskPass -Force -ErrorAction SilentlyContinue
    }
    $script:TargetPassword = $null
    Remove-Item Env:CRIO_SSH_PASSWORD -ErrorAction SilentlyContinue
}
