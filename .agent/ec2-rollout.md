# Authorized persistent Rails logging rollout

## Preflight
- Fetched origin/main d33370eb5bccbbdd9cadd199014227b7429d8740; feature fast-forwarded from 3993dea using temporary stash, then restored all implementation/untracked notes without conflict.
- Direct SSH using supplied key in place (never read/copied), BatchMode, ConnectTimeout=15, StrictHostKeyChecking=accept-new.
- Supplied new instance: Amazon Linux 2023, x86_64, Docker 25.0.14, Compose 2.29.7, Docker active, root filesystem 30G / 27G free.
- ec2-user requires sudo for Docker. /opt/anabuki-event/shared owned anabuki-deploy mode 0750; log directory not yet present.
- current release and both api/worker images are d33370eb5bccbbdd9cadd199014227b7429d8740; API healthy, worker/cloudflared running. Compose labels point to that release.
- GitHub main CI 35628222892 completed success; deployment through ssh.anabuki-event.com completed 2026-09-21T16:55:45Z, matching this instance's current release and recent container uptime. Prior runs failed before this successful deployment. Existing deploy targets therefore match supplied instance by release and time evidence; no infrastructure/secret/DNS configuration changed by agent.
- Removed cloudflared logging-driver change to preserve SSH tunnel container configuration. API/worker bounded Docker logging retained; README corrected.
- Existing automatic workflow reasserts Cloudflare ingress/API DNS as part of normal deploy; no workflow changes in this PR.

## Local verification after main update
- Focused spec: 6 examples, 0 failures.
- Rubocop: 161 files, no offenses.
- Rails test Zeitwerk: passed.
- bash -n deploy/ec2/deploy.sh; git diff --check: passed.
- Compose parsed with temporary empty env files (removed afterward), asserts debug, independent custom absolute log mounts, bounded api/worker driver, Que --log-level debug, and no cloudflared logging override.
- Full DB-dependent suite left to CI (local PostgreSQL unavailable in previous investigation).

Previous investigation notes describe their earlier point-in-time state. This document supersedes those statuses and the earlier all-three-services logging statement.
