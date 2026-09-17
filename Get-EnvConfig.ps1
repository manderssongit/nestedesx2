<#
    Get-EnvConfig.ps1  —  gemensam config-laddare for hela nested-VCF-pipelinen.

    KANONISK KALLA: env-config.psd1 (ren PowerShell-datafil, ditt teams sprak).
    JSON stods aven som utbytesformat mot HTML-vyn - men psd1 ar sanningen.

        . "$PSScriptRoot\Get-EnvConfig.ps1"
        $cfg = Get-EnvConfig                       # laser env-config.psd1 (annars .json)
        $cfg = Get-EnvConfig -Path D:\prod.psd1    # eller en sparad template ("prod kopia")
        $cfg = Get-EnvConfig -Template prod        # = .\templates\prod.psd1|.json

    Hjalp-metoder pa objektet:  $cfg.HostGroup('mgmt'), $cfg.GuestId(),
    $cfg.Fqdn($rec), $cfg.ZoneDomain('corp'), $cfg.Lookup('depot').

    Ovriga cmdlets (logiken bor i PowerShell, inte i HTML):
        Test-EnvConfig  $cfg            -> validering (dubbletter, ip-krock, guestId ...)
        Sync-EnvHostDns $cfg            -> bygg om esx-* DNS ur hostGroups
        Export-EnvConfigJson $cfg -Path .\env-config.json   (mata HTML-vyn)
        Export-EnvConfigPsd1 $cfg -Path .\env-config.psd1   (skriv tillbaka kallan)

    Ren PS 5.1 / 7.x. Ingen PowerCLI. 5.2 vs 9.1 = data i configen (esxiVersion m.m).
#>

# ----------------------------------------------------------------------------
# intern: djup-konvertera Hashtable (fran psd1) -> PSCustomObject sa resten av
# koden kan behandla psd1 och json identiskt.
# ----------------------------------------------------------------------------
function ConvertTo-PsObjectDeep {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $o = [ordered]@{}
        foreach ($k in $InputObject.Keys) { $o[[string]$k] = ConvertTo-PsObjectDeep $InputObject[$k] }
        return [pscustomobject]$o
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return @($InputObject | ForEach-Object { ConvertTo-PsObjectDeep $_ })
    }
    return $InputObject
}

function Add-EnvMethods {
    param($cfg)
    $cfg | Add-Member -MemberType ScriptMethod -Name 'ZoneDomain' -Force -Value {
        param([string]$Zone)
        $realm = $this.adForest.$Zone
        if ($realm) { return $realm.domain } else { return $Zone }
    }
    $cfg | Add-Member -MemberType ScriptMethod -Name 'Fqdn' -Force -Value {
        param($DnsRecord)
        "$($DnsRecord.name).$($this.ZoneDomain($DnsRecord.zone))"
    }
    $cfg | Add-Member -MemberType ScriptMethod -Name 'MgmtBase' -Force -Value {
        $o = $this.network.mgmt.subnet.Split('/')[0].Split('.'); "$($o[0]).$($o[1]).$($o[2])"
    }
    # env-slug (gemener, slugifierat) och objekt-stam for vCenter-namn
    $cfg | Add-Member -MemberType ScriptMethod -Name 'EnvSlug' -Force -Value {
        (($this.nestedEnv.friendlyName.ToLower() -replace '[^a-z0-9]+','-').Trim('-'))
    }
    $cfg | Add-Member -MemberType ScriptMethod -Name 'EnvStem' -Force -Value {
        "$($this.nestedEnv.prefix)$($this.EnvSlug())"          # t.ex. nes-aurora
    }
    $cfg | Add-Member -MemberType ScriptMethod -Name 'VmName' -Force -Value {
        param([string]$Short) "$($this.EnvStem())-$Short" # t.ex. nes-aurora-esx-mgmt01
    }
    $cfg | Add-Member -MemberType ScriptMethod -Name 'TrunkPg' -Force -Value {
        "$($this.EnvStem())-trunk"                        # t.ex. nes-aurora-trunk
    }
    $cfg | Add-Member -MemberType ScriptMethod -Name 'HostGroup' -Force -Value {
        param([string]$GroupName)
        $g = $this.hostGroups.$GroupName
        if (-not $g) { throw "okand host-grupp: $GroupName (finns: $($this.hostGroups.PSObject.Properties.Name -join ', '))" }
        $base = $this.MgmtBase(); $size = $this.hostSizes.$($g.size)
        1..$g.count | ForEach-Object {
            $n = '{0}{1:D2}' -f $g.prefix, $_
            [pscustomobject]@{
                name = $n; ip = '{0}.{1}' -f $base, ($g.startIp + $_ - 1)
                fqdn = "$n.$($this.adForest.infra.domain)"; vmName = $this.VmName($n)
                size = $g.size; spec = $size; vsanMode = $g.vsanMode; group = $GroupName
            }
        }
    }
    $cfg | Add-Member -MemberType ScriptMethod -Name 'Lookup' -Force -Value {
        param([string]$Name) $this.dns | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    }
    $cfg | Add-Member -MemberType ScriptMethod -Name 'GuestId' -Force -Value {
        $v = [string]$this.physicalEnv.esxiVersion; $id = $this.physicalEnv.guestIdMap.$v
        if (-not $id) { throw "guestIdMap saknar version '$v'" }; $id
    }
    return $cfg
}

