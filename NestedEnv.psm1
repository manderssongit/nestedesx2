<#
    NestedEnv.psm1  —  Steg 1: spinna upp / riva nested-ESXi-labb i en VCF WLD
    ---------------------------------------------------------------------------
    Deploy-metod: kickstart-ISO (ks=cdrom:/KS.CFG), en per-host-ISO per nested ESX.
    Slutmal for steg 1: N nested ESX uppe, SSH+NTP+DNS klara -> redo for Cloud
    Builder (steg 2).

    Beroenden:
      * PowerCLI: VCF.PowerCLI (PS 7.4+) ELLER VMware.PowerCLI 13.x (PS 5.1/7).
                  Loadern nedan tar den som finns - bada namnen ger samma cmdlets.
      * ISO-bygge via inbyggt IMAPI2 (Windows)  - inget ADK/oscdimg behovs
      * En bas-ESXi-8-ISO som matchar din nested-VCF BOM
      * En fardig FTT=0 vSAN-storagepolicy   (disponibelt lab -> ingen redundans)
      * Den unmanaged uplink-losa vDS:en finns (New-EnvPortGroup dot-sourcad)
      * RSAT DnsServer + WinRM till lab-DC:n   (for -RegisterDns)

    Sok pa 'TODO' for saker du behover tuna mot din miljo.
#>

# --- PowerCLI-loader: ta den modul som finns, importera ALDRIG bada ---
if     (Get-Module -ListAvailable VCF.PowerCLI)    { Import-Module VCF.PowerCLI }
elseif (Get-Module -ListAvailable VMware.PowerCLI) { Import-Module VMware.PowerCLI }
else   { throw 'PowerCLI saknas - installera VCF.PowerCLI (PS 7.4+) eller VMware.PowerCLI.' }
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Warning 'Windows PowerShell 5.1 fungerar men ar deprecerat i VCF PowerCLI 9.x - planera PS 7.4+.'
}

. "$PSScriptRoot\2-New-EnvPortGroup.ps1"   # ateranvander portgroup-funktionen

# ---------------------------------------------------------------------------
#  Site-profil: satt EN gang. Allt trakigt bor har.
#  Ladda med:  $p = Import-PowerShellDataFile .\NestedEnv.profile.psd1
# ---------------------------------------------------------------------------
# Exempel-profil (spara som NestedEnv.profile.psd1):
<#
@{
    Prefix         = 'nes-'                # tvingande prefix pa ALLA vCenter-objekt
    ParentFolder   = 'nested'              # parent-VM-folder; lab-foldrar hamnar under
    VDSwitchName   = 'vds-nested'          # den unmanaged uplink-losa vDS:en
    DatastoreName  = 'wld-vsan'            # WLD:ns vSAN dar nested-VM:erna lagras
    StoragePolicy  = 'Env-FTT0-Thin'       # fardig FTT=0-policy
    BaseIsoPath    = 'C:\iso\ESXi-8.0U3.iso'
    EsxiVersion    = '8'                   # valjer GuestId ur GuestIdMap nedan
    GuestIdMap     = @{                     # nested-ESXi guest-OS-id per version
        '8' = 'vmkernel8Guest'
        '9' = 'vmkernel9Guest'             # TODO: verifiera exakt id for ESXi 9
    }
    # vSAN ESA HCL mock-VIB, serverad over HTTP fran depoten (tom = hoppa install).
    # NVMe-diskar syns redan som flash, sa ingen SSD-markering behovs - bara VIB:en.
    MockVibUrl     = 'http://depot.infra.test/vibs/nested-vsan-esa-mock-hw_7x8x.zip'
    WorkDir        = 'C:\nestedlab\work'   # temp for ISO-bygge
    ContentLibrary = 'nes-iso'             # lokal CL for per-host-ISO:erna (vSAN tillater inte losa filer)
    DomainSuffix   = 'infra.test'
    HostnamePrefix = 'esx-mgmt'            # mgmt-doman: -> esx-mgmt01 ...  (WLD-runs: 'esx-prod'/'esx-test')
    DnsServer      = '192.168.0.10'        # lab-AD:ts IP
    DcComputer     = 'dc.infra.test'  # for -RegisterDns
    DnsZone        = 'infra.test'
    NtpServer      = '192.168.0.10'
    MgmtCidr       = '192.168.0.0/24'
    MgmtGateway    = '192.168.0.10'        # mgmt-gw = DC (svarar pa ping; ingen router pa flatt isolerat nat)
    MgmtStartIp    = 51                    # mgmt esx-mgmt01 = .51  (WLD-runs: prod 81, test 111)
    Netmask        = '255.255.255.0'
    Sizes = @{
        Small  = @{ vCPU = 8;  MemGB = 24; BootGB = 32; CacheGB = 0;   CapGB = 0;   CapDisks = 0 }
        Medium = @{ vCPU = 8;  MemGB = 48; BootGB = 32; CacheGB = 80;  CapGB = 200; CapDisks = 1 }
        Large  = @{ vCPU = 12; MemGB = 96; BootGB = 32; CacheGB = 120; CapGB = 400; CapDisks = 2 }
    }
}
#>

