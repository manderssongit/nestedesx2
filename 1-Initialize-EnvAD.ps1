<#
    1-Initialize-EnvAD.ps1  —  Golden-AD bootstrap for isolerade nested-lab-pods
    ---------------------------------------------------------------------------
    Kor EN gang pa en ren Windows Server 2025 for att baka golden-DC:n, klona
    sen hela (avstangda) VM:en som pod-template. Alternativt: droppa scriptet
    som firstboot per pod — det ar stage-idempotent, sa bada modellerna funkar.

    Flode (en SYSTEM-startup-task overlever bada reboot:arna):
      Stage 0:  statisk IP (ingen gateway) + DNS-self + rename  -> boxen startar om
      Stage 1:  AD DS + Install-ADDSForest                      -> boxen startar om
      Stage 2:  DNS -> NTP -> CA -> PKI-trust -> pki.infra.test -> DNS-import
                -> IIS-depot -> depot-HTTPS (CA-signerat cert)
      (Stage 3 = klar. Kor Import-VmcaRootToTrust pa JUMPHOSTEN efter steg 2/bringup.)
    ---------------------------------------------------------------------------
    Kor forsta gangen som lokal admin, elevated:
        powershell -ExecutionPolicy Bypass -File .\1-Initialize-EnvAD.ps1
    Sok 'TODO' for det som ska tunas mot din miljo.
#>

# ===========================================================================
#  NATVERKSPLAN (referens) - allt utom Management rider som VLAN-taggar pa den
#  nested trunk-portgruppen. BARA management-planet behover DNS-poster (DnsRecords).
#  ---------------------------------------------------------------------------
#   Nat          VLAN    Subnat             GW              MTU    IP-pooler (mgmt / prod / test)
#   Management   0/untag 192.168.0.0/24     192.168.0.10    1500   se DnsRecords (GW = DC)
#   vMotion      20      192.168.20.0/24    192.168.20.1    9000   .11-.30 / .31-.50 / .51-.70
#   vSAN         30      192.168.30.0/24    192.168.30.1    9000   .11-.30 / .31-.50 / .51-.70
#   Host TEP     40      192.168.40.0/24    192.168.40.1    9000   .11-.40 / .41-.70 / .71-.100
#   Edge TEP     50      192.168.50.0/24    192.168.50.1    9000   -     / .11-.30 / .31-.50  (om Edges)
#   Uplink-01    60      192.168.60.0/24    192.168.60.1    9000   T0-uplink pa mgmt-VLAN i lab (om Edges)
#   Uplink-02    61      192.168.61.0/24    192.168.61.1    9000   T0-uplink (om Edges/dual)
#   Overlay      (NSX)   172.16.0.0/12      per T1 (.1)     -      workload-segment, se fas 3
#  ---------------------------------------------------------------------------
#   - Yttre laget (unmanaged vDS + trunk-portgroup) MTU 9000 sa overlay/vSAN-jumbo ryms.
#   - Cloud Builder PINGAR mgmt-gw. Pa ett flatt isolerat L2 racker att peka mgmt-gw
#     pa DC:n (.10) som svarar pa ping - ingen router behovs. vMotion/vSAN/TEP ar L2
#     pa samma host (ingen routing); fyll GW-faltet med .1 eller lamna default.
#   - En riktig router-peer (VyOS/pfSense) behovs FORST nar du deployar NSX Edges med
#     T0-uplinks/BGP - inte for mgmt-domanen eller WLD-bringup.
#   - Alla trafikslag ar bara VLAN-taggar pa samma trunk-portgroup; separata subnat
#     halls isar av VLAN-taggning inne i nested-miljon, inte av separata portgrupper.
# ===========================================================================
#  KONFIG  — allt trakigt har. Aven DNS-posterna (inline ELLER via CSV).
# ===========================================================================
param(
    [ValidateSet('infra','corp')][string]$Role,      # vilken AD-forest (adForest.infra/corp)
    [string]$ConfigPath,                              # env-config.psd1 (default: bredvid scriptet)
    [string]$Template,                                # sparad template istallet
    [string]$DsrmPassword  = 'ChangeMe-DSRM-P@ss1',   # TODO: valvsecret
    [string]$DepotUser     = 'depot',
    [string]$DepotPassword = 'ChangeMe-Depot-P@ss1'   # TODO: valvsecret
)

