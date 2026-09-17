# Fas 3 — Workload- & NSX-referenskonfig (design)

Utkast att spika innan kod. Fas 3 ligger ovanpå en färdig WLD (efter steg 1 = bygg hostar, steg 2 = Cloud Builder/SDDC bringup). Målet: en **självinnesluten overlay-demo** — klient + 3-tier-app + egen identitet — som visar NSX overlay och distribuerad brandvägg (DFW), **utan att röra mgmt-nätet och utan internet**.

## Grundprinciper

- **Allt öst-väst under en T1.** Klient, identitet och app-tier ligger på overlay-segment under samma Tier-1-gateway. Trafiken routas av T1 inne i NSX — **ingen Edge/T0 behövs** för demon.
- **Två separata AD:n, två roller.** Infra-identitet och workload-identitet blandas inte.
- **Ingen overlay↔mgmt-routing.** Admin driver klienten via **VM-konsolen** (mgmt-sidans vCenter), inte via nätet. Overlay förblir isolerat.
- **Per WLD.** Prod och Test har separat NSX, så topologin byggs en gång per WLD med egna subnät.
- **Air-gap-PKI.** Ingen internet → varje CA:s CDP/AIA måste peka lokalt. Både infra-DC (`pki.infra.test`) och corp-DC (`pki.corp.test`) hostar sin egen CDP; annars timeoutar cert-validering/TLS när en klient söker CRL/AIA mot ett internet som inte finns.

## De två AD-rollerna

| Roll | Var | Domän (förslag) | Betjänar |
|---|---|---|---|
| **infra-AD** | mgmt (192.168.0.10) | `infra.test` | Plattformen: DNS/NTP för ESXi/vCenter/SDDC/NSX, CA/PKI för VCF, offline-depot |
| **client-AD** | overlay (`seg-identity`) | `corp.test` (egen forest) | Workload: **AD + DNS + NTP + CA** (`Corp-Root-CA`). Klienten domänjoinar, DNS för app-tiern (web/api/db), egen PKI |

client-AD är en **egen forest utan trust** mot infra-AD → ingen replikering, ingen routing mellan dem. Bygger du workload-demon i både Prod och Test blir varje WLD:s client-AD en **egen isolerad `corp.test`-forest** — identiskt namn är ok just för att de aldrig ser varandra (samma logik som identiska pod-namn).

### Forest-design (låst)

Två **skilda forest-rötter**, inte sub-labels av en delad förälder och inte en flat domän med två DC:er:

- infra-AD rot: `infra.test`  → `dc.infra.test` osv.
- client-AD rot: `corp.test`   → `dc.corp.test`, `web.corp.test` osv.

Varför inte alternativen:
- `corp.infra.test` (sub-label) *ser ut* som en child-domän under `infra.test` → antyder en gemensam forest med trust/replikering → skulle kräva overlay↔mgmt-koppling. Undvik.
- En flat `infra.test` med `dc-infra`/`dc-corp` = **en** domän, två DC:er som replikerar → kräver koppling → ingen separation. Undvik.

Självdokumentationen ligger i **suffixet** (`infra` vs `corp`), så hostnamnen hålls korta (`dc`, `web`) utan roll-prefix. "Nested" = hur hela labbet körs; realm-namnet = vilket identitetsrike. Behöver de två rikena någonsin prata (t.ex. delad tjänst) läggs en **explicit forest-trust** mellan rötterna senare — kontrollerat, inte implicit.

Långsiktigt (VKS, Private AI Services, DBaaS): de är tjänster i workload-planet och konsumeras av end-usern i `corp.test`; infra-identiteten (`infra.test`) driver plattformen. Två rena riken som var för sig kan växa.

Bygget återanvänder golden-AD-mallen (`Initialize-EnvAD`) med en **roll-parameter** (`infra` / `client`): båda rollerna bygger **AD + DNS + NTP + CA + lokal CDP/AIA** (`pki.infra.test` resp. `pki.corp.test`). client-rollen hoppar bara de VCF-specifika bitarna (offline-depot, ESXi/vCenter/NSX-DNS-poster), kör på overlay-IP och sätter `Corp-Root-CA`. Den lokala CDP:n är inte valfri — utan den timeoutar corp-certen vid revocation-check.

## Nätverkstopologi (per WLD)

Alla segment är overlay, hänger på **en T1**, T1 är default-gateway (`.1`) för varje segment. Overlay-rymden är **172.16.0.0/12** (172.16.0.0–172.31.255.255); varje segment är ett `/24` ur den. Prod använder `172.16.x`, Test `172.17.x` — båda inom /12, med gott om plats för fler WLD/segment (`172.18.x` …).

