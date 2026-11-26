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
| `get.sh` | The one-line installer above |

## Supported systems

| OS | Notes |
| --- | --- |
| Ubuntu 22.04, 24.04 (and newer) | tested end to end |
| Debian 11, 12, 13 | |
| Arch Linux (and derivatives such as Manjaro, EndeavourOS) | Redis is provided by Valkey when available; wkhtmltopdf is unpacked from the official Debian build. Install `libnewt` for dialog boxes |
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

Every run of `install.sh` and `update-bench.sh` writes a full log to `~/frappe-setup-logs/`.

## What `install.sh` does

All questions come first, so once you confirm the summary the install runs without stopping
(except for a couple of production choices such as replacing nginx's default site).

1. **Setup type**: development (`bench start`, developer mode) or production (nginx + supervisor).
2. **System check**: memory and swap, CPU, free disk (home and `/var/lib` for MariaDB), whether the ports
   are free (8000, 9000, 11000, 13000 in development; 80 and 443 in production), whether GitHub, PyPI and
   npm can be reached, WSL 1 vs 2, and systemd. Failed checks ask whether to go on. On a small machine
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

Before changing anything it offers to back up all sites, and it checks the app repositories for
uncommitted changes (stash, discard or abort).

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

## Non-interactive use

Every prompt has a default. `ASSUME_DEFAULTS=1` accepts all of them, and secrets come from the
environment:

```bash
ASSUME_DEFAULTS=1 DB_ROOT_PASSWORD='…' ADMIN_PASSWORD='…' ./install.sh
```

Other variables: `BENCH_PATH` (bench used by the update/site scripts), `FRAPPE_USER` /
`FRAPPE_USER_PASSWORD` (user created when run as root), `NO_COLOR=1`.

## Layout

```
get.sh              one-line installer (clone or update, then open the menu)
frappe-setup.sh     main menu
install.sh          new bench
update-bench.sh     update / upgrade a bench
manage-sites.sh     site management
lib/common.sh       prompts, OS detection, services, bench helpers
lib/ui.sh           dialog boxes (whiptail/dialog) with plain fallback, validation, passwords, progress, summary box
lib/preflight.sh    system checks (memory, disk, ports, network, DNS) and swap file
lib/prereqs.sh      packages, MariaDB, wkhtmltopdf, uv/Python, nvm/Node, bench, nginx/supervisor
lib/apps.sh         official app catalog, dependencies, branch matching
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
