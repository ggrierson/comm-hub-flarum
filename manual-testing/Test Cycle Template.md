# Flarum Deployment Test Plan

## ✅ Objectives

This test plan validates the following core tenets of your deployment:

1. **Zero-touch** provisioning
2. **Idempotent** boot scripts
3. **Resilient** infrastructure (survives VM restarts and boot disk replacement)
4. **Automated and trusted SSL** provisioning and renewal
5. **Separation of concerns** (ephemeral boot disk vs persistent data disk)

---

## 🔰 Preconditions

* [ ] Forum DNS (`forum-hub.team-apps.net`) points to correct IP
* [ ] GCP Secrets Manager contains all required secrets
* [ ] Data disk snapshot or tarball is available
* [ ] Latest deployment scripts/configs pushed to repo

---

## ✅ Phase 1: Fresh Boot / First-Time Deploy

* [ ] Deploy with `LETSENCRYPT_ENV_STAGING=true`
* [ ] Manually install production cert
* [ ] Confirm staging cert is used initially and replaced cleanly
* [ ] Git repo clones and `.flarum.env` is templated with secrets
* [ ] `docker-compose up -d` runs without error
* [ ] Forum UI loads at `forum-hub.team-apps.net`
* [ ] Admin login works
* [ ] Reboot VM and validate forum state is retained (users/posts)
* [ ] Confirm secret-dependent env values are still valid (e.g., login works, SMTP config is correct)

---

## ✅ Phase 2: Critical Recovery Tests

* [ ] Delete and re-create boot disk, reuse data disk
* [ ] Validate automated recovery of forum
* [ ] Manually install prod cert and reboot
* [ ] Cert is preserved post-reboot
* [ ] Run `docker kill flarum`, recover with `docker-compose up -d`
* [ ] DNS update propagates correctly if temporarily changed

---

## ✅ Phase 3: Idempotency / Re-runs

* [ ] `postboot.sh` exits early on reboot (marker file present)
* [ ] `.flarum.env` is consistently templated on repeat boots
* [ ] Real certs are retained, staging/bootstrap certs replaced
* [ ] Repo is not re-cloned if `.git` exists

---

## ✅ Bonus: Observability Checks

* [ ] Cert is present in NGINX container (`docker exec flarum_nginx ls ...`)
* [ ] Verify cert issuer via `openssl x509` output
* [ ] `curl` a healthcheck file from ACME challenge dir externally
* [ ] Check logs with `journalctl` or serial console viewer

---

## 🧪 Execution Tips

* Prioritize Phase 2 failures after validating Phase 1
* Run multiple tests before rebooting to maximize coverage
* Use `DEBUG=true` temporarily for deeper inspection

---

## 📝 Future Enhancements

* [ ] Automate post-deploy data disk snapshot
* [ ] Script full ACME HTTP-01 validation check
* [ ] Integrate this checklist into CI/pre-deploy workflow