# ===========================================================================
#  KONFIG - byggs nu ur env-config.psd1 (kanonisk kalla). Rollen valjer AD-forest.
#  Resten av scriptet konsumerar $Config-nycklarna precis som forr.
# ===========================================================================
. "$PSScriptRoot\Get-EnvConfig.ps1"
$StateDir = 'C:\EnvBuild'
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir | Out-Null }
$ParamFile = Join-Path $StateDir 'params.json'
# Resume-tasken kor scriptet utan argument efter reboot -> persistera valen sa de overlever.
if ($Role -or $ConfigPath -or $Template) {
    @{ Role = $Role; ConfigPath = $ConfigPath; Template = $Template } | ConvertTo-Json | Set-Content $ParamFile
} elseif (Test-Path $ParamFile) {
    $pp = Get-Content $ParamFile -Raw | ConvertFrom-Json
    if (-not $Role)       { $Role       = $pp.Role }
    if (-not $ConfigPath) { $ConfigPath = $pp.ConfigPath }
    if (-not $Template)   { $Template   = $pp.Template }
}
if (-not $Role) { $Role = 'infra' }

$c     = Get-EnvConfig -Path $ConfigPath -Template $Template
$realm = $c.adForest.$Role
if (-not $realm) { throw "adForest saknar roll '$Role' (finns: $($c.adForest.PSObject.Properties.Name -join ', '))" }
# subnet/reverse las explicit ur configen; fallback = harled /24 ur DC-IP om falten saknas.
$subnet  = $realm.subnet
$reverse = $realm.reverseZone
if (-not $subnet -or -not $reverse) {
    $o = $realm.dcIp.Split('.')
    if (-not $subnet)  { $subnet  = "$($o[0]).$($o[1]).$($o[2]).0/24" }
    if (-not $reverse) { $reverse = "$($o[2]).$($o[1]).$($o[0]).in-addr.arpa" }
}

$Config = @{
    ComputerName   = $(if ($realm.dcHostname) { $realm.dcHostname } else { 'dc' })   # -> <namn>.<doman>
    FriendlyName   = $c.nestedEnv.friendlyName            # fallback om guestinfo.envname saknas
    DomainName     = $realm.domain
    NetbiosName    = $realm.netbios
    DsrmPassword   = $DsrmPassword
    DcIp           = $realm.dcIp
    MgmtSubnetId   = $subnet
    ReverseZone    = $reverse

    CaCommonName   = $realm.caName
    CaValidityYrs  = $realm.caValidityYrs
    PkiHostname    = $realm.pkiHostname

    DepotRoot      = $c.depot.root
    DepotFqdn      = $c.depot.fqdn
    DepotHttpsPort = $c.depot.httpsPort
    DepotCertMode  = $(if ($c.depot.certMode -eq 'CA') { 'CA' } else { 'SelfSigned' })
    DepotUser      = $DepotUser
    DepotPassword  = $DepotPassword
    DepotMimeExts  = @($c.depot.mimeExts)

    # DNS-poster for denna forest (zone == roll). Infra = mgmt-planet; corp fyller pa i fas 3.
    DnsRecordsCsv  = ''
    DnsRecords     = @($c.dns | Where-Object { $_.zone -eq $Role } | ForEach-Object { @{ Name = $_.name; Ip = $_.ip } })
}

# Tre-delad bild:  $Config = malet | state.json = var vi ar | envad.log = handelselogg
$StateDir  = 'C:\EnvBuild'
$StateFile = Join-Path $StateDir 'state.json'
$LogFile   = Join-Path $StateDir 'envad.log'
$ResumeTask = 'EnvAD-Resume'
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir | Out-Null }
Start-Transcript -Path (Join-Path $StateDir 'build.log') -Append | Out-Null   # ra backstop

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $LogFile -Value $line
    Write-Host $line -ForegroundColor @{ INFO='Gray'; WARN='Yellow'; ERROR='Red' }[$Level]
}

# ---------------------------------------------------------------------------
#  Stage- och reboot-hantering
# ---------------------------------------------------------------------------
function Get-Stage { if (Test-Path $StateFile) { (Get-Content $StateFile | ConvertFrom-Json).Stage } else { 0 } }
function Set-Stage([int]$n) { @{ Stage = $n } | ConvertTo-Json | Set-Content $StateFile }

