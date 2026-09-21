# EC2 deploy tunnel lifecycle repair

## Scope / preflight
- Branch fix-ec2-deploy-tunnel, worktree backend/.worktree/fix-ec2-deploy-tunnel, fetched origin/main b61bcabb (PR82).
- Read ec2-rollout.md and ec2-minimal-recovery.md from logging worktree. No infrastructure/secret/DNS changes; gh not used.
- Direct SSH preflight: Compose 2.29.7; existing connector aa60fd50b71100e9e919b8b83a787a60410086bd0cd28b2130344724e77dee2c running since 2026-09-21T17:09:48.911096489Z; current symlink b61bcabb. Key used in place, never read/output.

## Minimal fix
- Activation/rollback explicitly target api worker with --no-deps, without orphan removal.
- Rollback RELEASE_SHA set from previous release directory (otherwise Compose would reuse failed new image).
- cloudflared no longer depends on api. Running connector is never converged. Absent/stopped connector uses --no-deps --no-recreate bootstrap only.
- README documents separate approved direct SSH/SSM maintenance for connector image/env updates; normal deployments do not apply these implicitly.
- CI has no other project-wide up/rollback. Added deployment regression step.
- Existing symlink timing and external health validation remain unchanged; no transaction redesign or DB migration in scope.

## Local validation
- bash -n, git diff --check passed.
- Mock Docker regression tests: 4 passed (running tunnel untouched, absent/stopped bootstrap without recreation, scoped rollback with old image, initial failure).
- Compose config parsed; cloudflared has no depends_on, Que CLI debug asserted. Temporary empty env files removed.
- mise exec -- bundle exec rspec spec/config/production_logging_spec.rb: 6 examples, 0 failures.
- Rubocop: 161 files, no offenses. RAILS_ENV=test Zeitwerk passed.
- Plain system Ruby initially lacked locked Bundler; switched to existing mise environment, no installation/change required.

## Pending
PR/CI/merge and actual EC2 all-severity persistence confirmation.
