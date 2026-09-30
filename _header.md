# Azure Verified Naming Utility

Generate Azure resource names from JSON catalogs. Requires Terraform 1.9 or later. This utility creates no Azure resources and requires no Azure credentials.

```hcl
module "naming" {
  source = "Azure/avm-utl-naming/azure"

  suffix = ["workload", "dev"]
}
```

Use `module.naming.names.storage_account.name_unique` or `module.naming.names_by_azure_type["Microsoft.Storage/storageAccounts"].storage_account.name_unique`.

## Modern catalogs and manual corrections

- `data/resource-name-rules.json` is generated from Microsoft's [naming rules](https://learn.microsoft.com/azure/azure-resource-manager/management/resource-name-rules) and [CAF abbreviations](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/azure-best-practices/resource-abbreviations).
- `data/resource-name-rules.manual.json` contains additions and property overrides in the same `resources` map, plus compatibility mappings and persisted public-key assignments. Original slugs fill gaps where the selected sources have no unambiguous CAF abbreviation; documented CAF recommendations remain the default.

Both resource maps use snake-case keys, with distinct entries for variants such as web apps and function apps. Key generation happens in PowerShell. Existing keys are retained when new types collide; only new entries are qualified. `names_by_azure_type` groups entries into maps using the same keys. Non-ARM manual entries appear only in `names`.

Catalogs merge in order: **generated, then bundled manual, then customer file**. Each layer can add keys or override individual properties of an existing key. For example, this manual or customer file changes only the static-site maximum:

```json
{
  "schema_version": 2,
  "resources": {
    "static_site": {
      "max_length": 30
    }
  }
}
```

Omitted properties and unrelated keys survive the merge. Supplied properties replace their previous values, including `false`, `0`, `""`, and nullable constraints set to `null`. Arrays and nested metadata objects replace as whole properties; this is not an arbitrary recursive JSON merge. Bundled corrections retain provenance in `override_reason` and `override_source`. Generated source data is unchanged.

### Customer override file

```hcl
module "naming" {
  source = "Azure/avm-utl-naming/azure"

  custom_override_file = "${path.module}/naming-overrides.json"
}
```

See [the customer-file example](examples/customer_overrides) for a partial slug override, an overridden manual limit, and a new storage-account variant. The file is caller-owned, not another bundled catalog. It must exist before Terraform starts; relative paths resolve from the Terraform working directory.

New keys require a string `slug` (empty omits it). Optional fields default to unknown constraints, lowercase separator-free names, and incomplete validation. Set `resource_type` and a distinct `variant` to expose a variant in the Azure-type view. Lengths, regexes, scope, `dashes`, `lowercase`, `name_kind`/`fixed_name`, and validation settings use the same properties as the bundled catalogs. String-array properties are `validation_notes`, `forbidden_prefixes`, `forbidden_suffixes`, `forbidden_sequences`, and `reserved_names`; clear an array with `[]`, not `null`.

Invalid keys, property names/types, naming modes, regexes, and reversed bounds are rejected. `slug_overrides` takes precedence over every file. Customer `legacy_outputs` metadata cannot reassign deprecated aliases; their membership comes from the bundled catalogs.

Missing constraints remain null unless an override supplies them. Clearing a bound or regex also makes validation incomplete, even if `validation_complete = true` was inherited. Incomplete modern validation returns null flags with `validation_notes`; these are candidate names, not verified Azure names. Name availability is not checked.

### Editor validation

`$schema` annotations in the bundled catalogs and customer example point to the committed [generated catalog schema](schemas/naming-catalog.schema.json) and [partial override schema](schemas/naming-overrides.schema.json). The updater writes the catalog references, so editor support survives regeneration and AVM synchronization without custom managed VS Code settings. Partial entries need not repeat inherited properties such as `slug`. Schemas check structure and types; merged-entry requirements, bound ordering, and Terraform RE2/template validity remain runtime checks.

## Numbered instances

Set `instance` to a nonnegative whole number. `instance_format` defaults to Terraform's `"%03d"` format: `instance = 7` produces `007`. The default convention appends this token after the suffix, using the resource's separator. A null instance leaves existing names unchanged.

