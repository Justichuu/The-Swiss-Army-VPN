# Roadmap

## Ideas under consideration

### Optional United States installation

Offer a country choice during installation while keeping Switzerland as the default.

Guardrails for a future implementation:

- Install exactly one managed VPN profile, not parallel country profiles.
- Make the selected country explicit in the profile name, interface text, diagnostics, server validation, and installation state.
- Maintain separate vetted live-server filters and offline seed pools for each country.
- Preserve the existing fail-closed kill-switch behavior during every connection change.
- Treat switching countries after installation as a deliberate reconfiguration, not automatic failover.

Status: idea only; not part of v1.2.0.
