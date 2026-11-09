#requires -Version 7.4

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$overlaySchema = Join-Path $root 'schemas\naming-overrides.schema.json'
$catalogSchema = Join-Path $root 'schemas\naming-catalog.schema.json'
$script:Passed = 0
$schemaOptions = @{}
if ((Get-Command Test-Json).Parameters.ContainsKey('FetchExternalReference')) {
    $schemaOptions.FetchExternalReference = $true
}

function Test-SchemaCase {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Json,
        [string] $Schema = $overlaySchema,
        [bool] $Expected = $true
    )

    $schemaErrors = @()
    $actual = Test-Json -Json $Json -SchemaFile $Schema @schemaOptions -ErrorAction SilentlyContinue -ErrorVariable schemaErrors
    if ($actual -ne $Expected) {
        throw "Schema case '$Name' expected $Expected, got '$actual': $($schemaErrors -join '; ')"
    }
    $script:Passed++
}

function ConvertTo-TestOverlay {
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Resources)

    return ConvertTo-Json -Depth 40 -InputObject @{ schema_version = 2; resources = $Resources }
}

function Test-SchemaDocument {
    param(
        [Parameter(Mandatory)][string] $RelativePath,
        [Parameter(Mandatory)][string] $Schema,
        [Parameter(Mandatory)][string] $Reference
    )

    $path = Join-Path $root $RelativePath
    $json = Get-Content -LiteralPath $path -Raw
    $document = ConvertFrom-Json -InputObject $json -AsHashtable
    if ($document -isnot [System.Collections.IDictionary] -or
        -not ($document.Keys -ccontains '$schema') -or
        $document['$schema'] -isnot [string] -or $document['$schema'] -cne $Reference) {
        throw "'$RelativePath' must declare the editor schema '$Reference'; managed VS Code settings cannot supply this association."
    }
    $declaredPath = (Resolve-Path -LiteralPath (Join-Path (Split-Path $path -Parent) $document['$schema'])).Path
    if ($declaredPath -cne (Resolve-Path -LiteralPath $Schema).Path) {
        throw "'$RelativePath' resolves to an unexpected editor schema: $declaredPath"
    }
    $script:Passed++
    Test-SchemaCase -Name $RelativePath -Json $json -Schema $declaredPath
    return $json
}

foreach ($schema in @($overlaySchema, $catalogSchema)) {
    Test-SchemaCase -Name "empty catalog: $schema" -Json '{"schema_version":2,"resources":{}}' -Schema $schema
}

$generatedJson = Test-SchemaDocument -RelativePath 'data\resource-name-rules.json' `
    -Schema $catalogSchema -Reference '../schemas/naming-catalog.schema.json'
$null = Test-SchemaDocument -RelativePath 'data\resource-name-rules.manual.json' `
    -Schema $overlaySchema -Reference '../schemas/naming-overrides.schema.json'
$null = Test-SchemaDocument -RelativePath 'examples\customer_overrides\naming-overrides.json' `
    -Schema $overlaySchema -Reference '../../schemas/naming-overrides.schema.json'
$null = Test-SchemaDocument -RelativePath 'tests\unit\fixtures\customer_values.json' `
    -Schema $overlaySchema -Reference '../../../schemas/naming-overrides.schema.json'

foreach ($relativePath in @(
    'tests\unit\fixtures\invalid_catalog_schema.json',
    'tests\unit\fixtures\invalid_catalog_shape.json',
    'tests\unit\fixtures\malformed_catalog.txt'
)) {
    Test-SchemaCase -Name $relativePath -Json (Get-Content -LiteralPath (Join-Path $root $relativePath) -Raw) -Expected $false
}

$invalidEntries = (Get-Content -LiteralPath (Join-Path $root 'tests\unit\fixtures\invalid_catalog_entries.json') -Raw |
    ConvertFrom-Json -AsHashtable).resources
$runtimeOnlyCases = @('missing_slug', 'reversed_bounds', 'invalid_regex', 'missing_literal')
foreach ($key in $invalidEntries.Keys) {
    Test-SchemaCase -Name "entry $key" `
        -Json (ConvertTo-TestOverlay @{ $key = $invalidEntries[$key] }) `
        -Expected ($key -in $runtimeOnlyCases)
}

