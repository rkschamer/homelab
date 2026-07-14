# Pets

Manually managed infrastructure — everything that is **not** controlled via IaC
(Terraform/Flux). Pets vs. cattle: these hosts are set up and maintained by hand,
so each one gets a runbook here that makes it rebuildable from scratch.

**Admission rule:** if it can't be recreated with `terraform apply` or a Flux sync,
its documentation lives here. Nothing in this directory is reconciled automatically —
being a pet is a deliberate choice (the machinery to automate it would outweigh the
service), not an accident. Keep this collection small.

## Conventions

- One folder per pet, `README.md` as the runbook (creation, install, config, recovery).
- Helper scripts and config snippets live next to the runbook in the same folder.
- Note explicitly which state is mutable/non-disposable (e.g. auth files) and which
  parts are throwaway.
- Cross-cutting architecture rationale stays in `docs/`; the pet folder covers the
  host itself.

## Inventory

| Pet | Purpose | IP |
|-----|---------|-----|
| [horsmar-proxy](horsmar-proxy/) | socat TCP proxy bridging cluster traffic to Horsmar Home Assistant via FritzBox VPN | 192.168.123.11 |
| [audible](audible/) | audible-rs audiobook download + sync to NAS | DHCP |
