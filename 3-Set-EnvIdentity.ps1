<#
    3-Set-EnvIdentity.ps1 — ger en identiskt-namngiven pod-DC ett synligt "friendly lab name".
    En sanningskalla (maskin-env-var EnvName), manga ytor: prompt, banner, desktop, (BGInfo).

    Kor per pod EFTER klon, antingen med explicit namn:
        .\3-Set-EnvIdentity.ps1 -Name 'Aurora'
    eller lat den lasa namnet fran VM:ens guestinfo (satt vid deploy med PowerCLI:
        New-AdvancedSetting -Entity $vm -Name guestinfo.envname -Value 'Aurora' -Force):
        .\3-Set-EnvIdentity.ps1
#>
param([string]$Name)

# --- 1) Kalla: guestinfo om -Name utelamnats (automatisk per-pod-identitet) ---
if (-not $Name) {
    $vmtoolsd = 'C:\Program Files\VMware\VMware Tools\vmtoolsd.exe'
    if (Test-Path $vmtoolsd) { $Name = (& $vmtoolsd --cmd 'info-get guestinfo.envname' 2>$null).Trim() }
}
if (-not $Name) { throw 'Inget lab-namn. Ange -Name, eller satt guestinfo.envname pa VM:en.' }
Write-Host "Satter lab-identitet: $Name"

# --- 2) Sanningskallan: maskin-env-var EnvName ---
[Environment]::SetEnvironmentVariable('EnvName', $Name, 'Machine')
$env:EnvName = $Name

# --- 3) PowerShell-prompt for alla anvandare (Linux-PS1-motsvarigheten, RDP-saker) ---
$allUsers = $PROFILE.AllUsersAllHosts
$dir = Split-Path $allUsers
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
@'
function prompt {
    $lab = [Environment]::GetEnvironmentVariable('EnvName','Machine')
    Write-Host "[LAB $lab] " -ForegroundColor Cyan -NoNewline
    "$($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) "
}
'@ | Set-Content -Path $allUsers -Encoding UTF8

# --- 4) Logon-banner (omissbar vid varje inloggning, aven RDP) ---
$sys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
Set-ItemProperty $sys -Name legalnoticecaption -Value "ENV: $Name"
Set-ItemProperty $sys -Name legalnoticetext    -Value "Inloggad pa miljo: $Name  (dc.infra.test)"

# --- 5) Desktop-fil for alla anvandare (billig extra-cue) ---
Get-ChildItem 'C:\Users\Public\Desktop\ENV - *.txt' -EA SilentlyContinue | Remove-Item -Force
"ENV: $Name`r`nEnv-DC: dc.infra.test" | Set-Content "C:\Users\Public\Desktop\ENV - $Name.txt"

# --- 6) (valfritt) BGInfo: baka in namnet i wallpaper, syns aven over RDP ---
#     Kraver Bginfo64.exe + en .bgi med ett custom-falt som laser env-var EnvName.
#     Kor vid logon (scheduled task / startup):
#     & C:\Tools\Bginfo64.exe C:\Tools\lab.bgi /timer:0 /nolicprompt /silent

Write-Host 'Klar. En ny PowerShell-session visar [LAB <namn>] i prompten.'
