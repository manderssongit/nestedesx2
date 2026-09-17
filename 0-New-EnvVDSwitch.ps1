<#
    0-New-EnvVDSwitch.ps1  —  Steg 0: fysisk host-prep, unmanaged uplink-los vDS
    ---------------------------------------------------------------------------
    Skapar den unmanaged vDS:en (0 uplinks = host-lokal switching) och lagger till
    de fysiska WLD-hostarna UTAN att mappa nagra vmnics, samt satter MTU 9000.
    Kors fran jumphosten mot WLD-vCenter. Engangs (och vid nya hostar).

    OBS: separat fran SDDC Managers managed vDS - denna ar din egen, orord av VCF LCM.
#>

# --- PowerCLI-loader: ta den modul som finns, importera ALDRIG bada ---
if     (Get-Module -ListAvailable VCF.PowerCLI)    { Import-Module VCF.PowerCLI }
elseif (Get-Module -ListAvailable VMware.PowerCLI) { Import-Module VMware.PowerCLI }
else   { throw 'PowerCLI saknas - installera VCF.PowerCLI (PS 7.4+) eller VMware.PowerCLI.' }

function New-EnvVDSwitch {
    <#
      Ex:  Connect-VIServer vcenter-wld
           New-EnvVDSwitch -Name nes-vds -Datacenter DC-WLD -VMHost phys01,phys02,phys03 -Mtu 9000
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,          # t.ex. nes-vds
        [Parameter(Mandatory)][string]$Datacenter,    # datacenter i WLD-vCenter dar vDS skapas
        [Parameter(Mandatory)][string[]]$VMHost,      # fysiska hostar att lagga till (utan uplinks)
        [int]$Mtu = 9000
    )

    $dc  = Get-Datacenter -Name $Datacenter -ErrorAction Stop
    $vds = Get-VDSwitch -Name $Name -ErrorAction SilentlyContinue
    if (-not $vds) {
        # Skapa vDS:en. MTU 9000 sa overlay/vSAN-jumbo far plats aven pa det inre laget.
        $vds = New-VDSwitch -Name $Name -Location $dc -Mtu $Mtu -ErrorAction Stop
        Write-Host "vDS '$Name' skapad (MTU $Mtu)."
    } else {
        Write-Host "vDS '$Name' finns redan - lagger bara till ev. nya hostar."
    }

    foreach ($hn in $VMHost) {
        $vmh = Get-VMHost -Name $hn -ErrorAction Stop
        if (Get-VDSwitch -Name $Name -VMHost $vmh -ErrorAction SilentlyContinue) {
            Write-Host "  $hn redan medlem - hoppar."
            continue
        }
        # Lagg till host UTAN -VMHostPhysicalNic  => inga uplinks => host-lokal switching
        Add-VDSwitchVMHost -VDSwitch $vds -VMHost $vmh -ErrorAction Stop
        Write-Host "  $hn tillagd (0 uplinks)."
    }

    Write-Host "Klar. '$Name' spanner $($VMHost.Count) hostar, host-lokal (inga uplinks), MTU $Mtu."
    Write-Host "Nasta: New-EnvPortGroup for trunk-portgruppen."
    return Get-VDSwitch -Name $Name
}