The [instances example](examples/instances) uses `for_each` for numbers 1 through 20 and returns resource-group and storage-account names ending in `001` through `020`. It sets `unique_length = 0`, so no randomness is needed.

When numeric `instance` is set, it supplies the `instance` template token; also setting `naming_template_variables.instance` is an error. Without a numeric instance, that custom token remains available.

## Naming templates

Modern mode defaults to prefix, slug, suffix, optional instance, and uniqueness, using the entry's separator and casing rules. Null and empty prefix/suffix elements are ignored. Override the convention with escaped `$${token}` expressions.

In HCL string inputs, the extra `$` in `$${token}` passes literal `${token}` to this module's `templatestring` call instead of resolving it in the caller. Without escaping, module tokens such as `slug` can cause invalid-reference validation errors before the module evaluates the template.

```hcl
naming_template_variables = {
  environment = "prod"
  location    = "uks"
}
naming_templates = {
  name        = "$${join(separator, compact([slug, environment, location]))}"
  name_unique = "$${join(separator, compact([unique, name]))}"
}
```

The function-based template composes the components and places uniqueness first. Alternatively, use direct interpolation with the module's built-in instance formatting:

```hcl
instance = 1
naming_template_variables = {
  environment = "prod"
  location    = "uks"
}
naming_templates = {
  name = "$${slug}-$${environment}-$${location}-$${instance}"
}
```

This reads directly as `rg-prod-uks-001` for a resource group. `environment` and `location` are custom string tokens; the module formats numeric `instance = 1` as `001`. Override `instance_format` to change the formatting.

Literal hyphens suit resource groups but not storage accounts. Use the built-in separator token to support both without functions:

```hcl
naming_templates = {
  name = "$${slug}$${separator}$${environment}$${separator}$${location}$${separator}$${instance}"
}
```

Omitting `name_unique` keeps its default behavior, including avoiding a trailing separator when uniqueness is disabled. The [templates example](examples/templates) includes the original function-based convention and both additional direct-interpolation versions.

Built-in tokens are `prefix` and `suffix` lists, `slug`, `separator`, `unique`, `unique_seed`, `terraform_key`, `resource_type`, `variant`, `min_length`, and `max_length`, plus `instance` when its numeric input is set. The unique template also receives `name`, with space reserved for the template's overhead. Custom string tokens cannot replace built-in tokens.

Default truncation preserves the complete formatted instance and uniqueness tokens. Custom name templates must retain the complete `instance` token when supplied; unique templates must also retain the complete `unique` token. Interpolate these tokens directly or through whole-token case conversions such as `upper(unique)`. Arbitrary hashing, slicing, or conditional transformations of protected tokens are not supported.

For shorter names, use a compact template rather than additional padded/short output fields. The [compact example](examples/compact) hashes only workload prefix/suffix content and directly interpolates the complete instance and unique tokens.

Feasibility is per entry: an oversized or unverifiable name returns null with `name_available = false` and `name_errors`, or `name_unique_available = false` and `name_unique_errors`. Other entries remain usable. These flags describe rendering and token retention, not Azure name availability. `fits_max_length` describes the unique-name candidate and is null when no maximum is known. Check the selected entry before using it:

```hcl
output "storage_account_name" {
  value = module.naming.names.storage_account.name_unique

  precondition {
    condition     = module.naming.names.storage_account.name_unique_available
    error_message = join(" ", module.naming.names.storage_account.name_unique_errors)
  }
}
```

Entries expose `unique_suffix_retained`, the formatted `instance`, and `instance_retained.name` / `instance_retained.name_unique`. `separator` reports the catalog-derived separator even when a custom template does not use it. Literal names remain fixed; GUID-only names use deterministic UUID rendering. For Windows consumers whose `computer_name` defaults to the resource name, use `names.virtual_machine_windows` (15-character cap) instead of the generic 64-character ARM-name entry.

`slug_overrides` is a nullable map keyed by the JSON key. An empty override omits the slug.

## Stable names and randomness

Modern mode creates random resources only when `unique_length` is nonzero and no nonempty `unique_seed` is supplied. A supplied seed is returned unchanged. With `unique_length = 0`, `name_unique` equals `name`; without a supplied seed, `unique_seed` is null. Keep the inputs that determine whether random resources are needed known during planning.

