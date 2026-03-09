terraform {
  required_version = "~> 1.5"

  backend "gcs" {
    bucket = "rajamohan-tf-state-myproject"
    prefix = "project-5/state"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }
}

provider "google" {
  project = "my-ever-first-project-488313"
  region  = "us-central1"
}

locals {
  zones = ["us-central1-a", "us-central1-b"]
}

# --- Networking ---
resource "google_compute_network" "main_vpc" {
  name                    = "main-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "main_subnet" {
  name          = "main-subnet"
  ip_cidr_range = "10.0.0.0/16"
  region        = "us-central1"
  network       = google_compute_network.main_vpc.self_link
}


# -------------------------
# GKE Cluster
# -------------------------
resource "google_container_cluster" "primary" {
  name                = "gke-cluster"
  location            = "us-central1"
  deletion_protection = false
  network             = google_compute_network.main_vpc.id
  subnetwork          = google_compute_subnetwork.main_subnet.id
  #remove_default_node_pool = true
  initial_node_count = 1

  # ✅ Override default node pool config before it's removed
  node_config {
    machine_type = "e2-small"
    disk_type    = "pd-standard" # Prevents SSD quota hit
    disk_size_gb = 20
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}

# --- Service Networking for Cloud SQL ---
resource "google_project_service" "service_networking" {
  project = "my-ever-first-project-488313"
  service = "servicenetworking.googleapis.com"
}

resource "google_compute_global_address" "private_ip_range" {
  name          = "google-managed-services-main-vpc"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.main_vpc.self_link
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.main_vpc.self_link
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_range.name]

  depends_on = [google_project_service.service_networking]

  lifecycle {
    create_before_destroy = true
  }
}

# --- Cloud SQL Instance (HA / DR) ---
resource "google_sql_database_instance" "postgres_instance" {
  name                = "postgres-ha"
  region              = "us-central1"
  database_version    = "POSTGRES_14"
  deletion_protection = false

  settings {
    tier              = "db-f1-micro" # smallest tier (not free in HA mode)
    availability_type = "REGIONAL"    # HA across zones

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.main_vpc.self_link
    }
  }

  depends_on = [google_service_networking_connection.private_vpc_connection]

}

resource "google_sql_database" "default_db" {
  name     = "appdb"
  instance = google_sql_database_instance.postgres_instance.name
}

resource "google_sql_user" "db_user" {
  name     = "appuser"
  instance = google_sql_database_instance.postgres_instance.name
  password = "StrongPassword123!" # replace with secret manager
}