# ---------------------------------------------------------------------------
#  Kickstart-mall. Placeholders {{...}} ersatts per host.
# ---------------------------------------------------------------------------
$script:KsTemplate = @'
vmaccepteula
# Installera BARA pa forsta disken, ingen lokal VMFS -> ovriga diskar blanka for vSAN
install --firstdisk=local --novmfsondisk
rootpw {{ROOTPW}}
network --bootproto=static --ip={{IP}} --netmask={{MASK}} --gateway={{GW}} --nameserver={{DNS}} --hostname={{FQDN}} --addvmportgroup=0
reboot

%firstboot --interpreter=busybox
# SSH + ESXi shell pa och persistent
vim-cmd hostsvc/enable_ssh
vim-cmd hostsvc/start_ssh
vim-cmd hostsvc/enable_esx_shell
vim-cmd hostsvc/start_esx_shell
esxcli system settings advanced set -o /UserVars/SuppressShellWarning -i 1
# NTP (Cloud Builder ar strikt pa tid)
echo "server {{NTP}}" > /etc/ntp.conf
esxcli system ntp set -e 1 -s {{NTP}}
# Exponera hw-virt sa nested-i-nested + vSAN funkar
esxcli system settings kernel set -s vhvEnable -v TRUE
'@

# ---------------------------------------------------------------------------
#  ISO-bygge med inbyggt Windows-IMAPI2 (ersatter oscdimg/ADK helt).
#  Liten C#-hjalpare skriver IMAPI2:s resultat-IStream till fil (PS 5.1 + 7.x).
# ---------------------------------------------------------------------------
if (-not ('ISOFile' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class ISOFile {
    public static void Create(string path, object stream, int blockSize, int totalBlocks) {
        IStream i = (IStream)stream;
        using (FileStream o = File.OpenWrite(path)) {
            byte[] buf = new byte[blockSize];
            IntPtr read = Marshal.AllocHGlobal(4);
            try {
                while (totalBlocks-- > 0) {
                    i.Read(buf, blockSize, read);
                    o.Write(buf, 0, Marshal.ReadInt32(read));
                }
                o.Flush();
            } finally { Marshal.FreeHGlobal(read); }
        }
    }
}
'@
}

function New-EsxiBootIso {
    <#  Byggar en UEFI-bootbar ISO fran en katalog med IMAPI2 (Windows inbyggt).
        EFI-boot = efiboot.img i ISO-roten, no-emulation, platform EFI (0xEF).
        TODO: verifiera med EN boot av en nested VM - boot-parametrarna/filsystemen
        ar den kansliga biten (samma sorts sak som oscdimg-argumenten var). Strular
        boot pa saknade filer: hoj FileSystemsToCreate till 7 (lagg till UDF).  #>
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$OutIso,
        [string]$VolumeName = 'ESXI'
    )
    if (Test-Path $OutIso) { Remove-Item $OutIso -Force }

    $efi = Join-Path $SourceDir 'EFIBOOT.IMG'
    if (-not (Test-Path $efi)) { $efi = Join-Path $SourceDir 'efiboot.img' }
    if (-not (Test-Path $efi)) { throw "Ingen efiboot.img i $SourceDir - kan inte gora UEFI-bootbar." }

    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.FileSystemsToCreate = 7            # ISO9660(1)+Joliet(2)+UDF(4) - matchar ESXi-media
    $fsi.VolumeName = $VolumeName

    # EFI-boot: ladda efiboot.img, no-emulation, platform EFI
    $stream = New-Object -ComObject ADODB.Stream
    $stream.Type = 1                        # binart
    $stream.Open()
    $stream.LoadFromFile($efi)
    $boot = New-Object -ComObject IMAPI2FS.BootOptions
    $boot.AssignBootImage($stream)
    $boot.Emulation  = 0                    # FsiEmulationNone
    $boot.PlatformId = 0xEF                 # EFI
    $fsi.BootImageOptions = $boot

    $fsi.Root.AddTree($SourceDir, $false)   # hela tradet inkl. KS.CFG + boot.cfg
    $img = $fsi.CreateResultImage()
    [ISOFile]::Create($OutIso, $img.ImageStream, $img.BlockSize, $img.TotalBlocks)
}

