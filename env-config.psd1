@{
    # env-config.psd1 - KANONISK sanningskalla for hela nested-VCF-pipelinen.
    #
    # Detta ar en PowerShell Data File (.psd1): ren deklarativ hashtabell, ingen kod kors
    # (lases med Import-PowerShellDataFile). Redigera fritt i VS Code med full PS-tooling,
    # kommentarer och kommatecken - inga JSON-fallgropar. Get-EnvConfig laser denna
    # direkt; JSON finns kvar som utbytesformat mot HTML-vyn (Export-EnvConfigJson).

    schema = 'env-config v1 (psd1) - gemensam kalla for nested-VCF-pipelinen'

    nestedEnv = @{
        # friendlyName ar bade lasbar etikett OCH stammen i vCenter-objektnamnen:
        #   slug   = friendlyName gemener + slugifierat  -> 'aurora'
        #   stem   = prefix + slug                        -> 'nes-aurora'
        #   VM     = stem + '-' + hostShort               -> 'nes-aurora-esx-mgmt01'
        # (Get-EnvConfig: $cfg.EnvSlug()/$cfg.EnvStem()/$cfg.VmName('esx-mgmt01'))
        friendlyName = 'Aurora'
        prefix       = 'nes-'      # tvingande prefix pa ALLA vCenter-objekt
        parentFolder = 'nested'    # gemensam parent-folder for alla env
    }

    physicalEnv = @{
        wldVCenter    = 'vcenter-wld.fabric'
        datacenter    = 'DC-WLD'
        physicalHosts = @('phys01','phys02','phys03')   # affinity: en env per host
        vdSwitch      = 'nes-vds'                        # unmanaged, 0 uplinks
        datastore     = 'wld-vsan'
        storagePolicy = 'Env-FTT0-Thin'
        contentLibrary= 'nes-iso'
        baseIso       = 'ESXi-8.0U3'
        esxiVersion   = '8'                              # byt till '9' for VCF 9.1
        guestIdMap    = @{ '8' = 'vmkernel8Guest'; '9' = 'vmkernel9Guest' }
        mockVibUrl    = 'http://depot.infra.test/vibs/nested-vsan-esa-mock-hw_7x8x.zip'
    }

    network = @{
        mgmt = @{
            subnet      = '192.168.0.0/24'
            gateway     = '192.168.0.10'                 # = DC:n, svarar pa ping for Cloud Builder
            netmask     = '255.255.255.0'
            reverseZone = '0.168.192.in-addr.arpa'
            mtu         = 1500
        }
        # VLAN/transport - pooler = sista-oktett-intervall per host-grupp
        vlans = @{
            vmotion = @{ id = 20; subnet = '192.168.20.0/24'; mtu = 9000; pools = @{ mgmt = '11-30'; prod = '31-50'; test = '51-70' } }
            vsan    = @{ id = 30; subnet = '192.168.30.0/24'; mtu = 9000; pools = @{ mgmt = '11-30'; prod = '31-50'; test = '51-70' } }
            hostTep = @{ id = 40; subnet = '192.168.40.0/24'; mtu = 9000; pools = @{ mgmt = '11-40'; prod = '41-70'; test = '71-100' } }
            edgeTep = @{ id = 50; subnet = '192.168.50.0/24'; mtu = 9000; pools = @{ prod = '11-30'; test = '31-50' } }
        }
        overlay = @{ supernet = '172.16.0.0/12'; prod = '172.16.0.0/16'; test = '172.17.0.0/16' }
    }

    adForest = @{
        # dcHostname = DC:ns korta namn (blir dcHostname.domain). subnet/reverseZone = DC:ns
        # eget nat (infra sitter pa mgmt-planet; corp lever i overlay).
        infra = @{
            role = 'infra'; domain = 'infra.test'; netbios = 'INFRA'; dcHostname = 'dc'; dcIp = '192.168.0.10'
            subnet = '192.168.0.0/24'; reverseZone = '0.168.192.in-addr.arpa'   # = network.mgmt (DC pa mgmt-planet)
            caName = 'Infra-Root-CA'; caValidityYrs = 20; pkiHostname = 'pki'
            ntpServer = '192.168.0.10'; dnsServer = '192.168.0.10'
        }
        corp = @{
            role = 'client'; domain = 'corp.test'; netbios = 'CORP'; dcHostname = 'dc'; dcIp = '172.16.1.10'
            subnet = '172.16.1.0/24'; reverseZone = '1.16.172.in-addr.arpa'
            caName = 'Corp-Root-CA'; caValidityYrs = 20; pkiHostname = 'pki'
            ntpServer = '172.16.1.10'; dnsServer = '172.16.1.10'
        }
    }

    depot = @{
        root = 'C:\depot'; fqdn = 'depot'; httpsPort = 443; certMode = 'CA'
        mimeExts = @('.sig','.vib','.manifest','.json','.xml','.zip','.gz','.cfg')
    }

    hostGroups = @{
        mgmt = @{ prefix = 'esx-mgmt'; count = 6; startIp = 51;  size = 'Medium'; vsanMode = 'ESA' }
        prod = @{ prefix = 'esx-prod'; count = 3; startIp = 81;  size = 'Medium'; vsanMode = 'ESA' }
        test = @{ prefix = 'esx-test'; count = 3; startIp = 111; size = 'Medium'; vsanMode = 'ESA' }
    }

    hostSizes = @{
        Small  = @{ vCPU = 8;  memGB = 24; bootGB = 32; cacheGB = 0;   capGB = 0;   capDisks = 0 }
        Medium = @{ vCPU = 8;  memGB = 48; bootGB = 32; cacheGB = 80;  capGB = 200; capDisks = 1 }
        Large  = @{ vCPU = 12; memGB = 96; bootGB = 32; cacheGB = 120; capGB = 400; capDisks = 2 }
    }

    # DNS-poster. Namnen MASTE matcha Cloud Builder-specen exakt.
    # esx-*-raderna kan regenereras ur hostGroups med Sync-EnvHostDns.
    dns = @(
        @{ name = 'gw';           ip = '192.168.0.10';  zone = 'infra' }
        @{ name = 'dc';           ip = '192.168.0.10';  zone = 'infra' }
        @{ name = 'pki';          ip = '192.168.0.10';  zone = 'infra' }
        @{ name = 'depot';        ip = '192.168.0.10';  zone = 'infra' }
        @{ name = 'ntp';          ip = '192.168.0.10';  zone = 'infra' }
        @{ name = 'jump';         ip = '192.168.0.11';  zone = 'infra' }
        @{ name = 'cb';           ip = '192.168.0.20';  zone = 'infra' }
        @{ name = 'vcenter-mgmt'; ip = '192.168.0.30';  zone = 'infra' }
        @{ name = 'sddc';         ip = '192.168.0.31';  zone = 'infra' }
        @{ name = 'nsx-mgmt-vip'; ip = '192.168.0.40';  zone = 'infra' }
        @{ name = 'nsx-mgmt01';   ip = '192.168.0.41';  zone = 'infra' }
        @{ name = 'nsx-mgmt02';   ip = '192.168.0.42';  zone = 'infra' }
        @{ name = 'nsx-mgmt03';   ip = '192.168.0.43';  zone = 'infra' }
        @{ name = 'esx-mgmt01';   ip = '192.168.0.51';  zone = 'infra' }
        @{ name = 'esx-mgmt02';   ip = '192.168.0.52';  zone = 'infra' }
        @{ name = 'esx-mgmt03';   ip = '192.168.0.53';  zone = 'infra' }
        @{ name = 'esx-mgmt04';   ip = '192.168.0.54';  zone = 'infra' }
        @{ name = 'esx-mgmt05';   ip = '192.168.0.55';  zone = 'infra' }
        @{ name = 'esx-mgmt06';   ip = '192.168.0.56';  zone = 'infra' }
        @{ name = 'vcenter-prod'; ip = '192.168.0.60';  zone = 'infra' }
        @{ name = 'nsx-prod-vip'; ip = '192.168.0.70';  zone = 'infra' }
        @{ name = 'nsx-prod01';   ip = '192.168.0.71';  zone = 'infra' }
        @{ name = 'nsx-prod02';   ip = '192.168.0.72';  zone = 'infra' }
        @{ name = 'nsx-prod03';   ip = '192.168.0.73';  zone = 'infra' }
        @{ name = 'esx-prod01';   ip = '192.168.0.81';  zone = 'infra' }
        @{ name = 'esx-prod02';   ip = '192.168.0.82';  zone = 'infra' }
        @{ name = 'esx-prod03';   ip = '192.168.0.83';  zone = 'infra' }
        @{ name = 'vcenter-test'; ip = '192.168.0.90';  zone = 'infra' }
        @{ name = 'nsx-test-vip'; ip = '192.168.0.100'; zone = 'infra' }
        @{ name = 'nsx-test01';   ip = '192.168.0.101'; zone = 'infra' }
        @{ name = 'nsx-test02';   ip = '192.168.0.102'; zone = 'infra' }
        @{ name = 'nsx-test03';   ip = '192.168.0.103'; zone = 'infra' }
        @{ name = 'esx-test01';   ip = '192.168.0.111'; zone = 'infra' }
        @{ name = 'esx-test02';   ip = '192.168.0.112'; zone = 'infra' }
        @{ name = 'esx-test03';   ip = '192.168.0.113'; zone = 'infra' }
    )
}
