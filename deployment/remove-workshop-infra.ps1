<#
.SYNOPSIS
  Instructor script: removes the shared workshop infrastructure that provision-workshop.ps1 created.
  Never deletes the resource group, the Foundry resource, the projects, or any resource it did not create.

.DESCRIPTION
  Deletes, after you type DELETE to confirm:
    - the shared Azure AI Search service (this also removes every student's knowledge source, knowledge base and index)
    - Application Insights and the Log Analytics workspace
    - the container registry ONLY if it carries the tag workshop=foundry-agent-lab (a registry that existed before
      the workshop is kept)
  Optional:
    -StudentsCsv           also removes these roles for the listed students and the project identities, on the
                           project, the Foundry resource and the registry: Foundry User, Foundry Project Manager,
                           Reader, the Search roles, Container Registry Tasks Contributor, AcrPull, Log Analytics Reader.
                           It removes them whether or not the provisioning script created them, so use it only when
                           the students' access should end.
    -RemoveEmbeddingDeployment  deletes the embedding deployment from the Foundry resource.
  Resources are only deleted when they carry the tag workshop=foundry-agent-lab, so look-alike names are safe.
  Hosted agents and Prompt Agents live in the projects: remove them with scripts/delete_lab_agents.py
  (students run it) or from the portal.

.EXAMPLE
  ./deployment/remove-workshop-infra.ps1 -SubscriptionId <id> -ResourceGroup <rg> -FoundryAccountName <name> `
      -SearchServiceName <search> -StudentsCsv ./deployment/students.csv -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SubscriptionId,
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [Parameter(Mandatory = $true)][string]$FoundryAccountName,
    [string]$SearchServiceName,
    [string]$AcrName,
    [string]$LogAnalyticsName = 'log-triage-workshop',
    [string]$AppInsightsName = 'appi-triage-workshop',
    [string]$EmbeddingDeploymentName = 'text-embedding-3-small',
    [string]$StudentsCsv,
    [switch]$RemoveEmbeddingDeployment,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$WorkshopTagValue = 'foundry-agent-lab'

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
function Get-AzJson {
    param([Parameter(Mandatory = $true)][string[]]$AzArgs, [switch]$AllowFail)
    $result = Invoke-Az -AzArgs ($AzArgs + @('-o', 'json')) -AllowFail:$AllowFail
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Output)) { return }
    foreach ($item in ($result.Output | ConvertFrom-Json)) { $item }
}

Invoke-Az -AzArgs @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
$rgScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
$accountId = "$rgScope/providers/Microsoft.CognitiveServices/accounts/$FoundryAccountName"
if (-not $SearchServiceName) { $SearchServiceName = ('srch' + ($FoundryAccountName.ToLower() -replace '[^a-z0-9]', '')) }
if ($SearchServiceName.Length -gt 60) { $SearchServiceName = $SearchServiceName.Substring(0, 60) }

# Resources to delete: only those that exist and carry the workshop tag.
$targets = @()
function Add-Target([string]$Label, [string]$ResourceId) {
    $result = Invoke-Az -AllowFail -AzArgs @('resource', 'show', '--ids', $ResourceId, '-o', 'json')
    if ($result.ExitCode -ne 0 -or -not $result.Output) { Write-Host "   not found (nothing to do): $Label"; return }
    $resource = $result.Output | ConvertFrom-Json
    $tagValue = $null
    if ($resource.tags) { $tagValue = $resource.tags.workshop }
    if ($tagValue -ne $WorkshopTagValue) { Write-Warning "Keeping $Label because it is not tagged workshop=$WorkshopTagValue (it was not created by the provisioning script)."; return }
    $script:targets += [pscustomobject]@{ Label = $Label; Id = $ResourceId }
}

Write-Host "Checking resources in '$ResourceGroup'..."
Add-Target "search service '$SearchServiceName'" "$rgScope/providers/Microsoft.Search/searchServices/$SearchServiceName"
Add-Target "Application Insights '$AppInsightsName'" "$rgScope/providers/Microsoft.Insights/components/$AppInsightsName"
Add-Target "Log Analytics workspace '$LogAnalyticsName'" "$rgScope/providers/Microsoft.OperationalInsights/workspaces/$LogAnalyticsName"
if ($AcrName) { Add-Target "registry '$AcrName'" "$rgScope/providers/Microsoft.ContainerRegistry/registries/$AcrName" }

# Role assignments to remove (only the roles the provisioning script grants).
$managedRoleIds = @(
    '53ca6127-db72-4b80-b1b0-d745d6d5456d', 'eadc314b-1a2d-4efa-be10-5d325db5065e', 'acdd72a7-3385-48ef-bd42-f606fba81ae7',
    '7ca78c08-252a-4471-8644-bb5ff32d4ba0', '8ebe5a00-799e-43f5-93ac-243d3dce84a7', '1407120a-92aa-4202-b7e9-c0e197c71c8f',
    'fb382eab-e894-4461-af04-94435c366c3f', '73c42c96-874c-492b-b04d-ab87d138a893', '7f951dda-4ed3-4680-a7ca-43fe172d538d',
    'b93aa761-3e63-49ed-ac28-beffa264f7ac', 'a97b65f3-24c7-4388-baec-2e87135dc908'
)
$assignmentsToRemove = @()
if ($StudentsCsv) {
    if (-not (Test-Path $StudentsCsv)) { throw "Students CSV not found: $StudentsCsv" }
    $rows = @(Import-Csv -Path $StudentsCsv)
    $columns = @($rows[0].PSObject.Properties.Name)
    $principals = @{}
    foreach ($row in $rows) {
        $objectId = $null
        if ($columns -contains 'ObjectId') { $objectId = ([string]$row.ObjectId).Trim() }
        if (-not $objectId) {
            $lookup = Invoke-Az -AllowFail -AzArgs @('ad', 'user', 'show', '--id', ([string]$row.UserPrincipalName).Trim(), '--query', 'id', '-o', 'tsv')
            if ($lookup.ExitCode -eq 0 -and $lookup.Output) { $objectId = $lookup.Output.Trim() }
        }
        if ($objectId) { $principals[$objectId.ToLower()] = ([string]$row.UserPrincipalName).Trim() }
        else { Write-Warning "Could not resolve '$($row.UserPrincipalName)'; its role assignments are not removed." }
    }
    # Project identities (the registry pull role).
    $page = (Invoke-Az -AzArgs @('rest', '--method', 'get', '--uri', "https://management.azure.com$accountId/projects?api-version=2025-06-01", '-o', 'json')).Output | ConvertFrom-Json
    foreach ($project in $page.value) { if ($project.identity -and $project.identity.principalId) { $principals[$project.identity.principalId.ToLower()] = "project $(($project.name -split '/')[-1])" } }

    $scopes = @($accountId) + @(
        foreach ($project in $page.value) { "$accountId/projects/$(($project.name -split '/')[-1])" }
    )
    if ($AcrName) { $scopes += "$rgScope/providers/Microsoft.ContainerRegistry/registries/$AcrName" }
    foreach ($scope in $scopes) {
        foreach ($assignment in @(Get-AzJson -AzArgs @('role', 'assignment', 'list', '--scope', $scope, '--subscription', $SubscriptionId) -AllowFail)) {
            $roleId = ($assignment.roleDefinitionId -split '/')[-1]
            if ($assignment.scope -ieq $scope -and $principals.ContainsKey($assignment.principalId.ToLower()) -and $managedRoleIds -contains $roleId) {
                $assignmentsToRemove += [pscustomobject]@{ Id = $assignment.id; Text = "$($assignment.roleDefinitionName) for $($principals[$assignment.principalId.ToLower()]) on $($scope -replace '^.*/providers/','')" }
            }
        }
    }
}

Write-Host ''
Write-Host 'The following will be removed:' -ForegroundColor Yellow
$targets | ForEach-Object { Write-Host "  resource: $($_.Label)" }
$assignmentsToRemove | ForEach-Object { Write-Host "  role    : $($_.Text)" }
if ($RemoveEmbeddingDeployment) { Write-Host "  deployment: $EmbeddingDeploymentName on $FoundryAccountName" }
if (-not $targets -and -not $assignmentsToRemove -and -not $RemoveEmbeddingDeployment) { Write-Host '  (nothing)'; return }
if ($DryRun) { Write-Host ''; Write-Host 'DRY RUN: nothing was deleted.' -ForegroundColor Yellow; return }

$answer = Read-Host "Type DELETE to continue"
if ($answer -cne 'DELETE') { Write-Host 'Cancelled.'; exit 1 }

foreach ($item in $assignmentsToRemove) {
    Invoke-Az -AzArgs @('role', 'assignment', 'delete', '--ids', $item.Id, '--subscription', $SubscriptionId) -AllowFail | Out-Null
    Write-Host "removed role: $($item.Text)"
}
if ($RemoveEmbeddingDeployment) {
    Invoke-Az -AllowFail -AzArgs @('cognitiveservices', 'account', 'deployment', 'delete', '--name', $FoundryAccountName, '--resource-group', $ResourceGroup,
        '--subscription', $SubscriptionId, '--deployment-name', $EmbeddingDeploymentName) | Out-Null
    Write-Host "removed deployment: $EmbeddingDeploymentName"
}
foreach ($target in $targets) {
    Write-Host "deleting $($target.Label)..."
    Invoke-Az -AzArgs @('resource', 'delete', '--ids', $target.Id) | Out-Null
}
Write-Host 'Done. Soft-deleted Log Analytics data is purged automatically; check the portal if anything remains.'
