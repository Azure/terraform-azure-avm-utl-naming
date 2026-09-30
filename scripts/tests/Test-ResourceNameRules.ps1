#requires -Version 7.4

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\ResourceNameRules.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\ResourceNameCatalog.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\ResourceNameRules.Automation.psm1') -Force
$script:Passed = 0

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Exception {
    param([scriptblock] $Action, [string] $Pattern)
    try { & $Action }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
        return
    }
    throw "Expected an error matching '$Pattern'."
}

function Test-Case {
    param([string] $Name, [scriptblock] $Body)
    & $Body
    $script:Passed++
    Write-Output "PASS $Name"
}

function Get-RulesDocument {
    param([string] $Extra = '')
    return @"
# Naming rules and restrictions for Azure resources

## Microsoft.Storage
| Entity | Scope | Length | Valid Characters |
| --- | --- | --- | --- |
| storageAccounts | global | 3-24 | Lowercase letters and numbers |

## Microsoft.Web
| Entity | Scope | Length | Valid Characters |
| --- | --- | --- | --- |
| sites | global | 2-60 | Alphanumerics and hyphens. Start and end with alphanumeric. |

## Microsoft.Foo
| Entity | Scope | Length | Valid Characters |
| --- | --- | --- | --- |
| servers | parent | 1-20 | Alphanumerics |

## Microsoft.Bar
| Entity | Scope | Length | Valid Characters |
| --- | --- | --- | --- |
| servers | parent | 1-20 | Alphanumerics |

$Extra

## Next steps
[Naming](https://example.test/naming-and-tagging)
[Reserved names](error-reserved-resource-name.md)
"@
}

$script:Abbreviations = @'
# Abbreviation recommendations for Azure resources

## Examples
| Resource | Resource provider namespace | Abbreviation |
|--|--|--|
| Storage account | `Microsoft.Storage/storageAccounts` | `st` |
| VM storage account | `Microsoft.Storage/storageAccounts` | `stvm` |
| Web app | `Microsoft.Web/sites` | `app` |
| Function app | `Microsoft.Web/sites` | `func` |

## Next step
[Tags](./resource-tagging.md)
'@
$script:Rules = Get-RulesDocument
$script:Manual = [ordered]@{
    schema_version = 2
    legacy_mappings = [ordered]@{
        storage_account = @{ resource_type = 'Microsoft.Storage/storageAccounts'; variant = $null; slug = 'legacy' }
        app_service = @{ resource_type = 'Microsoft.Web/sites'; variant = 'web_app'; slug = 'app' }
        function_app = @{ resource_type = 'Microsoft.Web/sites'; variant = 'function_app'; slug = 'func' }
    }
    resources = [ordered]@{}
}

function Get-TestCatalog {
    return ConvertTo-ResourceNameCatalog -RulesMarkdown $script:Rules -AbbreviationsMarkdown $script:Abbreviations -Manual $script:Manual
}

function Get-BundledCatalog {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $generated = ConvertFrom-NamingCatalogJson (Get-Content -LiteralPath (Join-Path $root 'data\resource-name-rules.json') -Raw)
    $manual = ConvertFrom-NamingCatalogJson (Get-Content -LiteralPath (Join-Path $root 'data\resource-name-rules.manual.json') -Raw) -AllowPartial
    return Merge-NamingCatalog -Catalogs @($generated, $manual)
}

function Test-KnownCatalogName {
    param([System.Collections.IDictionary] $Rule, [AllowEmptyString()][string] $Name)

    if (-not $Rule.validation_complete) { throw 'This assertion requires complete naming constraints.' }
    if ($Name.Length -lt $Rule.min_length -or $Name.Length -gt $Rule.max_length -or $Name -cnotmatch $Rule.regex) { return $false }
    foreach ($prefix in $Rule.forbidden_prefixes) {
        if ($Name.StartsWith($prefix, [StringComparison]::Ordinal)) { return $false }
    }
    foreach ($suffix in $Rule.forbidden_suffixes) {
        if ($Name.EndsWith($suffix, [StringComparison]::Ordinal)) { return $false }
    }
    foreach ($sequence in $Rule.forbidden_sequences) {
        if ($Name.Contains($sequence, [StringComparison]::Ordinal)) { return $false }
    }
    return $Name -notin $Rule.reserved_names
}

function Invoke-MockedPublication {
    param(
        [string] $Root,
        [string] $Document,
        [string] $Failure = ''
    )

    $catalog = Get-TestCatalog
    $null = Write-NamingCatalog $catalog.Generated (Join-Path $Root 'data\resource-name-rules.json') -Confirm:$false
    $null = Write-NamingCatalog $catalog.Manual (Join-Path $Root 'data\resource-name-rules.manual.json') -AllowPartial -Confirm:$false
    $state = @{
        calls = [System.Collections.Generic.List[string]]::new()
        failure = $Failure
        validated = $false
        changed = $Document -cne $script:Rules
    }
    $expectedRoot = $Root
    $runner = {
        param($FileName, $Arguments, $Directory)
        if ($Directory -cne $expectedRoot) { throw 'Unexpected working directory.' }
        $index = 0
        while ($Arguments[$index] -eq '-c') { $index += 2 }
        $operation = "$FileName.$($Arguments[$index])"
        $state.calls.Add($operation)
        if ($state.failure -eq $operation) {
            return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'Simulated failure.' }
        }
        $stdout = ''
        $exitCode = 0
        switch ($operation) {
            'git.status' {}
            'git.remote' { $stdout = 'https://github.com/Azure/terraform-azure-avm-utl-naming.git' }
            'git.check-ref-format' {}
            'git.fetch' {}
            'git.ls-remote' { $exitCode = 2 }
            'git.checkout' {}
            'git.diff' { if ($state.changed) { $stdout = 'data/resource-name-rules.json' } }
            'git.add' {}
            'git.commit' {
                if (-not $state.validated) { throw 'Commit occurred before validation.' }
            }
            'git.push' {
                if (-not $state.validated) { throw 'Push occurred before validation.' }
                if (-not ($Arguments -match '^--force-with-lease=')) { throw 'Push has no concurrency guard.' }
            }
            'gh.api' {
                if ($Arguments -contains 'GET') { $stdout = '[]' }
                else { $stdout = '{"fork":false,"full_name":"Azure/terraform-azure-avm-utl-naming","default_branch":"main"}' }
            }
            'gh.pr' { $stdout = 'https://github.com/Azure/terraform-azure-avm-utl-naming/pull/123' }
            default { throw "Unmocked operation: $operation" }
        }
        return [pscustomobject]@{ ExitCode = $exitCode; StdOut = $stdout; StdErr = '' }
    }.GetNewClosure()
    $validation = {
        if ($state.failure -eq 'validation') { throw 'Simulated validation failure.' }
        $state.validated = $true
    }.GetNewClosure()
    $result = Publish-ResourceNameRulesUpdate -Repository 'Azure/terraform-azure-avm-utl-naming' -BaseBranch main -RepositoryRoot $Root -Markdown $Document -AbbreviationsMarkdown $script:Abbreviations -CommandRunner $runner -ValidationRunner $validation
    return [pscustomobject]@{ Result = $result; State = $state }
}

