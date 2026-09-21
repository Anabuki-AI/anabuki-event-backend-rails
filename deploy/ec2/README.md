# EC2 Rails deployment

The production compose file runs Rails (`api`), Que (`worker`), and the official
Cloudflare Tunnel connector (`cloudflared`) on one private Docker network.
Neither Rails nor PostgreSQL is published on an EC2 host port. The tunnel's
remotely managed ingress points at `http://api:3000`.

## Reboot and IP-change resilience

All deploy SSH traffic goes through the Cloudflare Tunnel hostname
`ssh.anabuki-event.com` (`ssh://172.17.0.1:22` ingress, the host-side docker0
gateway). GitHub Actions opens the channel with `cloudflared access tcp` and
connects to `127.0.0.1:2222`, so deploys keep working when the instance
reboots or its public IP changes. The EC2 public IP is never referenced.

After a reboot the stack recovers automatically: Docker is enabled at boot and
every compose service uses `restart: unless-stopped`; `cloudflared` reconnects
its outbound tunnel without any configuration change.

`shared/.env.production` and `shared/.cloudflared.env` are created by the
production GitHub Actions job with mode `0600`; they are never committed. The
release script does not run migrations. A migration, if ever required, is a
separate reviewed operation against the managed production database.

The deployment user only needs Docker access and write access under
`/opt/anabuki-event`. The initial CI connection uses the existing `ec2-user`
account with sudo to install Docker and provision `anabuki-deploy`; subsequent
release operations use the least-privileged deploy user.

## Tunnel lifecycle is separate from application releases

Activation and rollback run `up -d --no-deps api worker`, never a project-wide
`up`, `down`, or `--remove-orphans`. cloudflared deliberately has no API
`depends_on`: Compose can stop dependents before recreating API, disconnecting
its own deploy SSH session. A running connector is left untouched even if the
release changes its image or env file. If none is running, deployment uses
`up -d --no-deps --no-recreate cloudflared` to create an absent connector or
start an existing stopped one without replacing its configuration. Initial
bootstrap still needs direct SSH/SSM because tunnel SSH cannot open beforehand.

Connector image/token/config updates are **explicit maintenance**, not applied
by app releases. Arrange direct EC2 SSH or SSM first; never run this over the
connector being replaced. In an approved maintenance window, after reviewing
the current Compose definition and private env file, run as the deploy user:

```sh
export RELEASE_SHA="$(basename "$(readlink -f /opt/anabuki-event/current)")"
docker compose --project-name anabuki-event --file /opt/anabuki-event/current/deploy/ec2/docker-compose.production.yml pull cloudflared
docker compose --project-name anabuki-event --file /opt/anabuki-event/current/deploy/ec2/docker-compose.production.yml up -d --no-deps --force-recreate cloudflared
```

Then verify connector registration, public `/health`, and a new tunnel SSH
connection before closing the independent access session. Expect a brief tunnel
interruption. This operation is not part of normal deploy/rollback automation.

## EC2-local production logs

Compose enables `RAILS_LOG_LEVEL=debug` and `RAILS_LOG_PATH=/app/log/production.log`
for both Rails and Que. All emitted Rails severities (debug/info/warn/error/fatal/
unknown) go to tagged stdout **and** a rotating file; no CloudWatch logging driver
is used. Que's CLI receives the same level explicitly because its default `info`
would otherwise overwrite the Rails logger level. Without `RAILS_LOG_PATH` (or
with a blank path), production remains stdout-only.

Persistent host files, outside disposable releases:

- `/opt/anabuki-event/shared/log/api/production.log`
- `/opt/anabuki-event/shared/log/worker/production.log`

`deploy.sh` creates log directories with mode `0750` and exports the absolute
`SHARED_LOG_ROOT` derived from `APP_ROOT`. An alternate `APP_ROOT` therefore also
moves the logs. For manual Compose commands, export `SHARED_LOG_ROOT` when using
an alternate root. Compose `${...}` interpolation reads the invoking shell / its
Compose env configuration, **not** service `env_file`; changing `RAILS_LOG_LEVEL`
in `shared/.env.production` alone does not override the explicit Compose level.
To override it, export `RAILS_LOG_LEVEL` when deploying/running Compose (this also
sets Que's CLI level). No CI runtime-file generation change is needed.

The current containers run as root: log files are root-owned, mode `0640` or
stricter. File-enabled processes retain a restrictive umask (`existing | 0027`)
so newly rotated files are never world-readable; this also restricts other files
created by that process. Existing active log permissions are tightened at boot.
Use sudo rather than broadening log permissions:

```sh
sudo tail -F /opt/anabuki-event/shared/log/api/production.log
sudo tail -F /opt/anabuki-event/shared/log/worker/production.log
sudo grep -F 'REQUEST-ID' /opt/anabuki-event/shared/log/api/production.log
sudo sh -c 'grep -F "job_errored" /opt/anabuki-event/shared/log/worker/production.log*'
docker compose --project-name anabuki-event --file /opt/anabuki-event/current/deploy/ec2/docker-compose.production.yml logs --tail 100 api worker
```

Rotation defaults: `RAILS_LOG_ROTATION_COUNT=10` and
`RAILS_LOG_ROTATION_SIZE=20971520` (20 MiB), each validated as a positive integer.
These optional container settings can be placed in `shared/.env.production`.
With the defaults, each service retains the active file plus nine backups
(`production.log.0` through `.8`), approximately **400 MiB total** for API and
worker. This is not a strict size ceiling: rotation checks occur before writes
and a single large message can exceed the threshold. Ruby Logger retains at
least one backup even when count is 1. Old files are automatically discarded:
this is **not permanent retention of every log**. Monitor disk space and log
volume; EC2 disk loss is not covered by this local-only storage.

API and worker use Docker's `local` stdout/stderr driver with `max-size=10m`
and `max-file=3` (additional space beyond Rails files). The cloudflared logging
configuration is unchanged to avoid recreating the deployment SSH tunnel.
Direct stdout/stderr writes
and Puma startup output exist only in those bounded Docker logs, not the Rails
persistent file. No request/response body capture or Que `--log-internals` is
added. Existing `/up` healthcheck and deprecation suppression remain unchanged;
“all” refers to severity, not to enabling previously suppressed events.

Existing Rails parameter filters are preserved. Production disables Active Job
argument logging, and Que's JSON formatter applies Rails parameter filtering and
replaces each args/kwargs value with `[FILTERED]` without mutating the job. Event,
job ID/class and timing metadata remain available. **Arbitrary SQL, exception
messages/backtraces and other free-form strings are not guaranteed anonymized**;
restrict access, avoid logging secrets, and assess debug-level exposure before
using these files for sharing or long-term archiving.