function New-EnvKickstartIso {
    <#  Renderar ks.cfg for en host och byggar en per-host UEFI-ISO dar
        kickstarten lases fran CD:n (ks=cdrom:/KS.CFG). Returnerar ISO-sokvag. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Profile,
        [Parameter(Mandatory)][string]$Fqdn,
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$RootPw,
        [Parameter(Mandatory)][string]$OutIso
    )

    $ks = $script:KsTemplate `
        -replace '{{ROOTPW}}', $RootPw `
        -replace '{{IP}}',     $Ip `
        -replace '{{MASK}}',   $Profile.Netmask `
        -replace '{{GW}}',     $Profile.MgmtGateway `
        -replace '{{DNS}}',    $Profile.DnsServer `
        -replace '{{FQDN}}',   $Fqdn `
        -replace '{{NTP}}',    $Profile.NtpServer

    # vSAN ESA HCL mock-VIB i %firstboot (om konfigurerad), hamtad over HTTP fran depoten
    if ($Profile.MockVibUrl) {
        $ks += @"

# vSAN ESA HCL mock-VIB (nested passerar HCL-checken; NVMe-diskar = flash)
esxcli software acceptance set --level=CommunitySupported
esxcli software vib install -d $($Profile.MockVibUrl)
/etc/init.d/vsanmgmtd restart
"@
    }

    # 1) Extrahera bas-ISO:n till en arbetskatalog
    $stage = Join-Path $Profile.WorkDir ("iso_" + ($Fqdn -replace '\.', '_'))
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage | Out-Null

    $mount = Mount-DiskImage -ImagePath $Profile.BaseIsoPath -PassThru
    $drive = ($mount | Get-Volume).DriveLetter + ':\'
    Copy-Item -Path (Join-Path $drive '*') -Destination $stage -Recurse -Force
    Dismount-DiskImage -ImagePath $Profile.BaseIsoPath | Out-Null

    # 2) Lagg in KS.CFG och peka boot.cfg:s kernelopt pa den (UEFI-vagen)
    $ks | Set-Content -Path (Join-Path $stage 'KS.CFG') -Encoding Ascii
    foreach ($bc in @((Join-Path $stage 'BOOT.CFG'), (Join-Path $stage 'EFI\BOOT\BOOT.CFG'))) {
        if (Test-Path $bc) {
            (Get-Content $bc) -replace '^kernelopt=.*', 'kernelopt=ks=cdrom:/KS.CFG' |
                Set-Content $bc -Encoding Ascii
        }
    }

    # 3) Bygg bootbar UEFI-ISO med inbyggt IMAPI2 (inget oscdimg/ADK)
    New-EsxiBootIso -SourceDir $stage -OutIso $OutIso

    Remove-Item $stage -Recurse -Force
    return $OutIso
}

function Register-EnvDns {
    <#  Skriver A + PTR for hostarna till lab-DC:n. Cloud Builder kraver det. #>
    [CmdletBinding()]
    param([hashtable]$Profile, [hashtable[]]$Hosts)
    foreach ($h in $Hosts) {
        Add-DnsServerResourceRecordA -ComputerName $Profile.DcComputer `
            -ZoneName $Profile.DnsZone -Name $h.ShortName `
            -IPv4Address $h.Ip -CreatePtr -ErrorAction Stop
    }
    Write-Host "DNS: $($Hosts.Count) A+PTR skrivna till $($Profile.DcComputer)"
}

function New-NestedEnv {
    <#
      Spinnar upp ett nested-lab: portgrupp -> per-host kickstart-ISO -> nested
      ESX-VM:er pinnade till en host -> DNS -> must-run-affinitet. Allt taggat
      med labbnamnet for enkel rivning.

      Ex:  New-NestedEnv -Name lab01 -EsxiCount 4 -Size Medium
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateRange(1,32)][int]$EsxiCount = 4,
        [ValidateSet('Small','Medium','Large')][string]$Size = 'Medium',
        [string]$TargetHost,                       # tom = auto-pick minst lastad
        [Parameter(Mandatory)][hashtable]$Profile,
        [string]$RootPw,                           # tom = auto-genereras + returneras
        [string]$FriendlyName,                     # tom = anvand env-namnet ($Name)
        [string]$HostnamePrefix,                   # tom = profilens (esx-mgmt); WLD: 'esx-prod'/'esx-test'
        [int]$StartIp,                             # tom = profilens; WLD: prod 81, test 111
        [switch]$RegisterDns = $true,
        [switch]$PowerOn      = $true
    )

    if (-not $FriendlyName)   { $FriendlyName   = $Name }
    if (-not $HostnamePrefix) { $HostnamePrefix = $Profile.HostnamePrefix }
    if (-not $StartIp)        { $StartIp        = [int]$Profile.MgmtStartIp }
    if ($EsxiCount -lt 4) {
        Write-Warning "En VCF-mgmt-doman behover minst 4 hostar; en WLD racker med 3."
    }
    $spec = $Profile.Sizes[$Size]
    $guestId = $Profile.GuestIdMap[$Profile.EsxiVersion]   # version -> nested-ESXi guest-id
    if (-not $guestId) { throw "Ingen GuestId for EsxiVersion '$($Profile.EsxiVersion)' i GuestIdMap." }
    if (-not $RootPw) { $RootPw = -join ((33..126) | Get-Random -Count 16 | % {[char]$_}) }

    # Valj fysisk host (must-run pinnar hela labbet hit)
    if (-not $TargetHost) {
        $TargetHost = (Get-VMHost | Sort-Object { (Get-VM -Location $_).Count } |
                       Select-Object -First 1).Name
    }
    $vmhost = Get-VMHost -Name $TargetHost -ErrorAction Stop
    $pfx  = $Profile.Prefix                     # tvingande prefix, t.ex. 'nes-'
    $lab  = "$pfx$Name"                          # vCenter-objektnamn -> nes-lab01
    Write-Host "Lab '$Name' (objekt-prefix '$pfx'): $EsxiCount x $Size pa host $TargetHost"

    # Parent-folder for ALLA nested-lab-objekt (strukturell separation fran fysiska labbet)
    $parentName = $Profile.ParentFolder
    $vmroot = Get-Folder vm -ErrorAction Stop
    $parent = Get-Folder -Name $parentName -EA SilentlyContinue
    if (-not $parent) { $parent = New-Folder -Name $parentName -Location $vmroot }

    # Folder + portgrupp for labbet (host-lokal, trunk + MAC learning)
    $folder = Get-Folder -Name $lab -EA SilentlyContinue
    if (-not $folder) { $folder = New-Folder -Name $lab -Location $parent }
    $pgName = "$lab-trunk"
    if (-not (Get-VDPortgroup -Name $pgName -EA SilentlyContinue)) {   # idempotent: delas av mgmt/prod/test i samma pod
        New-EnvPortGroup -VDSwitchName $Profile.VDSwitchName -Name $pgName | Out-Null
    }

    # Berakna per-host-identitet
    $base   = [int]$StartIp
    $prefix = ([ipaddress]($Profile.MgmtCidr.Split('/')[0])).GetAddressBytes()[0..2] -join '.'
    $hosts  = 1..$EsxiCount | ForEach-Object {
        $short = ('{0}{1:D2}' -f $HostnamePrefix, $_)
        [pscustomobject]@{
            ShortName = $short
            Fqdn      = "$short.$($Profile.DomainSuffix)"
            Ip        = "$prefix.$($base + $_ - 1)"
            VmName    = "$lab-$short"
        }
    }

    if ($RegisterDns) {
        Register-EnvDns -Profile $Profile `
            -Hosts ($hosts | ForEach-Object { @{ ShortName=$_.ShortName; Ip=$_.Ip } })
    }

    # Content Library for ISO:erna (vSAN/VCF tillater inte losa filer pa datastore-roten)
    $cl = Get-ContentLibrary -Name $Profile.ContentLibrary -EA SilentlyContinue
    if (-not $cl) {
        $cl = New-ContentLibrary -Name $Profile.ContentLibrary -Datastore (Get-Datastore $Profile.DatastoreName)
    }

    # Deploya varje nested ESX
    foreach ($h in $hosts) {
        $iso = Join-Path $Profile.WorkDir "$($h.VmName).iso"
        New-EnvKickstartIso -Profile $Profile -Fqdn $h.Fqdn -Ip $h.Ip `
            -RootPw $RootPw -OutIso $iso | Out-Null
        # Importera ISO:n som ett Content Library-item (ersatt ev. tidigare med samma namn)
        Get-ContentLibraryItem -ContentLibrary $cl -Name $h.VmName -EA SilentlyContinue |
            Remove-ContentLibraryItem -Confirm:$false -EA SilentlyContinue
        $clIso = New-ContentLibraryItem -ContentLibrary $cl -Name $h.VmName -Files $iso -ItemType iso

        $vm = New-VM -Name $h.VmName -VMHost $vmhost -Datastore $Profile.DatastoreName `
            -DiskGB $spec.BootGB -MemoryGB $spec.MemGB -NumCpu $spec.vCPU `
            -GuestId $guestId -Portgroup (Get-VDPortgroup $pgName) `
            -StoragePolicy (Get-SpbmStoragePolicy $Profile.StoragePolicy) `
            -Location $folder -DiskStorageFormat Thin

        # vSAN-data-diskar pa NVMe-controller -> nested ser dem som flash (ingen SSD-markering)
        Add-EnvNvmeVsanDisks -VM $vm -Spec $spec -StoragePolicy $Profile.StoragePolicy -Datastore $Profile.DatastoreName

        # Exponera hw-virt + koppla per-host-ISO:n
        $vm | New-AdvancedSetting -Name 'featMask.vm.cpuid.VT' -Value 'Val:1' -Confirm:$false -Force | Out-Null
        $vm | Get-CDDrive | Set-CDDrive -ContentLibraryIso $clIso `
            -StartConnected $true -Confirm:$false | Out-Null
        Set-EnvBootOrder -VM $vm      # disk fore CD -> ingen install-loop pa reboot

        # Tagga for rivning
        $vm | New-TagAssignment -Tag (Get-Tag -Name $lab -ErrorAction SilentlyContinue) -ErrorAction SilentlyContinue | Out-Null

        if ($PowerOn) { Start-VM $vm | Out-Null }
    }

    # Must-run-affinitet: hela labbet stannar pa target-hosten
    $group = "$lab-vmgroup"
    $cluster = Get-Cluster -VMHost $vmhost
    if ($g = Get-DrsClusterGroup -Name $group -Cluster $cluster -ErrorAction SilentlyContinue) {
        Set-DrsClusterGroup -DrsClusterGroup $g -VM (Get-VM "$lab-*") -Append -ErrorAction SilentlyContinue | Out-Null
    } else {
        New-DrsClusterGroup -Name $group -VM (Get-VM "$lab-*") -Cluster $cluster -ErrorAction SilentlyContinue | Out-Null
    }
    New-DrsVMHostRule -Name "$lab-mustrun" -Cluster $cluster `
        -VMGroup $group -VMHostGroup (Get-DrsClusterGroup -Type VMHostGroup | Where Name -match $TargetHost | Select -First 1).Name `
        -Type MustRunOn -ErrorAction SilentlyContinue | Out-Null

    # Friendly name pa alla pod-VM:er (guestinfo.envname + vCenter custom attribute).
    # Windows-boxarna (DC/jumphost) laser guestinfo vid boot; namnge dem "$Name-*"
    # sa de kommer med har, annars kor Set-EnvFriendlyName pa dem separat.
    Get-VM "$lab-*" -EA SilentlyContinue | ForEach-Object { Set-EnvFriendlyName -VM $_ -FriendlyName $FriendlyName }

    Write-Host "Lab '$Name' klart. Root-losenord: $RootPw"
    Write-Host "Nasta: lat hostarna installera fardigt, verifiera DNS/NTP/SSH, kor steg 2 (Cloud Builder)."
    return [pscustomobject]@{ Name=$Name; Host=$TargetHost; Hosts=$hosts; RootPw=$RootPw }
}

