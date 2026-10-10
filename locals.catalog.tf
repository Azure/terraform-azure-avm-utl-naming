locals {
  bundled_catalog = {
    for key in setunion(toset(keys(local.generated_catalog.resources)), toset(keys(local.manual_catalog.resources))) :
    key => merge(
      local.catalog_entry_defaults,
      try(local.generated_catalog.resources[key], {}),
      try(local.manual_catalog.resources[key], {}),
    )
  }
  catalog = {
    for key, definition in local.catalog_entries : key => merge(definition, {
      validation_complete = definition.validation_complete && local.catalog_rules_present[key]
      validation_notes = distinct(concat(
        definition.validation_notes,
        local.catalog_rules_present[key] ? [] : ["Validation is incomplete while min_length, max_length, or regex is null."],
        !definition.validation_complete && local.catalog_rules_present[key] && length(definition.validation_notes) == 0 ? ["Validation completeness has not been specified for this entry."] : [],
      ))
    })
  }
  catalog_entries = {
    for key in setunion(toset(keys(local.bundled_catalog)), toset(keys(local.customer_resources_valid))) :
    key => merge(
      local.catalog_entry_defaults,
      try(local.bundled_catalog[key], {}),
      try(local.customer_resources_valid[key], {}),
    )
  }
  catalog_entry_defaults = {
    resource_type       = null
    variant             = null
    slug                = null
    slug_source         = "manual"
    legacy_slug         = null
    legacy_outputs      = []
    min_length          = null
    max_length          = null
    scope               = null
    regex               = null
    dashes              = false
    lowercase           = true
    name_kind           = "standard"
    fixed_name          = null
    validation_complete = false
    validation_notes    = []
    forbidden_prefixes  = []
    forbidden_suffixes  = []
    forbidden_sequences = []
    reserved_names      = []
  }
  catalog_rules_present = {
    for key, definition in local.catalog_entries :
    key => definition.min_length != null && definition.max_length != null && definition.regex != null
  }
  customer_catalog = try(jsondecode(local.customer_catalog_json), null)
  customer_catalog_json = (
    var.legacy_mode || var.custom_override_file == null ? jsonencode({ schema_version = 2, resources = {} }) :
    try(file(var.custom_override_file), null)
  )
  customer_catalog_valid = try(
    local.customer_catalog.schema_version == 2 &&
    can(keys(local.customer_catalog.resources)) &&
    !contains(keys(local.customer_catalog), "overrides"),
    false,
  )
  customer_entries = {
    for key, definition in local.customer_resources :
    key => merge(local.catalog_entry_defaults, try(local.bundled_catalog[key], {}), try(merge(definition), {}))
  }
  customer_entry_valid = {
    for key, definition in local.customer_entries : key => try(
      can(regex("^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$", key)) &&
      can(keys(local.customer_resources[key])) &&
      length(setsubtract(toset(keys(local.customer_resources[key])), setunion(
        toset(keys(local.catalog_entry_defaults)), toset(["source", "override_reason", "override_source"]),
      ))) == 0 &&
      alltrue([
        for field in ["slug", "slug_source", "name_kind"] :
        definition[field] != null && tostring(definition[field]) == definition[field]
      ]) &&
      alltrue([
        for field in ["resource_type", "variant", "legacy_slug", "scope", "regex", "fixed_name"] :
        definition[field] == null ? true : tostring(definition[field]) == definition[field]
      ]) &&
      alltrue([
        for field in ["dashes", "lowercase", "validation_complete"] :
        definition[field] != null && contains([true, false], definition[field])
      ]) &&
      alltrue([
        for field in ["legacy_outputs", "validation_notes", "forbidden_prefixes", "forbidden_suffixes", "forbidden_sequences", "reserved_names"] :
        definition[field] != null && can(tolist(definition[field])) &&
        alltrue([for value in definition[field] : value != null && tostring(value) == value])
      ]) &&
      alltrue([
        for field in ["min_length", "max_length"] :
        definition[field] == null ? true : (
          tonumber(definition[field]) == definition[field] &&
          definition[field] >= 0 && floor(definition[field]) == definition[field]
        )
      ]) &&
      (definition.min_length == null || definition.max_length == null ? true : definition.min_length <= definition.max_length) &&
      contains(["caf", "derived", "manual"], definition.slug_source) &&
      contains(["standard", "uuid", "literal"], definition.name_kind) &&
      (definition.name_kind == "literal" ? definition.fixed_name != null : true) &&
      (definition.regex == null ? true : can(regexall(templatestring(definition.regex, {
        min_length = definition.min_length
        max_length = definition.max_length
      }), ""))) &&
      (try(local.customer_resources[key].source, null) == null ? true : can(keys(local.customer_resources[key].source))) &&
      alltrue([
        for field in ["override_reason", "override_source"] :
        contains(keys(local.customer_resources[key]), field) ? (
          local.customer_resources[key][field] != null && tostring(local.customer_resources[key][field]) == local.customer_resources[key][field]
        ) : true
      ]),
      false,
    )
  }
  customer_entry_error = "Invalid merged custom_override_file entries: ${join(", ", [for key, valid in local.customer_entry_valid : key if !valid])}. Use lower-snake-case keys and supported properties with their JSON types, a string slug, nonnegative integer bounds (min_length <= max_length), a valid RE2 regex/template, and fixed_name for literal names. Lists must be string arrays, not null."
  customer_resources = jsondecode(
    local.customer_catalog_valid ? jsonencode(local.customer_catalog.resources) : jsonencode({})
  )
  # Invalid overlays fail output preconditions, rather than reaching the renderer.
  customer_resources_valid = {
    for key, definition in local.customer_resources : key => definition if local.customer_entry_valid[key]
  }
  generated_catalog = jsondecode(var.legacy_mode ? jsonencode({ schema_version = 2, resources = {} }) : file("${path.module}/data/resource-name-rules.json"))
  manual_catalog    = jsondecode(var.legacy_mode ? jsonencode({ schema_version = 2, resources = {} }) : file("${path.module}/data/resource-name-rules.manual.json"))
}