| Segment | Subnät (Prod / Test) | GW | Innehåll |
|---|---|---|---|
| `seg-identity` | 172.16.1.0/24 / 172.17.1.0/24 | .1 | client-DC (DNS + domän) |
| `seg-office`   | 172.16.2.0/24 / 172.17.2.0/24 | .1 | Windows-klient (domänjoinad) |
| `seg-web`      | 172.16.10.0/24 / 172.17.10.0/24 | .1 | web-VM |
| `seg-api`      | 172.16.20.0/24 / 172.17.20.0/24 | .1 | api-VM |
| `seg-db`       | 172.16.30.0/24 / 172.17.30.0/24 | .1 | db-VM |

- **T1** ensam räcker (öst-väst). **T0/Edge** införs bara om du senare vill nå overlay från jumphosten eller köra forest-trust mot infra-AD.
- **MTU:** overlay-i-overlay — yttre trunk 9000 (redan satt), nested TEP 1600. Utan det svartshålar overlay.
- DNS: app-tiern och klienten pekar på **client-DC** (`seg-identity`), inte på infra-AD.

## DNS-namnrymder (ingen krock)

Två skilda DNS-zoner i två skilda forests och nät — de kan aldrig kollidera:

| Zon | Nät | Innehåller |
|---|---|---|
| `infra.test` (infra-AD) | mgmt 192.168.0.0/24 | dc, pki, depot, ntp, **jump**, cb, vcenter-mgmt, sddc, nsx-*, esx-* |
| `corp.test` (client-AD) | overlay 172.16/17.x | client-dc, client-win, web, api, db |

- Suffixet disambiguerar: `dc.infra.test` ≠ `dc.corp.test`. **Infra-listan döps inte om.**
- **`jump` = infra-/admin-box** på mgmt (PowerCLI, administrerar plattformen) — den är INTE office-klienten och stannar i infra-AD.
- **`client-win`** = office-klient-simulatorn på `seg-office` i client-AD — en egen, ny VM, inte en omdöpt `jump`.
- (Vill du ha en admin-/jumphost även i overlay för att sköta workload-världen utan konsol — lägg den i client-AD senare. Valfritt.)

## VM:er

| VM | Segment | OS | Roll |
|---|---|---|---|
| `client-dc` | seg-identity | Windows | client-AD DC + DNS (egen forest) |
| `client-win` | seg-office | Windows | simulerad klient, domänjoinad, surfar till web |
| `web` | seg-web | valfritt | frontend |
| `api` | seg-api | valfritt | mellanlager |
| `db` | seg-db | valfritt | databas |

Klienten **och hela app-tiern (web/api/db)** domänjoinar client-AD (`corp.test`) → riktig DNS/auth, helt inom overlay, ingen hosts-fil. Därför måste DFW släppa DNS/Kerberos/LDAP från alla workload-segment till `seg-identity`.

## DFW — distribuerad brandvägg

Tillämpas per-vNIC oavsett segment.

### v1 — börja enkelt

| # | Källa | Destination | Tjänst | Action |
|---|---|---|---|---|
| 1 | any-workload | seg-identity | DNS(53), Kerberos(88), LDAP(389/636), SMB(445) | Allow — domänjoin/auth |
| 2 | any-workload | any-workload | RDP(3389) | Allow — nå alla VM:er |
| 3 | seg-office | seg-web | HTTP(80)/HTTPS(443) | Allow |
| 4 | (allt annat öst-väst) | | any | Allow (löst i v1) |

I v1 är default öst-väst **tillåtet** — RDP till alla + 80/443 till web + auth till identity räcker för att komma igång och verifiera att appen funkar. Konsolåtkomst för admin påverkas inte (out-of-band via ESXi).

### v2 — strama åt (zero-trust)

Byt default till **Deny** och lägg tier-reglerna: office→web (80/443), web→api (app-port), api→db (db-port), plus auth till identity. Då visar du mikrosegmenteringen: office når inte db/api direkt, web når inte db, bara api når db.

## Admin-åtkomst

- Klienten drivs via **VM-konsol** (VMRC) från WLD-vCenter (mgmt-sidan). Ingen overlay↔mgmt-routing.
- Vill du nå web/klient från jumphosten utan konsol → inför Edge/T0 + statisk rutt (senare, valfritt).

## Vad som byggs (när designen är spikad)

