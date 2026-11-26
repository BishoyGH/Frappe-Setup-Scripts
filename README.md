# Frappe Setup Scripts

Interactive shell scripts that take a **fresh** Linux machine to a working
[Frappe](https://frappe.io/framework) bench with the official Frappe apps, and then help you keep it
updated and manage its sites.

```bash
curl -fsSL https://raw.githubusercontent.com/BishoyGH/Frappe-Setup-Scripts/main/get.sh | bash
```

That one line installs `git` if needed, puts the scripts in `~/Frappe-Setup-Scripts` and opens the
main menu. The questions appear as dialog boxes (arrow keys, Space to tick, Enter to confirm) when
`whiptail` or `dialog` is available, and as plain numbered prompts otherwise.

| Script | What it does |
| --- | --- |
| `frappe-setup.sh` | Main menu: shows the benches already on the machine and launches the scripts below |
| `install.sh` | Checks the machine, installs every prerequisite, creates a bench, fetches the apps you pick and (optionally) creates a site, for **development** or **production** |
| `update-bench.sh` | Updates an existing bench and **all** of its sites, or upgrades it to a new Frappe major version |
| `manage-sites.sh` | Create, migrate, back up, restore and remove sites; install or uninstall apps; get new apps; set the default site; HTTPS / developer mode |
| `ops.sh` | Production operations: scheduled backups with retention and encrypted offsite copies, restore (also from another server), rollback of a failed update, health checks with alerts, firewall/fail2ban/MariaDB tuning, custom domains and certificate renewal |
| `get.sh` | The one-line installer above |

## Supported systems

| OS | Notes |
| --- | --- |
| Ubuntu 24.04, 26.04 (22.04 should work) | 24.04 and 26.04 tested in CI |
| Debian 13 (12 should work, 11 untested) | 13 tested in CI |
| Arch Linux (and derivatives such as Manjaro, EndeavourOS) | tested in CI; Redis is provided by Valkey when available; wkhtmltopdf is unpacked from the official Debian build. Install `libnewt` for dialog boxes |
| Any of the above under **WSL 2** | works with or without systemd; the installer offers to enable systemd in `/etc/wsl.conf` |

x86_64 and arm64 are supported. Recommended: 4 GB RAM (2 GB works with swap) and 15 GB free disk.

## Quick start

One line, as above, or with arguments for the menu:

```bash
# Go straight to the installer, with compact output
curl -fsSL https://raw.githubusercontent.com/BishoyGH/Frappe-Setup-Scripts/main/get.sh | bash -s -- install --quiet

# Only check whether this machine is ready (memory, disk, ports, network)
curl -fsSL https://raw.githubusercontent.com/BishoyGH/Frappe-Setup-Scripts/main/get.sh | bash -s -- check
```

`get.sh` accepts `FSS_DIR` (where to put the scripts) and `FSS_REF` (branch or tag). Running it again
updates the scripts.

Or clone the repository yourself:

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

## Options for every script

| Option | Environment | Effect |
| --- | --- | --- |
| `--plain` | `FSS_UI=plain` | numbered text prompts instead of dialog boxes (also used automatically without a terminal, or when the window is smaller than 60x15) |
| `--tui` | `FSS_UI=tui` (or `whiptail`, `dialog`) | dialog boxes; with a value, use that program |
| `--quiet` | `FSS_QUIET=1` | compact output: one line per command with a spinner, the elapsed time and the command's latest output line. Everything still goes to the log, and when a command fails its last 25 lines are printed |
| | `NO_COLOR=1` | no colors |

Every run writes a full log to `~/frappe-setup-logs/` (see [Logs](#logs)).

## What `install.sh` does

All questions come first, so once you confirm the summary the install runs without stopping
(except for a couple of production choices such as replacing nginx's default site).

1. **Setup type**: development (`bench start`, developer mode) or production (nginx + supervisor).
2. **System check**: memory and swap, CPU, free disk (home and `/var/lib` for MariaDB), whether the ports
   are free (8000, 9000, 11000, 13000 in development; 80 and 443 in production), whether GitHub, PyPI and
   npm can be reached, WSL 1 vs 2, and systemd. Failed checks ask whether to go on (unattended runs warn and continue; `FSS_STRICT_CHECKS=1` makes them stop, `FSS_SKIP_CHECKS=1` never stops). Resumed installs skip the check. On a small machine
   without swap it offers to create a 4 GB swap file so asset builds do not run out of memory.
3. **Frappe version**: the newest release branches are read live from GitHub (e.g. `version-16`,
   `version-15`, `version-14`), plus `develop` or any custom branch/tag such as `v15.50.0`.
   The matching Python and Node versions are chosen for you (you can override them):

   | Frappe | Python | Node |
   | --- | --- | --- |
   | v14 | 3.10 | 16 |
   | v15 | 3.11 | 18 |
   | v16 / develop | 3.14 | 24 |

4. **Apps**: tick any of the official apps: ERPNext, HRMS, CRM, Helpdesk, LMS, Insights, Builder,
   Print Designer, Payments, Wiki, Drive, Gameplan, Lending, Healthcare, Education, Webshop,
   Ecommerce Integrations, Telephony, plus any custom app by git URL (checked before it is accepted).
   Dependencies are added automatically (e.g. HRMS → ERPNext, Helpdesk → Telephony, LMS → Payments).
   Each app's branch is matched to the Frappe version (`version-15` with `version-15`, and so on). When an
   app has no such branch (e.g. Builder, Insights), the script falls back to `main`/`master`/`develop` and
   marks it so you can see. You can pick any branch for any app.
5. **Bench** directory name (default `~/frappe-bench`, or the next free name), and the MariaDB root
   password when MariaDB is not installed yet.
6. **Site**: name, Administrator password, which apps to install on it; in production also DNS
   multitenancy and an optional Let's Encrypt certificate (the script checks that the domain resolves to
   this machine).

**Passwords**: press Enter at a password prompt to generate a strong one. Generated passwords are shown
once at the end (they are never written to the log) and saved in `~/.frappe-credentials/<bench>.txt`,
readable only by you. Move them to a password manager and delete the file.

Answers are checked as you type them: site and bench names, email addresses, Python/Node versions, git
URLs and branches. A bad answer explains what is wrong and asks again.

Then it installs, showing numbered steps with a progress bar and the elapsed time:

```
▶ Step 4/11  Python 3.14  ███████░░░░░░░░░░░░░  27%  3m12s elapsed
  ⠼ uv python install 3.14  41s  Downloading cpython-3.14.0-linux-x86_64-gnu
```

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

It ends with a summary of where everything is and how to open it, for example:

```
╭─ Frappe is ready  ·  14m52s ──────────────────────────────────╮
│  Bench       /home/frappe/frappe-bench                         │
│  Frappe      version-15  (Python 3.11, Node 18)                │
│  Apps        frappe erpnext hrms                               │
│                                                                │
│  Site        site1.localhost                                   │
│  Open        http://site1.localhost:8000                       │
│  Login       Administrator  (generated, see below)             │
│  MariaDB     root  (generated, see below)                      │
│                                                                │
│  Start the development server:                                 │
│    source ~/.bashrc                                            │
│    cd /home/frappe/frappe-bench && bench start                 │
╰────────────────────────────────────────────────────────────────╯
```

## Updating a bench (`update-bench.sh`)

- **update**: pull the latest commits on the current branches, install requirements, migrate
  **every site**, rebuild assets and restart. This is `bench update`, with a backup step first.
- **upgrade**: move to another major version (e.g. v15 → v16). The script shows the new branch for
  every app, switches them, rebuilds the Python env with the right Python version (`bench migrate-env`),
  switches Node, then migrates all sites.
- **apps**: update only the apps you choose.
- **migrate** / **build**: run only that step.

Before changing anything it checks the app repositories for uncommitted changes (stash, discard or
abort) and creates a **restore point**: the commit of every app, the Python and Node versions, and a
database dump of every site. If `bench update`, a branch switch or the Python rebuild fails, or a
production site stops answering afterwards, the script rolls the bench back to that restore point
(apps, Python env, requirements, databases, assets) and takes the sites out of maintenance mode.
`FSS_AUTO_ROLLBACK=0` makes it ask instead of rolling back by default. You can also roll back later
with `./ops.sh rollback`. The last 3 restore points are kept.

```bash
./update-bench.sh                     # pick the bench and the action from menus
./update-bench.sh ~/frappe-bench      # use this bench
```

## Managing sites (`manage-sites.sh`)

A menu that loops until you quit (Esc or Cancel also quits). The current sites and their apps are shown
above the menu.

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

## Production operations (`ops.sh`)

```bash
./ops.sh                      # menu
./ops.sh status               # health check (exit code 0 ok, 1 warnings, 2 failures)
./ops.sh backup               # back up every site now
./ops.sh schedule             # automatic backups, offsite copies, alerts
./ops.sh restore              # restore a site from a local or offsite backup
./ops.sh rollback             # undo an update
./ops.sh secure               # firewall, fail2ban, swap, security updates, MariaDB tuning
./ops.sh domain | ssl         # custom domains, certificate expiry and renewal
```

**Backups.** Each run backs up every site (database, public and private files, site config) into
`~/frappe-backups/<bench>/<site>/`, outside the bench so a broken bench does not take its backups
with it. Old sets are deleted after `BACKUP_KEEP_DAYS` (14), but the newest `BACKUP_KEEP_MIN` (7)
sets of each site are always kept, so a server that stopped backing up never loses its last good
backups. `schedule` installs a cron job (daily, every 12 h, 6 h or hourly) guarded by `flock`, and logs
to `~/frappe-backups/<bench>/backup.log`.

**Offsite copies.** `schedule` can copy every backup to S3-compatible storage (AWS S3, Cloudflare R2,
Backblaze B2, Wasabi, DigitalOcean Spaces, MinIO) or to any [rclone](https://rclone.org) remote
(SFTP, Google Drive, ...). Backups can be encrypted on the server before upload (rclone crypt); the
password is shown once and must be kept somewhere safe, because it is needed to restore on another
server. Offsite copies older than `OFFSITE_KEEP_DAYS` (30) are deleted, only right after a successful
upload. Keys are stored in rclone's config (`~/.config/rclone/rclone.conf`, mode 600), not on the
command line.

**Restore.** Pick a site, then a backup from the local folder, the offsite storage, bench's own
backup folder, or any path. Backups of another site can be restored into this one (for example to
copy production into a staging site), and a backup from another server brings its `encryption_key`
along so saved passwords and API keys still decrypt. The current state is backed up first.

**Health check.** `status` checks MariaDB, the bench's Redis, nginx and every supervisor process, that
each site answers `/api/method/ping`, maintenance mode, whether the scheduler is enabled, disk and
memory, the age of the newest backup and the backup schedule, offsite copies and certificate expiry.
With a webhook (Slack, Discord, Mattermost) set in `schedule`, it can run every 10 minutes and alert
when something breaks and when it recovers (repeated every 6 hours while it stays broken). Backup
failures and failed updates are alerted too.

**Secure.** One step at a time, each with a question: ufw allowing only SSH (the port you are
connected on is always kept open), HTTP and HTTPS; fail2ban for SSH; unattended security updates
(Debian/Ubuntu); a swap file on small machines plus `vm.overcommit_memory=1` for Redis; MariaDB sized
to the machine's RAM (`innodb_buffer_pool_size`, log file size, slow query log) in a separate
`zz-frappe-tuning.cnf`.

**Domains and certificates.** `domain` adds or removes a custom domain on a site, regenerates the
nginx config and can get a Let's Encrypt certificate for it. `ssl` lists certificate expiry for every
site and domain and adds a renewal job if none exists.

Settings are stored per bench in `<bench>/.frappe-ops.conf` (mode 600). Variables set in the
environment win over the file, for example
`BENCH_PATH=~/frappe-bench BACKUP_KEEP_DAYS=30 ./ops.sh backup --no-offsite`.
The cron jobs run the scripts from where they are, so keep this folder in place (or run `schedule`
again after moving it).

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
the update/site/ops scripts), `FSS_LOG_DIR`, `FSS_AUTO_ROLLBACK=0`, `NO_COLOR=1`. For `ops.sh schedule`:
`S3_ENDPOINT`, `S3_REGION`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_BUCKET`, `OFFSITE_CRYPT_PASSWORD`.

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
a full unattended install in fresh containers of the newest release of each distro (Ubuntu 24.04 and 26.04,
the two newest LTS releases; Debian 13; Arch Linux), in development and production mode. Each install is
stopped half-way on purpose, resumed, re-run, and then checked by pinging the site.

To keep CI fast, the install jobs cache what apt/pacman, uv, pip and yarn download (one cache per distro,
renewed monthly and when `lib/prereqs.sh` or `lib/apps.sh` change); every package is still installed and
every bench still built from scratch. The weekly run uses no cache, so it also catches upstream changes
(Frappe, distro packages, mirrors) the way a fresh machine would. Draft pull requests and changes that
only touch Markdown run no install tests.

## Layout

```
get.sh              one-line installer (clone or update, then open the menu)
frappe-setup.sh     main menu
install.sh          new bench
update-bench.sh     update / upgrade a bench
manage-sites.sh     site management
ops.sh              backups, restore, rollback, health checks, hardening, domains
lib/common.sh       prompts, OS detection, services, bench helpers
lib/ui.sh           dialog boxes (whiptail/dialog) with plain fallback, validation, passwords, progress, summary box
lib/preflight.sh    system checks (memory, disk, ports, network, DNS) and swap file
lib/prereqs.sh      packages, MariaDB, wkhtmltopdf, uv/Python, nvm/Node, bench, nginx/supervisor
lib/apps.sh         official app catalog, dependencies, branch matching
lib/ops.sh          backup sets, offsite (rclone), restore points and rollback, health checks, cron
lib/unattended.sh   preset answers (flags / answers file) and resumable steps
examples/           sample answers file for unattended installs
tests/              unit tests and the container install test used by CI
```

## Troubleshooting

| Problem | What to do |
| --- | --- |
| Dialog boxes look broken or keys do not work | run with `--plain` |
| A step failed | the error names the step and the log file; with `--quiet` the last lines of output are shown. Fix the cause and run the script again |
| `bench build` is killed / runs out of memory | add swap (the installer offers it when RAM < 4 GB) or more RAM |
| `bench start` says a port is in use | another bench or service uses 8000/9000/11000/13000; `./frappe-setup.sh check` shows which |
| Let's Encrypt fails | the domain must resolve to this server and ports 80/443 must be open; retry from `manage-sites.sh` → https |

## Notes

- Production on WSL works, but WSL is not meant to host a public server.
- Let's Encrypt needs a public domain whose DNS already points to the machine, and ports 80/443 open.
- Frappe supports upgrading one major version at a time (v14 → v15 → v16).
