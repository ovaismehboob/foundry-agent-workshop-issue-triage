<#
.SYNOPSIS
  Instructor script: creates the student accounts and one Foundry project per student, writes the students CSV,
  and (by default) grants the access by running provision-workshop.ps1.

.DESCRIPTION
  For each number N from -StartIndex for -Count students it creates, when missing:
    - a Microsoft Entra user  user<N>_foundrywksp@<domain>  (display name "Foundry Lab User <N>"). The account gets a
      random password that is never shown or stored, so it can only be used with a Temporary Access Pass (TAP).
    - a Foundry project  proj-student<NN>  (system-assigned identity) on your existing Foundry resource.
  It then:
    - optionally issues a TAP for each user (-IssueTap) and saves it to deployment/output/accounts.csv
      (SENSITIVE: anyone with a TAP can sign in as that student until it expires; the folder is ignored by Git),
    - adds the accounts to the students CSV (default deployment/students.csv; existing rows are kept, rows with the
      same user are updated), using StudentId s<NN>,
    - runs provision-workshop.ps1 to assign Foundry User + Foundry Project Manager on each student's project, and the
      Search / registry / monitoring access and the shared infrastructure (skip with -SkipProvisioning).

  Existing users and projects are reused and never modified or deleted, so the script is safe to re-run.
  Note that provisioning creates the shared Standard search service if it doesn't exist yet.

  Requires: Azure CLI signed in as Owner on the resource group AND as a Microsoft Entra administrator who can create
  users (User Administrator) and, for -IssueTap, manage authentication methods (Authentication Administrator or
  Privileged Authentication Administrator). Temporary Access Pass must be enabled in the tenant
  (Entra admin center > Protection > Authentication methods > Temporary Access Pass).
  If TAP creation is refused with a permissions error, create the TAPs in the Entra admin center instead
  (Users > select the user > Authentication methods > Add authentication method > Temporary Access Pass).
  The accounts and projects are still created.

.PARAMETER Count
  Number of students (default 22).
.PARAMETER StartIndex
  First student number (default 1). Numbers continue the pattern user<N>_foundrywksp; user0_foundrywksp is your test account.
.PARAMETER TapStartTime
  When the TAPs become valid, for example "2026-11-02 08:30" (local time). Default: immediately.
.PARAMETER TapLifetimeMinutes
  How long a TAP is valid (default 480). The tenant policy sets the allowed range.
.PARAMETER DryRun
  Shows what would be created without changing anything.

.EXAMPLE
  ./deployment/create-student-accounts.ps1 -SubscriptionId <id> -ResourceGroup <rg> -FoundryAccountName <name> -Count 22 -DryRun

