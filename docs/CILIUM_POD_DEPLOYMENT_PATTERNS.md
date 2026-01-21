# Pod Deployment Patterns for CiliumNetworkPolicy

This guide shows how to deploy applications with proper labels and network zone assignments for the CiliumNetworkPolicy framework.

## Pod Label Requirements

All pods should have these labels for policy enforcement:

```yaml
metadata:
  labels:
    # Required: Pod application name
    app: <app-name>

    # Required: Network zone (for zone-based isolation)
    network-zone: trusted | dmz | untrusted | monitoring

    # Optional: Component/tier
    tier: frontend | backend | database

    # Optional: Version
    version: v1
```

## Zone-Specific Deployment Patterns

### Pattern 1: Trusted Zone (Internal Services)

Use for services on Trusted worker that have home network access.

**Example**: Home Assistant, NAS, Internal APIs

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: homeassistant
  namespace: homeassistant
spec:
  selector:
    matchLabels:
      app: homeassistant
  template:
    metadata:
      labels:
        app: homeassistant
        network-zone: trusted
        tier: backend
    spec:
      # Schedule on Trusted worker
      nodeSelector:
        kubernetes.io/hostname: talos-worker-trusted-1

      containers:
      - name: homeassistant
        image: ghcr.io/home-assistant/home-assistant:latest
        ports:
        - containerPort: 8123
          name: http

---
# Network policy: Allow Traefik to reach this service
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-traefik-to-homeassistant
  namespace: homeassistant
spec:
  description: "Allow Traefik ingress controller to reach Home Assistant"
  endpointSelector:
    matchLabels:
      app: homeassistant
  ingress:
  - fromNamespaces:
    - name: kube-system
    fromLabelSelector:
      matchLabels:
        app: traefik
    toPorts:
    - ports:
      - port: "8123"
        protocol: TCP
  - fromNamespaces:
    - name: homeassistant
    fromLabelSelector:
      matchLabels:
        app: homeassistant
    toPorts:
    - ports:
      - port: "8123"
```

### Pattern 2: DMZ Zone (Public-Facing Services)

Use only for Traefik or other ingress controllers that need public internet access.

**Example**: Traefik, Reverse Proxies, Public APIs

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: traefik
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: traefik
  template:
    metadata:
      labels:
        app: traefik
        network-zone: dmz
        tier: frontend
    spec:
      # Schedule on DMZ worker
      nodeSelector:
        kubernetes.io/hostname: talos-worker-dmz-1

      serviceAccountName: traefik
      containers:
      - name: traefik
        image: traefik:latest
        ports:
        - containerPort: 80
          name: http
        - containerPort: 443
          name: https
        - containerPort: 8080
          name: dashboard

---
# Network policy: Traefik can reach all backends it needs
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-traefik-backends
  namespace: kube-system
spec:
  description: "Allow Traefik to reach backend services in Trusted zone"
  endpointSelector:
    matchLabels:
      app: traefik
      network-zone: dmz
  egress:
  # Reach Trusted zone services
  - toNamespaces:
    - name: homeassistant
    toLabelSelector:
      matchLabels:
        app: homeassistant
    toPorts:
    - ports:
      - port: "8123"
        protocol: TCP
  # Reach DNS
  - toNamespaces:
    - name: kube-system
    toFQDNs:
    - matchName: "*.svc.cluster.local"
    toPorts:
    - ports:
      - port: "53"
        protocol: UDP
```

### Pattern 3: Untrusted Zone (Experimental/Sandboxed)

Use for development, testing, or untrusted third-party workloads.

**Example**: Dev apps, Test deployments, Experimental services

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-app
  namespace: experimental
spec:
  selector:
    matchLabels:
      app: test-app
  template:
    metadata:
      labels:
        app: test-app
        network-zone: untrusted
        tier: backend
    spec:
      # Schedule on Untrusted worker
      nodeSelector:
        kubernetes.io/hostname: talos-worker-untrusted-1

      # Additional security: Run as non-root
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsReadOnlyRootFilesystem: true

      containers:
      - name: test-app
        image: myapp:dev
        ports:
        - containerPort: 3000

        # Restrict capabilities
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL

---
# Network policy: Untrusted pods can only talk to each other
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: untrusted-internal-only
  namespace: experimental
spec:
  description: "Untrusted pods isolated - internal communication only"
  endpointSelector:
    matchLabels:
      network-zone: untrusted
  ingress:
  # Allow from other untrusted pods
  - fromNamespaces:
    - name: experimental
    fromLabelSelector:
      matchLabels:
        network-zone: untrusted
    toPorts:
    - ports:
      - port: "3000"
        protocol: TCP
  # Allow metrics scraping
  - fromNamespaces:
    - name: monitoring
    fromLabelSelector:
      matchLabels:
        app: prometheus
    toPorts:
    - ports:
      - port: "9100"
        protocol: TCP
