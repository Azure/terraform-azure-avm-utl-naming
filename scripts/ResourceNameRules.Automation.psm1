#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ResourceNameRules.psm1')
Import-Module (Join-Path $PSScriptRoot 'ResourceNameCatalog.psm1')

function Test-ResourceNameRulesPublicationContext {
    param(
        [string] $GitHubActions,
        [string] $EventName,
        [string] $SourceRepository,
        [string] $SourceRef,
        [string] $WorkflowRef,
        [string] $BaseBranch,
        [string] $Token
    )

    if ($GitHubActions -cne 'true' -or $EventName -notin @('schedule', 'workflow_dispatch') -or
        [string]::IsNullOrWhiteSpace($BaseBranch) -or [string]::IsNullOrWhiteSpace($Token)) {
        return $false
    }
    return (
        ($SourceRepository -ceq 'Azure/terraform-azure-avm-utl-naming' -and $SourceRef -ceq "refs/heads/$BaseBranch") -or
        ($SourceRepository -ceq 'Azure/azure-verified-modules-tools' -and $SourceRef -ceq 'refs/heads/main' -and
            $WorkflowRef -ceq 'Azure/azure-verified-modules-tools/.github/workflows/repository-management-resource-name-rules-sync.yml@refs/heads/main')
    )
}

function Invoke-ResourceNameRulesNativeCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $FileName,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $ArgumentList,
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [ValidateRange(1, 300)][int] $TimeoutSeconds = 120
    )

    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FileName
    $start.WorkingDirectory = $WorkingDirectory
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false, $true)
    $start.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false, $true)
    $start.Environment['GIT_TERMINAL_PROMPT'] = '0'
    $start.Environment['GH_PROMPT_DISABLED'] = '1'
    $start.Environment['GH_HOST'] = 'github.com'
    foreach ($argument in $ArgumentList) {
        [void] $start.ArgumentList.Add($argument)
    }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) {
            throw "Could not start $FileName."
        }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "$FileName exceeded the command timeout."
        }
        return [pscustomobject] @{
            ExitCode = $process.ExitCode
            StdOut = $stdout.GetAwaiter().GetResult()
            StdErr = $stderr.GetAwaiter().GetResult()
        }
    }
    finally {
        $process.Dispose()
    }
}