- `.md` (denna) — spikad topologi + regler.
- Roll-parameter i `Initialize-EnvAD` (`infra` / `client`) → bygg client-DC.
- `New-EnvWorkloadNetwork` — via NSX Policy-API: skapar T1 + de fem segmenten + DFW-policyn.
- Enkel VM-deploy för client-win/web/api/db på rätt segment.
- (Valfritt) Edge/T0 + statisk rutt för jumphost-åtkomst / forest-trust.

## Beslutat (v1)

1. **Realm-namn:** `infra.test` (infra) + `corp.test` (client). client-AD identiskt i Prod/Test — egna isolerade forests, namnet får repeteras.
2. **App-tier:** domänjoinad mot `corp.test` (ingen hosts-fil).
3. **Overlay:** `172.16.0.0/12`; segment `/24` (Prod `172.16.x`, Test `172.17.x`).
4. **DFW:** v1 = RDP till alla + 80/443 till web + auth till identity, default tillåtet. v2 stramar åt till zero-trust.
5. **T1 vs Edge:** T1-only i v1 (öst-väst räcker). Edge/T0 **går att simulera nested** och läggs till senare för nord-syd / load balancing / NAT / forest-trust.

### Infra-nät (vMotion/vSAN/TEP)

Ligger i `1-Initialize-EnvAD.ps1`:s nätverksplan-kommentar — egna VLAN/subnät på `192.168.x` med IP-pooler per domän (mgmt/prod/test).

---

## Fas 4 — VKS / Private AI / DBaaS (nätverksskiss)

Ligger ovanpå fas 3. **Edge/T0 blir obligatoriskt här** — Ingress/Egress är T0-konstruktioner och tjänster frontas av en load balancer. Klienten konsumerar tjänster via **DNS → LB-VIP**, den byter aldrig segment.

### Vad varje tjänst drar nätverksmässigt

- **VKS / vSphere Supervisor:** aktiveras på en WLD och skapar per-namespace overlay-segment + T1 **automatiskt**. LoadBalancer-tjänster får VIP:ar ur ett **Ingress-CIDR** via NSX/Avi-LB; utgående SNAT:as via **Egress-CIDR**. Behöver Supervisor-mgmt-nät, Ingress, Egress + interna pod/service-CIDR:er (icke-routbara, auto).
- **Private AI:** K8s-workloads ovanpå VKS → konsumeras via samma Ingress/LB. Nätverksmässigt inget nytt; det nya är **GPU** (vGPU/passthrough) — den svåra biten i nested, inte nätet.
- **DBaaS (Data Services Manager):** databas-VM:er på ett eget segment (`seg-data`), konsumeras öst-väst via IP/endpoint. DSM-appliancen har mgmt-beroende (pratar med vCenter).
- **NSX ALB (Avi):** VCF använder Avi som LB för Supervisor → en Avi-controller-appliance tillkommer (infra-beroende).

### CIDR-reservationer (per WLD /16, inom 172.16.0.0/12)

Prod = `172.16.0.0/16`, Test = `172.17.0.0/16` (plats för fler: `172.18…`). Per WLD:

| Block | Prod-exempel | Routbar? | Not |
|---|---|---|---|
| Fas 3-segment (identity/office/web/api/db) | 172.16.1/2/10/20/30.0/24 | ja (T1) | manuella |
| `seg-data` (DBaaS) | 172.16.40.0/24 | ja (T1) | DB-VM:er |
| Supervisor-mgmt | 172.16.100.0/24 | ja | control plane |
| Ingress (LB-VIP) | 172.16.101.0/24 | ja (T0) | tjänste-VIP:ar |
| Egress (SNAT) | 172.16.102.0/24 | ja (T0) | utgående |
| Namespace-segment (auto) | 172.16.112.0/20 | ja (T1) | Supervisor delar ut per namespace |
| Pod/Service-CIDR (K8s-internt) | icke-överlappande block (t.ex. defaults) | nej | SNAT:as, syns ej utåt |

Test speglar på `172.17.x`.

### Nytt jämfört med fas 3

- **Edge-cluster + T0** — obligatoriskt här, men går att simulera nested.
- **Avi-controller** (LB) — extra appliance.
- **GPU** för Private AI — nested-utmaning (vGPU/passthrough).
- Klient-tjänst-DNS: `ai.corp.test`, `db.corp.test` → pekar på Ingress-VIP:ar.

### Så når office-klienten tjänsterna

Klienten stannar på `seg-office`. Den slår tjänstens DNS-namn → Ingress-VIP → LB → pod/DB. Enda kravet är routing `seg-office → T1 → T0 → Ingress-CIDR`, vilket finns så fort Edge/T0 är på plats. Inga nya segment på klienten — bara endpoints att konsumera.