.EXAMPLE
  ./deployment/create-student-accounts.ps1 -SubscriptionId <id> -ResourceGroup <rg> -FoundryAccountName <name> `
      -Count 22 -IssueTap -TapStartTime "2026-11-02 08:30" -TapLifetimeMinutes 600
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SubscriptionId,
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [Parameter(Mandatory = $true)][string]$FoundryAccountName,

    [ValidateRange(1, 200)][int]$Count = 22,
    [ValidateRange(0, 999)][int]$StartIndex = 1,
    [string]$Domain,
    [string]$UserPrefix = 'user',
    [string]$UserSuffix = '_foundrywksp',
    [string]$DisplayNamePrefix = 'Foundry Lab User ',
    [string]$ProjectPrefix = 'proj-student',
    [string]$StudentIdPrefix = 's',

    [switch]$IssueTap,
    [datetime]$TapStartTime,
    [ValidateRange(10, 43200)][int]$TapLifetimeMinutes = 480,
    [switch]$TapOneTimeUse,

    [string]$StudentsCsv,
    [string]$OutputDir,
    [switch]$SkipProvisioning,
    [hashtable]$ProvisionParameters = @{},
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'

function Write-Step([string]$Message) { Write-Host ''; Write-Host "== $Message" -ForegroundColor Cyan }
function Write-Info([string]$Message) { Write-Host "   $Message" }
function Write-DryRun([string]$Message) { Write-Host "   [dry run] $Message" -ForegroundColor Yellow }

function Invoke-Az {
    param([Parameter(Mandatory = $true)][string[]]$AzArgs, [switch]$AllowFail)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $raw = & az @AzArgs 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $previous }
    $stdout = @($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    $stderr = @($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() })
    if ($code -ne 0 -and -not $AllowFail) { throw "az $($AzArgs[0..([Math]::Min(3, $AzArgs.Count - 1))] -join ' ') failed: $($stderr -join ' ')" }
    return [pscustomobject]@{ ExitCode = $code; Output = ($stdout -join "`n"); Error = ($stderr -join "`n") }
}

function Invoke-Graph {
    param([string]$Method, [string]$Uri, $Body, [switch]$AllowFail)
    $arguments = @('rest', '--method', $Method.ToLower(), '--uri', $Uri, '-o', 'json')
    $file = $null
    try {
        if ($null -ne $Body) {
            $file = [System.IO.Path]::GetTempFileName()
            [System.IO.File]::WriteAllText($file, ($Body | ConvertTo-Json -Depth 6 -Compress))
            $arguments += @('--body', "@$file", '--headers', 'Content-Type=application/json')
        }
        return Invoke-Az -AzArgs $arguments -AllowFail:$AllowFail
    } finally { if ($file) { Remove-Item $file -ErrorAction SilentlyContinue } }
}

# Random 24-character password that satisfies the Entra complexity rules. It is never displayed or saved.
function New-RandomPassword {
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!@#$%^&*-_=+')
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $pick = { param($chars) $b = New-Object byte[] 4; $rng.GetBytes($b); $chars[[BitConverter]::ToUInt32($b, 0) % $chars.Length] }
    $chars = New-Object System.Collections.Generic.List[char]
    foreach ($set in $sets) { $chars.Add((& $pick $set)) }
    $all = ($sets -join '')
    while ($chars.Count -lt 24) { $chars.Add((& $pick $all)) }
    $shuffled = $chars | Sort-Object { $b = New-Object byte[] 4; $rng.GetBytes($b); [BitConverter]::ToUInt32($b, 0) }
    return -join $shuffled
}

# ------------------------------------------------------------------------------------------------
# Pre-flight (read-only)
# ------------------------------------------------------------------------------------------------
Write-Step 'Pre-flight checks'
if ($DryRun) { Write-Host '   DRY RUN: nothing will be created.' -ForegroundColor Yellow }
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) was not found. Install it and run az login.' }
Invoke-Az -AzArgs @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
$signedIn = (Invoke-Az -AzArgs @('account', 'show', '--query', 'user.name', '-o', 'tsv')).Output.Trim()
if (-not $Domain) {
    if ($signedIn -notmatch '@(.+)$') { throw "Can't work out the domain from '$signedIn'. Pass -Domain contoso.com." }
    $Domain = $Matches[1]
}
Write-Info "Signed in as $signedIn; student accounts will be <name>@$Domain"

$rgInfo = (Invoke-Az -AzArgs @('group', 'show', '--name', $ResourceGroup, '--subscription', $SubscriptionId, '-o', 'json') -AllowFail)
if ($rgInfo.ExitCode -ne 0) { throw "Resource group '$ResourceGroup' was not found in this subscription." }
$Location = ($rgInfo.Output | ConvertFrom-Json).location
$account = Invoke-Az -AzArgs @('cognitiveservices', 'account', 'show', '--name', $FoundryAccountName, '--resource-group', $ResourceGroup, '--subscription', $SubscriptionId, '--query', 'location', '-o', 'tsv') -AllowFail
if ($account.ExitCode -ne 0) { throw "Foundry resource '$FoundryAccountName' was not found in '$ResourceGroup'." }
$Location = $account.Output.Trim()

if (-not $StudentsCsv) { $StudentsCsv = Join-Path $PSScriptRoot 'students.csv' }
if (-not $OutputDir) { $OutputDir = Join-Path $PSScriptRoot 'output' }

$plan = @()
for ($i = 0; $i -lt $Count; $i++) {
    $number = $StartIndex + $i
    $plan += [pscustomobject]@{
        Number = $number
        Upn = "$UserPrefix$number$UserSuffix@$Domain"
        DisplayName = "$DisplayNamePrefix$number"
        MailNickname = "$UserPrefix$number$UserSuffix"
        Project = ('{0}{1:d2}' -f $ProjectPrefix, $number)
        StudentId = ('{0}{1:d2}' -f $StudentIdPrefix, $number)
        ObjectId = $null; Tap = $null; TapValidFrom = $null; TapExpires = $null
    }
}

# A StudentId must be unique across the CSV (it names the student's knowledge base).
$existingRows = @()
if (Test-Path $StudentsCsv) { $existingRows = @(Import-Csv -Path $StudentsCsv) }
foreach ($item in $plan) {
    $clash = @($existingRows | Where-Object { $_.StudentId -and $_.StudentId.Trim() -ieq $item.StudentId -and $_.UserPrincipalName.Trim() -ine $item.Upn })
    if ($clash.Count -gt 0) {
        throw "StudentId '$($item.StudentId)' is already used by '$($clash[0].UserPrincipalName)' in $StudentsCsv. Edit that row's StudentId (for example s00) or use a different -StudentIdPrefix / -StartIndex."
    }
}

# ------------------------------------------------------------------------------------------------
# 1. Users
# ------------------------------------------------------------------------------------------------
Write-Step "Student accounts ($($plan.Count))"
foreach ($item in $plan) {
    $existing = Invoke-Graph -Method GET -Uri ("https://graph.microsoft.com/v1.0/users/{0}?`$select=id" -f [uri]::EscapeDataString($item.Upn)) -AllowFail
    if ($existing.ExitCode -eq 0 -and $existing.Output) {
        $item.ObjectId = ($existing.Output | ConvertFrom-Json).id
        Write-Info "exists: $($item.Upn)"
        continue
    }
    if ($DryRun) { Write-DryRun "create user $($item.Upn) ('$($item.DisplayName)')"; continue }
    $body = @{
        accountEnabled = $true
        displayName = $item.DisplayName
        mailNickname = $item.MailNickname
        userPrincipalName = $item.Upn
        passwordProfile = @{ password = (New-RandomPassword); forceChangePasswordNextSignIn = $false }
    }
    $created = Invoke-Graph -Method POST -Uri 'https://graph.microsoft.com/v1.0/users' -Body $body
    $item.ObjectId = ($created.Output | ConvertFrom-Json).id
    Write-Info "created: $($item.Upn)"
}

