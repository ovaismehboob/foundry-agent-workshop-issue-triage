<#
.SYNOPSIS
  Instructor script: provisions the shared infrastructure for the workshop and grants every student the
  access they need (Modules 4-9), so students never create resources or assign permissions themselves.

.DESCRIPTION
  Works inside an EXISTING resource group that already holds the Foundry resource and one Foundry project
  per student. It creates or reuses:
    - one shared Azure AI Search service (Standard, 1 replica, 1 partition, managed identity, RBAC + keys)
      where each student creates their own knowledge source and knowledge base (Module 4)
    - one shared Azure Container Registry (an existing one is reused; Basic is created only if none exists)
    - one shared Log Analytics workspace (daily cap) + Application Insights (Module 8)
    - an embedding model deployment on the existing Foundry resource (Module 4)
  Then it assigns least-privilege roles:
    Student     : Foundry User + Foundry Project Manager on THEIR project, Reader on the Foundry resource,
                  Search Service Contributor + Search Index Data Contributor + Search Index Data Reader on the
                  shared search service, Container Registry Tasks Contributor on the registry (remote build),
                  Log Analytics Reader on Application Insights and the workspace.
    Search MI   : Cognitive Services User on the Foundry resource (knowledge bases call the models).
    Project MIs : Search Index Data Reader/Contributor + Search Service Contributor on the search service,
                  AcrPull on the registry (hosted agents pull their image).
  Finally it writes a non-secret handout (CSV + one .env snippet per student) to the output folder.

  It does NOT create projects, students, knowledge sources, knowledge bases, guardrails or hosted agents,
  does not change tenant policy, and never deletes anything. It is safe to re-run.

  Limits to know about:
    - Roles on a shared search service are service-wide. Unique names (kbtriage-<id>) prevent accidents, they
      are not an access boundary. Tell students to touch only their own objects.
    - The Application Insights / Log Analytics access is workspace-wide: students can see each other's traces.
    - Hosted-agent identities exist only after deployment. Grant them search access afterwards with
      deployment/assign-hosted-agent-roles.ps1.
    - The guardrail is created once by the instructor in the portal (Build > Guardrails).

  Requires: Azure CLI signed in (az login) as Owner (or User Access Administrator + Contributor) on the
  resource group, and permission to read users in Microsoft Entra ID.

.PARAMETER StudentsCsv
  CSV with a header row and the columns:
    UserPrincipalName  (required)  e.g. student01@contoso.com
    ProjectName        (required)  existing Foundry project for this student, e.g. proj-student01
    StudentId          (optional)  short id used in names, e.g. s01 (default: s01, s02, ... by row order)
    ObjectId           (optional)  Entra object ID; skips the directory lookup when supplied
  See deployment/students.example.csv. Do not put passwords or Temporary Access Passes in this file.

.PARAMETER DryRun
  Validates everything and prints what would be created or assigned, without changing Azure.

.EXAMPLE
  ./deployment/provision-workshop.ps1 -SubscriptionId <subscription-id> -ResourceGroup <rg> `
      -FoundryAccountName <foundry-resource> -StudentsCsv ./deployment/students.csv -DryRun

.EXAMPLE
  ./deployment/provision-workshop.ps1 -SubscriptionId <subscription-id> -ResourceGroup <rg> `
      -FoundryAccountName <foundry-resource> -StudentsCsv ./deployment/students.csv
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SubscriptionId,
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [Parameter(Mandatory = $true)][string]$FoundryAccountName,
    [Parameter(Mandatory = $true)][string]$StudentsCsv,

    [string]$ChatDeploymentName = 'gpt-5-mini',
    [string]$EmbeddingDeploymentName = 'text-embedding-3-small',
    [string]$EmbeddingModelName = 'text-embedding-3-small',
    [string]$EmbeddingModelVersion = '1',
    [ValidateSet('Standard', 'GlobalStandard')][string]$EmbeddingSku = 'Standard',
    [int]$EmbeddingCapacity = 50,

    [string]$SearchServiceName,
    [string]$SearchLocation,
    [ValidateSet('basic', 'standard', 'standard2', 'standard3')][string]$SearchSku = 'standard',
    [ValidateSet('disabled', 'free', 'standard')][string]$SemanticSearch = 'standard',

    [string]$AcrName,
    [string]$LogAnalyticsName = 'log-triage-workshop',
    [string]$AppInsightsName = 'appi-triage-workshop',
    [double]$LogDailyCapGb = 1,

    [switch]$SkipHostedAgent,
    [switch]$SkipMonitoring,
    [switch]$DryRun,
    [string]$OutputDir
)
$ErrorActionPreference = 'Stop'