function Register-Resume {
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
                 -Argument "-ExecutionPolicy Bypass -NonInteractive -File `"$PSCommandPath`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    Register-ScheduledTask -TaskName $ResumeTask -Action $action -Trigger $trigger `
        -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
}
function Unregister-Resume { Unregister-ScheduledTask -TaskName $ResumeTask -Confirm:$false -ErrorAction SilentlyContinue }

function Wait-ForAD {
    # Efter startup-task:en ar AD DS inte alltid klar direkt — vanta in domanen
    for ($i=0; $i -lt 60; $i++) {
        try { Import-Module ActiveDirectory -EA Stop; Get-ADDomain -EA Stop | Out-Null; return }
        catch { Start-Sleep 10 }
    }
    throw "AD DS blev aldrig redo efter reboot."
}

# ===========================================================================
#  STAGE 0 — statisk IP (ingen gateway) + rename  (boxen startar om)
# ===========================================================================
function Set-EnvNetwork {
    Write-Log 'Statisk IP + DNS (self), ingen gateway'
    $nic = Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1
    if (-not $nic) { throw "Ingen aktiv ethernet-adapter hittad." }
    $prefix = [int](($Config.MgmtSubnetId -split '/')[1])
    Write-Host "  NIC: $($nic.Name)  ->  $($Config.DcIp)/$prefix"
    Set-NetIPInterface -InterfaceAlias $nic.Name -Dhcp Disabled
    # rensa ev. befintlig IPv4-config + default route
    Get-NetIPAddress -InterfaceAlias $nic.Name -AddressFamily IPv4 -EA SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -EA SilentlyContinue
    Get-NetRoute -InterfaceAlias $nic.Name -DestinationPrefix '0.0.0.0/0' -EA SilentlyContinue |
        Remove-NetRoute -Confirm:$false -EA SilentlyContinue
    # ingen -DefaultGateway (isolerat nat); DNS pekar pa sig sjalv (blivande DC)
    New-NetIPAddress -InterfaceAlias $nic.Name -IPAddress $Config.DcIp -PrefixLength $prefix | Out-Null
    Set-DnsClientServerAddress -InterfaceAlias $nic.Name -ServerAddresses $Config.DcIp
    # Svara pa ping: DC:n ar mgmt-gateway (.10) och Cloud Builder pingar den vid bringup
    New-NetFirewallRule -DisplayName 'Allow ICMPv4-In (Echo)' -Protocol ICMPv4 -IcmpType 8 `
        -Direction Inbound -Action Allow -EA SilentlyContinue | Out-Null
}

function Invoke-Stage0-Network {
    Write-Log 'Stage 0: IP + rename'
    Set-EnvNetwork
    Register-Resume          # AtStartup-task overlever bada reboot:arna
    Set-Stage 1
    if ($env:COMPUTERNAME -ne $Config.ComputerName.ToUpper()) {
        Rename-Computer -NewName $Config.ComputerName -Force -Restart
        # <- boxen startar om; SYSTEM-task tar Stage 1 (forest)
    } else {
        Restart-Computer -Force   # redan ratt namn -> bara reboot in i Stage 1
    }
}

# ===========================================================================
#  STAGE 1 — AD DS + Forest  (boxen startar om pa slutet)
# ===========================================================================
function Invoke-Stage1-Forest {
    Write-Log 'Stage 1: AD DS + Forest'
    Install-WindowsFeature AD-Domain-Services -IncludeManagementTools | Out-Null
    Import-Module ADDSDeployment

    Set-Stage 2              # nasta reboot ska landa i konfig-steget

    $dsrm = ConvertTo-SecureString $Config.DsrmPassword -AsPlainText -Force
    # ForestMode/DomainMode utelamnas -> hogsta som OS:et stodjer (2025)
    Install-ADDSForest -DomainName $Config.DomainName -DomainNetbiosName $Config.NetbiosName `
        -SafeModeAdministratorPassword $dsrm -InstallDns:$true `
        -NoRebootOnCompletion:$false -Force
    # <- exekveringen slutar har; boxen startar om, SYSTEM-task:en tar Stage 1
}

# ===========================================================================
#  STAGE 2 — DNS, NTP, CA, IIS-depot, pki, DNS-import
# ===========================================================================
function Set-EnvDns {
    Write-Log 'DNS: reverse-zon + inga forwarders'
    Import-Module DnsServer
    # Reverse-zon (forward-zonen skapades av forest-installen)
    if (-not (Get-DnsServerZone -Name $Config.ReverseZone -EA SilentlyContinue)) {
        Add-DnsServerPrimaryZone -NetworkId $Config.MgmtSubnetId -ReplicationScope Forest
    }
    # Isolerat nat -> inga forwarders
    Set-DnsServerForwarder -IPAddress @() -EA SilentlyContinue
}

function Set-EnvNtp {
    Write-Log 'NTP (auktoritativ lokal klocka)'
    w32tm /config /manualpeerlist:"" /syncfromflags:manual /reliable:yes /update | Out-Null
    Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config' -Name AnnounceFlags -Value 5
    Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpServer' -Name Enabled -Value 1
    Restart-Service w32time
}

function Install-EnvCa {
    Write-Log 'AD CS Enterprise Root CA'
    Install-WindowsFeature ADCS-Cert-Authority, ADCS-Web-Enrollment -IncludeManagementTools | Out-Null
    if (-not (Get-Service certsvc -EA SilentlyContinue).Status -eq 'Running') {
        Install-AdcsCertificationAuthority -CAType EnterpriseRootCA `
            -CACommonName $Config.CaCommonName -KeyLength 4096 -HashAlgorithmName SHA256 `
            -ValidityPeriod Years -ValidityPeriodUnits $Config.CaValidityYrs -Force
    }
    # Web enrollment (/certsrv) — SDDC Managers Microsoft-CA-integration anvander den
    Install-AdcsWebEnrollment -Force -EA SilentlyContinue

    # --- CDP/AIA -> pki.infra.test (HTTP), sa nested-VCF kan revocation-checka i podden ---
    # TODO: verifiera URI-mallen mot din CA (namn-suffixen skiljer sig mellan versioner)
    $pkiBase = "http://$($Config.PkiHostname).$($Config.DomainName)/pki"
    Add-CACrlDistributionPoint -Uri "$pkiBase/%3%8%9.crl" -AddToCertificateCdp -Force -EA SilentlyContinue
    Add-CAAuthorityInformationAccess -Uri "$pkiBase/%3%4.crt" -AddToCertificateAia -Force -EA SilentlyContinue
    # Publicera CRL/CA-cert till IIS-mappen (skapas i Install-EnvDepot)
    Restart-Service certsvc
    certutil -CRL | Out-Null
}

function Install-EnvDepot {
    Write-Log 'IIS: offline depot + pki (CDP/AIA)'
    Install-WindowsFeature Web-Server, Web-Static-Content, Web-Basic-Auth, Web-Mgmt-Console | Out-Null
    Import-Module WebAdministration

    # pki-vdir (CDP/AIA) pa Default Web Site
    $pkiPath = 'C:\inetpub\pki'
    New-Item -ItemType Directory -Path $pkiPath -Force | Out-Null
    if (-not (Get-WebVirtualDirectory -Site 'Default Web Site' -Name 'pki' -EA SilentlyContinue)) {
        New-WebVirtualDirectory -Site 'Default Web Site' -Name 'pki' -PhysicalPath $pkiPath | Out-Null
    }
    # CRL-namn innehaller '+' -> tillat double escaping annars 404
    Set-WebConfigurationProperty -Filter /system.webServer/security/requestFiltering `
        -PSPath 'IIS:\Sites\Default Web Site\pki' -Name allowDoubleEscaping -Value $true
    # Kopiera CA-cert + CRL till pki-mappen (certsrv:s CertEnroll)
    Copy-Item 'C:\Windows\System32\CertSrv\CertEnroll\*.cr*' $pkiPath -Force -EA SilentlyContinue

    # HTTP vibs-vdir (Default Web Site:80) - hit laggs vSAN ESA mock-HW-VIB:en, som
    # nested-ESXi hamtar over HTTP i %firstboot (HTTP -> ingen cert-fraga vid boot)
    $vibsPath = 'C:\inetpub\vibs'
    New-Item -ItemType Directory -Path $vibsPath -Force | Out-Null
    if (-not (Get-WebVirtualDirectory -Site 'Default Web Site' -Name 'vibs' -EA SilentlyContinue)) {
        New-WebVirtualDirectory -Site 'Default Web Site' -Name 'vibs' -PhysicalPath $vibsPath | Out-Null
    }
    Add-WebConfigurationProperty -PSPath 'IIS:\Sites\Default Web Site\vibs' -Filter //staticContent `
        -Name '.' -Value @{ fileExtension = '.vib'; mimeType = 'application/octet-stream' } -EA SilentlyContinue

    # Depot-site (skapas pa 80; HTTPS-binding + cert satts i Set-EnvDepotHttps)
    New-Item -ItemType Directory -Path $Config.DepotRoot -Force | Out-Null
    if (-not (Get-Website -Name 'depot' -EA SilentlyContinue)) {
        New-Website -Name 'depot' -Port 80 -PhysicalPath $Config.DepotRoot | Out-Null
    }
    # MIME: registrera depot-extensionerna sa IIS inte 404:ar okanda typer
    foreach ($ext in $Config.DepotMimeExts) {
        Add-WebConfigurationProperty -PSPath 'IIS:\Sites\depot' -Filter //staticContent `
            -Name '.' -Value @{ fileExtension = $ext; mimeType = 'application/octet-stream' } -EA SilentlyContinue
    }
    # Katalogbladdring pa (index-filerna driver depoten)
    Set-WebConfigurationProperty -Filter /system.webServer/directoryBrowse -PSPath 'IIS:\Sites\depot' -Name enabled -Value $true

    # Lokal depot-user + Basic Auth
    $pw = ConvertTo-SecureString $Config.DepotPassword -AsPlainText -Force
    if (-not (Get-LocalUser -Name $Config.DepotUser -EA SilentlyContinue)) {
        New-LocalUser -Name $Config.DepotUser -Password $pw -PasswordNeverExpires -AccountNeverExpires | Out-Null
    }
    icacls $Config.DepotRoot /grant "$($Config.DepotUser):(OI)(CI)R" | Out-Null
    Set-WebConfigurationProperty -Filter /system.webServer/security/authentication/basicAuthentication `
        -PSPath 'IIS:\Sites\depot' -Name enabled -Value $true
    Set-WebConfigurationProperty -Filter /system.webServer/security/authentication/anonymousAuthentication `
        -PSPath 'IIS:\Sites\depot' -Name enabled -Value $false
}

