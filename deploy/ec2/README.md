# EC2 Rails deployment

The production compose file runs Rails (`api`), Que (`worker`), and the official
Cloudflare Tunnel connector (`cloudflared`) on one private Docker network.
Neither Rails nor PostgreSQL is published on an EC2 host port. The tunnel's
remotely managed ingress points at `http://api:3000`.

`shared/.env.production` and `shared/.cloudflared.env` are created by the
production GitHub Actions job with mode `0600`; they are never committed. The
release script does not run migrations. A migration, if ever required, is a
separate reviewed operation against the managed production database.

The deployment user only needs Docker access and write access under
`/opt/anabuki-event`. The initial CI connection uses the existing `ec2-user`
account with sudo to install Docker and provision `anabuki-deploy`; subsequent
release operations use the least-privileged deploy user.