# Built-in role definition IDs (verified with `az role definition list`).
$Role = @{
    FoundryUser          = @{ Id = '53ca6127-db72-4b80-b1b0-d745d6d5456d'; Name = 'Foundry User' }
    FoundryProjectMgr    = @{ Id = 'eadc314b-1a2d-4efa-be10-5d325db5065e'; Name = 'Foundry Project Manager' }
    Reader               = @{ Id = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'; Name = 'Reader' }
    SearchServiceContrib = @{ Id = '7ca78c08-252a-4471-8644-bb5ff32d4ba0'; Name = 'Search Service Contributor' }
    SearchDataContrib    = @{ Id = '8ebe5a00-799e-43f5-93ac-243d3dce84a7'; Name = 'Search Index Data Contributor' }
    SearchDataReader     = @{ Id = '1407120a-92aa-4202-b7e9-c0e197c71c8f'; Name = 'Search Index Data Reader' }
    CognitiveServicesUse = @{ Id = 'a97b65f3-24c7-4388-baec-2e87135dc908'; Name = 'Cognitive Services User' }
    AcrPull              = @{ Id = '7f951dda-4ed3-4680-a7ca-43fe172d538d'; Name = 'AcrPull' }
    AcrRepoReader        = @{ Id = 'b93aa761-3e63-49ed-ac28-beffa264f7ac'; Name = 'Container Registry Repository Reader' }
    AcrTasksContrib      = @{ Id = 'fb382eab-e894-4461-af04-94435c366c3f'; Name = 'Container Registry Tasks Contributor' }
    LogAnalyticsReader   = @{ Id = '73c42c96-874c-492b-b04d-ab87d138a893'; Name = 'Log Analytics Reader' }
}
$WorkshopTag = 'workshop=foundry-agent-lab'
$Summary = @{ Assigned = 0; Skipped = 0; WouldAssign = 0 }
$RoleCache = @{}

# ------------------------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------------------------
function Write-Step([string]$Message) { Write-Host ''; Write-Host "== $Message" -ForegroundColor Cyan }
function Write-Info([string]$Message) { Write-Host "   $Message" }
function Write-DryRun([string]$Message) { Write-Host "   [dry run] $Message" -ForegroundColor Yellow }

# Runs the Azure CLI, captures stdout and stderr separately and never lets stderr warnings abort the script.
function Invoke-Az {
    param([Parameter(Mandatory = $true)][string[]]$AzArgs, [switch]$AllowFail)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $raw = & az @AzArgs 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $previous }
    $stdout = @($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    $stderr = @($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() })
    if ($code -ne 0 -and -not $AllowFail) {
        throw "az $($AzArgs[0..([Math]::Min(3, $AzArgs.Count - 1))] -join ' ') failed: $($stderr -join ' ')"
    }
    return [pscustomobject]@{ ExitCode = $code; Output = ($stdout -join "`n"); Error = ($stderr -join "`n") }
}

# Returns the parsed JSON (arrays are unrolled one item at a time), or nothing when the command fails.
function Get-AzJson {
    param([Parameter(Mandatory = $true)][string[]]$AzArgs, [switch]$AllowFail)
    $result = Invoke-Az -AzArgs ($AzArgs + @('-o', 'json')) -AllowFail:$AllowFail
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Output)) { return }
    $parsed = $result.Output | ConvertFrom-Json
    foreach ($item in $parsed) { $item }
}

function Invoke-ArmPut {
    param([string]$Uri, [hashtable]$Body)
    $file = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($file, ($Body | ConvertTo-Json -Depth 10 -Compress))
        Invoke-Az -AzArgs @('rest', '--method', 'put', '--uri', $Uri, '--body', "@$file", '-o', 'none') | Out-Null
    } finally { Remove-Item $file -ErrorAction SilentlyContinue }
}

