"""Deployment command regression tests; no Docker daemon or credentials required."""
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest


DEPLOY = Path(__file__).with_name("deploy.sh")
MOCK_DOCKER = '''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ['COMMAND_LOG'], 'a') as log:
    log.write(json.dumps([os.environ['RELEASE_SHA'], args]) + '\\n')
command = args[5:]
if command == ['ps', '--status', 'running', '--quiet', 'cloudflared']:
    if os.environ['TUNNEL_RUNNING'] == '1':
        print('existing-tunnel-id')
if command == ['up', '-d', '--no-deps', 'api', 'worker']:
    if os.environ['FAIL_ACTIVATION'] == '1' and os.environ['RELEASE_SHA'] == 'new':
        sys.exit(42)
'''


class DeployTest(unittest.TestCase):
    def run_deploy(self, running=True, fail=False, previous=True):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "app"
            shared = app / "shared"
            shared.mkdir(parents=True)
            for name in (".env.production", ".cloudflared.env"):
                (shared / name).touch()
            if previous:
                old = app / "releases/old/deploy/ec2"
                old.mkdir(parents=True)
                (old / "docker-compose.production.yml").touch()
                (app / "current").symlink_to(app / "releases/old")
            source = root / "source/deploy/ec2"
            source.mkdir(parents=True)
            (source / "docker-compose.production.yml").touch()
            archive = root / "release.tar.gz"
            with tarfile.open(archive, "w:gz") as tar:
                tar.add(root / "source/deploy", arcname="deploy")
            binaries = root / "bin"
            binaries.mkdir()
            for name, content in (("docker", MOCK_DOCKER), ("find", "#!/bin/sh\nexit 0\n")):
                binary = binaries / name
                binary.write_text(content)
                binary.chmod(0o755)
            log = root / "commands.jsonl"
            env = dict(os.environ, PATH=f"{binaries}:{os.environ['PATH']}",
                       APP_ROOT=str(app), RELEASE_SHA="new", ARCHIVE_PATH=str(archive),
                       COMMAND_LOG=str(log), TUNNEL_RUNNING=str(int(running)),
                       FAIL_ACTIVATION=str(int(fail)))
            result = subprocess.run(["bash", str(DEPLOY)], env=env, capture_output=True, text=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            up = [(sha, args[5:]) for sha, args in calls if args[5] == "up"]
            self.assertEqual(result.returncode, 42 if fail else 0, result.stderr)
            self.assertEqual((app / "current").resolve().name, "old" if fail and previous else "new")
            return up

    def test_running_tunnel_not_converged(self):
        self.assertEqual(self.run_deploy(), [("new", ["up", "-d", "--no-deps", "api", "worker"])])

    def test_absent_or_stopped_tunnel_bootstrapped_without_recreation(self):
        self.assertEqual(self.run_deploy(running=False, previous=False), [
            ("new", ["up", "-d", "--no-deps", "api", "worker"]),
            ("new", ["up", "-d", "--no-deps", "--no-recreate", "cloudflared"])])

    def test_rollback_scoped_and_uses_previous_image(self):
        self.assertEqual(self.run_deploy(fail=True), [
            ("new", ["up", "-d", "--no-deps", "api", "worker"]),
            ("old", ["up", "-d", "--no-deps", "api", "worker"])])

    def test_initial_failure_does_not_start_tunnel_or_rollback(self):
        self.assertEqual(self.run_deploy(running=False, fail=True, previous=False), [
            ("new", ["up", "-d", "--no-deps", "api", "worker"])])


if __name__ == "__main__":
    unittest.main()
