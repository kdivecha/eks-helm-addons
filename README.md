# EKS Local Helm Add-on Staging & Deployment

This repository provides an automated, modular, data-driven workflow engine using **PowerShell Core (`pwsh`)** to cache, stage, sync, and deploy a comprehensive suite of cloud infrastructure add-ons sequentially onto Amazon EKS clusters.

---

## 🛠️  Architecture & Key Features

*   **Decoupled & Isolated Staging:** The staging layer relies exclusively on an internet connection and the `helm` and `git` command binaries. It operates independently of an active AWS session context footprint.
*   **Structured Project Tree Workspace:** Extracted upstream raw charts are cleanly managed under an isolated `charts/` root folder. Custom configuration manifests are stored inside a dedicated `overrides/` folder.
*   **Completely Data-Driven Property Templates:** Avoids messy embedded script configuration logic. The staging script parses data properties mapped natively under the `DefaultValues` configuration block inside `inventory.yaml` and handles parsing tasks automatically.
*   **Secure Environment Isolation Guard:** Protects live systems by binding credentials strictly to a temporary process session profile (`$env:KUBECONFIG`). Accidental production data leaks or cross-contamination is functionally impossible.
*   **Idempotency & Version Shifting Cache:** Reads your local configuration definitions dynamically. If versions match, downloading is safely bypassed. If version data changes, older directory trees are cleanly archived to `<chart-name>-<old-version>` to protect adjustments.
*   **Dynamic Component Execution Toggles:** Features a built-in `Enabled: true/false` block. The script evaluates this flag smoothly to allow toggling entire sub-workloads on or off instantly without purging inventory entries.
*   **Automated Cross-Cluster Multi-Targeting:** Orchestrates backend calls dynamically. The deployment runner uses a unified positional input variable to dynamically inject active parameters like `clusterName` or `settings.clusterName` on the fly via the Helm installation engine.

---

## 📁 Workspace Structural Footprints

```text
📁 eks-helm-addons/
├── 📄 inventory.yaml     # Core data-driven configuration inventory index ledger
├── 📄 vendor.ps1         # Phase 1: Local chart asset staging and cache runner
├── 📄 install.ps1        # Phase 2: Secure sequential sandboxed installer driver
├── 📁 charts/            # Subdirectory target folder where extracted Helm charts live
│   ├── 📁 eks-pod-identity-agent/
│   ├── 📁 aws-load-balancer-controller/
│   └── ...
├── 📁 overrides/         # Subdirectory target folder where value configuration manifests live
│   ├── 📄 pod-identity-agent.yaml
│   ├── 📄 lb-controller.yaml
│   └── ...
├── 📁 dashboards/        # Grafana dashboard ConfigMap manifests
│   ├── 📄 cluster-overview.yaml
│   ├── 📄 loki-logs-overview.yaml
│   ├── 📄 nats-overview.yaml
│   └── 📄 namespace-overview.yaml
└── 📁 infra-ingress/     # Shared internal ALB Ingress manifests
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
    RoleArn: arn:REPLACE_WITH_AWS_PARTITION:iam::123456789012:role/AWSLoadBalancerControllerPodIdentityRole
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

## 🚀 Running The Workflow Steps

### Phase 1: Staging Local Workspace Assets
Run this execution layer to reconcile version data and sync remote configuration charts straight into your working flat layout folder. 

```powershell
.\vendor.ps1
```

### Phase 2: Installing to Target EKS Cluster
Run the driver file by passing the name of your target cluster as a positional argument. The tool isolates credentials automatically and updates configurations sequentially. Any component marked `Enabled: false` inside the inventory index will be skipped automatically.

```powershell
.\install.ps1 my-production-cluster -Profile admin
```

`Profile` defaults to `admin`; the script exports it as `AWS_PROFILE` and uses the AWS Region configured in that CLI profile.

### Grafana Dashboard ConfigMaps

The `dashboards/` directory contains Kubernetes YAML ConfigMaps for Grafana dashboards. After the enabled `kube-prometheus-stack` add-on and Grafana finish rolling out, `install.ps1` automatically runs `kubectl apply --filename dashboards/` using its isolated cluster context.

Each manifest must use the following label and target the `monitoring` namespace so the Grafana dashboard sidecar discovers it:

```yaml
metadata:
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
```

The ConfigMap manifests are YAML. Grafana dashboard models are embedded as JSON strings in the ConfigMap `data` field because Grafana's dashboard provisioning format requires JSON. Add new dashboard ConfigMaps to `dashboards/`; they are included on the next installer run.

### Infrastructure Ingress

`infra-ingress/grafana.yaml` and `infra-ingress/argocd.yaml` create the shared internal ALB routes for Grafana and Argo CD. Kubernetes Ingresses cannot reference Services in another namespace, so each application has a namespace-local Ingress; the shared `alb.ingress.kubernetes.io/group.name: infra` annotation makes AWS Load Balancer Controller serve both from one ALB.

`install.ps1` applies Grafana's Ingress after kube-prometheus-stack rolls out. It applies Argo CD's Ingress only after Argo CD rolls out, so Grafana remains available when Argo CD is disabled. Before running it, replace these placeholders:

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