function Get-ExistingAssignments([string]$Scope) {
    if (-not $RoleCache.ContainsKey($Scope)) {
        $keys = @{}
        foreach ($item in @(Get-AzJson -AzArgs @('role', 'assignment', 'list', '--scope', $Scope, '--subscription', $SubscriptionId) -AllowFail)) {
            if ($item.scope -and $item.scope -ieq $Scope) {
                $keys[("{0}|{1}" -f $item.principalId, ($item.roleDefinitionId -split '/')[-1]).ToLower()] = $true
            }
        }
        $RoleCache[$Scope] = $keys
    }
    return $RoleCache[$Scope]
}

function Grant-Role {
    param(
        [string]$PrincipalId, [ValidateSet('User', 'ServicePrincipal')][string]$PrincipalType,
        [hashtable]$RoleDef, [string]$Scope, [string]$Who, [string]$Where
    )
    $key = ("{0}|{1}" -f $PrincipalId, $RoleDef.Id).ToLower()
    $existing = Get-ExistingAssignments $Scope
    if ($existing.ContainsKey($key)) { $Summary.Skipped++; return }
    if ($DryRun) { Write-DryRun "assign '$($RoleDef.Name)' to $Who on $Where"; $Summary.WouldAssign++; return }
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        $result = Invoke-Az -AllowFail -AzArgs @(
            'role', 'assignment', 'create', '--assignee-object-id', $PrincipalId, '--assignee-principal-type', $PrincipalType,
            '--role', $RoleDef.Id, '--scope', $Scope, '--subscription', $SubscriptionId, '-o', 'none')
        if ($result.ExitCode -eq 0 -or $result.Error -match 'already exists') {
            $existing[$key] = $true; $Summary.Assigned++
            Write-Info "assigned '$($RoleDef.Name)' to $Who on $Where"
            return
        }
        # A newly created identity can take a short while to replicate.
        if ($result.Error -match 'PrincipalNotFound|does not exist in the directory' -and $attempt -lt 4) { Start-Sleep -Seconds 15; continue }
        throw "Could not assign '$($RoleDef.Name)' to $Who on ${Where}: $($result.Error)"
    }
}

function Get-ResourceIdSafe([string[]]$ShowArgs) {
    $r = Invoke-Az -AzArgs ($ShowArgs + @('--query', 'id', '-o', 'tsv')) -AllowFail
    if ($r.ExitCode -eq 0 -and $r.Output) { return $r.Output.Trim() }
}

# ------------------------------------------------------------------------------------------------
# 0. Pre-flight checks (read-only)
# ------------------------------------------------------------------------------------------------
Write-Step 'Pre-flight checks'
if ($DryRun) { Write-Host '   DRY RUN: nothing will be created or assigned.' -ForegroundColor Yellow }
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) was not found. Install it and run az login.' }
Invoke-Az -AzArgs @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
$signedIn = (Invoke-Az -AzArgs @('account', 'show', '--query', 'user.name', '-o', 'tsv')).Output.Trim()
Write-Info "Signed in as $signedIn, subscription $SubscriptionId"

$rgInfo = Get-AzJson -AzArgs @('group', 'show', '--name', $ResourceGroup, '--subscription', $SubscriptionId) -AllowFail
if (-not $rgInfo) { throw "Resource group '$ResourceGroup' was not found in this subscription." }
$Location = $rgInfo.location
if (-not $SearchLocation) { $SearchLocation = $Location }

$accountId = Get-ResourceIdSafe @('cognitiveservices', 'account', 'show', '--name', $FoundryAccountName, '--resource-group', $ResourceGroup, '--subscription', $SubscriptionId)
if (-not $accountId) { throw "Foundry resource '$FoundryAccountName' was not found in '$ResourceGroup'." }
Write-Info "Foundry resource '$FoundryAccountName' found in $Location"

if (-not $SearchServiceName) { $SearchServiceName = ('srch' + ($FoundryAccountName.ToLower() -replace '[^a-z0-9]', '')) }
if ($SearchServiceName.Length -gt 60) { $SearchServiceName = $SearchServiceName.Substring(0, 60) }
$searchEndpoint = "https://$SearchServiceName.search.windows.net"

