# Longhorn Notes

## Kubernetes Compatibility: VolumeAttributesClass RBAC

On newer Kubernetes versions, Longhorn components may watch
`volumeattributesclasses.storage.k8s.io` at cluster scope.

If the Longhorn service account does not have `get/list/watch` on this resource,
logs can show errors similar to:

```text
Failed to list *v1.VolumeAttributesClass: volumeattributesclasses.storage.k8s.io is forbidden
```

This repository includes a dedicated RBAC manifest to prevent that issue:
- `longhorn-volumeattributesclass-rbac.yaml`

Do not remove this RBAC unless the Longhorn chart natively grants the same
permissions.
