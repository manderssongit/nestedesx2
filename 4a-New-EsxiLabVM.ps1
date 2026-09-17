<#
    4a-New-EsxiLabVM.ps1  —  "Steg"-laget, del 1 av 2 (para ihop med 4b-Set-EsxiHostBaseline.ps1)
    -------------------------------------------------------------------------------------------
    Skapar EN tom nested-ESXi-VM med ratt hardvara (NVMe-diskar = flash, hw-virt,
    trunk-portgroup, boot order disk-fore-CD) och monterar en STOCK ESXi-ISO fran en
    Content Library. Sen:
        1. Starta VM:en, installera ESXi FOR HAND pa defaults, satt IP i DCUI.
        2. Kor Set-EsxiHostBaseline mot hosten (NTP/SSH/DNS/vhv).

    Kor mot din WLD-vCenter (dar VM:erna skapas):  Connect-VIServer <vcenter> forst.
    Krav: VCF.PowerCLI eller VMware.PowerCLI. Stock-ISO:n ligger som ett CL-item
    (vSAN tillater inte losa filer pa datastore-roten).

    Config-driven (rekommenderat) - bygger HELA en host-grupp med ratt namn/hw ur configen:
        .\4a-New-EsxiLabVM.ps1 -Group mgmt -VMHost phys01 -PowerOn
      Namn foljer configen: prefix + friendlyName + hostShort -> nes-aurora-esx-mgmt01.
      Datastore/portgroup/guestId/storagePolicy/storlek hamtas ur env-config.psd1.

    Manuellt (en VM, som forr):
        New-EsxiLabVM -Name esx-mgmt01 -VMHost phys01 -Datastore wld-vsan -Portgroup ... -IsoItem ...
#>

param(
    [ValidateSet('mgmt','prod','test')][string]$Group,
    [string]$VMHost,                 # fysisk host gruppen laggs pa (affinity: en env per host)
    [string]$ConfigPath,
    [string]$Template,
    [switch]$PowerOn
)

# --- config-laddare + PowerCLI-loader: ta den modul som finns, importera ALDRIG bada ---
. "$PSScriptRoot\Get-EnvConfig.ps1"
if     (Get-Module -ListAvailable VCF.PowerCLI)    { Import-Module VCF.PowerCLI }
elseif (Get-Module -ListAvailable VMware.PowerCLI) { Import-Module VMware.PowerCLI }
else   { throw 'PowerCLI saknas - installera VCF.PowerCLI (PS 7.4+) eller VMware.PowerCLI.' }

