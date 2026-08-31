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
└── 📁 overrides/         # Subdirectory target folder where value configuration manifests live
    ├── 📄 pod-identity-agent.yaml
    ├── 📄 lb-controller.yaml
    └── ...
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

---

## 🔒 Recommended Operational Safety Settings

To ensure your workspace layout does not leak temporary authorization data tokens into public repositories, add this entry to your global project **`.gitignore`** configuration:

```text
# Ignore temporary cluster login context files
kubeconfig-*.tmp
```

*(Note: Do not add the directory folder definitions to gitignore if you intend to version control and retain your local source Helm chart directories directly inside your Git repository context).*