# ------------------------------------------------------------------------------------------------
# 2. Foundry projects
# ------------------------------------------------------------------------------------------------
Write-Step "Foundry projects on '$FoundryAccountName'"
foreach ($item in $plan) {
    $show = Invoke-Az -AllowFail -AzArgs @('cognitiveservices', 'account', 'project', 'show', '--name', $FoundryAccountName, '--resource-group', $ResourceGroup,
        '--subscription', $SubscriptionId, '--project-name', $item.Project, '--query', 'name', '-o', 'tsv')
    if ($show.ExitCode -eq 0 -and $show.Output) { Write-Info "exists: $($item.Project)"; continue }
    if ($DryRun) { Write-DryRun "create project $($item.Project) in $Location"; continue }
    Write-Info "creating $($item.Project)..."
    Invoke-Az -AzArgs @('cognitiveservices', 'account', 'project', 'create', '--name', $FoundryAccountName, '--resource-group', $ResourceGroup,
        '--subscription', $SubscriptionId, '--project-name', $item.Project, '--location', $Location, '--display-name', $item.Project,
        '--description', "Workshop project for $($item.Upn)", '--assign-identity', '-o', 'none') | Out-Null
}

# ------------------------------------------------------------------------------------------------
# 3. Temporary Access Passes (optional)
# ------------------------------------------------------------------------------------------------
if ($IssueTap) {
    Write-Step 'Temporary Access Passes'
    $tapFailures = 0
    foreach ($item in $plan) {
        if ($DryRun) { Write-DryRun "issue a TAP for $($item.Upn) (valid $TapLifetimeMinutes minutes)"; continue }
        if (-not $item.ObjectId) { continue }
        $tapUri = "https://graph.microsoft.com/v1.0/users/$($item.ObjectId)/authentication/temporaryAccessPassMethods"
        # A user can hold only one TAP: replace any existing one.
        $current = Invoke-Graph -Method GET -Uri $tapUri -AllowFail
        if ($current.ExitCode -eq 0 -and $current.Output) {
            foreach ($old in @(($current.Output | ConvertFrom-Json).value)) { Invoke-Graph -Method DELETE -Uri "$tapUri/$($old.id)" -AllowFail | Out-Null }
        }
        $tapBody = @{ lifetimeInMinutes = $TapLifetimeMinutes; isUsableOnce = [bool]$TapOneTimeUse }
        if ($PSBoundParameters.ContainsKey('TapStartTime')) { $tapBody.startDateTime = $TapStartTime.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
        $result = Invoke-Graph -Method POST -Uri $tapUri -Body $tapBody -AllowFail
        if ($result.ExitCode -ne 0) {
            $tapFailures++
            Write-Warning "Could not create a TAP for $($item.Upn): $($result.Error)"
            continue
        }
        $tap = $result.Output | ConvertFrom-Json
        $item.Tap = $tap.temporaryAccessPass
        $item.TapValidFrom = $tap.startDateTime
        $item.TapExpires = ([datetime]$tap.startDateTime).AddMinutes([int]$tap.lifetimeInMinutes).ToString('s') + 'Z'
        Write-Info "TAP created for $($item.Upn)"
    }
    if ($tapFailures -gt 0) {
        Write-Warning "$tapFailures TAP(s) failed. Check that Temporary Access Pass is enabled in the tenant and that you hold an authentication administrator role; or create them in the Entra admin center."
    }
}

# ------------------------------------------------------------------------------------------------
# 4. Students CSV and TAP file
# ------------------------------------------------------------------------------------------------
Write-Step 'Students CSV'
if ($DryRun) {
    Write-DryRun "add/update $($plan.Count) row(s) in $StudentsCsv and write TAPs to $OutputDir\accounts.csv"
} else {
    $planUpns = @($plan | ForEach-Object { $_.Upn.ToLower() })
    $kept = @($existingRows | Where-Object { $planUpns -notcontains $_.UserPrincipalName.Trim().ToLower() })
    $rows = @()
    foreach ($row in $kept) {
        $objectId = ''
        if ($row.PSObject.Properties.Name -contains 'ObjectId') { $objectId = $row.ObjectId }
        $rows += [pscustomobject]@{ UserPrincipalName = $row.UserPrincipalName; ProjectName = $row.ProjectName; StudentId = $row.StudentId; ObjectId = $objectId }
    }
    foreach ($item in $plan) {
        $rows += [pscustomobject]@{ UserPrincipalName = $item.Upn; ProjectName = $item.Project; StudentId = $item.StudentId; ObjectId = $item.ObjectId }
    }
    $rows | Export-Csv -Path $StudentsCsv -NoTypeInformation -Encoding UTF8
    Write-Info "$($rows.Count) row(s) in $StudentsCsv"

    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    $accountsFile = Join-Path $OutputDir 'accounts.csv'
    $plan | Select-Object @{ n = 'UserPrincipalName'; e = { $_.Upn } }, @{ n = 'DisplayName'; e = { $_.DisplayName } }, @{ n = 'Project'; e = { $_.Project } },
        @{ n = 'TemporaryAccessPass'; e = { $_.Tap } }, @{ n = 'TapValidFrom'; e = { $_.TapValidFrom } }, @{ n = 'TapExpiresUtc'; e = { $_.TapExpires } } |
        Export-Csv -Path $accountsFile -NoTypeInformation -Encoding UTF8
    Write-Info "account list written to $accountsFile"
    if ($IssueTap) { Write-Host '   SENSITIVE: accounts.csv contains Temporary Access Passes. Share each pass only with its student and delete the file after the class.' -ForegroundColor Yellow }
}

# ------------------------------------------------------------------------------------------------
# 5. Access
# ------------------------------------------------------------------------------------------------
Write-Step 'Access'
if ($SkipProvisioning) {
    Write-Info 'Skipped (-SkipProvisioning). Grant access with:'
    Write-Info "./deployment/provision-workshop.ps1 -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -FoundryAccountName $FoundryAccountName -StudentsCsv $StudentsCsv"
} elseif ($DryRun) {
    Write-DryRun 'run provision-workshop.ps1 to assign Foundry User + Foundry Project Manager (own project), Reader (Foundry resource), search, registry and monitoring access, and create the shared infrastructure'
} else {
    Write-Info 'Waiting 30 seconds for the new accounts to replicate before assigning roles...'
    Start-Sleep -Seconds 30
    & (Join-Path $PSScriptRoot 'provision-workshop.ps1') -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup `
        -FoundryAccountName $FoundryAccountName -StudentsCsv $StudentsCsv @ProvisionParameters
}

Write-Step 'Done'
Write-Info 'Students sign in at https://ai.azure.com with their account and Temporary Access Pass, then open their own project.'