function Set-EnvDepotHttps {
    Write-Log 'Depot HTTPS (VCF 5.2 kraver TLS)'
    Import-Module WebAdministration
    $fqdn = "$($Config.DepotFqdn).$($Config.DomainName)"

    if ($Config.DepotCertMode -eq 'CA') {
        # CA-signerat (rek.): kedjar till AD-rooten som SDDC Manager anda litar pa,
        # sa depoten funkar i varje pod utan per-pod cert-import.
        # FORUTSATTNING: den som kor har Enroll pa WebServer-templaten. SYSTEM/dator-
        # kontot har det INTE by default -> kor detta steg som Domain Admin, ELLER ge
        # datorkontot Enroll pa WebServer-templaten forst.  TODO
        $req   = Get-Certificate -Template WebServer -DnsName $fqdn `
                     -SubjectName "CN=$fqdn" -CertStoreLocation Cert:\LocalMachine\My
        $thumb = $req.Certificate.Thumbprint
    } else {
        # Self-signed fallback: SDDC Manager maste importera JUST detta cert i sin
        # trust store innan depoten laggs till (per pod, olika cert varje gang).
        $c = New-SelfSignedCertificate -DnsName $fqdn -CertStoreLocation Cert:\LocalMachine\My `
                 -FriendlyName "depot-$fqdn" -NotAfter (Get-Date).AddYears(10)
        $thumb = $c.Thumbprint
        Export-Certificate -Cert $c -FilePath (Join-Path $StateDir 'depot.cer') | Out-Null
    }

    # HTTPS-binding med SNI, ta bort HTTP-bindningen
    if (-not (Get-WebBinding -Name 'depot' -Protocol https -EA SilentlyContinue)) {
        New-WebBinding -Name 'depot' -Protocol https -Port $Config.DepotHttpsPort -HostHeader $fqdn -SslFlags 1
    }
    (Get-WebBinding -Name 'depot' -Protocol https -HostHeader $fqdn).AddSslCertificate($thumb, 'My')
    Remove-WebBinding -Name 'depot' -Protocol http -EA SilentlyContinue
    Write-Host "  Depot: https://$fqdn`:$($Config.DepotHttpsPort)/  (cert-mode: $($Config.DepotCertMode))"
}

