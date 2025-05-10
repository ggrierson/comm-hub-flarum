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

* Forum is hosted at `forum-hub.team-apps.net`
* DNS is already configured and points to the correct GCP external IP
* `flarum-oss-forum` project has GCP Secrets Manager entries populated
* You have a snapshot of the working data disk or a backup tarball
* `postboot.sh`, `.flarum.env.template`, `.postboot.env.template`, and `docker-compose.yml` are up-to-date

---

## ✅ Phase 1: Fresh Boot / First-Time Deploy

| Objective                                       | Test                                                                              | Expected Result                                                                                 |
| ----------------------------------------------- | --------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Certificate issuance (staging then manual prod) | Deploy with `LETSENCRYPT_ENV_STAGING=true`, then manually install production cert | Staging cert is installed and site is reachable; red triangle disappears after prod cert reload |
| Git + secret-based env creation                 | Confirm repo is cloned, secrets retrieved, `.flarum.env` populated                | Docker Compose runs with correct values                                                         |
| Container health                                | Access forum URL and login with admin                                             | UI renders, login succeeds                                                                      |
| Persistent disk reuse                           | Reboot VM, confirm users/posts remain                                             | Forum state is preserved                                                                        |
| Secret retrieval                                | Check logs for gcloud secret fetch                                                | All secrets are pulled without errors                                                           |

---

## ✅ Phase 2: Critical Recovery Tests

| Scenario                  | Simulation                                        | Validate                                               |
| ------------------------- | ------------------------------------------------- | ------------------------------------------------------ |
| Boot disk replacement     | Delete boot disk, re-deploy from Terraform        | Forum is restored automatically from postboot pipeline |
| Production cert retention | Install prod cert, then reboot                    | Real cert is preserved and served                      |
| Service crash             | `docker kill flarum`, then `docker-compose up -d` | Service recovers without data loss                     |
| DNS reassignment          | Temporarily change IP mapping in DNS              | Forum becomes reachable again post-update              |

---

## ✅ Phase 3: Idempotency / Re-runs

| Check                          | Observation                                                    |
| ------------------------------ | -------------------------------------------------------------- |
| `postboot.sh` re-run avoidance | Marker prevents re-execution (`.postboot-done`)                |
| `.flarum.env` generation       | Templated identically on each boot (hash-matching)             |
| Cert protection                | Self-signed or staging certs are replaced, real certs retained |
| Git repo clone skip            | Repo is not recloned if `.git/` exists                         |

---

## ✅ Bonus: Observability Checks

| Diagnostic            | How                                                                         |
| --------------------- | --------------------------------------------------------------------------- |
| NGINX cert visibility | `docker exec flarum_nginx ls /etc/letsencrypt/live/forum-hub.team-apps.net` |
| Cert issuer           | `openssl x509 -in fullchain.pem -noout -issuer -dates`                      |
| ACME webroot          | Write to `.well-known/acme-challenge/` and curl it externally               |
| View startup logs     | `journalctl -u google-startup-scripts.service` or serial console logs       |

---

## 🧪 Execution Tips

* Prioritize Phase 2 failures after validating Phase 1
* Run multiple tests before rebooting to maximize coverage
* Use `DEBUG=true` temporarily if you need verbose logging

---

## 📝 Future Enhancements

* Automate snapshotting of data disk post-successful deploy
* Add test script for full ACME challenge roundtrip
* Integrate `test-plan.md` checks into CI or a pre-deploy checklist
