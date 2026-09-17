# Steg-läget: nested ESXi steg för steg

Två kommandon med handpålägg emellan — bygg VM:en, installera ESXi för hand, sätt baslinjen.

```powershell
Connect-VIServer vcenter-wld
New-EsxiLabVM -Name esx-mgmt01 -VMHost phys01 -Datastore wld-vsan `
    -Portgroup nes-vcf01-trunk -IsoContentLibrary nes-iso -IsoItem ESXi-8.0U3 -PowerOn
#  -> starta konsolen, installera ESXi för hand på defaults, sätt IP i DCUI
Set-EsxiHostBaseline -HostAddress 192.168.0.51 -RootPw 'VMware1!' `
    -ShortName esx-mgmt01 -Domain infra.test -Dns 192.168.0.10 -Ntp 192.168.0.10
```

## Vad `New-EsxiLabVM` bygger

En tom VM med boot-disk på SCSI, **NVMe-controller med cache/capacity-diskarna** (så nested ser dem som flash — ingen SSD-markering), `vhvEnable`-flaggan, trunk-portgruppen, stock-ESXi-ISO:n monterad och ansluten från en Content Library, och **boot order disk-före-CD** (tom disk faller igenom till CD:n vid install, bootar disken efteråt — ingen loop). Sen är den redo att startas och installeras för hand.

Den delar med flit designen med den fulla modulen (samma NVMe- och boot-order-API-logik) men är **fristående** — egen PowerCLI-loader, inga profil-beroenden, allt som explicita parametrar med defaults. Det är själva poängen med steg-läget: allt syns i klartext, och när någon sen tittar på `New-NestedEnv` känner de igen exakt samma steg, fast automatiserade och obemannade.

## Tre saker att veta

- Trunk-**portgruppen måste finnas** först (kör `New-EnvPortGroup` eller peka på en du gjort för hand).
- Stock-**ISO:n måste ligga som ett CL-item** (samma vSAN-skäl som per-host-ISO:erna — vSAN tillåter inte lösa filer på datastore-roten).
- Du kör detta mot **WLD-vCenter** (där VM:erna skapas), till skillnad från `Set-EsxiHostBaseline` som ansluter direkt till varje färsk ESXi-host.

`-StoragePolicy` är valfri — utelämnar du den hamnar diskarna på datastore-defaulten; i lab vill du nog peka den på FTT=0.

## Två nivåer

- **Steg-läget** (`New-EsxiLabVM` + `Set-EsxiHostBaseline`) — för att förstå och för att andra ska kunna följa med.
- **Full auto** (`New-NestedEnv`) — när det ska gå fort.
