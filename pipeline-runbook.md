# Nested VCF — pipeline (steg-läge)

Löst kopplade steg. Varje steg är ett fristående script eller en manuell åtgärd du kör i ordning från **AD** eller **jump** — ingen monolitisk orkestrerare. Du kan stanna, inspektera och köra om mellan steg, och byta/lägga till steg när 5.2→9.1 kommer. Kickstart-automationen är **pausad** — ESX byggs halvmanuellt.

## Översikt

| # | Steg | Körs från | Hur | Frekvens |
|---|---|---|---|---|
| 0 | Fysisk host-prep + unmanaged vDS (0 uplinks, MTU 9000) | jump → WLD-vCenter | `0-New-EnvVDSwitch.ps1` + fysisk checklista | en gång (+ nya hostar) |
| 1 | Golden-AD-template | färsk Win2025-VM | `1-Initialize-EnvAD.ps1` → stäng av → klona mall | **var ~90 dag** |
| 2 | Nested trunk-portgroup | jump | `New-EnvPortGroup` | per pod |
| 3 | Deploy AD (klon) + identitet | vCenter + gäst | klona golden-mallen → starta → `Set-EnvIdentity` | per pod |
| 4 | Deploy N ESX (halvmanuellt) | jump + konsol | `4a-New-EsxiLabVM.ps1` → installera för hand → `4b-Set-EsxiHostBaseline.ps1` | per host-grupp |
| 5 | Verifiera hostar redo | jump | `5-Test-EnvReadiness.ps1` | före varje bringup/WLD |
| 6 | Prep Cloud Builder-spec | jump/manuell | fyll CB Excel/JSON från DNS/IP-planen | per mgmt-bringup |
| 7 | Cloud Builder bringup → mgmt-domän | Cloud Builder | CB kör: vcenter-mgmt, nsx-mgmt×3+vip, sddc | per pod |
| 8 | Stämpla identitet på mgmt-lagret | jump | SSO login-titel (manuell) + `Set-EnvFriendlyName`/guestinfo | efter bringup |
| 9 | Deploy WLD (Prod/Test) | jump → SDDC Manager | steg 4+5 för WLD-hostar, sen WLD-JSON via PowerVCF/API | per WLD |

## Detaljer per steg

**0 — Fysisk prep + vDS.** Fysiska VCF-hosten klar (VCF 5.2/ESXi 8 igång). Kör `New-EnvVDSwitch -Name nes-vds -Datacenter <dc> -VMHost phys01[,…] -Mtu 9000`. Skapar din egna unmanaged vDS utan uplinks (host-lokal), skild från SDDC Managers managed vDS.

**1 — Golden-AD (var ~90 dag).** På en ren Win2025-VM: `1-Initialize-EnvAD.ps1` (IP/rename → forest → DNS/NTP/CA `Infra-Root-CA`/lokal CDP/depot/pki). Stäng av, klona som mall. 90-dagarscykeln håller mallen patchad och färsk. Client-AD (`corp.test`, `Corp-Root-CA`) byggs med samma script + roll-parameter (fas 3).

**2 — Portgroup.** `New-EnvPortGroup -VDSwitchName nes-vds -Name nes-<pod>-trunk` (trunk + MAC learning, host-lokal).

**3 — Deploy AD.** Klona golden-mallen till podden (manuell vCenter-klon i steg-läge), lägg på trunk-portgruppen, starta. Sätt `guestinfo.envname` och kör `Set-EnvIdentity` för friendly name (prompt/banner/desktop). Gateway = DC (.10).

**4 — Deploy ESX (halvmanuellt).** Per host-grupp: `New-EsxiLabVM` (skapar VM, NVMe-diskar, monterar stock-ISO) → **installera ESXi för hand** på defaults, sätt IP i DCUI → `Set-EsxiHostBaseline` (SSH/NTP/DNS/vhv, ev. mock-VIB). Körs om per grupp: **mgmt (6, esx-mgmt01-06)**, **prod (3, esx-prod01-03)**, **test (3, esx-test01-03)**.

**5 — Verifiera.** `Test-EnvReadiness -Hosts <lista> -Dns 192.168.0.10` → grön/röd på DNS fwd+rev, NTP, SSH, diskantal, ev. VIB. Grinden före varje bringup/WLD.

**6 — CB-spec.** Fyll Cloud Builders deployment-workbook (Excel/JSON) från DNS/IP-planen — mgmt-hostar, vcenter-mgmt, sddc, nsx-mgmt×3+vip, nät. Namnen MÅSTE matcha DNS exakt.

**7 — Bringup.** Kör Cloud Builder → mgmt-domänen reser sig (vcenter-mgmt, nsx-kluster, sddc). Cloud Builder pingar mgmt-gw = DC (.10, svarar).

**8 — Identitet mgmt-lager.** SSO login-titel på vcenter-mgmt (manuell, Administration → SSO → Login Message, titel utan consent) + `Set-EnvFriendlyName`/`Sync-EnvName` för guestinfo-stämpel (vilken pod). Datacenter-namnet sattes redan i CB-specen.

**9 — WLD.** Bygg WLD-hostarna (steg 4+5 med `esx-prod*`/`esx-test*`), sen skapa WLD:n i SDDC Manager via **JSON-spec** (PowerVCF / SDDC Manager-API). Eget NSX per WLD (prod/test). Fas 3 (workload/NSX) och fas 4 (VKS/AI/DBaaS) ligger ovanpå detta.

## Identitet — per lager (inte ett steg)

- **DC / jumphost** (Windows): `Set-EnvIdentity` vid klon (steg 3), läser `guestinfo.envname`.
- **mgmt/WLD-appliances** (Photon): SSO-titel + guestinfo-stämpel (steg 8) — de kör inte `Set-EnvIdentity`.
- **nes-** prefix + folder på vCenter-objekt sätts vid deploy.

## Swap-points inför 5.2 → 9.1

Löst kopplat = du byter enskilda steg utan att röra resten:

- **Steg 0/1/2/3:** oförändrade (vDS, golden-AD, portgroup, AD-klon).
- **Steg 4:** byt `EsxiVersion`/ISO/`GuestId` till ESXi 9 (profil-styrt).
- **Steg 6/7:** VCF 9-installern istället för 5.2 Cloud Builder.
- **Nytt steg 7b:** VCF Fleet / Operations-onboarding (nytt i 9.x) — läggs in som eget steg.
- **Steg 9:** WLD via uppdaterat SDDC/Fleet-API.

Poängen: nya fleet-tjänster i 9.1 blir **nya rader i tabellen**, inte en omskrivning.

## Filer per steg

- Steg 0: `0-New-EnvVDSwitch.ps1`
- Steg 1: `1-Initialize-EnvAD.ps1` (+ `3-Set-EnvIdentity.ps1`)
- Steg 2: `2-New-EnvPortGroup.ps1`
- Steg 4: `4a-New-EsxiLabVM.ps1`, `4b-Set-EsxiHostBaseline.ps1`  (se `steglaget-esxi.md`)
- Steg 5: `5-Test-EnvReadiness.ps1`
- Steg 8/9: `NestedEnv.psm1` (`Set-EnvFriendlyName`/`Sync-EnvName`), PowerVCF för WLD
- Fas 3/4: `fas3-workload-nsx-design.md`
