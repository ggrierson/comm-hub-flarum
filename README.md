# Flarum GCP Zero-Touch Deployment

This project automates the deployment of a self-hosted [Flarum](https://flarum.org/) forum using Docker on Google Cloud Platform (GCP). It emphasizes security, idempotency, and zero-touch provisioning.

## Overview

* **Tech Stack**: Flarum (via [mondediefr/docker-flarum](https://github.com/mondediefr/docker-flarum)), MariaDB, NGINX, Certbot, Docker Compose, Terraform.
* **Infrastructure**: GCP Compute Engine VM (Debian 12), persistent data disk, HTTPS via Let's Encrypt.
* **Automation**: Provisioning and postboot logic fully automated via metadata scripts and secret injection.
* **Security**: Passwords stored in Google Secret Manager, limited file permissions, hardened defaults.

## Key Features

* **Zero-Touch Provisioning**: Entire setup runs without manual intervention after `terraform apply`.
* **Idempotent Design**: Re-running provisioning scripts is safe and non-destructive.
* **Persistent Data Volume**: Forum data is stored separately on a persistent disk that survives reboots and VM rebuilds.
* **Secure Certificate Handling**:

  * Certbot uses the webroot method.
  * Automatic fallback to self-signed certificates for first boot.
  * Renewals handled by a dedicated Docker container that triggers NGINX reloads.
  * Certificate promotion logic switches to Let's Encrypt when available.
  * Symlinked `/etc/letsencrypt/current` directory ensures stable paths for NGINX.

## Project Structure and Boot Sequence

This repository includes multiple directories and files organized as follows:

```
.
├── .devcontainer/               # Devcontainer config (VSCode, Docker, Terraform preinstalled)
├── nginx/                       # Custom NGINX configs and Certbot webroot
├── scripts/                     # Startup and postboot automation scripts
│   ├── init-startup.sh          # Injected via GCP metadata as `startup-script` (runs on VM boot)
│   ├── postboot.sh              # Main provisioning logic: secrets, certs, Docker, services
│   ├── logging.sh               # Shared logging functions, used by postboot.sh
│   └── (bootstrap.sh)           # Created dynamically by `init-startup.sh` at runtime
├── terraform/                   # Terraform configs: VM, DNS, disks, metadata
│   ├── main.tf
│   ├── outputs.tf
│   ├── terraform.tfvars         # Per-deployment configuration (example below)
│   └── variables.tf
├── .flarum.env.template         # Template file used to generate .flarum.env
├── docker-compose.yml           # Flarum, NGINX, MariaDB, Certbot containers
├── README.md
└── ...
```

### Boot Sequence

1. **Terraform Apply**: GCP VM and persistent disk are provisioned, metadata attributes injected (including startup-script).
2. **`init-startup.sh` runs (via GCP metadata)**:

   * Minimal setup and logging.
   * Writes and executes a temporary `bootstrap.sh` script.
3. **`bootstrap.sh` (written to disk)**:

   * Fetches postboot logic (`postboot.sh`) and metadata-injected config vars.
4. **`postboot.sh`**:

   * Waits for apt locks and systemd readiness.
   * Installs dependencies and services.
   * Templating of `.flarum.env` using Google Secret Manager.
   * Sets permissions, configures TLS, and starts Docker Compose.

## Terraform Management

The infrastructure is managed using Terraform. On initial deployment, a boot disk and persistent data disk are created. The VM is rebuilt by tainting the compute instance (leaving the data disk untouched):

```bash
terraform taint google_compute_instance.flarum_vm
terraform apply -var-file=terraform.tfvars
```

DNS records are managed via Google Cloud DNS and are updated based on the `SUBDOMAIN` variable. VM metadata injection is used to supply configuration, scripts, and secrets.

## Example `terraform.tfvars`

```hcl
project_id              = "example-project-id"
region                  = "asia-southeast1"
zone                    = "asia-southeast1-b"
domain                  = "forum.example.com"
git_branch              = "main"
loglevel                = "info"
letsencrypt_env_staging = false
clean_unused_certs      = true
```

## Devcontainer Usage

This project is optimized for use with [Dev Containers](https://containers.dev/). The `.devcontainer` folder provides a reproducible environment for editing, testing, and deploying:

* Pre-configured with Docker, Terraform, and Google SDK tools.
* Enables GitHub Codespaces or local VS Code development.
* Mounts credentials and SSH keys via secrets for seamless deployment.

To use:

1. Open the project in VS Code.
2. Reopen in container when prompted.
3. Authenticate via `gcloud auth login`.
4. Use Terraform and Docker commands as needed.

## Deployment Variables

Injected as metadata attributes in Terraform:

```hcl
metadata = {
  startup-script          = file("../scripts/init-startup.sh")
  postboot-script         = file("../scripts/postboot.sh")
  logging-lib             = file("../scripts/logging.sh")
  enable-osconfig         = "TRUE"

  # Configuration flags
  GIT_BRANCH              = var.git_branch
  SUBDOMAIN               = var.domain
  LETSENCRYPT_ENV_STAGING = var.letsencrypt_env_staging
  CLEAN_UNUSED_CERTS      = var.clean_unused_certs
  LOGLEVEL                = var.loglevel
}
```

## Logging

All scripts support log-level-based output, controlled by the `LOGLEVEL` variable (`debug`, `info`, etc). The `logging.sh` script maps log level strings to severity and conditionally enables `set -x` for shell tracing in debug mode.

In `postboot.sh`, the log level is sourced and respected for all subsequent output:

```bash
# Example usage:
log_info "Starting deployment"
log_debug "Certificate symlink resolved"
```

## Environment Templating

`.flarum.env.template` is used to generate `.flarum.env` dynamically using secrets from Google Secret Manager. Secrets are fetched securely and inserted using `sed` after proper escaping.

All secrets such as database passwords, admin credentials, and Certbot email are handled this way. The resulting `.flarum.env` is never committed to git.

## File Permissions and Security

* `.flarum.env` is locked down post-templating:

  ```bash
  chmod 640 .flarum.env
  chown root:$(logname) .flarum.env
  ```

  This allows `docker-compose` to function without exposing secrets to other users.

* `/opt/flarum-data` (mounted persistent disk) is tightened:

  ```bash
  chmod 700 /opt/flarum-data
  chown root:root /opt/flarum-data
  ```

## Password Rotation

Passwords are injected from Google Secret Manager and used during provisioning:

* `flarum-db-password`: for Flarum's DB user.
* `flarum-maria-root-password`: for MariaDB `root@localhost`.

**To rotate passwords:**

1. Update the secrets in Google Secret Manager.
2. SSH into the VM and run:

   ```bash
   docker exec -it flarum_db mysql -uroot -p
   ```

   Then in the MariaDB shell:

   ```sql
   ALTER USER 'flarum'@'%' IDENTIFIED BY 'new_password';
   ALTER USER 'root'@'localhost' IDENTIFIED BY 'new_password';
   FLUSH PRIVILEGES;
   DROP USER 'root'@'%';
   ```
3. Update the secrets in Secret Manager and re-run `postboot.sh` (or rebuild the VM).

## Multi-Module Architecture

This deployment isolates Flarum as a module and can be extended into a broader application ecosystem. Separation is achieved via subdomain routing, container separation, and isolated config files. Each module can be independently developed and versioned.

## Troubleshooting

* **Login issues with MySQL**:

  * Use `MYSQL_PWD='...' mysql -uroot` or pass the password inline (no space):

    ```bash
    mysql -uroot -pYourPasswordHere
    ```
  * Interactive prompt paste may silently fail depending on terminal.

* **Access denied (password issue)**:

  * Check `.flarum.env` for pollution. Ensure values do not include `[INFO]` prefixes (from logging).

* **Resetting the VM**:

  * Use `terraform taint google_compute_instance.flarum_vm && terraform apply -var-file=terraform.tfvars` to recreate the boot disk without affecting the data volume.

## .gitignore

Sensitive files are excluded:

```gitignore
.terraform/
*.tfstate*
terraform.tfvars
certs/
.env
*.log
.flarum.env
```

## Security Considerations

* **Never store secrets in source control** — all secrets must be handled via Google Secret Manager.
* **Avoid logging secrets** — log only minimal info during `init-startup.sh` and `bootstrap.sh`.
* **Lock down files** — `.flarum.env` and mounted volumes are permission-restricted.
* **Drop remote root user** — `DROP USER 'root'@'%'` is strongly recommended.

---

For more information, see the original Docker image [here](https://github.com/mondediefr/docker-flarum) or [Flarum Docs](https://docs.flarum.org/).