function Set-EnvPkiTrust {
    Write-Log 'PKI-trust: publicera root i AD + autoenroll-GPO'
    Import-Module GroupPolicy -EA SilentlyContinue
    # Enterprise Root publicerar sig sjalv i AD, men sakerstall Root + NTAuth explicit
    $root = Get-ChildItem Cert:\LocalMachine\CA, Cert:\LocalMachine\Root |
                Where-Object Subject -match $Config.CaCommonName | Select-Object -First 1
    if ($root) {
        $crt = Join-Path $StateDir 'envroot.cer'
        Export-Certificate -Cert $root -FilePath $crt | Out-Null
        certutil -dspublish -f $crt RootCA   | Out-Null
        certutil -dspublish -f $crt NTAuthCA | Out-Null
    }
    # GPO som slar pa cert-autoenrollment for domanmedlemmar (snabbar root-spridningen).
    # Domanmedlemmar litar pa AD-rooten automatiskt anda; detta gor det prompt + NTAuth.
    $gpoName = 'Env-Autoenroll'
    if (-not (Get-GPO -Name $gpoName -EA SilentlyContinue)) { New-GPO -Name $gpoName | Out-Null }
    Set-GPRegistryValue -Name $gpoName -Type DWord -Value 7 `
        -Key 'HKLM\Software\Policies\Microsoft\Cryptography\AutoEnrollment' -ValueName 'AEPolicy' | Out-Null
    New-GPLink -Name $gpoName -Target (Get-ADDomain).DistinguishedName -LinkEnabled Yes -EA SilentlyContinue | Out-Null
}

function Add-EnvPkiRecord {
    Write-Log 'pki.infra.test A-post'
    if (-not (Get-DnsServerResourceRecord -ZoneName $Config.DomainName -Name $Config.PkiHostname -EA SilentlyContinue)) {
        Add-DnsServerResourceRecordA -ZoneName $Config.DomainName -Name $Config.PkiHostname `
            -IPv4Address $Config.DcIp -CreatePtr
    }
}