function Remove-NestedEnv {
    <#  River allt for ett lab: VM:er, affinitetsregler, folder, portgrupp, DNS. #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$Profile,
        [switch]$KeepDns
    )
    $lab = "$($Profile.Prefix)$Name"          # samma prefixade objektnamn som vid deploy
    Get-VM "$lab-*" -ErrorAction SilentlyContinue | ForEach-Object {
        Stop-VM $_ -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        Remove-VM  $_ -DeletePermanently -Confirm:$false
    }
    Get-DrsVMHostRule   -Name "$lab-mustrun" -ErrorAction SilentlyContinue | Remove-DrsVMHostRule   -Confirm:$false
    Get-DrsClusterGroup -Name "$lab-vmgroup" -ErrorAction SilentlyContinue | Remove-DrsClusterGroup -Confirm:$false
    Get-VDPortgroup     -Name "$lab-trunk"   -ErrorAction SilentlyContinue | Remove-VDPortgroup     -Confirm:$false
    Get-Folder          -Name $lab           -ErrorAction SilentlyContinue | Remove-Folder          -Confirm:$false
    # Content Library-items for miljon
    if ($cl = Get-ContentLibrary -Name $Profile.ContentLibrary -EA SilentlyContinue) {
        Get-ContentLibraryItem -ContentLibrary $cl -EA SilentlyContinue |
            Where-Object Name -like "$lab-*" | Remove-ContentLibraryItem -Confirm:$false -EA SilentlyContinue
    }
    # parent-foldern ($Prefix utan '-') lamnas kvar - delas av alla labb
    if (-not $KeepDns) {
        # TODO: ta bort A+PTR fran $Profile.DcComputer for host-prefixen
    }
    Write-Host "Lab '$Name' rivet."
}

