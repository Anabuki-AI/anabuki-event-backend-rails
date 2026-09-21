# Read-only merge / EC2 readiness investigation

- Fetched backend origin; origin/main and GitHub API main both d33370eb5bccbbdd9cadd199014227b7429d8740 (#81 Docker Compose install).
- Logging worktree HEAD 3993dea7759319df119fe9f5b91a974d84d4ce46; uncommitted logging implementation preserved. Backend root main remains unchanged. Upstream changes since HEAD touch only .github/workflows/ci.yml and app/services/reaction_event_store.rb; logging edits do not overlap. No actual merge/rebase performed, so conflict assessment is based on disjoint paths.
- Read logging implementation/spec, production config diff, deploy script, Compose diff, Dockerfile, README, CI and latest CI diff. Existing .agent/ec2-persistent-logging.md contains earlier wider checks and limitations.
- Re-ran focused RSpec: 6 examples, 0 failures. bash -n deploy/ec2/deploy.sh and git diff --check passed. No full DB suite, container startup or EC2 connection in this investigation.

## EC2 compatibility / outstanding risks

- No EC2 public IP in deploy flow; ssh.anabuki-event.com Cloudflare tunnel -> 172.17.0.1:22 is used. Same instance reboot/IP change should not require log config changes if disk, SSH keys and tunnel survive.
- A replacement instance needs bootstrap: SSH tunnel must already function before CI can provision Docker/deploy user. CI only ensures API DNS, not SSH DNS. Verify correct tunnel ingress/token, ssh hostname route, connector running on new instance and old connector retired as appropriate.
- New host keys require production EC2_KNOWN_HOSTS update (CI connects to [127.0.0.1]:2222 with strict checking); EC2_SSH_PRIVATE_KEY must match ec2-user authorized_keys. Do not disable host verification.
- Latest #81 downloads docker-compose-linux-x86_64; provisioning uses dnf and ec2-user. New instance must fit those OS/architecture assumptions (ARM/Ubuntu not supported by this provision command as written).
- Existing provisioning shell uses an overly broad `... && useradd ... || true && ...`: failures earlier than useradd can be swallowed. This predates logging and needs separate hardening.
- /opt/anabuki-event/shared/log is release-persistent, not instance-persistent. Preserve/transfer old EBS/log data explicitly on replacement; old Docker stdout logs are not imported. Verify free disk (~400 MiB Rails retention plus Docker logs/images/releases), ownership, deploy-user access, root container file modes, actual rotation and redeploy persistence.
- Runtime secrets (DB/encryption/OAuth/R2/Cloudflare) are GitHub production environment inputs; confirm same resources and network egress/DB allowlists on replacement. Never regenerate encryption keys merely because EC2 changed.
- Default debug may expose SQL/free-form exceptions; structured parameter/Que argument filters do not sanitize all text. Rotation settings manually added to shared/.env.production are overwritten by next CI generation (no corresponding CI input today). RAILS_LOG_LEVEL in that file does not override Compose interpolation; CI defaults to debug.
- Compose logging driver changes recreate services including cloudflared, which also transports deployment SSH: possible channel interruption needs rollout review (existing deploy flow shares this dependency).

## GitHub PR route (no gh)

Origin: https://github.com/Anabuki-AI/anabuki-event-backend-rails
Existing osxkeychain credential resolved in process memory only; no credential values printed or written. Read-only authenticated GitHub REST returned repository admin/push permissions, main protected=false, protection endpoint 404, effective branch rules empty. Merge/squash/rebase enabled. GET success does not prove fine-grained token write scope.
After explicit authorization: update/retest branch against latest main, commit logging, push feature branch, POST /repos/Anabuki-AI/anabuki-event-backend-rails/pulls (base main), review CI, PUT /pulls/{number}/merge with expected head SHA. Use credential-helper-backed in-memory authorization, not gh or direct main push. PR creation/merge write authorization not exercised. Main merge triggers production deployment, so merging itself needs production rollout readiness.

No merge, rebase, commit, push, GitHub mutation, SSH, cloud changes or production operations performed. Only fetch, local focused tests, read-only GitHub API and this note.
