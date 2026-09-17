#
# Modulmanifest for NestedEnv
# Skapa/uppdatera annars med:  New-ModuleManifest / Update-ModuleManifest
#
# Installeras genom att lagga filerna i en mapp som heter NestedEnv/ pa en
# modulsokvag ($env:PSModulePath), t.ex.:
#   NestedEnv\NestedEnv.psd1   (denna)
#   NestedEnv\NestedEnv.psm1
#   NestedEnv\New-EnvPortGroup.ps1
# Sen racker:  Import-Module NestedEnv
#
@{
    RootModule        = 'NestedEnv.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '3123bcbf-b944-4f96-a15d-9edb5a56ee97'
    Author            = 'Magnus Andersson'
    CompanyName       = 'Skatteverket'
    Copyright         = '(c) Skatteverket. Internt bruk.'
    Description       = 'Spinn upp / riv nested-ESXi referensmiljoer (env) i en VCF Workload Domain - steg 1 (kickstart-ISO, DNS, friendly name), fore Cloud Builder-bringup.'

    # 5.1 som golv sa modulen laddar pa nuvarande jumphost. Loadern i .psm1 varnar
    # nar den kor pa 5.1 (deprecerat i VCF PowerCLI 9.x) - hoj till 7.4 nar ni gar dit.
    PowerShellVersion = '5.1'

    # PowerCLI deklareras MEDVETET INTE i RequiredModules: manifestet kan bara krava
    # ETT modulnamn/EN version, vilket skulle bryta stodet for bade VCF.PowerCLI och
    # VMware.PowerCLI. NestedEnv.psm1:s loader valjer den som finns vid import istallet.
    # RequiredModules = @()

    FunctionsToExport = @(
        'New-NestedEnv'        # spinn upp en miljo (N nested ESX, DNS, friendly name)
        'Remove-NestedEnv'     # riv en miljo (VM:er, regler, folder, portgrupp)
        'New-EnvPortGroup'     # engangs: trunkad dvportgroup + MAC learning
        'Set-VDSwitchMtu'      # engangs: jumbo-MTU pa den unmanaged vDS:en
        'Register-EnvDns'      # A+PTR till lab-DC:n for en uppsattning hostar
        'Set-EnvFriendlyName'  # stampa friendly name (guestinfo + custom attribute)
        'Sync-EnvName'         # brygga: tagg/namn i vCenter -> guestinfo.envname
        'New-EnvKickstartIso'  # helper (per-host kickstart-ISO) - kan gommas vid behov
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('VCF','vSphere','PowerCLI','nested','ESXi','lab','VCF52','VCF9')
            ReleaseNotes = '1.0.0 - kickstart-deploy, host-lokal trunk + MAC learning, FTT0, must-run-affinitet, friendly name via guestinfo, versionsneutral PowerCLI-loader, GuestIdMap per ESXi-version.'
        }
    }
}