Test-Case 'snake-case keys are generated from hierarchy and plural nouns' {
    Assert-True ((ConvertTo-NamingTerraformKey 'Microsoft.Storage/storageAccounts') -ceq 'storage_account') 'Incorrect storage key.'
    Assert-True ((ConvertTo-NamingTerraformKey 'Microsoft.Kusto/clusters/databases') -ceq 'cluster_database') 'Incorrect child key.'
    Assert-True ((ConvertTo-NamingTerraformKey 'Microsoft.KeyVault/managedHSMs') -ceq 'managed_hsm') 'Incorrect acronym key.'
}

Test-Case 'only colliding keys receive provider prefixes' {
    $catalog = Get-TestCatalog
    Assert-True ($catalog.Generated.resources.Contains('storage_account')) 'A unique key was renamed.'
    Assert-True ($catalog.Generated.resources.Contains('foo_server') -and $catalog.Generated.resources.Contains('bar_server')) 'Collisions were not qualified.'
}

Test-Case 'same-type variants are distinct JSON entries' {
    $catalog = Get-TestCatalog
    $web = $catalog.Generated.resources.site_web_app
    $function = $catalog.Generated.resources.site_function_app
    Assert-True ($web.resource_type -ceq $function.resource_type) 'Variants invented different Azure types.'
    Assert-True ($web.legacy_slug -ceq 'app' -and $function.legacy_slug -ceq 'func') 'Legacy variant slugs changed.'
    Assert-True ($web.legacy_outputs -contains 'app_service' -and $function.legacy_outputs -contains 'function_app') 'Legacy aliases were lost.'
}

Test-Case 'explicit variants are not collapsed by a shared abbreviation' {
    $manual = $script:Manual | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
    $manual.legacy_mappings.storage_special = @{
        resource_type = 'Microsoft.Storage/storageAccounts'
        variant = 'special'
        slug = 'st'
        separate_variant = $true
    }
    $catalog = ConvertTo-ResourceNameCatalog -RulesMarkdown $script:Rules -AbbreviationsMarkdown $script:Abbreviations -Manual $manual
    Assert-True ($catalog.Generated.resources.Contains('storage_account_special')) 'The explicit variant was folded into the generic entry.'
    Assert-True ($catalog.Generated.resources.storage_account_special.legacy_outputs -contains 'storage_special') 'The variant lost its compatibility mapping.'
    Assert-True ($catalog.Generated.resources.storage_account.legacy_outputs -notcontains 'storage_special') 'The generic entry captured the explicit variant.'
}

Test-Case 'current and legacy slugs remain independent' {
    $catalog = Get-TestCatalog
    $storage = $catalog.Generated.resources.storage_account
    Assert-True ($storage.slug -ceq 'st' -and $storage.slug_source -ceq 'caf') 'The documented abbreviation was not selected.'
    Assert-True ($storage.legacy_slug -ceq 'legacy') 'The old slug was not retained independently.'
    Assert-True ($catalog.Generated.resources.foo_server.slug_source -ceq 'derived') 'A derived slug was presented as a documented abbreviation.'
}

Test-Case 'simple bounds and character constraints are translated' {
    $record = (Get-TestCatalog).Generated.resources.storage_account
    Assert-True ($record.min_length -eq 3 -and $record.max_length -eq 24) 'Numeric bounds changed.'
    Assert-True ($record.validation_complete -and $record.lowercase -and -not $record.dashes) 'A simple rule was not correctly translated.'
    Assert-True ('abc123' -cmatch $record.regex -and 'ABC' -cnotmatch $record.regex) 'The generated character class is incorrect.'
}

Test-Case 'mixed-case alphanumerics retain distinct uppercase and lowercase ranges' {
    $record = ConvertTo-NamingRuntimeRule -Rule @{
        resource_type = 'Microsoft.Test/names'; scope = 'parent'; length = '1-30'
        valid_characters = 'Alphanumerics and hyphens. Start and end with alphanumeric.'
    }
    Assert-True ('Contoso-Test' -cmatch $record.regex -and 'contoso-test' -cmatch $record.regex) 'Uppercase letters were lost during character-class compression.'
    Assert-True (-not $record.lowercase -and $record.dashes) 'Mixed-case separator policy changed.'
}

Test-Case 'comma-separated lowercase rules retain documented hyphens' {
    $record = ConvertTo-NamingRuntimeRule -Rule @{
        resource_type = 'Microsoft.Test/names'; scope = 'parent'; length = '3-40'
        valid_characters = "Lowercase letters, numbers, and hyphens. Can't start or end with hyphen."
    }
    Assert-True ($record.dashes -and $record.lowercase) 'Documented hyphens were silently disabled.'
    Assert-True ($record.forbidden_prefixes -contains '-' -and $record.forbidden_suffixes -contains '-') 'Hyphen boundary restrictions were lost.'
}

Test-Case 'character lists are independent of word ordering' {
    $rules = @(
        "Lowercase letters, numbers, and hyphens. Can't start or end with hyphen.",
        "Lowercase letters, hyphens, and numbers. Can't start or end with hyphen."
    )
    $records = @($rules | ForEach-Object {
        ConvertTo-NamingRuntimeRule -Rule @{
            resource_type = 'Microsoft.Test/names'; scope = 'parent'; length = '3-40'; valid_characters = $_
        }
    })
    Assert-True ($records[0].regex -ceq $records[1].regex -and $records[1].dashes -and $records[1].validation_complete) 'Equivalent character lists produced different rules.'
    Assert-True ('abc-123' -cmatch $records[1].regex -and '-abc' -cnotmatch $records[1].regex -and 'abc-' -cnotmatch $records[1].regex) 'Published regex omitted the documented hyphen boundaries.'
}

