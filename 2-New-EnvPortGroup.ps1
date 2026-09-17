<#
    2-New-EnvPortGroup.ps1
    Nested-ESXi lab networking helpers for PowerCLI
    ------------------------------------------------
    - Set-VDSwitchMtu        : sätter MTU (jumbo) på en vDS via API
    - New-EnvPortGroup : skapar en trunkad dvportgroup med native MAC learning
                               + forged transmits (promiscuous AV) — allt i ett reconfigure

    Krav:
      * PowerCLI: VCF.PowerCLI (PS 7.4+) eller VMware.PowerCLI 13.x (PS 5.1/7).
                  NestedEnv.psm1 laddar ratt modul; vid fristaende korning importera sjalv.
      * vDS version 6.6+ (native MAC learning kräver 6.7-serien / dvfilter)
      * Anslut först:  Connect-VIServer <vcenter-eller-host>

    OBS: MAC learning-policyn finns inte i Set-VDPortgroup, därför API-vägen nedan.
#>

function Set-VDSwitchMtu {
    <#
        Sätter MaxMtu på en vDS. Yttre laget MÅSTE vara >= största inre MTU,
        annars svartshålar NSX-overlay (Geneve/TEP) och vSAN-jumbo.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VDSwitchName,
        [int]$Mtu = 9000
    )

    $vds  = Get-VDSwitch -Name $VDSwitchName -ErrorAction Stop
    $spec = New-Object VMware.Vim.VMwareDVSConfigSpec
    $spec.ConfigVersion = $vds.ExtensionData.Config.ConfigVersion
    $spec.MaxMtu        = $Mtu

    $task = $vds.ExtensionData.ReconfigureDvs_Task($spec)
    Write-Host "vDS '$VDSwitchName' MTU -> $Mtu (task $task)"
}

function New-EnvPortGroup {
    <#
        Skapar en dvportgroup avsedd att bära ALL nested-trafik för ett lab:
        trunk (default 0-4094) så mgmt/vMotion/vSAN/TEP kan separeras på VLAN
        inne i nested-miljön, med MAC learning + forged transmits påslaget.

        Exempel:
          New-EnvPortGroup -VDSwitchName 'vds-lab' -Name 'Lab01-Trunk'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VDSwitchName,
        [Parameter(Mandatory)][string]$Name,
        [int]$VlanStart = 0,
        [int]$VlanEnd   = 4094,
        [int]$NumPorts  = 128,
        [int]$MacLimit  = 4096
    )

    $vds = Get-VDSwitch -Name $VDSwitchName -ErrorAction Stop

    # 1) Skapa portgruppen (static binding). VLAN/MAC-policy sätts i steg 2.
    $pg = New-VDPortgroup -VDSwitch $vds -Name $Name -NumPorts $NumPorts -ErrorAction Stop

    # 2) Bygg port-settingen
    $portSetting = New-Object VMware.Vim.VMwareDVSPortSetting

    # --- VLAN trunk-range ---
    $trunk = New-Object VMware.Vim.VmwareDistributedVirtualSwitchTrunkVlanSpec
    $range = New-Object VMware.Vim.NumericRange
    $range.Start   = $VlanStart
    $range.End     = $VlanEnd
    $trunk.VlanId  = @($range)
    $trunk.Inherited = $false
    $portSetting.Vlan = $trunk

    # --- MAC management: promiscuous AV, forged transmits PÅ ---
    $macMgmt = New-Object VMware.Vim.DVSMacManagementPolicy
    $macMgmt.AllowPromiscuous = $false   # vi använder MAC learning istället
    $macMgmt.ForgedTransmits  = $true    # KRÄVS för utgående nested-trafik
    $macMgmt.MacChanges       = $false   # behövs normalt inte när forged=on

    # --- Native MAC learning ---
    $macLearn = New-Object VMware.Vim.DVSMacLearningPolicy
    $macLearn.Enabled              = $true
    $macLearn.AllowUnicastFlooding = $true     # okänd unicast tills MAC lärts in
    $macLearn.Limit                = $MacLimit  # tak för inlärda MAC per port
    $macLearn.LimitPolicy          = 'DROP'     # 'DROP' vid tak (alt. 'ALLOW')
    $macMgmt.MacLearningPolicy = $macLearn

    $portSetting.MacManagementPolicy = $macMgmt

    # 3) Reconfigure portgruppen med specen ovan
    $spec = New-Object VMware.Vim.DVPortgroupConfigSpec
    $spec.ConfigVersion     = $pg.ExtensionData.Config.ConfigVersion
    $spec.DefaultPortConfig = $portSetting

    $pg.ExtensionData.ReconfigureDVPortgroup_Task($spec) | Out-Null

    Write-Host ("Portgroup '{0}' klar pa '{1}' — trunk {2}-{3}, MAC learning ON, forged transmits ON, promiscuous OFF." `
        -f $Name, $VDSwitchName, $VlanStart, $VlanEnd)

    return Get-VDPortgroup -Name $Name -VDSwitch $vds
}

# ------------------------------------------------------------------
# Exempel: sätt jumbo på vDS:en och skapa en trunk-PG per lab
# ------------------------------------------------------------------
# Connect-VIServer vcenter.infra.test
#
# Set-VDSwitchMtu -VDSwitchName 'vds-lab' -Mtu 9000
#
# 1..4 | ForEach-Object {
#     New-EnvPortGroup -VDSwitchName 'vds-lab' -Name ("Lab{0:D2}-Trunk" -f $_)
# }
