#---------------------------------------------------------------
# Node pool service account + policy bindings
#---------------------------------------------------------------

# Why not use the default Compute service account?
# The default <project-number>-compute@developer.gserviceaccount.com has Editor on the project which is way too broad.
# A custom service account with specific roles follows least-privilege.
# List of permissions granted:
# roles/container.defaultNodeServiceAccount (includes logging, monitoring, metadata writer)
# roles/artifactregistry.reader

# Creates a dedicated GCP service account for the GKE node pool,
# grants it the necessary permissions it needs to run nodes.
resource "google_service_account" "compute" {
  account_id   = local.cluster_name
  display_name = "Compute Engine Service Account for ${local.cluster_name}"
}

# Grants the GKE node pool service account the permission to read container images in Artifact Registry.
resource "google_project_iam_member" "artifact_registry_reader" {
  project = local.project_ids.platform_management
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.compute.email}"
}

# Required by GKE for logging, monitoring, and HPA to function properly on custom node SAs.
resource "google_project_iam_member" "default_node_service_account" {
  project = local.project_ids.platform_management
  role    = "roles/container.defaultNodeServiceAccount"
  member  = "serviceAccount:${google_service_account.compute.email}"
}

#---------------------------------------------------------------
# tenant-provisioner GCP service account + policy bindings
#---------------------------------------------------------------

# This service account is used in 'tenant-gcp-resources' namespace
# to create all the Google Cloud resources necessary for our tenants. 
# This includes resources such as Projects, Service Accounts, etc.
resource "google_service_account" "tenant_provisioner" {
  account_id   = "tenant-provisioner"
  display_name = "Tenant Provisioner"
  description  = "This service account is used for provisioning cloud resources for all platform tenants."
}

# Lets the Kubernetes service account 'cnrm-controller-manager-tenant-gcp-resources'
# (used by Config Connector in the 'cnrm-system' namespace) act as the GCP 'tenant-provisioner' service account.
resource "google_service_account_iam_member" "tenant_provisioner_gcp_resources" {
  service_account_id = google_service_account.tenant_provisioner.id
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.project_ids.platform_management}.svc.id.goog[cnrm-system/cnrm-controller-manager-tenant-gcp-resources]"
}

# Lets the Kubernetes service account 'cnrm-controller-manager-tenant-platform-resouces'
# act as the GCP 'tenant-provisioner' service account.
resource "google_service_account_iam_member" "tenant_provisioner_platform_resources" {
  service_account_id = google_service_account.tenant_provisioner.id
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.project_ids.platform_management}.svc.id.goog[cnrm-system/cnrm-controller-manager-tenant-platform-resources]"
}

# 'tenant-provisioner' service account needs to be able to create service accounts in tenant projects.
resource "google_project_iam_member" "tenant_provisioner_sa_admin" {
  project = local.project_ids.platform_management
  role    = "roles/iam.serviceAccountAdmin"
  member  = "serviceAccount:${google_service_account.tenant_provisioner.email}"
}

# 'tenant-provisioner' service account needs to be able to create IAM role bindings in tenant projects.
resource "google_project_iam_member" "tenant_provisioner_iam_admin" {
  project = local.project_ids.platform_management
  role    = "roles/resourcemanager.projectIamAdmin"
  member  = "serviceAccount:${google_service_account.tenant_provisioner.email}"
}

# 'tenant-provisioner' service account permissions on 'Tenant Environments' folder

# This allows tenant-provisioner service account to create tenant projects in the 'Tenant Environments' folder.
resource "google_folder_iam_member" "project_creator" {
  folder = "folders/${local.folder_ids.tenant_environments}"
  role   = "roles/resourcemanager.projectCreator"
  member = "serviceAccount:${google_service_account.tenant_provisioner.email}"
}

# Grants the 'tenant-provisioner' service account full owner access on the 'Tenant Environments' folder,
# which inherits down to every tenant project created inside it.
resource "google_folder_iam_member" "tenant_folder_owner" {
  folder = "folders/${local.folder_ids.tenant_environments}"
  role   = "roles/owner"
  member = "serviceAccount:${google_service_account.tenant_provisioner.email}"
}

# Grants the 'tenant-provisioner' service account the ability to manage IAM policies on the 'Tenant Environments' folder.
resource "google_folder_iam_member" "tenant_folder_iam_admin" {
  folder = "folders/${local.folder_ids.tenant_environments}"
  role   = "roles/resourcemanager.folderIamAdmin"
  member = "serviceAccount:${google_service_account.tenant_provisioner.email}"
}

#---------------------------------------------------------------
# platform-provisioner GCP service account + policy bindings
#---------------------------------------------------------------

# This service account is used in 'platform-system' namespace.
resource "google_service_account" "platform_provisioner" {
  account_id   = "platform-provisioner"
  display_name = "Platform Provisioner"
  description  = "This service account is used by Config Connector to provision GCP resources in the platform-system namespace in all clusters"
}

# This lets the Kubernetes service account 'cnrm-controller-manager-platform-system'
# (used by Config Connector in the 'cnrm-system' namespace) act as the GCP 'platform-provisioner' service account.
resource "google_service_account_iam_member" "platform_provisioner" {
  service_account_id = google_service_account.platform_provisioner.id
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.project_ids.platform_management}.svc.id.goog[cnrm-system/cnrm-controller-manager-platform-system]"
}

# Gives the permission to the 'platform-provisioner' service account to provision
# resources in the crossplane-system namespace.
resource "google_service_account_iam_member" "platform_provisioner_crossplane" {
  service_account_id = google_service_account.platform_provisioner.id
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.project_ids.platform_management}.svc.id.goog[cnrm-system/cnrm-controller-manager-crossplane-system]"
}

# Grants the 'platform-provisioner' service account full owner access in the 'kara-mgmt' project.
resource "google_project_iam_member" "platform_mgmt_owner_platform_resources" {
  project = local.project_ids.platform_management
  role    = "roles/owner"
  member  = "serviceAccount:${google_service_account.platform_provisioner.email}"
}

# Allows the 'platform-provisioner' service account to set IAM permissions on the 'Tenant Environments' folder.
resource "google_folder_iam_member" "folder_iam_admin_tenant_envs" {
  folder = "folders/${local.folder_ids.tenant_environments}"
  role   = "roles/resourcemanager.folderIamAdmin"
  member = "serviceAccount:${google_service_account.platform_provisioner.email}"
}

#---------------------------------------------------------------
# Argo CD GCP service account + policy bindings
#---------------------------------------------------------------

# Create a GCP service account for Argo CD to use in the 'argocd' namespace in the management cluster.
resource "google_service_account" "argocd" {
  account_id   = "argocd"
  display_name = "Argo CD"
  description  = "Used by Argo CD server to connect and manage other clusters"
}

# Grant the Argo CD GCP service account the permission to impersonate the GKE node pool service account.
resource "google_service_account_iam_binding" "argocd_workload_identity" {
  service_account_id = google_service_account.argocd.name
  role               = "roles/iam.workloadIdentityUser"

  members = [
    "serviceAccount:${local.project_ids.platform_management}.svc.id.goog[argocd/argocd-application-controller]",
    "serviceAccount:${local.project_ids.platform_management}.svc.id.goog[argocd/argocd-server]",
  ]
}

# Grant the Argo CD GCP service account the permissions to manage GKE clusters in the 'kara-mgmt' project.
resource "google_project_iam_member" "argocd_container_admin" {
  project = local.project_ids.platform_management
  role    = "roles/container.admin"
  member  = "serviceAccount:${google_service_account.argocd.email}"
}