Test-Case 'letter-only rules do not implicitly allow digits' {
    $record = ConvertTo-NamingRuntimeRule -Rule @{
        resource_type = 'Microsoft.Test/names'; scope = 'parent'; length = '1-40'
        valid_characters = 'Lowercase letters and hyphens.'
    }
    Assert-True ('abc-def' -cmatch $record.regex -and 'abc123' -cnotmatch $record.regex) 'Digits were added to a letter-only rule.'
}

Test-Case 'start and end classes are reflected in explicit boundary metadata' {
    $record = ConvertTo-NamingRuntimeRule -Rule @{
        resource_type = 'Microsoft.Test/names'; scope = 'parent'; length = '1-40'
        valid_characters = 'Alphanumerics and hyphens. Start and end with alphanumeric.'
    }
    Assert-True ($record.forbidden_prefixes -contains '-' -and $record.forbidden_suffixes -contains '-') 'Regex boundaries and truncation metadata disagree.'
}

Test-Case 'compound boundary clauses preserve every documented alternative' {
    $cases = @(
        @{
            characters = 'Lowercase letters, numbers, and hyphens. Start with lowercase letter or number.'
            valid = @('1abc', 'abc1')
            invalid = @('-abc', 'ABC')
        },
        @{
            characters = 'Lowercase letters, hyphens, and numbers. Start and end with letter or number.'
            valid = @('1', '1abc2', 'abc-2')
            invalid = @('-abc', 'abc-', 'Abc')
        },
        @{
            characters = 'Alphanumerics and hyphens. Start with a letter. End with letter or number.'
            valid = @('Abc1', 'abc-2')
            invalid = @('1abc', '-abc', 'abc-')
        },
        @{
            characters = 'Alphanumerics and hyphens. Start with a letter and end with alphanumeric.'
            valid = @('Abc1', 'abc-2')
            invalid = @('1abc', '-abc', 'abc-')
        },
        @{
            characters = 'Alphanumerics, underscores, periods, and hyphens. Start with a letter or number. End with letter, number, or underscore.'
            valid = @('1abc_', 'Abc-2', '1')
            invalid = @('_abc', '-abc', 'abc-', 'abc.')
        },
        @{
            characters = 'Alphanumerics, underscores, and hyphens. Start and end with alphanumeric or underscore.'
            valid = @('_abc_', '1abc_', '_')
            invalid = @('-abc', 'abc-')
        },
        @{
            characters = 'Alphanumerics, underscores, periods, and hyphens. Start with alphanumeric; end alphanumeric or underscore.'
            valid = @('1abc_', 'Abc-2')
            invalid = @('_abc', '-abc', 'abc-', 'abc.')
        }
    )
    foreach ($case in $cases) {
        $record = ConvertTo-NamingRuntimeRule -Rule @{
            resource_type = 'Microsoft.Test/names'; scope = 'parent'; length = '1-50'; valid_characters = $case.characters
        }
        Assert-True $record.validation_complete "A supported boundary clause was not fully interpreted: $($case.characters)"
        foreach ($name in $case.valid) {
            Assert-True ($name -cmatch $record.regex) "Rejected documented name '$name': $($case.characters)"
        }
        foreach ($name in $case.invalid) {
            Assert-True ($name -cnotmatch $record.regex) "Accepted invalid name '$name': $($case.characters)"
        }
        Assert-True ($record.forbidden_suffixes -notcontains '1') 'Numeric suffixes were incorrectly forbidden.'
    }
}

Test-Case 'unsupported boundary alternatives are not partially consumed' {
    $record = ConvertTo-NamingRuntimeRule -Rule @{
        resource_type = 'Microsoft.Test/names'; scope = 'parent'; length = '1-50'
        valid_characters = 'Alphanumerics and hyphens. Start with a letter or emoji.'
    }
    Assert-True (-not $record.validation_complete -and '1abc' -cmatch $record.regex) 'An unsupported alternative became a misleading letter-only boundary.'
}

Test-Case 'semicolon-delimited bounds survive unsupported additional prose' {
    $record = ConvertTo-NamingRuntimeRule -Rule @{
        resource_type = 'Microsoft.Test/names'; scope = 'parent'; length = '1-50'
        valid_characters = 'Alphanumerics and hyphens. Start and end with alphanumeric; can''t be all numbers.'
    }
    Assert-True (-not $record.validation_complete -and 'abc1' -cmatch $record.regex) 'Unsupported additional prose was silently discarded.'
    Assert-True ('-abc' -cnotmatch $record.regex -and 'abc-' -cnotmatch $record.regex) 'Known boundary restrictions were lost.'
}

Test-Case 'documented literal exclusions survive compound boundary parsing' {
    $record = ConvertTo-NamingRuntimeRule -Rule @{
        resource_type = 'Microsoft.Synapse/workspaces'; scope = 'global'; length = '1-50'
        valid_characters = 'Lowercase letters, hyphens, and numbers. Start and end with letter or number. Can''t contain `-ondemand`.'
    }
    Assert-True ($record.validation_complete -and $record.forbidden_sequences -contains '-ondemand') 'The Synapse exclusion was lost or left uninterpreted.'
    Assert-True ($record.forbidden_prefixes.Count -eq 1 -and $record.forbidden_prefixes -contains '-') 'The starting boundary is incorrect.'
    Assert-True ($record.forbidden_suffixes.Count -eq 1 -and $record.forbidden_suffixes -contains '-') 'Truncation would remove valid numeric suffixes.'
}

Test-Case 'unknown rules remain explicit rather than permissive success' {
    $record = ConvertTo-NamingRuntimeRule -Rule $null
    Assert-True ($null -eq $record.regex -and $null -eq $record.max_length -and -not $record.validation_complete) 'Unknown constraints were invented.'
    Assert-True ($record.validation_notes.Count -gt 0) 'Unknown validation has no explanation.'
}

Test-Case 'GUID and literal naming modes are recognized' {
    $guid = ConvertTo-NamingRuntimeRule -Rule @{ resource_type = 'Microsoft.Test/guids'; scope = 'parent'; length = '36'; valid_characters = 'Must be a globally unique identifier (GUID).' }
    $literal = ConvertTo-NamingRuntimeRule -Rule @{ resource_type = 'Microsoft.Test/literals'; scope = 'parent'; length = '1-20'; valid_characters = 'Use default.' }
    Assert-True ($guid.name_kind -eq 'uuid' -and $guid.min_length -eq 36) 'GUID mode was not recognized.'
    Assert-True ($literal.name_kind -eq 'literal' -and $literal.fixed_name -ceq 'default') 'Literal mode was not recognized.'
}

