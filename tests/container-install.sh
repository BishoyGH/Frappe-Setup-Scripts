#!/usr/bin/env bash
# End-to-end install test, run as root inside a fresh distro container (see .github/workflows/ci.yml).
#
#   1. unattended install that is made to stop after "bench init"
#   2. the same command again: must resume and finish
#   3. the same command a third time: must notice the finished install and exit 0
#   4. smoke test: the site answers ping (bench execute in development, HTTP via nginx in production)
#   5. ops.sh: back up the site, restore it from that backup, run the health check
#
# Usage: tests/container-install.sh <development|production> [apps]
# Expects the repository at /src. Logs go to $FSS_LOG_DIR (default /logs).

set -euo pipefail
MODE=${1:-development}
APPS=${2:-}
SRC=${SRC:-/src}
export FSS_LOG_DIR=${FSS_LOG_DIR:-/logs}
export DB_ROOT_PASSWORD=ci-db-root-pw ADMIN_PASSWORD=ci-admin-pw NO_COLOR=1
mkdir -p "$FSS_LOG_DIR" && chmod 777 "$FSS_LOG_DIR"

# Download cache (CI only): when $CI_CACHE is a mounted directory, keep the packages that apt/pacman,
# uv, pip and yarn download there, so the next run can skip the downloads. Only downloads are cached:
# every package is still installed, and every bench is still built, from scratch.
if [[ -n "${CI_CACHE:-}" && -d "$CI_CACHE" ]]; then
	mkdir -p "$CI_CACHE/home"
	# The cache was restored by another user id on the host; let root and the bench user write to it.
	chmod -R a+rwX "$CI_CACHE"
	if command -v apt-get >/dev/null; then
		mkdir -p "$CI_CACHE/apt/partial"
		rm -f /etc/apt/apt.conf.d/docker-clean   # the image deletes downloaded .debs after every install
		cat >/etc/apt/apt.conf.d/90ci-cache <<-EOF2
			Dir::Cache::Archives "$CI_CACHE/apt";
			APT::Keep-Downloaded-Packages "true";
			Binary::apt::APT::Keep-Downloaded-Packages "true";
		EOF2
	elif command -v pacman >/dev/null; then
		mkdir -p "$CI_CACHE/pacman"
		sed -i "s|^#\?CacheDir.*|CacheDir = $CI_CACHE/pacman/|" /etc/pacman.conf
		grep -q "^CacheDir = $CI_CACHE/pacman/" /etc/pacman.conf || sed -i "/^\[options\]/a CacheDir = $CI_CACHE/pacman/" /etc/pacman.conf
	fi
	# New users get ~/.cache from /etc/skel: point it at the cache (uv, pip, yarn and node-gyp live there).
	mkdir -p /etc/skel /etc/uv
	ln -sfn "$CI_CACHE/home" /etc/skel/.cache
	# The cache is on another filesystem, so uv cannot hard-link from it; copy without warning.
	echo 'link-mode = "copy"' >/etc/uv/uv.toml
	echo "Using the download cache in $CI_CACHE ($(du -sh "$CI_CACHE" 2>/dev/null | cut -f1))."
fi

if [[ "$MODE" == production ]]; then SITE=ci.example.com; else SITE=ci.localhost; fi
CONF=/root/ci-install.conf
cat >"$CONF" <<EOF
MODE=$MODE
FRAPPE_BRANCH=${FRAPPE_BRANCH:-latest}
APPS=$APPS
BENCH_NAME=ci-bench
SITE_NAME=$SITE
SITE_APPS=all
LETSENCRYPT_EMAIL=
FRAPPE_USER=frappe
EOF
chmod 600 "$CONF"

step() { printf '\n\033[1;35m######## %s\033[0m\n' "$*"; }

step "1/4 install, stopping after bench init"
if FSS_FAIL_AFTER_STEP=bench-init bash "$SRC/install.sh" --yes --config "$CONF"; then
	echo "expected the first run to stop after bench-init" >&2; exit 1
fi
STATE=/home/frappe/.local/state/frappe-setup-scripts/install-ci-bench.steps
grep -qx 'done bench-init' "$STATE" || { echo "bench-init not recorded in $STATE" >&2; exit 1; }

step "2/4 same command again: resume"
bash "$SRC/install.sh" --yes --config "$CONF" 2>&1 | tee /tmp/run2.log
grep -q 'Skipping: system packages' /tmp/run2.log || { echo "run 2 did not skip finished steps" >&2; exit 1; }
grep -q 'Skipping: bench init' /tmp/run2.log || { echo "run 2 did not skip bench init" >&2; exit 1; }
grep -qx 'done complete' "$STATE" || { echo "install not marked complete" >&2; exit 1; }

step "3/4 same command a third time: nothing to do"
bash "$SRC/install.sh" --yes --config "$CONF" 2>&1 | tee /tmp/run3.log
grep -q 'nothing to do' /tmp/run3.log || { echo "run 3 did not detect the finished install" >&2; exit 1; }

step "4/4 smoke test"
[[ ! -e /etc/sudoers.d/zz-frappe-setup-frappe ]] || { echo "temporary sudoers file was left behind" >&2; exit 1; }
grep -rl 'ci-admin-pw\|ci-db-root-pw' "$FSS_LOG_DIR" && { echo "a password leaked into the logs" >&2; exit 1; }
if [[ "$MODE" == production ]]; then
	for _ in $(seq 1 60); do
		if curl -fsS -H "Host: $SITE" http://127.0.0.1/api/method/ping | tee /tmp/ping | grep -q pong; then break; fi
		sleep 2
	done
	grep -q pong /tmp/ping || { echo "site did not answer through nginx" >&2; sudo -u frappe sudo supervisorctl status || true; exit 1; }
else
	sudo -u frappe -H bash -lc '
		set -e
		export PATH="$HOME/.local/bin:$PATH"
		cd ~/ci-bench
		for c in config/redis_cache.conf config/redis_queue.conf; do [ -f "$c" ] && redis-server "$c" --daemonize yes; done
		sleep 1
		bench --site '"$SITE"' execute frappe.ping | tee /tmp/ping
		grep -q pong /tmp/ping
	'
fi
apps=$(sudo -u frappe -H bash -lc "cd ~/ci-bench && ~/.local/bin/bench --site $SITE list-apps")
echo "$apps"
for a in ${APPS//,/ }; do grep -q "^$a" <<<"$apps" || { echo "$a is not installed on $SITE" >&2; exit 1; }; done

step "ops.sh: backup, restore, status"
ops() { sudo -u frappe -H env ASSUME_DEFAULTS=1 NO_COLOR=1 FSS_LOG_DIR="$FSS_LOG_DIR" DB_ROOT_PASSWORD="$DB_ROOT_PASSWORD" \
	BENCH_PATH=/home/frappe/ci-bench bash /home/frappe/Frappe-Setup-Scripts/ops.sh "$@"; }
ops backup --no-offsite
ls /home/frappe/frappe-backups/ci-bench/"$SITE"/*-database.sql.gz >/dev/null || { echo "ops.sh backup wrote no database dump" >&2; exit 1; }
ops restore --site "$SITE" --yes
rc=0; ops status 2>&1 | tee /tmp/status.log || rc=$?
echo "status exit code: $rc"
((rc <= 2)) || { echo "ops.sh status crashed" >&2; exit 1; }
if [[ "$MODE" == production ]]; then
	grep -q "$SITE .*answers /api/method/ping" /tmp/status.log || { echo "status did not see the site answering" >&2; exit 1; }
fi
echo "All checks passed ($MODE${APPS:+, apps: $APPS})."
