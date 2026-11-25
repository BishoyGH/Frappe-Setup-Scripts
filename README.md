# Frappe Setup Scripts

Interactive shell scripts that take a **fresh** Linux machine to a working
[Frappe](https://frappe.io/framework) bench with the official Frappe apps, and then help you keep it
updated and manage its sites.

| Script | What it does |
| --- | --- |
| `frappe-setup.sh` | Main menu that launches the three scripts below |
| `install.sh` | Installs every prerequisite, creates a bench, fetches the apps you pick and (optionally) creates a site, for **development** or **production** |
| `update-bench.sh` | Updates an existing bench and **all** of its sites, or upgrades it to a new Frappe major version |
| `manage-sites.sh` | Create, migrate, back up, restore and remove sites; install or uninstall apps; get new apps; set the default site; HTTPS / developer mode |

## Supported systems

| OS | Notes |
| --- | --- |
| Ubuntu 22.04, 24.04, 26.04 | tested in CI |
| Debian 12, 13 (11 untested) | tested in CI |
| Arch Linux (and derivatives such as Manjaro, EndeavourOS) | tested in CI; Redis is provided by Valkey when available; wkhtmltopdf is unpacked from the official Debian build |
| Any of the above under **WSL 2** | works with or without systemd; the installer offers to enable systemd in `/etc/wsl.conf` |

x86_64 and arm64 are supported.

## Quick start

```bash
# On a brand-new machine you may need git first:
#   Ubuntu/Debian: sudo apt update && sudo apt install -y git
#   Arch:          sudo pacman -Sy --needed git
git clone https://github.com/BishoyGH/Frappe-Setup-Scripts.git
cd Frappe-Setup-Scripts
./frappe-setup.sh            # or ./install.sh, ./update-bench.sh, ./manage-sites.sh
```

Run the scripts as a normal user with `sudo` rights. If you start `install.sh` as **root** (common on a
fresh VPS or WSL), it installs `sudo`, creates a user (default `frappe`), copies the scripts into that
user's home and continues as that user, because benches must not be owned by root.

## What `install.sh` asks

1. **Setup type**: development (`bench start`, developer mode) or production (nginx + supervisor).
2. **Frappe version**: the newest release branches are read live from GitHub (e.g. `version-16`,
   `version-15`, `version-14`), plus `develop` or any custom branch/tag such as `v15.50.0`.
   The matching Python and Node versions are chosen for you (you can override them):

   | Frappe | Python | Node |
   | --- | --- | --- |
   | v14 | 3.10 | 16 |
   | v15 | 3.11 | 18 |
   | v16 / develop | 3.14 | 24 |

3. **Apps**: pick any of the official apps: ERPNext, HRMS, CRM, Helpdesk, LMS, Insights, Builder,
   Print Designer, Payments, Wiki, Drive, Gameplan, Lending, Healthcare, Education, Webshop,
   Ecommerce Integrations, Telephony, plus any custom app by git URL. Dependencies are added
   automatically (e.g. HRMS → ERPNext, Helpdesk → Telephony, LMS → Payments).
   Each app's branch is matched to the Frappe version (`version-15` with `version-15`, and so on). When an
   app has no such branch (e.g. Builder, Insights), the script falls back to `main`/`master`/`develop` and
   marks it so you can see. You can pick any branch for any app.
4. **Bench** directory name (default `~/frappe-bench`).
5. **Site**: name, Administrator password, which apps to install on it; in production also DNS
   multitenancy and an optional Let's Encrypt certificate.

It then shows a summary and, once you confirm, installs:

- build tools, git, curl, cron, fonts and libraries (`build-essential`/`base-devel`, `libmariadb-dev`, ...)
- **MariaDB** with the utf8mb4 settings Frappe needs, and a root password (socket login for `sudo mysql` is kept)
- **Redis** (or Valkey on Arch)
- **wkhtmltopdf 0.12.6.1 with patched Qt** (needed for PDFs)
- **Python** through [uv](https://github.com/astral-sh/uv) (so even Python 3.14 works on older distros)
- **Node.js** through [nvm](https://github.com/nvm-sh/nvm), and **yarn**
- the **bench** CLI (`uv tool install frappe-bench`)
- **nginx + supervisor** for production

The bench gets a `.nvmrc` with its Node version, so different benches can use different Node versions.
A full log of each run is written to `~/frappe-setup-logs/` (see [Logs](#logs)).

After a development install:

```bash
source ~/.bashrc
cd ~/frappe-bench && nvm use && bench start
# open http://site1.localhost:8000
```

## Updating a bench (`update-bench.sh`)

- **update**: pull the latest commits on the current branches, install requirements, migrate
  **every site**, rebuild assets and restart. This is `bench update`, with a backup step first.
- **upgrade**: move to another major version (e.g. v15 → v16). The script shows the new branch for
  every app, switches them, rebuilds the Python env with the right Python version (`bench migrate-env`),
  switches Node, then migrates all sites.
- **apps**: update only the apps you choose.
- **migrate** / **build**: run only that step.

Before changing anything it offers to back up all sites, and it checks the app repositories for
uncommitted changes (stash, discard or abort).

## Managing sites (`manage-sites.sh`)

A menu that loops until you quit:

- list sites with their installed apps
- create a site (apps, admin password, default site, `/etc/hosts` entry in development)
- install apps on a site / uninstall an app from a site
- get a new official or custom app into the bench (branch matched to Frappe)
- migrate one site or all sites
- back up one or all sites (with files, compressed)
- restore a site from a backup (database plus public and private files)
- remove (drop) a site, with a final backup and a typed confirmation
- set the default site
- production: set up HTTPS with Let's Encrypt; development: toggle developer mode

In production, nginx and supervisor are reloaded automatically after a site is added or removed.

## Unattended installs

Every question can be answered in advance, with flags or with an answers file
([`examples/install.conf`](examples/install.conf)); `--yes` takes the default for anything not
answered. Secrets come from the environment (or the answers file), never from flags, and are masked
in the output and the log.

```bash
# Development bench with ERPNext + HR, site dev.localhost, no questions asked
DB_ROOT_PASSWORD='…' ADMIN_PASSWORD='…' ./install.sh --yes --apps erpnext,hrms --site dev.localhost

# Production server from an answers file (works when started as root on a fresh VPS, too)
DB_ROOT_PASSWORD='…' ADMIN_PASSWORD='…' ./install.sh --yes --config my-server.conf
```

`./install.sh --help` lists every flag. Flags win over the answers file. When started as root with
`--yes`, the bench user is created without a password if `FRAPPE_USER_PASSWORD` is not set, and is
given passwordless sudo only while the installer runs.

`update-bench.sh` takes `--yes --action update|upgrade|apps|migrate|build [bench-path]`, e.g. for cron:
`./update-bench.sh --yes --action update ~/frappe-bench`. Other variables: `BENCH_PATH` (bench used by
the update/site scripts), `FSS_LOG_DIR`, `NO_COLOR=1`.

## Re-running and resuming

The installer records each finished step in `~/.local/state/frappe-setup-scripts/`. If a run stops
(network failure, a full disk, Ctrl+C), fix the cause and run the same command again: it offers to
resume with the saved answers (automatically with `--yes`) and skips the steps that already finished.
`--resume` forces resuming, `--fresh` starts over. Re-running a finished unattended install does nothing
and exits successfully, so the command is safe to repeat from provisioning tools.

## Logs

Every run of `install.sh`, `update-bench.sh` and `manage-sites.sh` writes a log to
`~/frappe-setup-logs/` (or `$FSS_LOG_DIR`): the full output without colour codes, readable only by you,
with passwords replaced by `****`. The newest 20 logs per script are kept. When a command fails the
error message names the log file.

## Testing

[CI](.github/workflows/ci.yml) runs shellcheck and the offline unit tests (`tests/run-tests.sh`), then
a full unattended install in fresh Ubuntu 22.04/24.04/26.04, Debian 12/13 and Arch Linux containers, in
development and production mode. Each install is stopped half-way on purpose, resumed, re-run, and then
checked by pinging the site. The install tests also run weekly to catch upstream changes.

## Layout

```
frappe-setup.sh     main menu
install.sh          new bench
update-bench.sh     update / upgrade a bench
manage-sites.sh     site management
lib/common.sh       prompts, OS detection, services, bench helpers
lib/prereqs.sh      packages, MariaDB, wkhtmltopdf, uv/Python, nvm/Node, bench, nginx/supervisor
lib/apps.sh         official app catalog, dependencies, branch matching
lib/unattended.sh   preset answers (flags / answers file) and resumable steps
examples/           sample answers file for unattended installs
tests/              unit tests and the container install test used by CI
```

## Notes

- Production on WSL works, but WSL is not meant to host a public server.
- Let's Encrypt needs a public domain whose DNS already points to the machine, and ports 80/443 open.
- Frappe supports upgrading one major version at a time (v14 → v15 → v16).
