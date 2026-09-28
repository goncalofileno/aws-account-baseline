terraform {
  required_version = ">= 1.10.0"

  # No provider requirement: this module has no resources or data sources, only locals and an
  # output. It computes the standard tag map (docs/tagging-policy.md) for callers to hand to a
  # provider's default_tags.
}
