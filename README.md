# EKS Local Helm Add-on Staging & Deployment

This repository provides an automated, modular, data-driven workflow engine using **PowerShell Core (`pwsh`)** to cache, stage, sync, and deploy a comprehensive suite of cloud infrastructure add-ons sequentially onto Amazon EKS clusters.

---

## 🛠️  Architecture & Key Features

*   **Decoupled & Isolated Staging:** The staging layer relies exclusively on an internet connection and the `helm` and `git` command binaries. It operates independently of an active AWS session context footprint.
*   **Structured Project Tree Workspace:** Extracted upstream raw charts are cleanly managed under an isolated `charts/` root folder. Custom configuration manifests are stored inside a dedicated `overrides/` folder.
*   **Separated Inventory and Values:** `inventory.yaml` defines add-on metadata, while the matching files in `overrides/` hold the Helm values. The staging script preserves existing overrides.
*   **Secure Environment Isolation Guard:** Protects live systems by binding credentials strictly to a temporary process session profile (`$env:KUBECONFIG`). Accidental production data leaks or cross-contamination is functionally impossible.
*   **Idempotency & Version Shifting Cache:** Reads your local configuration definitions dynamically. If versions match, downloading is safely bypassed. If version data changes, older directory trees are cleanly archived to `<chart-name>-<old-version>` to protect adjustments.
*   **Dynamic Component Execution Toggles:** Features a built-in `Enabled: true/false` block. The script evaluates this flag smoothly to allow toggling entire sub-workloads on or off instantly without purging inventory entries.
*   **Automated Cross-Cluster Multi-Targeting:** Orchestrates backend calls dynamically. The deployment runner uses a unified positional input variable to dynamically inject active parameters like `clusterName` or `settings.clusterName` on the fly via the Helm installation engine.

---

## 📁 Workspace Structural Footprints

```text
📁 eks-helm-addons/
├── 📄 inventory.yaml     # Add-on metadata, versions, namespaces, and rollout targets
├── 📄 vendor-charts.ps1  # Phase 1: Local chart asset staging and cache runner
├── 📄 install-charts.ps1 # Phase 2: Secure sequential sandboxed installer driver
├── 📁 charts/            # Subdirectory target folder where extracted Helm charts live
│   ├── 📁 eks-pod-identity-agent/
│   ├── 📁 aws-load-balancer-controller/
│   └── ...
├── 📁 overrides/         # UTF-8 Helm value configuration manifests
│   ├── 📄 pod-identity-agent.yaml
│   ├── 📄 lb-controller.yaml
│   └── ...
├── 📁 iam-roles/         # Pod Identity IAM role definitions and provisioning script
│   ├── 📄 role-inventory.yaml
│   ├── 📄 create-roles.ps1
│   └── 📁 policies/
├── 📁 secrets/           # External Secrets Store and NATS credentials manifests
│   ├── 📄 cluster-secret-store.yaml
│   ├── 📄 nats-auth.yaml
│   └── 📄 app-nats-auth.yaml
├── 📁 private-ca/        # AWS Private CA issuer manifests
│   └── 📄 cluster-issuer.yaml
├── 📁 dashboards/        # Grafana dashboard deployment script and ConfigMaps
│   ├── 📄 create-dashboards.ps1
│   └── 📁 manifests/
│       ├── 📄 cluster-overview.yaml
│       ├── 📄 loki-logs-overview.yaml
│       ├── 📄 nats-overview.yaml
│       └── 📄 namespace-overview.yaml
└── 📁 infra-ingress/     # Shared internal ALB Ingress deployment script and manifests
    ├── 📄 create-infra-ingress.ps1
    └── 📁 manifests/
        ├── 📄 grafana.yaml
        └── 📄 argocd.yaml
```

---

## ⚙️ Prerequisites

### 1. Required System CLI Tools
Ensure the following binaries are globally accessible in your system's `PATH`:
*   **PowerShell Core (`pwsh`) v7+**
*   **AWS CLI v2**
*   **Helm v3**
*   **kubectl**
*   **git**

### 2. Native PowerShell Helper Extensions
The repo relies on structural object mapping. Install the module by executing this command inside your terminal:
```powershell
Install-Module -Name powershell-yaml -Scope CurrentUser -Force
```

---

## 📄 Inventory Registry Mapping (`inventory.yaml`)

Define your targets, configurations, expected validation parameters, and Pod Identity rules here. Standard `# comments` are supported.
Set an optional `ReleaseName` when the Helm release name should differ from the chart directory name; it otherwise defaults to `ChartName`.

```yaml
- ChartName: aws-load-balancer-controller
  Enabled: true
  RepoUrl: https://github.io
  ChartVersion: 1.7.1
  Namespace: kube-system
  ValuesFile: lb-controller.yaml
  PodIdentity:
    RoleArn: arn:aws-us-gov:iam::123456789012:role/ProgramManaged-lb-controller-pod-identity
    ServiceAccount: aws-load-balancer-controller
  RolloutTargets:
    - Type: deployment
      Name: aws-load-balancer-controller
  DefaultValues:
    resources:
      limits: { cpu: "200m", memory: "256Mi" }
      requests: { cpu: "100m", memory: "128Mi" }
    env:
      AWS_CA_BUNDLE: "/host-ca/tls-ca-bundle.pem"
    extraVolumes:
      - name: custom-ca-bundle
        hostPath: { path: "/etc/pki/tls/certs", type: Directory }
    extraVolumeMounts:
      - name: custom-ca-bundle
        mountPath: "/host-ca"
        readOnly: true
```

---

## Deployment Sequence

Run the phases in this order. Each cluster-facing script creates an isolated temporary kubeconfig and uses the supplied AWS CLI profile. `-profile` defaults to `admin`.

