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

Alla stegscript läser sitt slice ur `env-config.psd1` via `Get-EnvConfig.ps1` (dot-source:as automatiskt). Namn följer configen: `prefix` + `friendlyName` → `nes-aurora-*`.

**0 — Fysisk prep + vDS.** Fysiska VCF-hosten klar (VCF 5.2/ESXi 8 igång). Kör `.\0-New-EnvVDSwitch.ps1 -FromConfig`. Läser `physicalEnv.vdSwitch/datacenter/physicalHosts` + max VLAN-MTU (9000). Skapar din egna unmanaged vDS utan uplinks (host-lokal), skild från SDDC Managers managed vDS.

**1 — Golden-AD (var ~90 dag).** På en ren Win2025-VM: `.\1-Initialize-EnvAD.ps1 -Role infra` (IP/rename → forest → DNS/NTP/CA/lokal CDP/depot/pki). Domän/NetBIOS/CA-namn/DNS/depot hämtas ur `adForest.infra` + `depot`. Stäng av, klona som mall. Client-AD byggs med samma script: `-Role corp` (`corp.test`, `Corp-Root-CA`). `-Role`/`-ConfigPath` persisteras i `params.json` så de överlever reboot:arna.

**2 — Portgroup.** `.\2-New-EnvPortGroup.ps1 -FromConfig` (sätter jumbo på vDS:en + skapar `nes-aurora-trunk` med MAC learning, host-lokal).

**3 — Deploy AD.** Klona golden-mallen till env:et (manuell vCenter-klon i steg-läge), lägg på trunk-portgruppen, starta. Sätt `guestinfo.envname` och kör `.\3-Set-EnvIdentity.ps1` för friendly name (prompt/banner/desktop). Namn: `-Name` > `guestinfo.envname` > `nestedEnv.friendlyName` (config). Gateway = DC (.10).

**4 — Deploy ESX (halvmanuellt).** Per host-grupp: `.\4a-New-EsxiLabVM.ps1 -Group mgmt -VMHost phys01 -PowerOn` (skapar VM:er `nes-aurora-esx-mgmt01…`, NVMe-diskar, stock-ISO ur configen) → **installera ESXi för hand** på defaults, sätt IP i DCUI → `.\4b-Set-EsxiHostBaseline.ps1 -Group mgmt` (SSH/NTP/DNS/vhv, mock-VIB om `vsanMode=ESA`). Körs om per grupp: **mgmt (6)**, **prod (3)**, **test (3)**.

**5 — Verifiera.** `.\5-Test-EnvReadiness.ps1 -Group mgmt` → grön/röd på DNS fwd+rev, NTP, SSH, diskantal, ev. VIB. Host-lista/DNS/förväntat diskantal ur configen. Grinden före varje bringup/WLD.

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

- Gemensamt: `env-config.psd1` (källa), `Get-EnvConfig.ps1` (laddare + `Test-EnvConfig`/`Sync-EnvHostDns`), `env-config-viewer.html` (read-only vy)
- Steg 0: `0-New-EnvVDSwitch.ps1 -FromConfig`
- Steg 1: `1-Initialize-EnvAD.ps1 -Role infra|corp` (+ `3-Set-EnvIdentity.ps1`)
- Steg 2: `2-New-EnvPortGroup.ps1 -FromConfig`
- Steg 4: `4a-New-EsxiLabVM.ps1 -Group <g> -VMHost <h>`, `4b-Set-EsxiHostBaseline.ps1 -Group <g>`  (se `steglaget-esxi.md`)
- Steg 5: `5-Test-EnvReadiness.ps1 -Group <g>`
- Steg 8/9: `NestedEnv.psm1` (`Set-EnvFriendlyName`/`Sync-EnvName`), PowerVCF för WLD
- Fas 3/4: `fas3-workload-nsx-design.md`