function Import-EnvDnsRecords {
    Write-Log 'DNS-import'
    $records = if ($Config.DnsRecordsCsv -and (Test-Path $Config.DnsRecordsCsv)) {
        Import-Csv $Config.DnsRecordsCsv                 # CSV med kolumnerna Name,Ip
    } else {
        $Config.DnsRecords | ForEach-Object { [pscustomobject]$_ }   # inline config-variabel
    }
    foreach ($r in $records) {
        if (-not (Get-DnsServerResourceRecord -ZoneName $Config.DomainName -Name $r.Name -EA SilentlyContinue)) {
            Add-DnsServerResourceRecordA -ZoneName $Config.DomainName -Name $r.Name `
                -IPv4Address $r.Ip -CreatePtr -EA SilentlyContinue
        }
    }
    Write-Host "  $($records.Count) A+PTR sakerstallda."
}

function Install-EnvIdentityTask {
    # Skriver ett apply-script + en startup-task som re-applar friendly name VID VARJE
    # BOOT fran guestinfo.envname. Andrar nagon guestinfo (via Sync-EnvName pa
    # vCenter-sidan) plockas det upp vid nasta reboot. Fallback = $Config.FriendlyName.
    Write-Log 'Identitet: apply-script + startup-task (laser guestinfo.envname varje boot)'
    $applyPath = Join-Path $StateDir 'Apply-EnvIdentity.ps1'
    $apply = @'
$name = $null
$vmtoolsd = 'C:\Program Files\VMware\VMware Tools\vmtoolsd.exe'
if (Test-Path $vmtoolsd) { $name = (& $vmtoolsd --cmd 'info-get guestinfo.envname' 2>$null).Trim() }
if (-not $name) { $name = '__FALLBACK__' }
if (-not $name) { $name = $env:COMPUTERNAME }
[Environment]::SetEnvironmentVariable('EnvName', $name, 'Machine')
$sys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
Set-ItemProperty $sys -Name legalnoticecaption -Value "ENV: $name"
Set-ItemProperty $sys -Name legalnoticetext    -Value "Inloggad pa miljo: $name  (dc.infra.test)"
Get-ChildItem 'C:\Users\Public\Desktop\ENV - *.txt' -EA SilentlyContinue | Remove-Item -Force
"ENV: $name`r`nEnv-DC: dc.infra.test" | Set-Content "C:\Users\Public\Desktop\ENV - $name.txt"
$prof = "$env:windir\System32\WindowsPowerShell\v1.0\profile.ps1"
@"
function prompt {
    `$lab = [Environment]::GetEnvironmentVariable('EnvName','Machine')
    Write-Host "[LAB `$lab] " -ForegroundColor Cyan -NoNewline
    "`$(`$executionContext.SessionState.Path.CurrentLocation)`$('>' * (`$nestedPromptLevel + 1)) "
}
"@ | Set-Content $prof -Encoding UTF8
'@
    $apply = $apply -replace '__FALLBACK__', $Config.FriendlyName
    Set-Content -Path $applyPath -Value $apply -Encoding UTF8

    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
                 -Argument "-ExecutionPolicy Bypass -NonInteractive -File `"$applyPath`""
    Register-ScheduledTask -TaskName 'EnvAD-Identity' -Action $action `
        -Trigger (New-ScheduledTaskTrigger -AtStartup) -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
    powershell -ExecutionPolicy Bypass -File $applyPath      # applicera direkt en gang
}

function Invoke-Stage2-Configure {
    Wait-ForAD
    Set-EnvDns
    Set-EnvNtp
    Install-EnvCa
    Set-EnvPkiTrust
    Add-EnvPkiRecord
    Import-EnvDnsRecords          # skapar bl.a. depot.infra.test
    Install-EnvDepot
    Set-EnvDepotHttps             # CA-signerat cert + HTTPS-binding
    Install-EnvIdentityTask       # friendly name fran guestinfo, re-appl vid varje boot
    Set-Stage 3
    Unregister-Resume
    Write-Log 'KLART: golden-AD byggd. Stang av och klona VM:en som pod-template.'
}

# ===========================================================================
#  KORS PA JUMPHOSTEN EFTER STEG 2 (inte av dispatchern) — VMCA-root till trust
# ===========================================================================
function Import-VmcaRootToTrust {
    <#  Nar vCenter finns (efter Cloud Builder) hamtar denna VMCA-rooten och
        importerar den sa VMRC/webblasare slutar poppa "untrusted cert" mot ESXi-
        hostarna. AD-rooten far domanmedlemmar automatiskt; VMCA-rooten ar den enda
        som AD inte sprider, sa den maste in for hand pa maskinen som kor VMRC.  #>
    param([string]$VCenterFqdn = 'vcenter.infra.test')
    $zip = Join-Path $env:TEMP 'vmca.zip'
    Invoke-WebRequest "https://$VCenterFqdn/certs/download.zip" -OutFile $zip -SkipCertificateCheck
    $dst = Join-Path $env:TEMP 'vmca'; Expand-Archive $zip $dst -Force
    Get-ChildItem "$dst\certs\win\*.crt" -Recurse | ForEach-Object {
        Import-Certificate -FilePath $_.FullName -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
    }
    Write-Host "VMCA-root fran $VCenterFqdn importerad till LocalMachine\Root."
}

# ===========================================================================
#  Dispatcher
# ===========================================================================
$stage = Get-Stage
try {
    Write-Log "=== Start: Stage $stage ==="
    switch ($stage) {
        0 { Invoke-Stage0-Network }        # IP + rename -> reboot
        1 { Invoke-Stage1-Forest }         # forest -> reboot (SYSTEM-task tar over)
        2 { Invoke-Stage2-Configure }
        default { Write-Log 'Redan byggd (Stage 3). Inget att gora.' }
    }
    # Stage 0/1 startar om innan denna rad -> loggas bara nar ett steg gar i mal
    Write-Log "=== Stage $stage klar ==="
} catch {
    Write-Log "Stage $stage FALLERADE: $($_.Exception.Message)" 'ERROR'
    Write-Log $_.ScriptStackTrace 'ERROR'
    throw
} finally { Stop-Transcript | Out-Null }