function Set-EnvFriendlyName {
    <#  Satter friendly name pa en VM: guestinfo.envname (gasten laser vid boot) +
        custom attribute 'EnvFriendlyName' (syns/redigeras i vCenter).  #>
    param([Parameter(Mandatory)]$VM, [Parameter(Mandatory)][string]$FriendlyName)
    if (-not (Get-CustomAttribute -Name 'EnvFriendlyName' -TargetType VirtualMachine -EA SilentlyContinue)) {
        New-CustomAttribute -Name 'EnvFriendlyName' -TargetType VirtualMachine | Out-Null
    }
    $VM | Set-Annotation -CustomAttribute 'EnvFriendlyName' -Value $FriendlyName | Out-Null
    $VM | New-AdvancedSetting -Name 'guestinfo.envname' -Value $FriendlyName -Confirm:$false -Force | Out-Null
}

function Sync-EnvName {
    <#  Bryggan tagg/namn -> gast: laser VM:ens 'EnvFriendlyName' (annars VM-displaynamnet)
        och skriver det till guestinfo.envname. Kor efter att nagon andrat attributet/namnet
        i vCenter; gasten plockar upp det vid nasta reboot (EnvAD-Identity-task:en laser
        guestinfo varje boot). Kan wire:as till en vCenter power-on-alarm for helautomatik.  #>
    param([Parameter(Mandatory)]$VM)
    $fn = ($VM | Get-Annotation -CustomAttribute 'EnvFriendlyName' -EA SilentlyContinue).Value
    if (-not $fn) { $fn = $VM.Name }
    $VM | New-AdvancedSetting -Name 'guestinfo.envname' -Value $fn -Confirm:$false -Force | Out-Null
    Write-Host "guestinfo.envname pa '$($VM.Name)' -> '$fn'"
}

