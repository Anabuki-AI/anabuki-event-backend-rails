# EC2 persistent logging implementation

## Scope / workspace

- Base: origin/main 3993dea (fetched at task start).
- Branch: feat/ec2-persistent-logging.
- Worktree: /Users/yuyu/Desktop/anabuki-event/backend/.worktree/feat-ec2-persistent-logging
- No main edits, production operations, pushes, PRs or commits performed.

## Changes

- production.rb uses lib/production_logging.rb: stdout retained, optional RAILS_LOG_PATH broadcast sink, explicit broadcast level, tagged broadcaster (tagged blocks run once, not once per sink).
- Defaults: 10 files including active, 20 MiB threshold; RAILS_LOG_ROTATION_COUNT/SIZE validate positive integers. Existing active file permissions tightened; process umask OR 0027 protects rotation creation before Logger reapplies permissions. Process-wide restrictive umask is intentional and documented.
- ActiveJob log_arguments=false; Que formatter copies args/kwargs into per-value FILTERED placeholders then uses Rails ParameterFilter and JSON.dump. Existing parameter filters unchanged.
- Que 2.4.1 inspected: utils/logging.rb default JSON.dump; worker.rb job_worked/job_errored include job hash; command_line_interface.rb sets Que.get_logger.level after Rails load. Compose therefore sets --log-level to same interpolated level as Rails.
- Compose: debug default, /app/log/production.log, separate api/worker shared bind mounts; all services local Docker log driver 10m x3.
- deploy.sh canonicalizes APP_ROOT, exports absolute SHARED_LOG_ROOT, creates/chmods shared/log and service directories 0750 before startup.
- README covers sudo viewing, root ownership, retention/size limits, non-guaranteed string anonymization, stdout/stderr-only output, env_file interpolation caveat. CI workflow unchanged because Compose explicitly supplies runtime log settings.

## Verification

All Ruby commands used `mise exec -- bundle exec` (Ruby 3.4.7, Rails 8.1.3.1, Que 2.4.1, logger 1.7.0).

Passed:
- rspec spec/config/production_logging_spec.rb: 6 examples, 0 failures. All six severities exactly once per sink + request tags, threshold, stdout-only fallback, rotation/retention/modes, invalid numeric settings, real Que.log formatter filtering/nonmutation/error and success events.
- rubocop: 161 files, no offenses.
- RAILS_ENV=test rails zeitwerk:check: all good.
- bash -n deploy/ec2/deploy.sh.
- git diff --check.
- Docker Compose v5.1.2 config --format json with temporary empty env files: asserted custom /custom/app/shared/log api/worker sources, debug level, Que --log-level debug, all three local driver/max-size/max-file settings. No containers or production resources started.
- Local production Rails initialization with dummy encryption/secret values and local Active Storage: asserted DEBUG broadcast/all sink levels, ActiveJob.log_arguments false, tagged six severities each exactly once in file, and Que argument filtering. No DB operations. Existing optional image_processing warning observed.

Blocked/unverified:
- Full `bundle exec rspec` attempted: 0 examples, 40 loading errors because local PostgreSQL localhost:5432 refuses connections. No database changes made.
- Real EC2 deployment, Linux ownership on bind mount, running Que worker against DB, actual Docker service recreation/rotation, concurrent multi-process stress, rollback/release-cleanup integration not exercised.
- Rails boot smoke files contain synthetic messages only at /tmp/anabuki-production-logging-smoke.log and /tmp/anabuki-production-logging-smoke-fixed.log; not committed.

## Operational caveats

- Approx. 400 MiB for default API+worker Rails files, not a hard bound; old logs discarded. Additional bounded Docker logs exist separately.
- Scope is emitted severities, not previously suppressed health/deprecation events. No body capture/internal Que logs added.
- SQL/exception/free-form strings can contain secrets. Existing Sentry configuration unchanged; no CloudWatch provisioning/removal attempted.
- If externally provisioned CloudWatch agents collect these host paths, their configuration is outside this repository/change.