Test-SchemaCase -Name 'explicit empty, zero, false, null, and replacement metadata' -Json (ConvertTo-TestOverlay @{
    storage_account = @{
        slug = ''; min_length = 0; max_length = $null; regex = $null
        resource_type = $null; variant = $null; legacy_slug = $null; scope = $null; fixed_name = $null
        dashes = $false; lowercase = $false; validation_complete = $false
        legacy_outputs = @(); validation_notes = @(); forbidden_prefixes = @()
        forbidden_suffixes = @(); forbidden_sequences = @(); reserved_names = @()
        source = @{ organization = @{ labels = @('internal') } }
        override_reason = ''; override_source = ''
    }
})
Test-SchemaCase -Name 'partial overlay need not repeat an inherited slug' `
    -Json (ConvertTo-TestOverlay @{ storage_account = @{ max_length = 20 } })
Test-SchemaCase -Name 'cross-file new-entry requirements remain runtime validation' `
    -Json (ConvertTo-TestOverlay @{ new_organization_label = @{} })
Test-SchemaCase -Name 'null source metadata' `
    -Json (ConvertTo-TestOverlay @{ storage_account = @{ source = $null } })
Test-SchemaCase -Name 'unconstrained document metadata' `
    -Json '{"schema_version":2,"resources":{},"organization":{"version":1},"key_assignments":{},"legacy_mappings":{}}'

foreach ($schema in @($overlaySchema, $catalogSchema)) {
    foreach ($json in @(
        '[]',
        'null',
        '{}',
        '{"schema_version":"2","resources":{}}',
        '{"schema_version":2,"resources":null}',
        '{"schema_version":2,"resources":{},"overrides":{}}'
    )) {
        Test-SchemaCase -Name "invalid document $json ($schema)" -Json $json -Schema $schema -Expected $false
    }
}

foreach ($key in @('Uppercase', 'double__underscore', '_leading', 'trailing_', 'has-dash', "newline`n")) {
    Test-SchemaCase -Name "invalid key $key" -Json (ConvertTo-TestOverlay @{ $key = @{ slug = 'test' } }) -Expected $false
}

foreach ($entry in @(
    @{ slug_source = 'unknown' },
    @{ name_kind = $null },
    @{ fixed_name = 123 },
    @{ resource_type = @() },
    @{ variant = $false },
    @{ scope = 10 },
    @{ legacy_slug = $false },
    @{ regex = $true },
    @{ min_length = $false },
    @{ max_length = 1.5 },
    @{ validation_complete = 'true' },
    @{ validation_notes = @($null) },
    @{ forbidden_prefixes = 'bad' },
    @{ forbidden_sequences = @(1) },
    @{ legacy_outputs = $null },
    @{ source = @() },
    @{ source = $false },
    @{ override_reason = $null },
    @{ override_source = 12 }
)) {
    Test-SchemaCase -Name "invalid property $($entry.Keys -join ',')" `
        -Json (ConvertTo-TestOverlay @{ storage_account = $entry }) -Expected $false
}

$generated = ConvertFrom-Json -InputObject $generatedJson -AsHashtable
$firstEntry = $generated.resources.Values | Select-Object -First 1
$incompleteEntry = [ordered]@{}
foreach ($field in $firstEntry.Keys) {
    if ($field -ne 'slug') { $incompleteEntry[$field] = $firstEntry[$field] }
}
$incompleteJson = ConvertTo-TestOverlay @{ example = $incompleteEntry }
Test-SchemaCase -Name 'generated entries require all declared fields' -Json $incompleteJson -Schema $catalogSchema -Expected $false
Test-SchemaCase -Name 'the same partial entry is an allowed overlay' -Json $incompleteJson
$incompleteEntry.slug = $false
Test-SchemaCase -Name 'complete generated entries still require valid property types' `
    -Json (ConvertTo-TestOverlay @{ example = $incompleteEntry }) -Schema $catalogSchema -Expected $false

Write-Output "Naming schema tests: $script:Passed passed. No files or Azure resources were changed."
