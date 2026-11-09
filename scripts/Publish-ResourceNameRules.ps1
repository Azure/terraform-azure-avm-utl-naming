#requires -Version 7.4
<#
.SYNOPSIS
Publishes runtime naming-catalog updates from the scheduled GitHub Actions job.
.DESCRIPTION
Uses one reserved branch and pull request, the actual repository default branch,
ephemeral gh credential helpers, and force-with-lease. Refuses forks and dirty
checkouts. The tools workflow uses the AVM GitHub App for publication.
Tests invoke the underlying function with mocked git/gh commands, never this entry point.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ResourceNameRules.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ResourceNameCatalog.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ResourceNameRules.Automation.psm1') -Force
if (-not (Test-ResourceNameRulesPublicationContext `
    -GitHubActions $env:GITHUB_ACTIONS `
    -EventName $env:GITHUB_EVENT_NAME `
    -SourceRepository $env:GITHUB_REPOSITORY `
    -SourceRef $env:GITHUB_REF `
    -WorkflowRef $env:GITHUB_WORKFLOW_REF `
    -BaseBranch $env:NAMING_RULES_BASE_BRANCH `
    -Token $env:GH_TOKEN)) {
    throw 'Publication is only allowed from an authenticated upstream scheduled/manual workflow on its default branch.'
}
$result = Publish-ResourceNameRulesUpdate `
    -Repository 'Azure/terraform-azure-avm-utl-naming' `
    -BaseBranch $env:NAMING_RULES_BASE_BRANCH `
    -RepositoryRoot (Split-Path $PSScriptRoot -Parent) `
    -Markdown (Get-ResourceNameRulesDocument) `
    -AbbreviationsMarkdown (Get-ResourceNameRulesDocument -Uri (Get-ResourceAbbreviationsSourceUrl))

if ($result.Status -eq 'unchanged') {
    Write-Information 'The runtime catalogs are current; no publication was needed.' -InformationAction Continue
}
elseif ($result.Status -eq 'pending_review') {
    Write-Information "An existing update is awaiting review and was left unchanged: $($result.PullRequestUrl)" -InformationAction Continue
}
else {
    Write-Information "Proposed runtime naming-catalog changes: $($result.PullRequestUrl)" -InformationAction Continue
}