function Set-EnvBootOrder {
    <#  Satter EFI boot-ordning disk-fore-CD: pa forsta boot ar disken tom (ingen
        boot-entry) sa firmware faller igenom till CD:n och installerar; pa andra
        boot bootar disken. Ingen install-loop, ingen CD-avkoppling behovs.  #>
    param([Parameter(Mandatory)]$VM)
    $VM.ExtensionData.UpdateViewData('Config.Hardware.Device')
    $dev  = $VM.ExtensionData.Config.Hardware.Device
    $scsi = $dev | Where-Object { $_ -is [VMware.Vim.VirtualSCSIController] } | Select-Object -First 1
    $bootDisk = $dev | Where-Object { $_ -is [VMware.Vim.VirtualDisk] -and $_.ControllerKey -eq $scsi.Key } |
                Sort-Object UnitNumber | Select-Object -First 1

    $diskBoot = New-Object VMware.Vim.VirtualMachineBootOptionsBootableDiskDevice
    $diskBoot.DeviceKey = $bootDisk.Key
    $cdBoot   = New-Object VMware.Vim.VirtualMachineBootOptionsBootableCdromDevice

    $opts = New-Object VMware.Vim.VirtualMachineBootOptions
    $opts.BootOrder = @($diskBoot, $cdBoot)
    $cfg = New-Object VMware.Vim.VirtualMachineConfigSpec
    $cfg.BootOptions = $opts
    $VM.ExtensionData.ReconfigVM($cfg)
}