# Foundry projects (follows paging links).
$projects = @{}
$uri = "https://management.azure.com$accountId/projects?api-version=2025-06-01"
while ($uri) {
    $page = (Invoke-Az -AzArgs @('rest', '--method', 'get', '--uri', $uri, '-o', 'json')).Output | ConvertFrom-Json
    foreach ($p in $page.value) {
        $shortName = ($p.name -split '/')[-1]
        $endpoint = $null
        if ($p.properties.endpoints) { $endpoint = $p.properties.endpoints.'AI Foundry API' }
        $principal = $null
        if ($p.identity) { $principal = $p.identity.principalId }
        $projects[$shortName.ToLower()] = @{ Name = $shortName; PrincipalId = $principal; Endpoint = $endpoint }
    }
    $uri = $page.nextLink
}
Write-Info "$($projects.Count) Foundry project(s) found"

# Student CSV.
if (-not (Test-Path $StudentsCsv)) { throw "Students CSV not found: $StudentsCsv" }
$rows = @(Import-Csv -Path $StudentsCsv)
if ($rows.Count -eq 0) { throw 'The students CSV has no rows.' }
$columns = @($rows[0].PSObject.Properties.Name)
foreach ($required in 'UserPrincipalName', 'ProjectName') {
    if ($columns -notcontains $required) { throw "The students CSV needs a '$required' column. Found: $($columns -join ', ')" }
}
$maxKnowledgeBases = if ($SearchSku -eq 'basic') { 15 } elseif ($SearchSku -eq 'standard') { 50 } else { 200 }
if ($rows.Count -gt $maxKnowledgeBases - 2) {
    throw "$($rows.Count) students is more than a '$SearchSku' search service supports (about $maxKnowledgeBases knowledge bases). Use a larger SKU."
}

$students = @()
$problems = @()
$index = 0
foreach ($row in $rows) {
    $index++
    $upn = ([string]$row.UserPrincipalName).Trim()
    $projectKey = ([string]$row.ProjectName).Trim() -replace '^.*/', ''
    $studentId = if ($columns -contains 'StudentId' -and ([string]$row.StudentId).Trim()) { ([string]$row.StudentId).Trim().ToLower() } else { 's{0:d2}' -f $index }
    if ($studentId -notmatch '^[a-z0-9][a-z0-9-]{0,19}$') { $problems += "Row ${index}: StudentId '$studentId' must be lowercase letters, digits or dashes (max 20)."; continue }
    if (-not $upn) { $problems += "Row ${index}: UserPrincipalName is empty."; continue }
    if (-not $projects.ContainsKey($projectKey.ToLower())) { $problems += "Row ${index}: project '$projectKey' does not exist on '$FoundryAccountName'."; continue }

    $objectId = $null
    if ($columns -contains 'ObjectId') { $objectId = ([string]$row.ObjectId).Trim() }
    if (-not $objectId) {
        $lookup = Invoke-Az -AzArgs @('ad', 'user', 'show', '--id', $upn, '--query', 'id', '-o', 'tsv') -AllowFail
        if ($lookup.ExitCode -ne 0 -or -not $lookup.Output) { $problems += "Row ${index}: user '$upn' was not found in Microsoft Entra ID (create the account first, or supply ObjectId)."; continue }
        $objectId = $lookup.Output.Trim()
    }
    $project = $projects[$projectKey.ToLower()]
    $students += [pscustomobject]@{
        StudentId = $studentId; Upn = $upn; ObjectId = $objectId; Project = $project
        KnowledgeBase = "kbtriage-$studentId"; KnowledgeSource = "kstriage-$studentId"
    }
}
foreach ($dup in ($students | Group-Object StudentId | Where-Object Count -gt 1)) { $problems += "StudentId '$($dup.Name)' is used more than once." }
foreach ($dup in ($students | Group-Object ObjectId | Where-Object Count -gt 1)) { $problems += "A user appears more than once ($($dup.Name))." }
foreach ($dup in ($students | Group-Object { $_.Project.Name } | Where-Object Count -gt 1)) { Write-Warning "Project '$($dup.Name)' is assigned to more than one student: they will share it." }
if ($problems.Count -gt 0) { throw ("The students CSV has problems:`n - " + ($problems -join "`n - ")) }
Write-Info "$($students.Count) student(s) validated"

