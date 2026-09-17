<#
    4b-Set-EsxiHostBaseline.ps1  —  "Steg"-laget for nested ESXi (steg fore full auto)
    ------------------------------------------------------------------------------------
    Tanke: skapa VM:en och installera ESXi FOR HAND pa defaults, sen kor detta mot
    hosten sa NTP/SSH/DNS/vhv sätts via PowerCLI. Samma installningar som kickstartens
    %firstboot gor - fast oppet och begripligt, sa fler kan folja med.

    Ansluter DIREKT till varje ESXi-host (inget vCenter behovs an - det ar ju det
    Cloud Builder bygger sen). Kor fran jumphosten pa pod-natet.

    Kravm: VCF.PowerCLI eller VMware.PowerCLI (loadern nedan tar den som finns).

    Config-driven (rekommenderat): baslinje pa hela en host-grupp ur env-config.psd1:
        .\4b-Set-EsxiHostBaseline.ps1 -Group mgmt -RootPw 'VMware1!'
#>

param(
    [ValidateSet('mgmt','prod','test')][string]$Group,
    [string]$RootPw = 'VMware1!',    # TODO: valvsecret
    [string]$ConfigPath,
    [string]$Template
)

# --- config-laddare + PowerCLI-loader: ta den modul som finns, importera ALDRIG bada ---
. "$PSScriptRoot\Get-EnvConfig.ps1"
if     (Get-Module -ListAvailable VCF.PowerCLI)    { Import-Module VCF.PowerCLI }
elseif (Get-Module -ListAvailable VMware.PowerCLI) { Import-Module VMware.PowerCLI }
else   { throw 'PowerCLI saknas - installera VCF.PowerCLI (PS 7.4+) eller VMware.PowerCLI.' }
# Farska hostar har self-signed cert -> ignorera cert-varning for sessionen
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null

function Set-EsxiHostBaseline {
    <#
      Ansluter till EN ESXi-host och sätter baslinjen. Exempel:
        Set-EsxiHostBaseline -HostAddress 192.168.0.51 -RootPw 'VMware1!' `
            -ShortName esx-mgmt01 -Domain infra.test -Dns 192.168.0.10 -Ntp 192.168.0.10
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostAddress,   # IP eller FQDN till hosten
        [Parameter(Mandatory)][string]$RootPw,
        [Parameter(Mandatory)][string]$ShortName,     # t.ex. esx-mgmt01
        [Parameter(Mandatory)][string]$Domain,        # t.ex. infra.test
        [Parameter(Mandatory)][string[]]$Dns,
        [Parameter(Mandatory)][string]$Ntp,
        [switch]$InstallMockVib,                        # vSAN ESA HCL mock-VIB
        [string]$MockVibUrl = 'http://depot.infra.test/vibs/nested-vsan-esa-mock-hw_7x8x.zip'
    )

    Write-Host "== $ShortName ($HostAddress) ==" -ForegroundColor Cyan
    Connect-VIServer -Server $HostAddress -User root -Password $RootPw | Out-Null
    try {
        $h = Get-VMHost                                 # standalone-anslutning -> hosten sjalv

        # 1) SSH + ESXi shell pa, och satt policy sa de startar vid boot
        foreach ($key in 'TSM-SSH','TSM') {
            $svc = Get-VMHostService -VMHost $h | Where-Object Key -eq $key
            Start-VMHostService $svc -Confirm:$false | Out-Null
            Set-VMHostService  $svc -Policy On -Confirm:$false | Out-Null
        }
        # Dampa shell-varningen i UI
        Get-AdvancedSetting -Entity $h -Name 'UserVars.SuppressShellWarning' |
            Set-AdvancedSetting -Value 1 -Confirm:$false | Out-Null

        # 2) NTP (Cloud Builder ar strikt pa tid)
        Add-VMHostNtpServer -VMHost $h -NtpServer $Ntp -Confirm:$false -EA SilentlyContinue | Out-Null
        $ntpd = Get-VMHostService -VMHost $h | Where-Object Key -eq 'ntpd'
        Set-VMHostService  $ntpd -Policy On -Confirm:$false | Out-Null
        Restart-VMHostService $ntpd -Confirm:$false | Out-Null

        # 3) Hostname + DNS + doman
        Get-VMHostNetwork -VMHost $h |
            Set-VMHostNetwork -HostName $ShortName -DomainName $Domain -DnsAddress $Dns -Confirm:$false | Out-Null

        # 4) Exponera hw-virt (nested-i-nested + vSAN) via esxcli
        $esxcli = Get-EsxCli -V2 -VMHost $h
        $k = $esxcli.system.settings.kernel.set.CreateArgs()
        $k.setting = 'vhvEnable'; $k.value = 'TRUE'
        $esxcli.system.settings.kernel.set.Invoke($k) | Out-Null

        # 5) (valfritt) vSAN ESA HCL mock-VIB
        if ($InstallMockVib) {
            $esxcli.software.acceptance.set.Invoke(@{ level = 'CommunitySupported' }) | Out-Null
            $vi = $esxcli.software.vib.install.CreateArgs()
            $vi.depot = $MockVibUrl
            $esxcli.software.vib.install.Invoke($vi) | Out-Null
            Write-Host "  mock-VIB installerad (reboota hosten for att aktivera vsanmgmt)" -ForegroundColor Yellow
        }

        Write-Host "  klar: SSH+shell pa, NTP=$Ntp, hostname=$ShortName.$Domain, vhv=TRUE" -ForegroundColor Green
    }
    finally { Disconnect-VIServer -Server $HostAddress -Confirm:$false | Out-Null }
}

# ------------------------------------------------------------------------------
#  Config-driven korning: baslinje pa hela host-gruppen ur env-config.psd1
# ------------------------------------------------------------------------------
if ($Group) {
    $cfg    = Get-EnvConfig -Path $ConfigPath -Template $Template
    $domain = $cfg.adForest.infra.domain
    $dns    = $cfg.adForest.infra.dnsServer
    $ntp    = $cfg.adForest.infra.ntpServer
    $vibUrl = $cfg.physicalEnv.mockVibUrl
    Write-Host ("== Grupp {0}: {1} host, doman {2}, dns {3}, ntp {4} ==" -f `
        $Group, $cfg.HostGroup($Group).Count, $domain, $dns, $ntp) -ForegroundColor Cyan
    foreach ($h in $cfg.HostGroup($Group)) {
        $esa = ($h.vsanMode -eq 'ESA')          # ESA -> installera vSAN-mock-VIB
        Set-EsxiHostBaseline -HostAddress $h.ip -RootPw $RootPw -ShortName $h.name `
            -Domain $domain -Dns $dns -Ntp $ntp -InstallMockVib:$esa -MockVibUrl $vibUrl
    }
    Write-Host "Grupp $Group klar. Nasta: 5-Test-EnvReadiness -Group $Group." -ForegroundColor Green
}

# ------------------------------------------------------------------------------
#  Manuellt exempel (en host, utan config)
# ------------------------------------------------------------------------------
# Set-EsxiHostBaseline -HostAddress 192.168.0.51 -RootPw 'VMware1!' -ShortName esx-mgmt01 `
#     -Domain infra.test -Dns 192.168.0.10 -Ntp 192.168.0.10 -InstallMockVib