function New-EsxiLabVM {
    <#
      Ex:  New-EsxiLabVM -Name esx-mgmt01 -VMHost phys01 -Datastore wld-vsan `
               -Portgroup nes-vcf01-trunk -IsoContentLibrary nes-iso -IsoItem ESXi-8.0U3 -PowerOn
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,               # VM-namn, t.ex. esx-mgmt01
        [Parameter(Mandatory)][string]$VMHost,             # fysisk host VM:en skapas pa
        [Parameter(Mandatory)][string]$Datastore,          # dar VM:en lagras (WLD vSAN)
        [Parameter(Mandatory)][string]$Portgroup,          # trunk-portgruppen (host-lokal)
        [Parameter(Mandatory)][string]$IsoContentLibrary,  # CL med stock-ESXi-ISO
        [Parameter(Mandatory)][string]$IsoItem,            # ISO-itemets namn i CL:n
        [int]$vCPU              = 8,
        [int]$MemoryGB          = 48,
        [int]$BootDiskGB        = 32,
        [int]$CacheDiskGB       = 100,     # 0 = hoppa cache (all-flash/ESA behover den anda)
        [int]$CapacityDiskGB    = 200,
        [int]$CapacityDiskCount = 1,
        [string]$GuestId        = 'vmkernel8Guest',   # ESXi 9: byt till motsvarande id
        [string]$StoragePolicy,                        # tom = datastore-default (lab -> garna FTT=0)
        [switch]$PowerOn
    )

    $vmh = Get-VMHost -Name $VMHost -ErrorAction Stop
    Write-Host "== Skapar $Name pa $VMHost ==" -ForegroundColor Cyan

    # 1) Grund-VM med boot-disk pa default-SCSI
    $p = @{
        Name = $Name; VMHost = $vmh; Datastore = $Datastore
        DiskGB = $BootDiskGB; MemoryGB = $MemoryGB; NumCpu = $vCPU
        GuestId = $GuestId; Portgroup = (Get-VDPortgroup -Name $Portgroup -ErrorAction Stop)
        DiskStorageFormat = 'Thin'
    }
    if ($StoragePolicy) { $p.StoragePolicy = (Get-SpbmStoragePolicy -Name $StoragePolicy -ErrorAction Stop) }
    $vm = New-VM @p -ErrorAction Stop

    # 2) NVMe-controller + vSAN-diskar (nested ser dem som flash -> ingen SSD-markering)
    $cfg = New-Object VMware.Vim.VirtualMachineConfigSpec
    $changes = @()
    $ctrl = New-Object VMware.Vim.VirtualDeviceConfigSpec
    $ctrl.operation = 'add'
    $nvme = New-Object VMware.Vim.VirtualNVMEController
    $nvme.key = -100; $nvme.busNumber = 0
    $ctrl.device = $nvme
    $changes += $ctrl

    $pspec = $null
    if ($StoragePolicy) {
        $pol = Get-SpbmStoragePolicy -Name $StoragePolicy
        $pspec = New-Object VMware.Vim.VirtualMachineDefinedProfileSpec
        $pspec.profileId = $pol.Id
    }
    $sizes = @()
    if ($CacheDiskGB -gt 0) { $sizes += $CacheDiskGB }
    for ($n = 1; $n -le $CapacityDiskCount; $n++) { $sizes += $CapacityDiskGB }

    $unit = 0
    foreach ($gb in $sizes) {
        $d = New-Object VMware.Vim.VirtualDeviceConfigSpec
        $d.operation = 'add'; $d.fileOperation = 'create'
        $disk = New-Object VMware.Vim.VirtualDisk
        $disk.capacityInKB = [int64]$gb * 1024 * 1024
        $disk.controllerKey = -100
        $disk.unitNumber = $unit
        $disk.key = -(200 + $unit)
        $back = New-Object VMware.Vim.VirtualDiskFlatVer2BackingInfo
        $back.diskMode = 'persistent'; $back.thinProvisioned = $true
        $back.fileName = "[$Datastore]"
        $disk.backing = $back
        $d.device = $disk
        if ($pspec) { $d.profile = @($pspec) }
        $changes += $d
        $unit++
    }
    $cfg.deviceChange = $changes
    $vm.ExtensionData.ReconfigVM($cfg)

    # 3) Exponera hw-virt (nested-i-nested + vSAN)
    $vm | New-AdvancedSetting -Name 'featMask.vm.cpuid.VT' -Value 'Val:1' -Force -Confirm:$false | Out-Null

    # 4) Montera stock-ESXi-ISO fran Content Library, ansluten vid boot
    $iso = Get-ContentLibraryItem -ContentLibrary $IsoContentLibrary -Name $IsoItem -ErrorAction Stop
    $vm | Get-CDDrive | Set-CDDrive -ContentLibraryIso $iso -StartConnected $true -Confirm:$false | Out-Null

    # 5) Boot order: disk fore CD (tom disk -> bootar installern; efter install -> disk)
    $vm.ExtensionData.UpdateViewData('Config.Hardware.Device')
    $scsi = $vm.ExtensionData.Config.Hardware.Device | Where-Object { $_ -is [VMware.Vim.VirtualSCSIController] } | Select-Object -First 1
    $bootDisk = $vm.ExtensionData.Config.Hardware.Device |
        Where-Object { $_ -is [VMware.Vim.VirtualDisk] -and $_.ControllerKey -eq $scsi.Key } |
        Sort-Object UnitNumber | Select-Object -First 1
    $diskBoot = New-Object VMware.Vim.VirtualMachineBootOptionsBootableDiskDevice
    $diskBoot.DeviceKey = $bootDisk.Key
    $cdBoot   = New-Object VMware.Vim.VirtualMachineBootOptionsBootableCdromDevice
    $bopts = New-Object VMware.Vim.VirtualMachineBootOptions
    $bopts.BootOrder = @($diskBoot, $cdBoot)
    $bcfg = New-Object VMware.Vim.VirtualMachineConfigSpec
    $bcfg.BootOptions = $bopts
    $vm.ExtensionData.ReconfigVM($bcfg)

    if ($PowerOn) { Start-VM $vm | Out-Null }
    Write-Host "  klar. Starta -> installera ESXi for hand -> kor sen Set-EsxiHostBaseline." -ForegroundColor Green
    return $vm
}

# ------------------------------------------------------------------------------
#  Config-driven korning: bygg hela host-gruppen ur env-config.psd1
# ------------------------------------------------------------------------------
if ($Group) {
    if (-not $VMHost) { throw 'Ange -VMHost (den fysiska host gruppen ska ligga pa).' }
    $cfg  = Get-EnvConfig -Path $ConfigPath -Template $Template
    $t    = $cfg.physicalEnv
    $pg   = $cfg.TrunkPg()                          # nes-aurora-trunk (fran steg 2)
    $gid  = $cfg.GuestId()                          # ur esxiVersion + guestIdMap
    Write-Host ("== Grupp {0} pa {1}: {2} host, portgroup {3}, guestId {4} ==" -f `
        $Group, $VMHost, $cfg.HostGroup($Group).Count, $pg, $gid) -ForegroundColor Cyan

    foreach ($h in $cfg.HostGroup($Group)) {
        $s = $h.spec                                # storleks-spec (vCPU/mem/diskar)
        $vmParams = @{
            Name              = $h.vmName           # nes-aurora-esx-mgmt01
            VMHost            = $VMHost
            Datastore         = $t.datastore
            Portgroup         = $pg
            IsoContentLibrary = $t.contentLibrary
            IsoItem           = $t.baseIso
            vCPU              = $s.vCPU
            MemoryGB          = $s.memGB
            BootDiskGB        = $s.bootGB
            CacheDiskGB       = $s.cacheGB
            CapacityDiskGB    = $s.capGB
            CapacityDiskCount = $s.capDisks
            GuestId           = $gid
            PowerOn           = $PowerOn
        }
        if ($t.storagePolicy) { $vmParams.StoragePolicy = $t.storagePolicy }
        New-EsxiLabVM @vmParams | Out-Null
    }
    Write-Host "Grupp $Group klar. Installera ESXi for hand -> kor sen 4b/5 med -Group $Group." -ForegroundColor Green
}

# ------------------------------------------------------------------------------
#  Manuellt exempel (utan config): en enskild host
# ------------------------------------------------------------------------------
# Connect-VIServer vcenter-wld.dittfabric
# New-EsxiLabVM -Name nes-aurora-esx-mgmt01 -VMHost phys01 -Datastore wld-vsan `
#     -Portgroup nes-aurora-trunk -IsoContentLibrary nes-iso -IsoItem 'ESXi-8.0U3' `
#     -StoragePolicy 'Env-FTT0-Thin' -PowerOn
