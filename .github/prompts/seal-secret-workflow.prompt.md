---
description: "Convert a plaintext Kubernetes Secret into a repo-correct SealedSecret for this homelab"
argument-hint: "Secret file or inline secret data, target namespace, and consuming app path"
agent: "agent"
---

You are helping convert a Kubernetes Secret into a SealedSecret that matches this repository's GitOps conventions.

Use this when the user provides a plaintext Secret manifest, secret literals, or a temp secret file that should be committed safely.

## Task

1. Identify the consuming workload and namespace.
2. Place the sealed secret next to the app that uses it, following the repo pattern `*-sealedsecret.yaml`.
3. Preserve the Secret shape and keys unless the repository's existing pattern requires a known naming adjustment.
4. Ensure the output is a `SealedSecret`, not a plaintext `Secret`.
5. Call out any namespace label or policy requirement if the secret belongs to a new namespace.
6. If the source data looks malformed or incomplete, stop and ask for the missing values before generating the manifest.

## Repository Rules to Respect

- Never leave plaintext secret material in Git.
- Prefer the app-local secret file alongside the workload manifests.
- Keep the namespace consistent with the workload and its `network-zone` label.
- Do not change unrelated manifests while converting the secret.

## Output

Return:
- the target file path you recommend in this repo
- the generated SealedSecret manifest
- any follow-up validation command the user should run

## References

- [Copilot instructions](../../.github/copilot-instructions.md)
- [Flux manifest guardrails](../../.github/instructions/flux-manifest-guardrails.instructions.md)
- [Repository overview](../../README.md)