function Publish-ResourceNameRulesUpdate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $BaseBranch,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Markdown,
        [Parameter(Mandatory)][AllowEmptyString()][string] $AbbreviationsMarkdown,

        # Local tests replace the process boundary; remote content is never executable input.
        [scriptblock] $CommandRunner,
        [scriptblock] $ValidationRunner
    )

    $branch = 'automation/resource-name-rules-additions'
    $catalogPaths = @('data/resource-name-rules.json', 'data/resource-name-rules.manual.json')
    $generatedPath = Join-Path $RepositoryRoot 'data' 'resource-name-rules.json'
    $manualPath = Join-Path $RepositoryRoot 'data' 'resource-name-rules.manual.json'
    if ($Repository -cne 'Azure/terraform-azure-avm-utl-naming') {
        throw 'Publication is restricted to the upstream naming module repository, never forks.'
    }
    if ([string]::IsNullOrWhiteSpace($BaseBranch) -or $BaseBranch -ceq $branch) {
        throw 'The publication base must be the repository default branch.'
    }
    $null = ConvertFrom-ResourceNameRulesMarkdown -Markdown $Markdown
    $null = ConvertFrom-ResourceAbbreviationsMarkdown -Markdown $AbbreviationsMarkdown
    if ($null -eq $CommandRunner) {
        $CommandRunner = {
            param($FileName, $Arguments, $Directory)
            Invoke-ResourceNameRulesNativeCommand -FileName $FileName -ArgumentList $Arguments -WorkingDirectory $Directory
        }
    }
    $run = {
        param([string] $FileName, [string[]] $Arguments, [int[]] $AllowedExitCodes = @(0))
        $result = & $CommandRunner $FileName $Arguments $RepositoryRoot
        if ($null -eq $result) {
            throw "$FileName command returned no result; publication was not completed."
        }
        if ($result.ExitCode -notin $AllowedExitCodes) {
            $operationIndex = 0
            while ($Arguments[$operationIndex] -eq '-c') {
                $operationIndex += 2
            }
            throw "$FileName command failed during $($Arguments[$operationIndex]); publication was not completed (exit code $($result.ExitCode))."
        }
        return $result
    }
    $authentication = @('-c', 'credential.helper=', '-c', 'credential.https://github.com.helper=!gh auth git-credential')
    $status = & $run 'git' @('status', '--porcelain', '--untracked-files=all')
    if (-not [string]::IsNullOrWhiteSpace($status.StdOut)) {
        throw 'Publication requires a clean checkout; refusing to include unrelated changes.'
    }
    $origin = (& $run 'git' @('remote', 'get-url', 'origin')).StdOut.Trim()
    if ($origin -notmatch ('^https://github\.com/' + [regex]::Escape($Repository) + '(?:\.git)?$')) {
        throw 'The origin remote is not the expected upstream GitHub repository.'
    }
    $repositoryInfo = (& $run 'gh' @('api', "repos/$Repository")).StdOut | ConvertFrom-Json -AsHashtable
    if ($repositoryInfo.fork -isnot [bool] -or $repositoryInfo.fork -or
        $repositoryInfo.full_name -cne $Repository -or $repositoryInfo.default_branch -cne $BaseBranch) {
        throw 'Refusing publication to a fork or a non-default base branch.'
    }
    $openResult = & $run 'gh' @(
        'api', '--method', 'GET', "repos/$Repository/pulls",
        '-f', 'state=open', '-f', "head=Azure:$branch", '-f', "base=$BaseBranch", '-f', 'per_page=100'
    )
    $open = ConvertFrom-Json -InputObject $openResult.StdOut -NoEnumerate
    if ($open -isnot [array] -or $open.Count -gt 1) { throw 'Expected at most one open naming-catalog update.' }
    if ($open.Count -eq 1) {
        $existing = $open[0]
        if ($existing.head.repo.full_name -cne $Repository -or $existing.head.ref -cne $branch -or
            $existing.base.repo.full_name -cne $Repository -or $existing.base.ref -cne $BaseBranch -or
            $existing.number -lt 1) {
            throw 'The existing update does not belong to the expected upstream branch and base.'
        }
        return [pscustomobject]@{
            Status = 'pending_review'; Changed = $false; Pushed = $false
            PullRequestUrl = "https://github.com/$Repository/pull/$($existing.number)"
        }
    }
    $null = & $run 'git' @('check-ref-format', "refs/heads/$BaseBranch")
    $baseRef = "refs/remotes/origin/$BaseBranch"
    $updateRef = "refs/remotes/origin/$branch"
    $null = & $run 'git' ($authentication + @('fetch', '--no-tags', 'origin', "+refs/heads/${BaseBranch}:$baseRef"))
    $remote = & $run 'git' ($authentication + @('ls-remote', '--exit-code', '--heads', 'origin', "refs/heads/$branch")) @(0, 2)
    $expectedHead = ''
    if ($remote.ExitCode -eq 0) {
        if ($remote.StdOut.Trim() -notmatch ('^[a-f0-9]{40}\s+refs/heads/' + [regex]::Escape($branch) + '$')) {
            throw 'Unexpected response while checking the update branch.'
        }
        $null = & $run 'git' ($authentication + @('fetch', '--no-tags', 'origin', "+refs/heads/${branch}:$updateRef"))
        $expectedHead = (& $run 'git' @('rev-parse', $updateRef)).StdOut.Trim()
        if ($expectedHead -notmatch '^[a-f0-9]{40}$') {
            throw 'Could not resolve the update branch commit.'
        }
        $commonBase = (& $run 'git' @('merge-base', $baseRef, $updateRef)).StdOut.Trim()
        if ($commonBase -notmatch '^[a-f0-9]{40}$') {
            throw 'The update branch has no verifiable common base.'
        }
        $branchChanges = @((& $run 'git' @('diff', '--name-only', $commonBase, $updateRef)).StdOut.Trim() -split '\r?\n' | Where-Object { $_ -ne '' })
        if (@($branchChanges | Where-Object { $_ -notin $catalogPaths }).Count -gt 0) {
            throw 'The reserved automation branch contains changes outside the naming catalogs; refusing to overwrite them.'
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($remote.StdOut)) {
        throw 'Unexpected output while checking for an absent update branch.'
    }

    $null = & $run 'git' @('checkout', '-B', $branch, $baseRef)
    $update = Update-ResourceNameCatalog -RulesMarkdown $Markdown -AbbreviationsMarkdown $AbbreviationsMarkdown -GeneratedPath $generatedPath -ManualPath $manualPath
    if (-not $update.Changed) {
        return [pscustomobject] @{ Status = 'unchanged'; Changed = $false; Pushed = $false; PullRequestUrl = $null }
    }
    $changedPaths = @((& $run 'git' @('diff', '--name-only')).StdOut.Trim() -split '\r?\n' | Where-Object { $_ -ne '' })
    if ($changedPaths.Count -eq 0 -or @($changedPaths | Where-Object { $_ -notin $catalogPaths }).Count -gt 0) {
        throw 'Catalog generation produced an unexpected change set.'
    }
    if ($null -eq $ValidationRunner) {
        $ValidationRunner = { Import-Module Avm.Authoring -ErrorAction Stop; avm test unit }
    }
    Push-Location -LiteralPath $RepositoryRoot
    try { & $ValidationRunner }
    finally { Pop-Location }
    $null = & $run 'git' (@('add', '--') + $catalogPaths)
    $stagedPaths = @((& $run 'git' @('diff', '--cached', '--name-only')).StdOut.Trim() -split '\r?\n' | Where-Object { $_ -ne '' })
    if ($stagedPaths.Count -eq 0 -or @($stagedPaths | Where-Object { $_ -notin $catalogPaths }).Count -gt 0) {
        throw 'The staged update contains unexpected files.'
    }
    $commitMessage = "chore: refresh documented Azure naming catalogs`n`nCo-authored-by: Copilot App <223556219+Copilot@users.noreply.github.com>"
    $null = & $run 'git' @(
        '-c', 'user.name=github-actions[bot]',
        '-c', 'user.email=41898282+github-actions[bot]@users.noreply.github.com',
        '-c', 'commit.gpgsign=false', 'commit', '-m', $commitMessage
    )
    $null = & $run 'git' ($authentication + @(
        'push', '--porcelain', "--force-with-lease=refs/heads/${branch}:$expectedHead",
        'origin', "HEAD:refs/heads/$branch"
    ))
    $title = 'chore: refresh documented Azure naming catalogs'
    $body = @'
## Runtime naming-catalog refresh

This change refreshes `data/resource-name-rules.json` while preserving the additions and property overrides in `data/resource-name-rules.manual.json`.

Sources: [Azure naming rules](https://github.com/MicrosoftDocs/azure-docs/blob/main/articles/azure-resource-manager/management/resource-name-rules.md) and [CAF abbreviations](https://github.com/MicrosoftDocs/cloud-adoption-framework/blob/main/docs/ready/azure-best-practices/resource-abbreviations.md).

### Review boundary

- These files are consumed by Terraform: corrected rules, abbreviations, variants, or keys can change generated names.
- Review additions, effective generated/manual property merges, and formerly documented entries retained beneath their manual patches.
- Source text and limitations are retained. Unknown validation is not a successful validation result.
- Only these two naming data files are included; no Terraform code is generated.
- Open review requests are not rewritten by later scheduled runs.
- **Human review is required. This workflow never approves or automatically merges pull requests.**

### Automation notes

The tools workflow runs parser/publication tests and native Terraform unit tests before publishing with the AVM GitHub App. The resulting pull request triggers the normal repository checks.
'@
    $pullRequestsResult = & $run 'gh' @(
        'api', '--method', 'GET', "repos/$Repository/pulls",
        '-f', 'state=open', '-f', "head=Azure:$branch", '-f', "base=$BaseBranch", '-f', 'per_page=100'
    )
    $pullRequests = ConvertFrom-Json -InputObject $pullRequestsResult.StdOut -NoEnumerate
    if ($pullRequests -isnot [array] -or $pullRequests.Count -gt 1) {
        throw 'Expected zero or one open pull request for the stable update branch.'
    }
    if ($pullRequests.Count -eq 0) {
        $created = & $run 'gh' @(
            'pr', 'create', '--repo', $Repository, '--base', $BaseBranch, '--head', $branch,
            '--title', $title, '--body', $body
        )
        $pullRequestUrl = $created.StdOut.Trim()
        if ($pullRequestUrl -notmatch ('^https://github\.com/' + [regex]::Escape($Repository) + '/pull/[0-9]+$')) {
            throw 'GitHub did not return a verifiable pull request URL.'
        }
    }
    else {
        $pullRequest = $pullRequests[0]
        if (($pullRequest.number -isnot [long] -and $pullRequest.number -isnot [int]) -or $pullRequest.number -lt 1) {
            throw 'GitHub returned an invalid pull request number.'
        }
        if ($pullRequest.head.repo.full_name -cne $Repository -or $pullRequest.head.ref -cne $branch -or
            $pullRequest.base.repo.full_name -cne $Repository -or $pullRequest.base.ref -cne $BaseBranch) {
            throw 'The existing pull request does not belong to the expected upstream branch and base.'
        }
        if ($pullRequest.title -cne $title -or $pullRequest.body -cne $body) {
            $null = & $run 'gh' @(
                'api', '--method', 'PATCH', "repos/$Repository/pulls/$($pullRequest.number)",
                '-f', "title=$title", '-f', "body=$body"
            )
        }
        $pullRequestUrl = "https://github.com/$Repository/pull/$($pullRequest.number)"
    }
    return [pscustomobject] @{ Status = 'proposed'; Changed = $true; Pushed = $true; PullRequestUrl = $pullRequestUrl }
}

Export-ModuleMember -Function Test-ResourceNameRulesPublicationContext, Invoke-ResourceNameRulesNativeCommand, Publish-ResourceNameRulesUpdate
