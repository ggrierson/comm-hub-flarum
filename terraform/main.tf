# Terraform config to deploy a GCE VM with a separate data disk for Flarum

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

module "ops_agent_policy" {
  source        = "github.com/terraform-google-modules/terraform-google-cloud-operations/modules/ops-agent-policy"
  count         = var.enable_ops_agent ? 1 : 0
  project       = var.project_id
  zone          = var.zone
  assignment_id = "goog-ops-agent-v2-x86-template-1-4-0-${var.zone}"

  agents_rule = {
    package_state = "installed"
    version       = "latest"
  }

  instance_filter = {
    all = false
    inclusion_labels = [{
      labels = {
        goog-ops-agent-policy = "v2-x86-template-1-4-0"
      }
    }]
  }
}

resource "google_compute_instance" "flarum-vm" {
  name                = "flarum-vm"
  machine_type        = var.machine_type
  zone                = var.zone
  can_ip_forward      = false
  deletion_protection = false
  enable_display      = false

  tags                = ["http-server", "https-server"]

  labels = {
    goog-ec-src           = "vm_add-tf"
    goog-ops-agent-policy = "v2-x86-template-1-4-0"
  }

  metadata = {
    startup-script   = file("../scripts/init-startup.sh")
    enable-osconfig  = "TRUE"
    postboot-script  = file("../scripts/postboot.sh")
    logging-lib      = file("../scripts/logging.sh")


    # Injected environment variables
    GIT_BRANCH               = var.git_branch
    SUBDOMAIN                = var.domain
    LETSENCRYPT_ENV_STAGING  = var.letsencrypt_env_staging
    CLEAN_UNUSED_CERTS       = var.clean_unused_certs
    LOGLEVEL                 = var.loglevel
  }

  boot_disk {
    device_name = "flarum-vm"
    auto_delete = true
    mode = "READ_WRITE"
    initialize_params {
      image = var.boot_image
      size  = 10
      type  = "pd-standard"
    }
  }

  attached_disk {
    source      = google_compute_disk.flarum-data-disk.id
    device_name = "flarum-data-disk"
    mode        = "READ_WRITE"
  }

  network_interface {
    network       = "default"
    access_config {
      nat_ip       = "34.124.188.219"
      network_tier = "PREMIUM"
    }
    queue_count = 0
    stack_type  = "IPV4_ONLY"
    subnetwork  = "projects/flarum-oss-forum/regions/asia-southeast1/subnetworks/default"
  }

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    preemptible         = false
    provisioning_model  = "STANDARD"
  }

  service_account {
    email  = var.service_account_email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  shielded_instance_config {
    enable_integrity_monitoring = true
    enable_secure_boot          = false
    enable_vtpm                 = true
  }
}

resource "google_compute_disk" "flarum-data-disk" {
  name  = "flarum-data-disk"
  type  = "pd-standard"
  zone  = var.zone
  size  = var.data_disk_size
}

resource "google_dns_record_set" "flarum_dns" {
  project      = var.dns_project
  name         = "${var.domain}."
  type         = "A"
  ttl          = 3600
  managed_zone = var.dns_zone_name

  # Replace the IP below with your reserved static IP
  rrdatas = ["34.124.188.219"]
}

variable "project_id" {}
variable "region" {}
variable "zone" {}
variable "machine_type" { default = "e2-micro" }
variable "boot_image" { default = "debian-cloud/debian-12" }
variable "data_disk_size" { default = 30 }
variable "service_account_email" {}

variable "domain" {
  description = "The forum's DNS name"
  type        = string
}

variable "dns_zone_name" {
  description = "The name of the Cloud DNS managed zone for the domain"
  type        = string
}

variable "dns_project" {
  description = "The GCP project ID that owns the DNS zone"
  type        = string
}

variable "enable_ops_agent" {
  type    = bool
  default = false
}

variable "git_branch" {
  description = "Branch to check out in the VM"
  type        = string
  default     = "master"
}

variable "letsencrypt_env_staging" {
  description = "Use Let's Encrypt staging environment"
  type    = bool
  default = false
}

variable "clean_unused_certs" {
  description = "Clean up unused numbered cert directories"
  type    = bool
  default = false
}

variable "loglevel" {
  description = "Standard log levels (debug, info, warn, error)"
  type        = string
  default     = "info"
}

