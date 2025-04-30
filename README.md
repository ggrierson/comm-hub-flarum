

# Flarum GCP Deployment (Automated)

This project automates the deployment of a self-hosted [Flarum](https://flarum.org) forum using Google Cloud Platform with Docker Compose, Terraform, and Let's Encrypt TLS.

---

## 🔧 What’s Included

- Google Compute Engine VM
- Separate persistent data disk (for safe redeploys)
- Docker Compose setup with:
  - Flarum
  - MariaDB
  - NGINX reverse proxy
  - Certbot (auto-renew TLS)
- DNS A record via Google Cloud DNS
- Automated provisioning via startup script

---

## ⚠️ Security Notice

**Warning:** This Dev Container binds your local `~/.config/gcloud`, `~/.docker`, `~/.gitconfig`, and `~/.ssh` directories. These mounts expose sensitive host credentials inside the container. Only use this setup on trusted, personal machines.

---

## 🚀 Getting Started

### 🔁 Option 1: Use Terraform Locally or via Cloud Shell

We recommend using the Terraform CLI from your local machine **or** [Google Cloud Shell](https://cloud.google.com/shell). Cloud Shell provides a pre-authenticated environment with Terraform and gcloud pre-installed.

You can also launch Cloud Shell directly with the project preloaded:

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.png)](https://ssh.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https://github.com/ggrierson/comm-hub-flarum&cloudshell_working_dir=terraform)

To deploy using the CLI:

1. **Configure your domain** in Google Cloud DNS.
2. **Create `terraform.tfvars`** with your values.
3. **Provision infrastructure**:
   ```bash
   terraform init
   terraform apply -var-file=terraform.tfvars
   ```

4. Visit your forum: `https://yourdomain.com`

### 🧱 Option 2: Use Google Infrastructure Manager (GIM)

GIM is a fully managed service that can apply and manage Terraform configs from the GCP Console. Ideal for production workflows, team collaboration, or auditability.

Read more: [Infrastructure Manager](https://cloud.google.com/infrastructure-manager/docs/overview)

### 🐳 Option 3: Use a Dev Container (VS Code Remote)

This repo includes a `.devcontainer.json` configuration to launch a dedicated VS Code Dev Container with:

- Docker-in-Docker
- Terraform
- Google Cloud CLI
- VS Code extensions for Terraform, Docker, and Cloud Code

Inside the Dev Container, you can run:
```bash
gcloud auth login
terraform plan
terraform apply -var-file=terraform.tfvars
```

---

## ⚠️ Terraform Management Tips

### ❌ To Safely Reset the VM Without Destroying Data or DNS
```bash
terraform destroy \
  -target=google_compute_instance.flarum_vm \
  -auto-approve && \
terraform apply -auto-approve
```
- Keeps your **data disk** and **static IP/DNS record** intact
- Good for iterative testing of provisioning scripts or instance config

### ⚠️ To Wipe Everything (Use With Caution)
```bash
terraform destroy -auto-approve
```
- Destroys all resources, including data disk and static IP
- Only use if you're starting completely fresh

### ✅ Safety Features Enabled
- `prevent_destroy = true` on your data disk to avoid accidental loss
- Static IP is defined and optionally preserved across redeployments

### 🔍 Tip
Use `terraform plan` before `apply` to preview changes, especially when dealing with IPs and disks

---

## 🛡️ Security

Secrets are pulled via Google Secret Manager during startup and never stored in source control.

---

## 📦 Notes

- All persistent data is stored on a non-boot disk.
- Redeploying the VM does **not** destroy your forum data.
- TLS renews automatically every 12h via cron loop in the `certbot` container.
