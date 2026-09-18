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
