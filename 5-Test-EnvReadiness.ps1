<#
    5-Test-EnvReadiness.ps1  —  Steg 5: verifieringsgrind fore Cloud Builder / WLD
    ---------------------------------------------------------------------------
    Kontrollerar det Cloud Builder/SDDC annars failar pa: DNS forward+reverse,
    NTP-tjanst, SSH, antal (blanka) diskar, och ev. mock-VIB. Kors fran jumphosten.
    Ren "gron/rod"-koll innan bringup - anda ingen automatik, bara insyn.

    Config-driven (steg-lage):
        .\5-Test-EnvReadiness.ps1 -Group mgmt -RootPw 'VMware1!'
      Laser host-listan, DNS-server och forvantat diskantal ur env-config.json
      (via Get-EnvConfig) for host-gruppen. Ingen host-lista behover skrivas for hand.

    Manuellt override (som forr) gar fortfarande:
        Test-EnvReadiness -Hosts $hosts -Dns 192.168.0.10 -MinDisks 3
#>

param(
    [ValidateSet('mgmt','prod','test')][string]$Group,
    [string]$ConfigPath,                       # env-config.json (default: bredvid scriptet)
    [string]$Template,                         # sparad template istallet (t.ex. 'prod')
    [string]$RootPw = 'VMware1!',              # TODO: hamta ur vault
    [switch]$CheckVib,
    [int]$MinDisks                             # override; annars harleds ur size i configen
)

# --- config-laddare + PowerCLI-loader ---
. "$PSScriptRoot\Get-EnvConfig.ps1"
if     (Get-Module -ListAvailable VCF.PowerCLI)    { Import-Module VCF.PowerCLI }
elseif (Get-Module -ListAvailable VMware.PowerCLI) { Import-Module VMware.PowerCLI }
else   { throw 'PowerCLI saknas - installera VCF.PowerCLI (PS 7.4+) eller VMware.PowerCLI.' }
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null

function Test-EnvReadiness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable[]]$Hosts,
        [string]$Dns      = '192.168.0.10',
        [int]$MinDisks    = 3,                 # boot + minst 2 vSAN-diskar
        [switch]$CheckVib                       # kontrollera mock-VIB (ESA)
    )

    $rows = foreach ($h in $Hosts) {
        $r = [ordered]@{ Host = $h.Fqdn; DNSfwd='-'; DNSrev='-'; NTP='-'; SSH='-'; Diskar='-'; VIB='-' }

        # DNS forward + reverse mot DC:n
        $fwd = (Resolve-DnsName -Name $h.Fqdn -Server $Dns -Type A -ErrorAction SilentlyContinue).IPAddress
        $r.DNSfwd = if ($fwd -eq $h.Ip) { 'OK' } else { "FEL($fwd)" }
        $rev = (Resolve-DnsName -Name $h.Ip -Server $Dns -Type PTR -ErrorAction SilentlyContinue).NameHost
        $r.DNSrev = if ($rev -match [regex]::Escape($h.Fqdn)) { 'OK' } else { "FEL($rev)" }

        # Host-sidan
        try {
            Connect-VIServer -Server $h.Ip -User root -Password $h.RootPw -ErrorAction Stop | Out-Null
            $vmh = Get-VMHost
            $r.NTP = if ((Get-VMHostService -VMHost $vmh | Where-Object Key -eq 'ntpd').Running) { 'OK' } else { 'STOPP' }
            $r.SSH = if ((Get-VMHostService -VMHost $vmh | Where-Object Key -eq 'TSM-SSH').Running) { 'OK' } else { 'STOPP' }
            $esxcli = Get-EsxCli -V2 -VMHost $vmh
            $nDisk = ($esxcli.storage.core.device.list.Invoke() | Where-Object { $_.IsSSD -or $_.Size -gt 0 }).Count
            $r.Diskar = if ($nDisk -ge $MinDisks) { "OK($nDisk)" } else { "FA($nDisk)" }
            if ($CheckVib) {
                $vib = $esxcli.software.vib.list.Invoke() | Where-Object { $_.Name -match 'mock|vsan-esa' }
                $r.VIB = if ($vib) { 'OK' } else { 'SAKNAS' }
            }
        } catch {
            $r.NTP = 'EJ NADD'; $r.SSH = 'EJ NADD'
        } finally {
            Disconnect-VIServer -Server $h.Ip -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        }
        [pscustomobject]$r
    }

    $rows | Format-Table -AutoSize
    $fail = $rows | Where-Object { ($_.PSObject.Properties.Value -join ' ') -match 'FEL|STOPP|EJ NADD|SAKNAS|FA\(' }
    if ($fail) { Write-Warning "$($fail.Count) host(ar) ej redo - atgarda ovan innan bringup." }
    else       { Write-Host "Alla hostar gron - redo for Cloud Builder / WLD." -ForegroundColor Green }
    return $rows
}

# --- config-driven korning: bygg -Hosts/-Dns/-MinDisks ur env-config.json ---
if ($Group) {
    $cfg   = Get-EnvConfig -Path $ConfigPath -Template $Template
    $dns   = $cfg.adForest.infra.dnsServer
    $hosts = $cfg.HostGroup($Group) | ForEach-Object {
        @{ Fqdn = $_.fqdn; Ip = $_.ip; RootPw = $RootPw }
    }
    if (-not $PSBoundParameters.ContainsKey('MinDisks')) {
        # forvantade diskar = boot + ev. cache + kapacitetsdiskar (ur size)
        $sz       = ($cfg.HostGroup($Group))[0].spec
        $MinDisks = 1 + $(if ($sz.cacheGB -gt 0) {1} else {0}) + [int]$sz.capDisks
    }
    Write-Host ("Grupp {0}: {1} host, DNS {2}, forvantar >= {3} diskar" -f `
        $Group, $hosts.Count, $dns, $MinDisks) -ForegroundColor Cyan
    Test-EnvReadiness -Hosts $hosts -Dns $dns -MinDisks $MinDisks -CheckVib:$CheckVib
}
