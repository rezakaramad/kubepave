# ArgoCD

ArgoCD is installed as a single multi tenantcy instance in the Management Cluster and serves the purpose of deploying all application
in the Platform, both tenant and platform resources to support the GitOps strategy.

The official ArgoCD Helm chart is included as a dependency in this custom Helm chart and configured via the `values.yaml` file.
Additional Kubernetes resources required by ArgoCD are provided in the `templates` folder of this chart.

The resources include:

- **AppProject: GitOps System**
    - Contains the "App of Apps" ArgoCD Application, `platform-application-folder`, which is responsible for deploying all other ArgoCD Applications used to manage the platform.
- **AppProject: Platform System**
    - Contains all ArgoCD Applications deployed by the `platform-application-folder` ArgoCD Application.
- **Cluster Credentials for Tenant Clusters**
    - A Kubernetes Secret is created for each tenant cluster with the label `argocd.argoproj.io/secret-type: cluster`. This label informs ArgoCD that the Secret represents cluster credentials.
    - ArgoCD uses Workload Identity Federation to authenticate to the clusters, so although these credentials are stored as Secrets, no static authentication keys are used.

## Single Sign-on

ArgoCD is configured to use Single Sign-On with Microsoft Entra ID.
To access the ArgoCD Web UI, you must be a member of at least one group assigned to the `app-argocd` Azure App Registration.

### Role Assignment

Your ArgoCD permissions are determined by your Entra ID group membership:

- **`ACL.PLT.ArgoCD.Administrator`**
  - Role: `admin`
  - Description: Full administrative access for Platform Engineers

Membership of the access groups is automatically managed by Omada IGA.

### Authentication Flow

ArgoCD uses Workload Identity Federation to authenticate with Azure and complete user login flows.
This allows ArgoCD to securely validate identities without storing long-lived secrets.

## Links

- [ArgoCD WebUI](https://argocd.jysk.tech)
- [ArgoCD Helm Chart](https://github.com/jysk-dev/platform-hub/tree/main/kubernetes/charts/argocd)
- [Azure App Registration](https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Overview/appId/ae9f42fc-9e1f-434e-86d3-a78acd6d8805/isMSAApp~/false)
- [Azure Enterprise Application](https://portal.azure.com/#view/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/Overview/objectId/c6a04ee4-3d72-48a6-a091-216613c6e15f/appId/ae9f42fc-9e1f-434e-86d3-a78acd6d8805/preferredSingleSignOnMode~/null/servicePrincipalType/Application/fromNav/)
- [ArgoCD Docs](https://argo-cd.readthedocs.io/en/stable/)