function Get-EnvConfig {
    [CmdletBinding()]
    param(
        [string]$Path,        # env-config.psd1|.json (default: bredvid scriptet)
        [string]$Template,    # namn i .\templates\ (utan tillagg)
        [switch]$Strict       # kasta pa valideringsfel istallet for att bara varna
    )

    # --- hitta filen: psd1 forst, sen json ---
    if ($Template) {
        foreach ($ext in 'psd1','json') {
            $p = Join-Path $PSScriptRoot "templates\$Template.$ext"
            if (Test-Path $p) { $Path = $p; break }
        }
        if (-not $Path) { throw "Get-EnvConfig: hittar ingen template '$Template' i .\templates\" }
    }
    if (-not $Path) {
        foreach ($cand in 'env-config.psd1','env-config.json','env-config.sample.psd1','env-config.sample.json') {
            $p = Join-Path $PSScriptRoot $cand
            if (Test-Path $p) { $Path = $p; break }
        }
    }
    if (-not $Path -or -not (Test-Path $Path)) {
        throw "Get-EnvConfig: hittar ingen config. Ange -Path, eller lagg env-config.psd1 bredvid scriptet."
    }

    # --- las + normalisera till PSCustomObject ---
    try {
        if ([IO.Path]::GetExtension($Path) -ieq '.psd1') {
            $cfg = ConvertTo-PsObjectDeep (Import-PowerShellDataFile -Path $Path)
        } else {
            $cfg = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        }
    } catch {
        throw "Get-EnvConfig: kunde inte lasa '$Path': $($_.Exception.Message)"
    }

    $cfg | Add-Member -NotePropertyName '_path' -NotePropertyValue $Path -Force
    $cfg = Add-EnvMethods $cfg

    $issues = Test-EnvConfig $cfg
    if ($issues) {
        $errs = @($issues | Where-Object Level -eq 'error')
        $msg  = "Config-varningar i '$Path':`n  - " + (($issues | ForEach-Object { "[$($_.Level)] $($_.Message)" }) -join "`n  - ")
        if ($Strict -and $errs) { throw $msg } else { Write-Warning $msg }
    }
    return $cfg
}

# ----------------------------------------------------------------------------
# validering - samma regler som HTML-vyn hade, men nu i PowerShell
# ----------------------------------------------------------------------------
function Test-EnvConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory,ValueFromPipeline)]$Config, [switch]$Strict)
    process {
        $out = New-Object System.Collections.Generic.List[object]
        function add($lvl,$m){ $out.Add([pscustomobject]@{ Level=$lvl; Message=$m }) }
        $ipre = '^(\d{1,3}\.){3}\d{1,3}$'

        if (-not $Config.nestedEnv -or -not $Config.nestedEnv.friendlyName) { add 'error' 'nestedEnv.friendlyName saknas' }
        elseif (-not $Config.EnvSlug())                        { add 'error' "nestedEnv.friendlyName '$($Config.nestedEnv.friendlyName)' ger tom slug" }
        if (-not $Config.physicalEnv -or -not $Config.physicalEnv.wldVCenter) { add 'warn' 'physicalEnv.wldVCenter tom' }
        if ($Config.physicalEnv) {
            $v = [string]$Config.physicalEnv.esxiVersion
            if (-not $Config.physicalEnv.guestIdMap.$v) { add 'error' "guestIdMap saknar version '$v'" }
        }
        # DNS: dubbletter + ip-format
        $seen = @{}
        foreach ($r in $Config.dns) {
            if (-not $r.name -or -not $r.ip) { add 'error' 'DNS-rad utan namn/ip'; continue }
            if ($r.ip -notmatch $ipre) { add 'warn' "DNS $($r.name): ip '$($r.ip)' ser fel ut" }
            $key = "$($r.name).$($r.zone)"
            if ($seen.ContainsKey($key)) { add 'error' "DNS-dubblett: $key" }
            $seen[$key] = $true
        }
        # host-grupp ip-krock
        $base = $Config.MgmtBase(); $gips = @{}
        foreach ($gn in $Config.hostGroups.PSObject.Properties.Name) {
            $g = $Config.hostGroups.$gn
            for ($i=0; $i -lt $g.count; $i++) {
                $ip = "$base.$($g.startIp + $i)"
                if ($gips.ContainsKey($ip)) { add 'error' "IP-krock ${ip}: $($gips[$ip]) vs $($g.prefix)$($i+1)" }
                $gips[$ip] = "$($g.prefix)$($i+1)"
            }
        }
        if ($Strict -and ($out | Where-Object Level -eq 'error')) {
            throw ("Test-EnvConfig: " + (($out | ForEach-Object { $_.Message }) -join '; '))
        }
        return $out
    }
}

