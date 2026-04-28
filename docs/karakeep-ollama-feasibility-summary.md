# Karakeep + Ollama Feasibility Summary

Date: 2026-04-28

## Goal

Capture the current discussion so the Karakeep/Ollama deployment decision can be revisited later without redoing the analysis.

## Bottom Line

Karakeep is feasible in this homelab. The hard constraint is not Karakeep itself, but the AI backend and the memory budget for running it locally.

The current workers are only 5 GiB each, so the practical local model range is still small. For this cluster, the realistic target is roughly 1B to 4B parameters, with 3B to 4B being the sweet spot.

## Zone Guidance

- Karakeep can live in `untrusted`.
- `untrusted` is internet-only by default.
- Karakeep in `untrusted` cannot reach Ollama in `trusted` unless an explicit allow policy is added.
- If Ollama needs home LAN or NAS access, `trusted` is the correct zone.
- `dmz` is only appropriate if Ollama needs to talk to explicit trusted Kubernetes backends while still staying off the home LAN.

## Model Candidates Found on Hugging Face

Best current small-model options:

- `microsoft/Phi-4-mini-instruct`
  - 3.8B parameters
  - Released Feb 2025
  - Best general-purpose small model for this cluster
  - Strong fit for Karakeep if you want a practical text-only Ollama backend

- `google/gemma-3-4b-it`
  - 4B parameters
  - 128K context
  - Current 2025 release
  - Good if you want a small but modern multimodal-capable option

- `microsoft/Phi-4-mini-reasoning`
  - 3.8B parameters
  - Released Apr 2025
  - Better if you care more about reasoning/math than broad general chat
  - More specialized than `Phi-4-mini-instruct`

- `google/gemma-3-1b-it`
  - 1B parameters
  - Current 2025 release
  - Safest option for extremely tight memory budgets
  - Lower capability, but easiest to fit

Less suitable options:

- `Qwen/Qwen3-8B`
  - Current and strong, but probably too large for the current worker memory budget without a RAM bump

- `mistralai/Mistral-Small-3.1-24B-Instruct-2503`
  - Too large for this setup
  - The card points to roughly 55 GB GPU RAM in bf16/fp16

## TurboQuant

TurboQuant looks interesting as research, but it is not a practical near-term answer to the memory constraint here.

## Practical Recommendation

If the goal is to get Karakeep working soon with a local model:

1. Start with `microsoft/Phi-4-mini-instruct`.
2. Use `google/gemma-3-4b-it` only if you want a path toward multimodal capability.
3. Use `google/gemma-3-1b-it` if the deployment needs to be as light as possible.
4. Treat `Qwen/Qwen3-8B` as a future option after a RAM increase.

## What This Means For Deployment

- Karakeep itself is lightweight enough to deploy in GitOps-managed Flux manifests.
- Ollama is the component that determines the real memory and zone placement constraints.
- If AI tagging is optional, Karakeep can be deployed first without committing to local LLM inference.
- If local inference is required, a small current model is the right approach, not a frontier-scale model.

## Possible Next Step

If you want to proceed, the next concrete task is to draft Flux manifests for:

- Karakeep in `untrusted`
- Optional Ollama deployment in the chosen zone
- Matching Cilium policy for the zone boundary