Test-Case 'source errors are corrected without creating fake duplicate types' {
    Assert-True ((Resolve-NamingResourceType 'Microsoft.Network/dnsForwardingRuleset') -ceq 'Microsoft.Network/dnsForwardingRulesets') 'DNS type correction failed.'
    Assert-True ((Resolve-NamingResourceType 'Microsoft.Databricks/workspaces/accessConnectors') -ceq 'Microsoft.Databricks/accessConnectors') 'Databricks type correction failed.'
    Assert-True ((Resolve-NamingResourceType 'Microsoft.Network/vpnGateways/vpnSites') -ceq 'Microsoft.Network/vpnSites') 'VPN site type correction failed.'
}

Test-Case 'malformed source documents fail before generation' {
    Assert-Exception { ConvertFrom-ResourceNameRulesMarkdown '# An error page' } 'Incomplete|expected'
    Assert-Exception { ConvertFrom-ResourceAbbreviationsMarkdown '# An error page' } 'Incomplete|unexpected'
    Assert-Exception { ConvertFrom-ResourceNameRulesMarkdown ($script:Rules.Replace('storageAccounts | global', 'storageAccounts | extra | global')) } 'four'
}

Test-Case 'duplicate source identities are rejected' {
    $duplicate = $script:Rules.Replace('| storageAccounts | global | 3-24 | Lowercase letters and numbers |', "| storageAccounts | global | 3-24 | Lowercase letters and numbers |`n| storageAccounts | global | 3-24 | Lowercase letters and numbers |")
    Assert-Exception { ConvertFrom-ResourceNameRulesMarkdown $duplicate } 'Duplicate'
}

Test-Case 'JSON duplicate properties and invalid schemas are rejected' {
    Assert-Exception { ConvertFrom-NamingCatalogJson '{"schema_version":2,"resources":{},"resources":{}}' } 'Duplicate'
    Assert-Exception { ConvertFrom-NamingCatalogJson '{"schema_version":1,"resources":{}}' } 'schema-v2'
}

Test-Case 'repeated generation produces identical bytes' {
    $first = ConvertTo-NamingCatalogJson (Get-TestCatalog).Generated
    $second = ConvertTo-NamingCatalogJson (Get-TestCatalog).Generated
    Assert-True ($first -ceq $second) 'Generation was not deterministic.'
}

Test-Case 'generated and manual catalogs declare their portable editor schemas' {
    $catalog = Get-TestCatalog
    Assert-True ($catalog.Generated['$schema'] -ceq '../schemas/naming-catalog.schema.json') 'Generated catalogs do not declare the full catalog schema.'
    Assert-True ($catalog.Manual['$schema'] -ceq '../schemas/naming-overrides.schema.json') 'Manual catalogs do not declare the partial-overlay schema.'
}

Test-Case 'new collisions do not rename existing keys or derived slugs' {
    $firstExtra = @'
## Microsoft.First
| Entity | Scope | Length | Valid Characters |
| --- | --- | --- | --- |
| widgets | parent | 1-40 | Alphanumerics |
'@
    $secondExtra = @'
## Microsoft.Second
| Entity | Scope | Length | Valid Characters |
| --- | --- | --- | --- |
| widgets | parent | 1-40 | Alphanumerics |
'@
    $initial = ConvertTo-ResourceNameCatalog -RulesMarkdown (Get-RulesDocument $firstExtra) -AbbreviationsMarkdown $script:Abbreviations -Manual $script:Manual
    $updated = ConvertTo-ResourceNameCatalog -RulesMarkdown (Get-RulesDocument ($firstExtra + "`n" + $secondExtra)) -AbbreviationsMarkdown $script:Abbreviations -Manual $initial.Manual -Previous $initial.Generated
    Assert-True ($updated.Generated.resources.Contains('widget') -and $updated.Generated.resources.Contains('second_widget')) 'The established key was renamed instead of qualifying the new collision.'
    Assert-True ($updated.Generated.resources.widget.slug -ceq $initial.Generated.resources.widget.slug) 'The established derived slug changed.'
    $rebuilt = ConvertTo-ResourceNameCatalog -RulesMarkdown (Get-RulesDocument ($firstExtra + "`n" + $secondExtra)) -AbbreviationsMarkdown $script:Abbreviations -Manual $updated.Manual
    Assert-True ((ConvertTo-NamingCatalogJson $rebuilt.Generated) -ceq (ConvertTo-NamingCatalogJson $updated.Generated)) 'Persisted assignments did not reproduce the same keys without the previous generated file.'
}

Test-Case 'manual resources patch individual properties without changing generated data' {
    $manual = [ordered]@{
        schema_version = 2
        resources = [ordered]@{
            storage_account = @{
                max_length = 20
                override_reason = 'Reviewed naming limit.'
                override_source = 'https://example.test/reviewed-rule'
            }
        }
        legacy_mappings = $script:Manual.legacy_mappings
    }
    $result = ConvertTo-ResourceNameCatalog -RulesMarkdown $script:Rules -AbbreviationsMarkdown $script:Abbreviations -Manual $manual
    $effective = Merge-NamingCatalog -Catalogs @($result.Generated, $result.Manual)
    Assert-True ($result.Generated.resources.storage_account.max_length -eq 24 -and $effective.resources.storage_account.max_length -eq 20) 'A manual patch changed generated data or was ignored.'
    Assert-True ($effective.resources.storage_account.regex -ceq $result.Generated.resources.storage_account.regex -and $effective.resources.storage_account.slug -ceq 'st') 'A partial patch discarded omitted properties.'
    Assert-True ($result.Manual.resources.storage_account.Count -eq 3) 'A partial patch was expanded into a redundant full definition.'
    $updated = ConvertTo-ResourceNameCatalog -RulesMarkdown $script:Rules -AbbreviationsMarkdown $script:Abbreviations -Manual $result.Manual -Previous $result.Generated
    Assert-True ((ConvertTo-NamingCatalogJson $updated.Manual) -ceq (ConvertTo-NamingCatalogJson $result.Manual)) 'Regeneration rewrote the manual patch.'
}