```

### Pattern 4: Monitoring Zone (Observability)

Use for Prometheus, Grafana, Hubble, and other monitoring infrastructure.

**Example**: Prometheus, Grafana, AlertManager

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: prometheus
  template:
    metadata:
      labels:
        app: prometheus
        network-zone: monitoring
        tier: backend
    spec:
      # Schedule on Monitoring worker
      nodeSelector:
        kubernetes.io/hostname: talos-worker-monitoring-1

      serviceAccountName: prometheus
      containers:
      - name: prometheus
        image: prom/prometheus:latest
        ports:
        - containerPort: 9090

        volumeMounts:
        - name: config
          mountPath: /etc/prometheus
        - name: storage
          mountPath: /prometheus

      volumes:
      - name: config
        configMap:
          name: prometheus-config
      - name: storage
        emptyDir: {}

---
# Network policy: Prometheus can pull metrics from all zones
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-prometheus-all-zones
  namespace: monitoring
spec:
  description: "Allow Prometheus to scrape metrics from all worker zones"
  endpointSelector:
    matchLabels:
      app: prometheus
  egress:
  # Query coredns
  - toNamespaces:
    - name: kube-system
    toLabelSelector:
      matchLabels:
        app.kubernetes.io/name: coredns
    toPorts:
    - ports:
      - port: "53"
        protocol: UDP

  # Scrape all worker zones
  - toLabelSelector:
      matchLabels:
        network-zone: trusted
    toPorts:
    - ports:
      - port: "9100"
        protocol: TCP
      - port: "9090"
        protocol: TCP

  - toLabelSelector:
      matchLabels:
        network-zone: dmz
    toPorts:
    - ports:
      - port: "9100"
        protocol: TCP

  - toLabelSelector:
      matchLabels:
        network-zone: untrusted
    toPorts:
    - ports:
      - port: "9100"
        protocol: TCP

  # Access Kubelet on all workers
  - toNamespaces:
    - name: kube-system
    toLabelSelector:
      matchLabels:
        k8s-app: kubelet
    toPorts:
    - ports:
      - port: "10250"
        protocol: TCP
```

## Common Ingress Pattern

When exposing services through Traefik:

```yaml
---
# Backend service (on Trusted worker)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-api
  namespace: my-app
spec:
  template:
    metadata:
      labels:
        app: my-api
        network-zone: trusted
        tier: backend
    spec:
      nodeSelector:
        kubernetes.io/hostname: talos-worker-trusted-1
      containers:
      - name: api
        image: myapi:latest
        ports:
        - containerPort: 8080

---
# Service for the backend
apiVersion: v1
kind: Service
metadata:
  name: my-api
  namespace: my-app
spec:
  selector:
    app: my-api
  ports:
  - port: 8080
    targetPort: 8080

---
# Ingress through Traefik (DMZ)
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-api-ingress
  namespace: my-app
  annotations:
    kubernetes.io/ingress.class: traefik
spec:
  rules:
  - host: api.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: my-api
            port:
              number: 8080

---
# Network policy: Allow Traefik to reach this backend
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-ingress-my-api
  namespace: my-app
spec:
  description: "Allow Traefik to reach my-api backend"
  endpointSelector:
    matchLabels:
      app: my-api
  ingress:
  - fromNamespaces:
    - name: kube-system
    fromLabelSelector:
      matchLabels:
        app: traefik
    toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
```

## Multi-Tier Application Example

Complete example with frontend, backend, and database:

```yaml
---
# Frontend on DMZ (public ingress)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: app
spec:
  template:
    metadata:
      labels:
        app: frontend
        tier: frontend
        network-zone: dmz
    spec:
      nodeSelector:
        kubernetes.io/hostname: talos-worker-dmz-1
      containers:
      - name: frontend
        image: myapp-frontend:latest
        ports:
        - containerPort: 80

---
# Backend on Trusted (internal only)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: app
spec:
  template:
    metadata:
      labels:
        app: backend
        tier: backend
        network-zone: trusted
    spec:
      nodeSelector:
        kubernetes.io/hostname: talos-worker-trusted-1
      containers:
      - name: backend
        image: myapp-backend:latest
        ports:
        - containerPort: 8080

---
# Database on Trusted (internal only)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: database
  namespace: app
spec:
  template:
    metadata:
      labels:
        app: database
        tier: database
        network-zone: trusted
    spec:
      nodeSelector:
        kubernetes.io/hostname: talos-worker-trusted-1
      containers:
      - name: postgres
        image: postgres:latest
        ports:
        - containerPort: 5432

---
# Network Policies for multi-tier
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: frontend-to-backend
  namespace: app
spec:
  description: "Frontend can reach backend"
  endpointSelector:
    matchLabels:
      app: backend
  ingress:
  - fromLabelSelector:
      matchLabels:
        app: frontend
    toPorts:
    - ports:
      - port: "8080"

---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: backend-to-database
  namespace: app
spec:
  description: "Backend can reach database"
  endpointSelector:
    matchLabels:
      app: database
  ingress:
  - fromLabelSelector:
      matchLabels:
        app: backend
    toPorts:
    - ports:
      - port: "5432"

---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: ingress-frontend
  namespace: app
spec:
  description: "Traefik can reach frontend"
  endpointSelector:
    matchLabels:
      app: frontend
  ingress:
  - fromNamespaces:
    - name: kube-system
    fromLabelSelector:
      matchLabels:
        app: traefik
    toPorts:
    - ports:
      - port: "80"
```

## Checklist for New Deployments

Before deploying a new app:

- [ ] Choose appropriate network zone (trusted, dmz, untrusted, monitoring)
- [ ] Add `network-zone` label to pod spec
- [ ] Add `app` label identifying the application
- [ ] Use `nodeSelector` to schedule on correct worker
- [ ] Create CiliumNetworkPolicy for ingress traffic
- [ ] If accessing other services, create egress policy
- [ ] Test connectivity with `kubectl exec` and `curl`
- [ ] Monitor with `cilium hubble observe`
- [ ] Commit manifests to Git

## References

- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Network Policies Best Practices](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [Cilium Policy Examples](https://docs.cilium.io/en/latest/security/policy/language/)