# ----------------------------------------------------------------------------
# bygg om esx-*-raderna ur hostGroups (motsvarar HTML-knappen "Bygg om esx-* DNS")
# ----------------------------------------------------------------------------
function Sync-EnvHostDns {
    [CmdletBinding()]
    param([Parameter(Mandatory,ValueFromPipeline)]$Config)
    process {
        $base     = $Config.MgmtBase()
        $prefixes = @($Config.hostGroups.PSObject.Properties.Name | ForEach-Object { $Config.hostGroups.$_.prefix })
        $kept = @($Config.dns | Where-Object { $n = $_.name; -not ($prefixes | Where-Object { $n.StartsWith($_) }) })
        $new  = foreach ($gn in $Config.hostGroups.PSObject.Properties.Name) {
            $g = $Config.hostGroups.$gn
            1..$g.count | ForEach-Object {
                [pscustomobject]@{ name = ('{0}{1:D2}' -f $g.prefix,$_); ip = "$base.$($g.startIp + $_ - 1)"; zone = 'infra' }
            }
        }
        $Config.dns = @($kept + $new)
        return $Config
    }
}

# ----------------------------------------------------------------------------
# konvertering psd1 <-> json (HTML-vyn ar en matad engangs-vy, inte en kalla)
# ----------------------------------------------------------------------------
function Export-EnvConfigJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Path)
    $clean = $Config | Select-Object -Property * -ExcludeProperty _path
    ($clean | ConvertTo-Json -Depth 20) | Set-Content -Path $Path -Encoding UTF8
    Write-Host "JSON skrivet: $Path (mata in i env-config-editor.html)" -ForegroundColor Cyan
}

function ConvertTo-Psd1String {
    param($InputObject, [int]$Indent = 0)
    $pad = '    ' * $Indent; $pad2 = '    ' * ($Indent + 1)
    if ($null -eq $InputObject) { return '$null' }
    if ($InputObject -is [bool])   { return $(if ($InputObject) {'$true'} else {'$false'}) }
    if ($InputObject -is [int] -or $InputObject -is [long] -or $InputObject -is [double]) { return "$InputObject" }
    if ($InputObject -is [string]) { return "'" + ($InputObject -replace "'","''") + "'" }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [System.Collections.IDictionary] -and $InputObject -isnot [string]) {
        $items = @($InputObject | ForEach-Object { $pad2 + (ConvertTo-Psd1String $_ ($Indent + 1)) })
        if (-not $items.Count) { return '@()' }
        return "@(`n" + ($items -join "`n") + "`n$pad)"
    }
    # dictionary eller PSCustomObject
    $pairs = @()
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($k in $InputObject.Keys) { $pairs += ,@($k, $InputObject[$k]) }
    } else {
        foreach ($p in $InputObject.PSObject.Properties) { if ($p.Name -ne '_path') { $pairs += ,@($p.Name, $p.Value) } }
    }
    $lines = foreach ($kv in $pairs) {
        $key = [string]$kv[0]
        if ($key -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { $key = "'" + ($key -replace "'","''") + "'" }
        "$pad2$key = " + (ConvertTo-Psd1String $kv[1] ($Indent + 1))
    }
    return "@{`n" + ($lines -join "`n") + "`n$pad}"
}

function Export-EnvConfigPsd1 {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Path)
    $body = ConvertTo-Psd1String $Config 0
    ("# env-config.psd1 - genererad " + (Get-Date -Format 'yyyy-MM-dd HH:mm') + "`n" + $body + "`n") |
        Set-Content -Path $Path -Encoding UTF8
    Write-Host "psd1 skrivet: $Path (kanonisk kalla)" -ForegroundColor Green
}

# Direkt-korning (inte dot-source:ad): skriv sammanfattning for kontroll.
if ($MyInvocation.InvocationName -ne '.') {
    $c = Get-EnvConfig @args
    Write-Host "Config:  $($c._path)" -ForegroundColor Cyan
    Write-Host "Env:     $($c.nestedEnv.friendlyName)  stam=$($c.EnvStem())  trunk=$($c.TrunkPg())"
    Write-Host "WLD:     $($c.physicalEnv.wldVCenter)  vDS=$($c.physicalEnv.vdSwitch)  ESXi $($c.physicalEnv.esxiVersion)  guestId=$($c.GuestId())"
    Write-Host "Realms:  infra=$($c.adForest.infra.domain)  corp=$($c.adForest.corp.domain)"
    foreach ($grp in $c.hostGroups.PSObject.Properties.Name) {
        $h = $c.HostGroup($grp)
        Write-Host ("Grupp {0,-5}: {1,2} host  {2} .. {3}  ({4})" -f $grp, $h.Count, $h[0].vmName, $h[-1].vmName, $h[0].size)
    }
    Write-Host "DNS:     $($c.dns.Count) poster"
}