# ------------------------------------------------------------------------------------------------
# 1. Shared Azure AI Search
# ------------------------------------------------------------------------------------------------
Write-Step "Azure AI Search: $SearchServiceName ($SearchSku)"
$search = Get-AzJson -AzArgs @('search', 'service', 'show', '--name', $SearchServiceName, '--resource-group', $ResourceGroup, '--subscription', $SubscriptionId) -AllowFail
$searchPrincipal = $null
if ($search) {
    Write-Info "exists (SKU $($search.sku.name)); making sure managed identity and RBAC are enabled"
    if (-not $DryRun) {
        Invoke-Az -AzArgs @('search', 'service', 'update', '--name', $SearchServiceName, '--resource-group', $ResourceGroup, '--subscription', $SubscriptionId,
            '--identity-type', 'SystemAssigned', '--auth-options', 'aadOrApiKey', '--aad-auth-failure-mode', 'http401WithBearerChallenge', '-o', 'none') | Out-Null
        $search = Get-AzJson -AzArgs @('search', 'service', 'show', '--name', $SearchServiceName, '--resource-group', $ResourceGroup, '--subscription', $SubscriptionId)
    }
} elseif ($DryRun) {
    Write-DryRun "create search service '$SearchServiceName' ($SearchSku, 1 replica, 1 partition, $SearchLocation, semantic ranker: $SemanticSearch)"
} else {
    Write-Info "creating (this takes a few minutes)..."
    Invoke-Az -AzArgs @('search', 'service', 'create', '--name', $SearchServiceName, '--resource-group', $ResourceGroup, '--subscription', $SubscriptionId,
        '--location', $SearchLocation, '--sku', $SearchSku, '--replica-count', '1', '--partition-count', '1',
        '--identity-type', 'SystemAssigned', '--auth-options', 'aadOrApiKey', '--aad-auth-failure-mode', 'http401WithBearerChallenge',
        '--semantic-search', $SemanticSearch, '--public-network-access', 'enabled', '--tags', $WorkshopTag, '-o', 'none') | Out-Null
    $search = Get-AzJson -AzArgs @('search', 'service', 'show', '--name', $SearchServiceName, '--resource-group', $ResourceGroup, '--subscription', $SubscriptionId)
}
if ($search -and $search.identity) { $searchPrincipal = $search.identity.principalId }
$searchId = Get-ResourceIdSafe @('search', 'service', 'show', '--name', $SearchServiceName, '--resource-group', $ResourceGroup, '--subscription', $SubscriptionId)
if (-not $searchId) { $searchId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Search/searchServices/$SearchServiceName" }

# ------------------------------------------------------------------------------------------------
# 2. Container registry (hosted agents, Module 7)
# ------------------------------------------------------------------------------------------------
$acrId = $null; $acrLoginServer = ''; $acrPullRole = $Role.AcrPull
if (-not $SkipHostedAgent) {
    Write-Step 'Azure Container Registry'
    if (-not $AcrName) {
        $found = @(Get-AzJson -AzArgs @('acr', 'list', '--resource-group', $ResourceGroup, '--subscription', $SubscriptionId) -AllowFail)
        if ($found.Count -eq 1) { $AcrName = $found[0].name }
        elseif ($found.Count -gt 1) { throw "Several registries exist in '$ResourceGroup'. Pass -AcrName." }
        else { throw "No registry found in '$ResourceGroup'. Pass -AcrName <new-name> to create a Basic registry, or -SkipHostedAgent." }
    }
    $acr = Get-AzJson -AzArgs @('acr', 'show', '--name', $AcrName, '--resource-group', $ResourceGroup, '--subscription', $SubscriptionId) -AllowFail
    if ($acr) {
        Write-Info "reusing existing registry '$AcrName' (SKU $($acr.sku.name))"
        $acrLoginServer = $acr.loginServer
        if ($acr.roleAssignmentMode -and $acr.roleAssignmentMode -notmatch 'Legacy') {
            $acrPullRole = $Role.AcrRepoReader
            Write-Warning "Registry uses '$($acr.roleAssignmentMode)'. Using 'Container Registry Repository Reader' for image pulls; validate with one student."
        }
    } elseif ($DryRun) {
        Write-DryRun "create Basic registry '$AcrName' in $Location"
    } else {
        Write-Info "creating Basic registry '$AcrName'..."
        Invoke-Az -AzArgs @('acr', 'create', '--name', $AcrName, '--resource-group', $ResourceGroup, '--subscription', $SubscriptionId,
            '--location', $Location, '--sku', 'Basic', '--admin-enabled', 'false', '--tags', $WorkshopTag, '-o', 'none') | Out-Null
        $acr = Get-AzJson -AzArgs @('acr', 'show', '--name', $AcrName, '--resource-group', $ResourceGroup, '--subscription', $SubscriptionId)
        $acrLoginServer = $acr.loginServer
    }
    $acrId = Get-ResourceIdSafe @('acr', 'show', '--name', $AcrName, '--resource-group', $ResourceGroup, '--subscription', $SubscriptionId)
    if (-not $acrId) { $acrId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ContainerRegistry/registries/$AcrName" }
}

# ------------------------------------------------------------------------------------------------
# 3. Application Insights + Log Analytics (Module 8)
# ------------------------------------------------------------------------------------------------
$appInsightsId = $null; $workspaceId = $null
if (-not $SkipMonitoring) {
    Write-Step "Monitoring: $LogAnalyticsName / $AppInsightsName"
    $workspaceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.OperationalInsights/workspaces/$LogAnalyticsName"
    $appInsightsId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Insights/components/$AppInsightsName"
    $tagBody = @{ workshop = 'foundry-agent-lab' }

    if (Get-ResourceIdSafe @('monitor', 'log-analytics', 'workspace', 'show', '--workspace-name', $LogAnalyticsName, '--resource-group', $ResourceGroup, '--subscription', $SubscriptionId)) {
        Write-Info "workspace '$LogAnalyticsName' exists"
    } elseif ($DryRun) {
        Write-DryRun "create Log Analytics workspace '$LogAnalyticsName' (30 days retention, daily cap $LogDailyCapGb GB)"
    } else {
        Write-Info "creating Log Analytics workspace (daily cap $LogDailyCapGb GB)..."
        Invoke-ArmPut -Uri "https://management.azure.com${workspaceId}?api-version=2023-09-01" -Body @{
            location = $Location; tags = $tagBody
            properties = @{ sku = @{ name = 'PerGB2018' }; retentionInDays = 30; workspaceCapping = @{ dailyQuotaGb = $LogDailyCapGb } }
        }
        for ($i = 0; $i -lt 30; $i++) {
            $state = Invoke-Az -AllowFail -AzArgs @('resource', 'show', '--ids', $workspaceId, '--query', 'properties.provisioningState', '-o', 'tsv')
            if ($state.Output.Trim() -eq 'Succeeded') { break }
            Start-Sleep -Seconds 5
        }
    }

    $existingInsights = Invoke-Az -AllowFail -AzArgs @('resource', 'show', '--ids', $appInsightsId, '--query', 'id', '-o', 'tsv')
    if ($existingInsights.ExitCode -eq 0 -and $existingInsights.Output) {
        Write-Info "Application Insights '$AppInsightsName' exists"
    } elseif ($DryRun) {
        Write-DryRun "create Application Insights '$AppInsightsName' linked to '$LogAnalyticsName'"
    } else {
        Write-Info 'creating Application Insights...'
        Invoke-ArmPut -Uri "https://management.azure.com${appInsightsId}?api-version=2020-02-02" -Body @{
            location = $Location; kind = 'web'; tags = $tagBody
            properties = @{ Application_Type = 'web'; WorkspaceResourceId = $workspaceId; IngestionMode = 'LogAnalytics' }
        }
    }
}

# ------------------------------------------------------------------------------------------------
# 4. Model deployments on the existing Foundry resource
# ------------------------------------------------------------------------------------------------
Write-Step 'Model deployments'
$deployments = @(Get-AzJson -AzArgs @('cognitiveservices', 'account', 'deployment', 'list', '--name', $FoundryAccountName, '--resource-group', $ResourceGroup, '--subscription', $SubscriptionId))
$deploymentNames = @($deployments | ForEach-Object { $_.name })
if ($deploymentNames -contains $ChatDeploymentName) { Write-Info "chat deployment '$ChatDeploymentName' found" }
else { Write-Warning "Chat deployment '$ChatDeploymentName' was not found on '$FoundryAccountName'. Students' MICROSOFT_FOUNDRY_MODEL_DEPLOYMENT_NAME would be wrong; pass -ChatDeploymentName." }
if ($deploymentNames -contains $EmbeddingDeploymentName) {
    Write-Info "embedding deployment '$EmbeddingDeploymentName' exists"
} elseif ($DryRun) {
    Write-DryRun "deploy '$EmbeddingDeploymentName' (model $EmbeddingModelName v$EmbeddingModelVersion, $EmbeddingSku, capacity $EmbeddingCapacity)"
} else {
    Write-Info "deploying '$EmbeddingDeploymentName' ($EmbeddingSku, capacity $EmbeddingCapacity)..."
    Invoke-Az -AzArgs @('cognitiveservices', 'account', 'deployment', 'create', '--name', $FoundryAccountName, '--resource-group', $ResourceGroup,
        '--subscription', $SubscriptionId, '--deployment-name', $EmbeddingDeploymentName, '--model-name', $EmbeddingModelName,
        '--model-version', $EmbeddingModelVersion, '--model-format', 'OpenAI', '--sku-name', $EmbeddingSku, '--sku-capacity', "$EmbeddingCapacity", '-o', 'none') | Out-Null
}

# ------------------------------------------------------------------------------------------------
# 5. Role assignments
# ------------------------------------------------------------------------------------------------
Write-Step 'Role assignments'
if ($searchPrincipal -or $DryRun) {
    if ($searchPrincipal) {
        Grant-Role -PrincipalId $searchPrincipal -PrincipalType ServicePrincipal -RoleDef $Role.CognitiveServicesUse -Scope $accountId `
            -Who "search service '$SearchServiceName' (managed identity)" -Where "Foundry resource '$FoundryAccountName'"
    } else { Write-DryRun "assign 'Cognitive Services User' to the new search service identity on the Foundry resource" }
} else { throw "The search service '$SearchServiceName' has no managed identity." }

$seenProjects = @{}
foreach ($student in $students) {
    $projectName = $student.Project.Name
    $projectScope = "$accountId/projects/$projectName"
    $who = "$($student.Upn)"

    Grant-Role -PrincipalId $student.ObjectId -PrincipalType User -RoleDef $Role.FoundryUser -Scope $projectScope -Who $who -Where "project '$projectName'"
    Grant-Role -PrincipalId $student.ObjectId -PrincipalType User -RoleDef $Role.FoundryProjectMgr -Scope $projectScope -Who $who -Where "project '$projectName'"
    Grant-Role -PrincipalId $student.ObjectId -PrincipalType User -RoleDef $Role.Reader -Scope $accountId -Who $who -Where "Foundry resource '$FoundryAccountName'"
    foreach ($searchRole in $Role.SearchServiceContrib, $Role.SearchDataContrib, $Role.SearchDataReader) {
        Grant-Role -PrincipalId $student.ObjectId -PrincipalType User -RoleDef $searchRole -Scope $searchId -Who $who -Where "search service '$SearchServiceName'"
    }
    if ($acrId) { Grant-Role -PrincipalId $student.ObjectId -PrincipalType User -RoleDef $Role.AcrTasksContrib -Scope $acrId -Who $who -Where "registry '$AcrName'" }
    if ($appInsightsId) {
        Grant-Role -PrincipalId $student.ObjectId -PrincipalType User -RoleDef $Role.LogAnalyticsReader -Scope $appInsightsId -Who $who -Where "Application Insights '$AppInsightsName'"
        Grant-Role -PrincipalId $student.ObjectId -PrincipalType User -RoleDef $Role.LogAnalyticsReader -Scope $workspaceId -Who $who -Where "workspace '$LogAnalyticsName'"
    }

    if (-not $seenProjects.ContainsKey($projectName)) {
        $seenProjects[$projectName] = $true
        $projectPrincipal = $student.Project.PrincipalId
        if (-not $projectPrincipal) { Write-Warning "Project '$projectName' has no system-assigned identity; skipping its search and registry roles."; continue }
        $projectWho = "project '$projectName' (managed identity)"
        foreach ($searchRole in $Role.SearchDataReader, $Role.SearchDataContrib, $Role.SearchServiceContrib) {
            Grant-Role -PrincipalId $projectPrincipal -PrincipalType ServicePrincipal -RoleDef $searchRole -Scope $searchId -Who $projectWho -Where "search service '$SearchServiceName'"
        }
        if ($acrId) { Grant-Role -PrincipalId $projectPrincipal -PrincipalType ServicePrincipal -RoleDef $acrPullRole -Scope $acrId -Who $projectWho -Where "registry '$AcrName'" }
    }
}

# ------------------------------------------------------------------------------------------------
# 6. Student handout (non-secret)
# ------------------------------------------------------------------------------------------------
Write-Step 'Student handout'
if (-not $OutputDir) { $OutputDir = Join-Path $PSScriptRoot 'output' }
if ($DryRun) {
    Write-DryRun "write handout.csv and one <student>.env.txt per student to $OutputDir"
} else {
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    $handout = foreach ($student in $students) {
        [pscustomobject]@{
            StudentId = $student.StudentId; UserPrincipalName = $student.Upn; ProjectName = $student.Project.Name
            ProjectEndpoint = $student.Project.Endpoint; ChatDeployment = $ChatDeploymentName; EmbeddingDeployment = $EmbeddingDeploymentName
            SearchService = $SearchServiceName; SearchEndpoint = $searchEndpoint
            KnowledgeBaseName = $student.KnowledgeBase; KnowledgeSourceName = $student.KnowledgeSource
            RegistryName = $AcrName; RegistryLoginServer = $acrLoginServer
        }
        $envText = @(
            "# Copy these lines into app/.env (this file contains no secrets)",
            "FOUNDRY_PROJECT_ENDPOINT=$($student.Project.Endpoint)",
            "MICROSOFT_FOUNDRY_MODEL_DEPLOYMENT_NAME=$ChatDeploymentName",
            "PROMPT_AGENT_NAME=issue-triage-agent",
            "PROMPT_AGENT_VERSION=1",
            "",
            "# Module 5 (after you create your knowledge base in Module 4)",
            "AZURE_SEARCH_ENDPOINT=$searchEndpoint",
            "AZURE_SEARCH_KNOWLEDGE_BASE_NAME=$($student.KnowledgeBase)",
            "",
            "# Names to use in the portal",
            "# Knowledge source: $($student.KnowledgeSource)",
            "# Knowledge base  : $($student.KnowledgeBase)",
            "# Embedding model : $EmbeddingDeploymentName",
            "# Registry (Module 7): $AcrName"
        ) -join "`r`n"
        [System.IO.File]::WriteAllText((Join-Path $OutputDir "$($student.StudentId).env.txt"), $envText + "`r`n")
    }
    $handout | Export-Csv -Path (Join-Path $OutputDir 'handout.csv') -NoTypeInformation -Encoding UTF8
    Write-Info "written to $OutputDir (ignored by Git)"
}

Write-Step 'Done'
Write-Info ("Role assignments: {0} created, {1} already present, {2} would be created (dry run)" -f $Summary.Assigned, $Summary.Skipped, $Summary.WouldAssign)
Write-Host @"

Next steps for the instructor:
  1. Pilot with ONE student account end to end (Modules 4, 5, 7, 8) before the class. Role assignments can take a few minutes.
  2. Create the guardrail once (Foundry portal > Build > Guardrails) and have students assign it to their agent in Module 8.
  3. After each student deploys a hosted agent (Module 7), grant its identity access to search:
       ./deployment/assign-hosted-agent-roles.ps1 -AgentPrincipalId <id> -SearchServiceName $SearchServiceName -ResourceGroup $ResourceGroup
  4. After the workshop run ./deployment/remove-workshop-infra.ps1 to delete what this script created.
"@
