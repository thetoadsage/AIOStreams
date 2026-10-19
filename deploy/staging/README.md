# Isolated metadata-reliability staging

This fork publishes **linux/amd64**, matching toadstool. Production's upstream image, Compose project, `/opt/docker/data/aiostreams`, networks, Traefik and Authelia configuration are not part of this deployment.

The staging service has its own project (`aiostreams-staging`), bridge network, SQLite database, encryption key, operator login and `data/` directory. Only `127.0.0.1:3001` is published. Traefik discovery and Watchtower updates are explicitly disabled by container labels. The service is limited to two CPUs and 2 GiB RAM. No production configuration, database, Redis or provider credentials should be copied into it.

## Image publication

Pushing `metadata-reliability` runs `.github/workflows/deploy-docker.yml`. Its validation job runs the full core tests, frontend tests and full container-package build on Node 24. Only after validation passes does the publishing job build the Docker image, boot it with disposable SQLite storage, check its HTTP health, and push that tested image using the repository's temporary `GITHUB_TOKEN`.

Images use `ghcr.io/thetoadsage/aiostreams:sha-<full 40-character commit>`. Existing commit tags are preserved on reruns; registry errors fail closed. There are no `latest`, nightly, Docker Hub or upstream publication tags. The Actions summary and `image-reference-<commit>` artifact record the registry digest. Deploy with that digest for an immutable reference; base images and network-fetched build inputs are not a guarantee of bit-for-bit rebuilds.

Upstream release, dev-image, docs, scheduled updates and native-app publishing jobs remain in the tree with an upstream-repository guard, so they cannot publish from this fork. Their repository-level Actions switches are also disabled where present. The adapted validation and publishing workflows remain enabled. No Docker Hub token, long-lived publishing token, Discord webhook or production secret is required.

GHCR packages initially default to private. If this package is private, either make it public in its GitHub package settings or authenticate **on toadstool** using a dedicated token with `read:packages` before pulling. Enter it with `docker login ghcr.io -u thetoadsage --password-stdin`; do not place it in Compose, the repository or shell command arguments. Publication itself does not change package visibility.

## First staging deployment (manual)

Select a successful run and copy its exact commit and image digest from the Actions summary. The commands below create only staging files and containers. Do not substitute production's directory or Compose project.

```bash
ssh toadstool
umask 077
mkdir -p /opt/docker/apps/aiostreams-staging
cd /opt/docker/apps/aiostreams-staging

BUILD_COMMIT=<successful-full-commit>
IMAGE=ghcr.io/thetoadsage/aiostreams@sha256:<published-digest>
SOURCE=https://raw.githubusercontent.com/thetoadsage/AIOStreams/$BUILD_COMMIT/deploy/staging
curl -fsSL "$SOURCE/compose.yaml" -o compose.yaml
curl -fsSL "$SOURCE/init.sh" -o init.sh
bash init.sh "$IMAGE"
docker compose -p aiostreams-staging config --quiet
docker compose -p aiostreams-staging pull aiostreams
docker compose -p aiostreams-staging up -d --no-deps aiostreams
docker compose -p aiostreams-staging ps
docker compose -p aiostreams-staging exec -T aiostreams /nodejs/bin/node /app/scripts/healthcheck.js
```

`init.sh` creates `.env` with mode 0600, a new 64-hex encryption key and a new `staging` password. It refuses to overwrite `.env` or reuse nonempty data. Read the `AIOSTREAMS_AUTH` entry privately on the host when logging in. Keep that encryption key for the lifetime of the staging database. Runtime settings and user configurations stay in staging's own SQLite database.

From the Mac, keep an SSH tunnel open:

```bash
ssh -N -L 3001:127.0.0.1:3001 toadstool
```

Open <http://localhost:3001> and authenticate with the staging login. The generated URLs use this local endpoint; external Stremio clients need their own tunnel or a separately approved HTTPS route. No proxy route or Authelia changes are needed for this setup. Production remains running independently.

## Update with a recoverable checkpoint

Run inside `/opt/docker/apps/aiostreams-staging`. Stop only staging while copying the complete SQLite directory, including any WAL/SHM files. The matching `.env` backup is sensitive because it includes the database's encryption key.

```bash
cd /opt/docker/apps/aiostreams-staging
umask 077
checkpoint="backups/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$checkpoint"
docker compose -p aiostreams-staging stop aiostreams
cp -p .env "$checkpoint/env"
tar -czf "$checkpoint/data.tar.gz" data
```

Edit **only** `AIOSTREAMS_IMAGE` in `.env` to the next verified digest, retaining the existing staging secret and login. Do not run `init.sh` again. Then:

```bash
docker compose -p aiostreams-staging config --quiet
docker compose -p aiostreams-staging pull aiostreams
docker compose -p aiostreams-staging up -d --no-deps aiostreams
docker compose -p aiostreams-staging exec -T aiostreams /nodejs/bin/node /app/scripts/healthcheck.js
```

## Rollback

Restore the old image **and its matching database and encryption key**, since a newer image may have migrated staging's schema. Retain failed data for inspection rather than deleting it:

```bash
cd /opt/docker/apps/aiostreams-staging
checkpoint=backups/<checkpoint-created-above>
docker compose -p aiostreams-staging stop aiostreams
mv data "backups/failed-data-$(date -u +%Y%m%dT%H%M%SZ)"
cp -p "$checkpoint/env" .env
chmod 600 .env
tar -xzf "$checkpoint/data.tar.gz"
docker compose -p aiostreams-staging config --quiet
docker compose -p aiostreams-staging pull aiostreams
docker compose -p aiostreams-staging up -d --no-deps aiostreams
docker compose -p aiostreams-staging exec -T aiostreams /nodejs/bin/node /app/scripts/healthcheck.js
```

For the first deployment, before any prior checkpoint exists, rollback means `docker compose -p aiostreams-staging down`. Bind-mounted staging data is retained. Never run these commands in production's Compose directory or use production's project name.

## Future upstream updates

Keep `origin` pointing at this fork and `upstream` pointing at `Viren070/AIOStreams`. On a clean local `metadata-reliability` branch:

```bash
git fetch upstream
git merge upstream/main
# Resolve conflicts while retaining the fork's GHCR workflow and upstream guards.
pnpm install --frozen-lockfile
pnpm -F @aiostreams/core test
pnpm -F @aiostreams/frontend test
pnpm build
git push origin metadata-reliability
```

Inspect newly added upstream workflows before pushing. A successful CI run publishes a new commit tag/digest; changing staging is a separate manual step. Production never follows this branch or an automatically moving image tag.