function Add-EnvNvmeVsanDisks {
    <#  Lagger till en NVMe-controller och vSAN-data-diskarna (cache + capacity) pa den,
        sa nested ESXi ser dem som NVMe-flash - da behovs ingen SSD-markering, bara
        HCL-mock-VIB:en. Diskarna far FTT=0-policyn. Gors via API (New-HardDisk kan inte
        satta NVMe-controller).  #>
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)]$Spec,
        [Parameter(Mandatory)][string]$StoragePolicy,
        [Parameter(Mandatory)][string]$Datastore
    )
    $policy = Get-SpbmStoragePolicy $StoragePolicy -ErrorAction Stop
    $pspec  = New-Object VMware.Vim.VirtualMachineDefinedProfileSpec
    $pspec.profileId = $policy.Id

    $cfg = New-Object VMware.Vim.VirtualMachineConfigSpec
    $changes = @()

    # NVMe-controller (nyckel -100)
    $ctrl = New-Object VMware.Vim.VirtualDeviceConfigSpec
    $ctrl.operation = 'add'
    $nvme = New-Object VMware.Vim.VirtualNVMEController
    $nvme.key = -100; $nvme.busNumber = 0
    $ctrl.device = $nvme
    $changes += $ctrl

    # Diskstorlekar: cache (om >0) + N capacity
    $sizes = @()
    if ($Spec.CacheGB -gt 0) { $sizes += [int]$Spec.CacheGB }
    for ($n = 1; $n -le [int]$Spec.CapDisks; $n++) { $sizes += [int]$Spec.CapGB }

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
        $d.device  = $disk
        $d.profile = @($pspec)
        $changes += $d
        $unit++
    }

    $cfg.deviceChange = $changes
    $VM.ExtensionData.ReconfigVM($cfg)
}

Export-ModuleMember -Function New-NestedEnv, Remove-NestedEnv, New-EnvPortGroup, Set-VDSwitchMtu, `
    Register-EnvDns, Set-EnvFriendlyName, Sync-EnvName, New-EnvKickstartIso