Modern mode now uses separate random resources. **Upgrading modern mode from v0.1.0 intentionally regenerates generated seeds when randomness is needed.** This one-time change can alter names and cause replacement of consumer resources; subsequent runs retain the new seed in state.

To preserve the previous uniqueness token, capture the full previous `unique_seed` before upgrading, for example from `module.naming.names.storage_account.unique_seed`, and supply that exact string through the `unique_seed` input. This preserves the seed/token, not necessarily complete modern names: catalog and slug corrections can also change names. Keep other naming inputs unchanged and inspect the plan. Retain Terraform state; selecting an explicit seed or zero uniqueness length can remove now-unused random resources.

Boundary-rule fixes preserve documented trailing digits across services such as Event Hubs and Key Vault, and permitted trailing underscores on network resources. Some previously incomplete rules now return validation results. Review selected names and validation flags when upgrading, even with a fixed seed.

Azure can reserve names after deletion, including soft-deleted Key Vault names. This module does not check availability or rotate names automatically. When a genuinely new name is required, deliberately change a stable `instance` or `unique_seed`. Do not use timestamps or routine state deletion to rotate names.

The bare CAF Log Analytics workspace slug `log` is shorter than its four-character minimum, so `names.operational_insights_workspace.validation.valid_name` is false without an affix or instance. Use `suffix = ["workload"]` for `log-workload`, `instance = 1` for `log-001`, or a unique name with sufficient length. The module does not pad the name or change the CAF abbreviation.

## Migrating from the original module

For original behavior, keep the existing module block name, input values, and Terraform state; change the source and add `legacy_mode = true`:

```hcl
module "naming" {
  source = "Azure/avm-utl-naming/azure"

  legacy_mode = true
  prefix      = ["Contoso"]
  suffix      = ["Prod"]
}

output "resource_group_name" {
  value = module.naming.resource_group.name
}
```

Run `terraform init -upgrade` and inspect the plan. Keep any existing seed and uniqueness-length configuration unchanged. The included moved blocks retain the original random values at indexed addresses; do not delete state to perform this migration. These original random resources are now legacy-only and remain present in legacy mode even with a supplied seed or zero uniqueness length.

Legacy mode uses the frozen [original renderer](https://github.com/Azure/terraform-azurerm-naming/tree/fc289126c9c888393ff02a79e1babadd6865861c) in `locals.legacy.tf`, not the current JSON rules. It retains original separators, casing, per-alias limits, regexes, scope tokens, and boolean validation, including historical quirks. Continue using the deprecated named outputs in `outputs.legacy.tf`; the modern dynamic maps are empty in this mode. Modern templates, custom tokens, slug overrides, bundled rule patches, and customer files do not change legacy results.

See [the override-free legacy example](examples/legacy). `legacy_mode` defaults to false. Modern mode can produce different names, so switching modes is a deliberate migration. The legacy code is temporary; pin a module version if you need it after its removal.

### Deprecated input names

| Deprecated input | Replacement |
| --- | --- |
| `unique-include-numbers` | `unique_include_numbers` |
| `unique-length` | `unique_length` |
| `unique-seed` | `unique_seed` |

The old inputs remain in `variables.deprecated.tf`. A non-null replacement takes precedence in either mode; null uses the deprecated input. Effective defaults remain `true`, `4`, and a state-persisted random seed. Explicit `false` and `0` are honored; an empty seed requests the default seed behavior for the selected mode.

## Updates

The Monday 06:23 UTC/manual workflow regenerates modern runtime data and proposes changes for review. It never updates the frozen legacy renderer or automatically merges changes. An open update is left untouched until merged or closed.

Manual additions, reviewed overrides, and public-key assignments persist across regeneration. Historical-slug fallbacks that exist only because no CAF abbreviation was documented are retired when a recommendation appears; `legacy_mode` retains the original names. Removed generated entries are retained beneath any existing manual patch so omitted properties are not lost.

Repository settings must permit GitHub Actions to create pull requests. Requests created with `GITHUB_TOKEN` do not automatically trigger other workflows; validation runs before publication.

## Contributing

See the [naming contribution guide](docs/contributing.md) for editable files, PowerShell catalog checks, schemas, and managed documentation commands.