### 1. Provision Pod Identity roles

Replace the `REPLACE_WITH_...` values in `iam-roles/policies/`, then create or reconcile every role and inline policy:

```powershell
.\iam-roles\create-roles.ps1 -Profile admin
```

The script creates missing roles, updates the Pod Identity trust policy on existing roles, and puts an inline permission policy using the same name as its role. It supports `-WhatIf` for a no-change preview.

### 2. Update the add-on inventory

Update `inventory.yaml` before vendoring charts. It is the source of truth for enabled add-ons, chart versions, namespaces, Pod Identity role ARNs, and rollout targets. Helm values belong in the corresponding file under `overrides/`. Ensure every enabled `PodIdentity.RoleArn` points to the role created in step 1.

### 3. Vendor the chart sources

Run the staging script to download the configured chart versions and validate the existing UTF-8 override files. It creates an empty override only when one is missing:

```powershell
.\vendor-charts.ps1
```

### 4. Install the enabled Helm charts

Before installing NATS, manually create the `eks-nats-auth-external` AWS Secrets Manager secret in the Region configured by `secrets/cluster-secret-store.yaml`. Its value must be JSON with `username` and `password` properties:

```json
{
  "username": "nats-user",
  "password": "your-password"
}
```

`secrets/cluster-secret-store.yaml` is configured for `us-gov-east-1`. `install-charts.ps1` creates the `nats-system` and `app-dev` namespaces when needed, then applies the ClusterSecretStore and both ExternalSecrets before installing NATS. Applications receive `NATS_URL`, `NATS_USERNAME`, and `NATS_PASSWORD` from `nats-client-credentials`.

Install all enabled charts after the NATS secret is available:

```powershell
.\install-charts.ps1 -cluster my-production-cluster -env prod -profile admin
```

`-env` sets Promtail's `log_environment` label and defaults to `test`. The installer also uses `-cluster` to set Promtail's `cluster` label, configures its Loki endpoint as `loki-gateway.logging.svc.cluster.local`, and sets Loki's S3 object prefix to `clusters/<cluster>`. This allows multiple clusters to use the same Loki bucket without mixing their objects. The installer creates Pod Identity associations, renders every enabled chart before installing it, and waits for the configured rollout targets. It does not apply dashboards or infrastructure Ingresses.

When `aws-privateca-issuer` is enabled, the installer applies `private-ca/cluster-issuer.yaml` after the issuer controller rolls out. Replace `REPLACE_WITH_PRIVATE_CA_ID` in both that manifest and `iam-roles/policies/privateca-issuer-perm.json` with the existing ACM Private CA ID before installation. The manifest creates the cluster-scoped `corporate-private-ca` issuer.

### 5. Apply infrastructure Ingresses

After the Load Balancer Controller, ExternalDNS, and the enabled Grafana and Argo CD services are ready, apply the shared ALB Ingress manifests:

```powershell
.\infra-ingress\create-infra-ingress.ps1 -cluster my-production-cluster -profile admin
```

This phase is independent of the chart enablement flags. If Argo CD is disabled, remove or defer `infra-ingress/manifests/argocd.yaml` before applying this phase.

### 6. Apply Grafana dashboards

After `kube-prometheus-stack` and Grafana are installed, apply the dashboard ConfigMaps:

```powershell
.\dashboards\create-dashboards.ps1 -cluster my-production-cluster -profile admin
```

### Grafana Dashboard ConfigMaps

The `dashboards/manifests/` directory contains Kubernetes YAML ConfigMaps for Grafana dashboards. After the enabled `kube-prometheus-stack` add-on and Grafana finish rolling out, run `dashboards/create-dashboards.ps1` to apply them using an isolated cluster context.

Each manifest must use the following label and target the `monitoring` namespace so the Grafana dashboard sidecar discovers it:

```yaml
metadata:
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
```

The ConfigMap manifests are YAML. Grafana dashboard models are embedded as JSON strings in the ConfigMap `data` field because Grafana's dashboard provisioning format requires JSON. Add new dashboard ConfigMaps to `dashboards/manifests/`; they are included on the next dashboard script run.

### Infrastructure Ingress

`infra-ingress/manifests/grafana.yaml` and `infra-ingress/manifests/argocd.yaml` create the shared internal ALB routes for Grafana and Argo CD. Kubernetes Ingresses cannot reference Services in another namespace, so each application has a namespace-local Ingress; the shared `alb.ingress.kubernetes.io/group.name: infra` annotation makes AWS Load Balancer Controller serve both from one ALB.

Before running `infra-ingress/create-infra-ingress.ps1`, replace these placeholders:

* `REPLACE_WITH_INFRA_ACM_CERTIFICATE_ARN` with the ACM certificate ARN for the two hostnames.
* `REPLACE_WITH_ROUTE53_DOMAIN` with your internal Route 53 zone, for example `corp.example.com`.

The manifests create `grafana.<domain>` and `argocd.<domain>` records through ExternalDNS, use an internal ALB with HTTP on port 80 redirected to HTTPS on port 443, and preserve Argo CD HTTP/2 support for CLI and API traffic. Any unmatched hostname on the ALB falls back to Grafana after the explicit Grafana and Argo CD host rules.

---

## 🔒 Recommended Operational Safety Settings

To ensure your workspace layout does not leak temporary authorization data tokens into public repositories, add this entry to your global project **`.gitignore`** configuration:

```text
# Ignore temporary cluster login context files
kubeconfig-*.tmp
```

*(Note: Do not add the directory folder definitions to gitignore if you intend to version control and retain your local source Helm chart directories directly inside your Git repository context).*