Test-Case 'documented abbreviations retire only obsolete legacy fallback patches' {
    $manual = $script:Manual | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
    $manual.legacy_mappings.foo_server = @{ resource_type = 'Microsoft.Foo/servers'; variant = $null; slug = 'old' }
    $manual.resources.foo_server = @{
        slug = 'old'
        slug_source = 'manual'
        override_reason = 'Use the original slug where the selected sources have no unambiguous CAF abbreviation.'
        override_source = 'https://github.com/Azure/terraform-azurerm-naming/blob/fc289126c9c888393ff02a79e1babadd6865861c/main.tf'
    }
    $initial = ConvertTo-ResourceNameCatalog -RulesMarkdown $script:Rules -AbbreviationsMarkdown $script:Abbreviations -Manual $manual
    $abbreviations = $script:Abbreviations.Replace('## Next step', @'
| Foo server | `Microsoft.Foo/servers` | `foo` |

## Next step
'@)
    $updated = ConvertTo-ResourceNameCatalog -RulesMarkdown $script:Rules -AbbreviationsMarkdown $abbreviations -Manual $initial.Manual -Previous $initial.Generated
    $effective = Merge-NamingCatalog -Catalogs @($updated.Generated, $updated.Manual)
    Assert-True ($initial.Generated.resources.foo_server.slug_source -ceq 'derived' -and $initial.Manual.resources.foo_server.slug -ceq 'old') 'The fixture did not start with a legacy fallback.'
    Assert-True ($updated.Generated.resources.foo_server.slug_source -ceq 'caf' -and $effective.resources.foo_server.slug -ceq 'foo' -and -not $updated.Manual.resources.Contains('foo_server')) 'The new CAF recommendation did not replace the obsolete fallback.'
    Assert-True ($updated.Generated.resources.foo_server.legacy_slug -ceq 'old' -and $updated.Manual.key_assignments.foo_server -ceq $initial.Manual.key_assignments.foo_server) 'Retiring the fallback changed the legacy alias or catalog key.'

    $reviewed = $initial.Manual | ConvertTo-Json -Depth 40 | ConvertFrom-Json -AsHashtable
    $reviewed.resources.foo_server.slug = 'curated'
    $reviewed.resources.foo_server.override_reason = 'Reviewed manual abbreviation.'
    $retained = ConvertTo-ResourceNameCatalog -RulesMarkdown $script:Rules -AbbreviationsMarkdown $abbreviations -Manual $reviewed -Previous $initial.Generated
    Assert-True ($retained.Manual.resources.foo_server.slug -ceq 'curated' -and
        (Merge-NamingCatalog -Catalogs @($retained.Generated, $retained.Manual)).resources.foo_server.slug -ceq 'curated') 'A reviewed manual override was removed with the obsolete fallbacks.'
}

Test-Case 'later layers win while omitted entries and properties survive' {
    $catalog = Get-TestCatalog
    $manual = @{ schema_version = 2; resources = @{ storage_account = @{ slug = 'manual'; max_length = 20; forbidden_sequences = @('--') } } }
    $customer = @{ schema_version = 2; resources = @{
        storage_account = @{ slug = ''; min_length = 0; lowercase = $false; forbidden_sequences = @() }
        organization_label = @{ slug = 'team'; dashes = $true }
    } }
    $effective = Merge-NamingCatalog -Catalogs @($catalog.Generated, $manual, $customer)
    $storage = $effective.resources.storage_account
    Assert-True ($storage.slug -ceq '' -and $storage.min_length -eq 0 -and -not $storage.lowercase -and $storage.forbidden_sequences.Count -eq 0) 'Explicit empty, zero, false, or array values were ignored.'
    Assert-True ($storage.max_length -eq 20 -and $storage.regex -ceq $catalog.Generated.resources.storage_account.regex) 'Omitted properties did not survive both overlays.'
    Assert-True ($effective.resources.Contains('foo_server') -and $effective.resources.organization_label.slug -ceq 'team') 'An unrelated entry was removed or a new key was not added.'
    Assert-True (-not $effective.resources.organization_label.validation_complete -and $effective.resources.organization_label.validation_notes.Count -gt 0) 'Minimal entries must not claim complete validation.'
}

Test-Case 'explicit null constraints make inherited validation incomplete' {
    $catalog = Get-TestCatalog
    $manual = @{ schema_version = 2; resources = @{ storage_account = @{ max_length = $null; regex = $null } } }
    $record = (Merge-NamingCatalog -Catalogs @($catalog.Generated, $manual)).resources.storage_account
    Assert-True ($null -eq $record.max_length -and $null -eq $record.regex -and $record.min_length -eq 3) 'Null was treated as an omitted value.'
    Assert-True (-not $record.validation_complete -and $record.validation_notes.Count -gt 0) 'Removing constraints retained a false complete-validation claim.'
}

Test-Case 'invalid partial and merged entries fail explicitly' {
    $catalog = Get-TestCatalog
    foreach ($entry in @(
        @{ dashes = 'false' }, @{ slug = $null }, @{ slug = 42 }, @{ min_length = -1 },
        @{ max_length = '20' }, @{ reserved_names = @($null) }, @{ forbidden_suffixes = $null },
        @{ misspelled_length = 20 }, @{ name_kind = 'unsupported' }
    )) {
        $partial = @{ schema_version = 2; resources = @{ storage_account = $entry } }
        Assert-Exception { ConvertFrom-NamingCatalogJson (ConvertTo-NamingCatalogJson $partial) -AllowPartial } 'Catalog|Negative|Invalid'
    }
    Assert-Exception {
        Merge-NamingCatalog -Catalogs @($catalog.Generated, @{ schema_version = 2; resources = @{ storage_account = @{ max_length = 1 } } })
    } 'Reversed'
    Assert-Exception {
        Merge-NamingCatalog -Catalogs @($catalog.Generated, @{ schema_version = 2; resources = @{ new_entry = @{ max_length = 20 } } })
    } 'slug'
    Assert-Exception { ConvertFrom-NamingCatalogJson '{"schema_version":2,"resources":{},"overrides":{}}' -AllowPartial } 'resources, not an overrides'
}

Test-Case 'documented entries retain explicit manual definitions and slugs' {
    $initial = Get-TestCatalog
    $record = $initial.Generated.resources.storage_account | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
    $record.slug = 'curated'
    $manual = [ordered]@{ schema_version = 2; legacy_mappings = $script:Manual.legacy_mappings; resources = [ordered]@{ storage_account = $record } }
    $result = ConvertTo-ResourceNameCatalog -RulesMarkdown $script:Rules -AbbreviationsMarkdown $script:Abbreviations -Manual $manual
    Assert-True ($result.Manual.resources.storage_account.slug -ceq 'curated' -and $result.Generated.resources.storage_account.slug -ceq 'st') 'Documented coverage deleted or rewrote the manual definition.'
}

Test-Case 'manual additions can share an Azure type using distinct variants' {
    $initial = Get-TestCatalog
    $initial.Manual.resources.site_internal = @{ resource_type = 'Microsoft.Web/sites'; variant = 'internal'; slug = 'internal' }
    $result = ConvertTo-ResourceNameCatalog -RulesMarkdown $script:Rules -AbbreviationsMarkdown $script:Abbreviations -Manual $initial.Manual -Previous $initial.Generated
    $effective = Merge-NamingCatalog -Catalogs @($result.Generated, $result.Manual)
    Assert-True ($effective.resources.site_internal.slug -ceq 'internal' -and $effective.resources.site_web_app.slug -ceq 'app') 'A manual same-type variant displaced a documented entry.'
    Assert-True ($result.Manual.resources.site_internal.Count -eq 3) 'A minimal manual addition was unnecessarily expanded.'
}

Test-Case 'retired generated entries hydrate beneath existing partial manual patches' {
    $initial = Get-TestCatalog
    $initial.Manual.resources.foo_server = @{ slug = 'keep'; max_length = 18 }
    $changed = ($script:Rules -replace "`r`n?", "`n").Replace("## Microsoft.Foo`n| Entity | Scope | Length | Valid Characters |`n| --- | --- | --- | --- |`n| servers | parent | 1-20 | Alphanumerics |`n", '')
    $result = ConvertTo-ResourceNameCatalog -RulesMarkdown $changed -AbbreviationsMarkdown $script:Abbreviations -Manual $initial.Manual -Previous $initial.Generated
    Assert-True ($result.Manual.resources.Contains('foo_server')) 'A formerly documented type was dropped.'
    Assert-True ($result.Manual.resources.foo_server.source.status -eq 'removed_from_selected_sources') 'Fallback provenance was not recorded.'
    Assert-True ($result.Manual.resources.foo_server.slug -ceq 'keep' -and $result.Manual.resources.foo_server.max_length -eq 18 -and $result.Manual.resources.foo_server.regex -ceq $initial.Generated.resources.foo_server.regex) 'Retirement replaced a manual patch or lost its inherited properties.'
    $restored = ConvertTo-ResourceNameCatalog -RulesMarkdown $script:Rules -AbbreviationsMarkdown $script:Abbreviations -Manual $result.Manual -Previous $result.Generated
    Assert-True ($restored.Generated.resources.Contains('foo_server') -and $restored.Manual.resources.foo_server.slug -ceq 'keep') 'A returning documented entry changed its public key or removed a manual setting.'
}

Test-Case 'bundled abbreviations retain historical slugs except reviewed modern corrections' {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $generated = ConvertFrom-NamingCatalogJson (Get-Content -LiteralPath (Join-Path $root 'data\resource-name-rules.json') -Raw)
    $manual = ConvertFrom-NamingCatalogJson (Get-Content -LiteralPath (Join-Path $root 'data\resource-name-rules.manual.json') -Raw) -AllowPartial
    $effective = Merge-NamingCatalog -Catalogs @($generated, $manual)
    $corrections = @{
        automation_account_runbook = @{ slug = 'aarb'; historical = 'aacred'; issue = 162 }
        firewall_application_rule_collection = @{ slug = 'fwapprc'; historical = 'fwapp'; issue = 163 }
        namespace_notification_hub_authorization_rule = @{ slug = 'nhar'; historical = 'dnsrec'; issue = 206 }
        namespace_topic_authorization_rule = @{ slug = 'sbtar'; historical = 'dnsrec'; issue = 206 }
    }
    foreach ($key in $effective.resources.Keys) {
        $record = $effective.resources[$key]
        if ($null -eq $record.legacy_slug) { continue }
        if ($generated.resources.Contains($key) -and $generated.resources[$key].slug_source -eq 'caf') {
            Assert-True ($record.slug -ceq $generated.resources[$key].slug) "A documented abbreviation was replaced for '$key'."
        }
        elseif ($corrections.ContainsKey($key)) {
            $expected = $corrections[$key]
            Assert-True ($record.slug -ceq $expected.slug -and $record.legacy_slug -ceq $expected.historical) "Reviewed correction or historical provenance changed for '$key'."
            Assert-True ($manual.resources[$key].override_source -ceq "https://github.com/Azure/terraform-azurerm-naming/issues/$($expected.issue)") "Reviewed correction '$key' has no matching source."
        }
        else {
            Assert-True ($manual.resources.Contains($key) -and $record.slug -ceq $record.legacy_slug) "The manual layer does not supply the original fallback slug for '$key'."
        }
    }
    foreach ($key in $corrections.Keys) {
        Assert-True ($effective.resources.Contains($key) -and $manual.resources.Contains($key)) "Reviewed correction '$key' was removed."
    }
}

Test-Case 'bundled storage tables enforce the documented service rules' {
    $rule = (Get-BundledCatalog).resources.storage_table
    Assert-True (-not $rule.dashes -and $rule.lowercase -and $rule.min_length -eq 3 -and $rule.max_length -eq 63) 'Storage-table generation conventions or limits changed.'
    foreach ($name in @('abc', 'Table123', ('a' * 63))) {
        Assert-True (Test-KnownCatalogName $rule $name) "Rejected valid table name '$name'."
    }
    foreach ($name in @('', 'ab', '123table', 'foo-bar-stt', ('a' * 64), 'tables', 'TABLES')) {
        Assert-True (-not (Test-KnownCatalogName $rule $name)) "Accepted invalid table name '$name'."
    }
}

Test-Case 'all Cosmos account variants retain 44-character alphanumeric boundaries' {
    $rules = @((Get-BundledCatalog).resources.Values | Where-Object { $_.resource_type -ieq 'Microsoft.DocumentDB/databaseAccounts' })
    Assert-True ($rules.Count -eq 6) 'A Cosmos account variant was lost or bypassed.'
    foreach ($rule in $rules) {
        Assert-True ($rule.min_length -eq 3 -and $rule.max_length -eq 44 -and $rule.lowercase -and $rule.scope -ceq 'global') 'Cosmos account bounds, case, or scope changed.'
        Assert-True ($rule.forbidden_prefixes -notcontains '1' -and $rule.forbidden_suffixes -contains '-') 'Cosmos repair metadata contradicts the boundaries.'
        foreach ($name in @('1ab', 'ab1', '1a-2', ('a' * 44))) {
            Assert-True (Test-KnownCatalogName $rule $name) "Rejected valid Cosmos account name '$name'."
        }
        foreach ($name in @('-abc', 'abc-', 'a_b', 'ABC', 'ab', ('a' * 45))) {
            Assert-True (-not (Test-KnownCatalogName $rule $name)) "Accepted invalid Cosmos account name '$name'."
        }
    }
}

Test-Case 'bundled Synapse names retain numeric endings and exclude ondemand' {
    $rule = (Get-BundledCatalog).resources.synapse_workspace
    Assert-True ($rule.dashes -and $rule.lowercase -and $rule.min_length -eq 1 -and $rule.max_length -eq 50) 'Synapse limits or separator behavior changed.'
    Assert-True ($rule.forbidden_suffixes.Count -eq 1 -and $rule.forbidden_suffixes -contains '-') 'Numeric endings would still be truncated.'
    foreach ($name in @('1', '1abc2', 'a-b1', (('a' * 49) + '1'))) {
        Assert-True (Test-KnownCatalogName $rule $name) "Rejected valid Synapse name '$name'."
    }
    foreach ($name in @('-abc', 'abc-', 'a_1', 'Abc', 'syn-ondemand', 'syn-ondemand-extra', ('a' * 51))) {
        Assert-True (-not (Test-KnownCatalogName $rule $name)) "Accepted invalid Synapse name '$name'."
    }
}

Test-Case 'policy definitions use resource-name rather than display-name constraints' {
    $rule = (Get-BundledCatalog).resources.policy_definition
    Assert-True ($rule.slug -ceq 'pdef' -and $rule.min_length -eq 1 -and $rule.max_length -eq 64) 'Policy-definition resource-name bounds or slug are incorrect.'
    Assert-True (-not $rule.dashes -and $rule.lowercase) 'Unrelated policy separator/case conventions changed.'
    foreach ($name in @('p', 'policy name', 'policy_with-dashes', 'policy.name', ('a' * 64), ([string][char]0x03BB + 'policy'))) {
        Assert-True (Test-KnownCatalogName $rule $name) "Rejected valid policy name '$name'."
    }
    foreach ($name in @('', ('a' * 65), '#policy', 'policy/name', 'policy\name', 'policy:name', 'policy.', 'policy ', ('policy' + [char]1), ('policy' + [char]0x85))) {
        Assert-True (-not (Test-KnownCatalogName $rule $name)) 'Accepted an invalid policy-definition resource name.'
    }
}

Test-Case 'reviewed manual additions keep stable identities and explicit unknowns' {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $manual = ConvertFrom-NamingCatalogJson (Get-Content -LiteralPath (Join-Path $root 'data\resource-name-rules.manual.json') -Raw) -AllowPartial
    $resources = (Get-BundledCatalog).resources
    $expected = @{
        monitor_workspace = @{ resource_type = 'Microsoft.Monitor/accounts'; slug = 'amw' }
        data_collection_rule_association = @{ resource_type = 'Microsoft.Insights/dataCollectionRuleAssociations'; slug = 'dcra' }
        disk_access = @{ resource_type = 'Microsoft.Compute/diskAccesses'; slug = 'da' }
    }
    foreach ($key in $expected.Keys) {
        $rule = $resources[$key]
        Assert-True ($rule.resource_type -ceq $expected[$key].resource_type -and $rule.slug -ceq $expected[$key].slug -and $rule.slug_source -ceq 'manual') "Incorrect manual identity or abbreviation for '$key'."
        Assert-True ($rule.legacy_outputs.Count -eq 0 -and $null -eq $rule.legacy_slug) "New coverage '$key' invented a historical alias."
        Assert-True ($manual.key_assignments[$key] -ceq ($rule.resource_type.ToLowerInvariant() + '|')) "The new key '$key' was not persisted."
        Assert-True (-not $rule.validation_complete -and $null -eq $rule.min_length -and $rule.validation_notes.Count -gt 0) "Unverified constraints for '$key' were presented as complete."
    }
    $workspace = $resources.monitor_workspace
    Assert-True ($null -eq $workspace.max_length -and $workspace.dashes) 'Unverified Monitor workspace bounds were copied from the old proposal.'
    foreach ($name in @('amw-test1', '-amw', 'amw-', 'a', 'ab?', 'a_b', 'ab')) {
        Assert-True (($name -cmatch $workspace.regex) -eq ($name -cmatch '^(?!-)[a-zA-Z0-9-]+[^-]$')) 'The RE2 translation changed the published Monitor workspace pattern.'
    }
    Assert-True ($null -eq $resources.data_collection_rule_association.regex -and $null -eq $resources.data_collection_rule_association.max_length) 'Unknown association constraints were invented.'
    $disk = $resources.disk_access
    Assert-True ($disk.max_length -eq 80 -and $disk.dashes -and 'Disk_1-2' -cmatch $disk.regex -and 'disk/name' -cnotmatch $disk.regex) 'Verified disk-access constraints were lost.'
    Assert-True (-not $resources.Contains('automation_dsc_configuration')) 'Excluded DSC coverage was added.'
}

Test-Case 'ASE uses the verified creation limit without inventing unresolved rules' {
    $resources = (Get-BundledCatalog).resources
    foreach ($key in @('hosting_environment', 'hosting_environment_app_service_environment')) {
        $rule = $resources[$key]
        Assert-True ($rule.max_length -eq 35 -and $null -eq $rule.min_length -and $null -eq $rule.regex -and -not $rule.validation_complete) "ASE constraints for '$key' do not reflect the bounded source review."
    }
    $port = $resources.express_route_port
    Assert-True ($port.slug -ceq 'erd' -and $null -eq $port.min_length -and $null -eq $port.max_length -and $null -eq $port.regex -and -not $port.validation_complete) 'Unverified ExpressRoute Direct constraints were invented.'
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "avm-naming-catalog-tests-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path (Join-Path $testRoot 'data') -Force
try {
    Test-Case 'file updates are byte-stable on a no-op refresh' {
        $catalog = Get-TestCatalog
        $generatedPath = Join-Path $testRoot 'data\resource-name-rules.json'
        $manualPath = Join-Path $testRoot 'data\resource-name-rules.manual.json'
        $null = Write-NamingCatalog $catalog.Generated $generatedPath -Confirm:$false
        $null = Write-NamingCatalog $catalog.Manual $manualPath -AllowPartial -Confirm:$false
        $before = (Get-FileHash -LiteralPath $generatedPath).Hash
        $update = Update-ResourceNameCatalog -RulesMarkdown $script:Rules -AbbreviationsMarkdown $script:Abbreviations -GeneratedPath $generatedPath -ManualPath $manualPath -Confirm:$false
        Assert-True (-not $update.Changed -and (Get-FileHash -LiteralPath $generatedPath).Hash -eq $before) 'A no-op refresh rewrote data.'
    }

    Test-Case 'the real updater adds missing schema annotations without changing naming data' {
        $catalog = Get-TestCatalog
        $null = $catalog.Generated.Remove('$schema')
        $null = $catalog.Manual.Remove('$schema')
        $generatedPath = Join-Path $testRoot 'data\resource-name-rules.json'
        $manualPath = Join-Path $testRoot 'data\resource-name-rules.manual.json'
        $null = Write-NamingCatalog $catalog.Generated $generatedPath -Confirm:$false
        $null = Write-NamingCatalog $catalog.Manual $manualPath -AllowPartial -Confirm:$false
        $update = Update-ResourceNameCatalog -RulesMarkdown $script:Rules -AbbreviationsMarkdown $script:Abbreviations -GeneratedPath $generatedPath -ManualPath $manualPath -Confirm:$false
        Assert-True ($update.Changed -and $update.ChangedFiles.Count -eq 2) 'Both catalogs must acquire their missing schema annotations.'
        $generated = ConvertFrom-NamingCatalogJson (Get-Content -LiteralPath $generatedPath -Raw)
        $manual = ConvertFrom-NamingCatalogJson (Get-Content -LiteralPath $manualPath -Raw) -AllowPartial
        Assert-True ($generated['$schema'] -ceq '../schemas/naming-catalog.schema.json' -and $manual['$schema'] -ceq '../schemas/naming-overrides.schema.json') 'The updater did not emit the portable schema annotations.'
        $again = Update-ResourceNameCatalog -RulesMarkdown $script:Rules -AbbreviationsMarkdown $script:Abbreviations -GeneratedPath $generatedPath -ManualPath $manualPath -Confirm:$false
        Assert-True (-not $again.Changed) 'Regeneration did not preserve the schema annotations byte-for-byte.'
        $null = $generated.Remove('$schema')
        $null = $manual.Remove('$schema')
        Assert-True ((ConvertTo-NamingCatalogJson $generated) -ceq (ConvertTo-NamingCatalogJson $catalog.Generated)) 'Adding the generated schema changed naming data.'
        Assert-True ((ConvertTo-NamingCatalogJson $manual) -ceq (ConvertTo-NamingCatalogJson $catalog.Manual)) 'Adding the manual schema changed rules or key assignments.'
    }

    Test-Case 'publication defers an existing review without changing files' {
        $state = @{ calls = [System.Collections.Generic.List[string]]::new() }
        $expectedDirectory = $testRoot
        $runner = {
            param($FileName, $Arguments, $Directory)
            if ($Directory -cne $expectedDirectory) { throw 'Unexpected publication working directory.' }
            $command = "$FileName $($Arguments -join ' ')"
            $state.calls.Add($command)
            $stdout = switch -Regex ($command) {
                '^git status ' { ''; break }
                '^git remote get-url origin$' { 'https://github.com/Azure/terraform-azure-avm-utl-naming.git'; break }
                '^gh api repos/Azure/terraform-azure-avm-utl-naming$' { '{"fork":false,"full_name":"Azure/terraform-azure-avm-utl-naming","default_branch":"main"}'; break }
                '^gh api --method GET ' { '[{"number":123,"head":{"ref":"automation/resource-name-rules-additions","repo":{"full_name":"Azure/terraform-azure-avm-utl-naming"}},"base":{"ref":"main","repo":{"full_name":"Azure/terraform-azure-avm-utl-naming"}}}]'; break }
                default { throw "Unexpected mutation or command: $command" }
            }
            return [pscustomobject]@{ ExitCode = 0; StdOut = $stdout; StdErr = '' }
        }.GetNewClosure()
        $result = Publish-ResourceNameRulesUpdate -Repository 'Azure/terraform-azure-avm-utl-naming' -BaseBranch main -RepositoryRoot $testRoot -Markdown $script:Rules -AbbreviationsMarkdown $script:Abbreviations -CommandRunner $runner
        Assert-True ($result.Status -eq 'pending_review' -and -not $result.Pushed) 'An open review was overwritten.'
        Assert-True ($state.calls.Count -eq 4) 'Unexpected publication calls occurred.'
    }

    $extra = @'
## Microsoft.New
| Entity | Scope | Length | Valid Characters |
| --- | --- | --- | --- |
| widgets | parent | 1-40 | Alphanumerics |
'@
    $changedDocument = Get-RulesDocument $extra
    Test-Case 'a no-op publication does not commit or push' {
        $result = Invoke-MockedPublication -Root $testRoot -Document $script:Rules
        Assert-True ($result.Result.Status -eq 'unchanged' -and -not $result.Result.Pushed) 'No-op publication changed the branch.'
        Assert-True (-not $result.State.calls.Contains('git.commit') -and -not $result.State.calls.Contains('git.push')) 'No-op publication performed a write.'
    }

    Test-Case 'changed runtime data is validated before guarded publication' {
        $result = Invoke-MockedPublication -Root $testRoot -Document $changedDocument
        Assert-True ($result.Result.Status -eq 'proposed' -and $result.Result.Pushed -and $result.State.validated) 'Runtime data was not validated and proposed.'
    }

    Test-Case 'publication failures are not reported as no changes' {
        foreach ($failure in @('git.fetch', 'git.commit', 'git.push', 'gh.pr', 'validation')) {
            Assert-Exception { Invoke-MockedPublication -Root $testRoot -Document $changedDocument -Failure $failure } 'failed|failure'
        }
    }

    Test-Case 'fork publication is rejected before commands execute' {
        Assert-Exception {
            Publish-ResourceNameRulesUpdate -Repository 'someone/fork' -BaseBranch main -RepositoryRoot $testRoot -Markdown $script:Rules -AbbreviationsMarkdown $script:Abbreviations -CommandRunner { throw 'Must not execute.' }
        } 'upstream'
    }
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}

Write-Output "Naming catalog tests: $script:Passed passed. Publication was mocked; no remote writes were made."
