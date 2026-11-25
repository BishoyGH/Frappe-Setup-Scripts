#!/usr/bin/env bash
# shellcheck shell=bash
# System prerequisites for Frappe: packages, MariaDB, Redis, wkhtmltopdf, Python (uv), Node (nvm), bench.
# Requires lib/common.sh to be sourced first and detect_os to have run.

[[ -n "${_FSS_PREREQS_LOADED:-}" ]] && return 0
_FSS_PREREQS_LOADED=1

NVM_VERSION="${NVM_VERSION:-v0.40.8}"
WKHTMLTOX_RELEASE="${WKHTMLTOX_RELEASE:-0.12.6.1-3}"

# --------------------------------------------------------------------------
# Package manager wrappers
# --------------------------------------------------------------------------
_APT_UPDATED=0
apt_install() {
	if ((!_APT_UPDATED)); then
		run as_root env DEBIAN_FRONTEND=noninteractive apt-get update -y
		_APT_UPDATED=1
	fi
	run as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

_PACMAN_SYNCED=0
pacman_install() {
	if ((!_PACMAN_SYNCED)); then
		# Arch does not support partial upgrades, so sync + upgrade once.
		run as_root pacman -Syu --noconfirm
		_PACMAN_SYNCED=1
	fi
	run as_root pacman -S --needed --noconfirm "$@"
}

pkg_install() {
	case "$OS_FAMILY" in
		debian) apt_install "$@" ;;
		arch) pacman_install "$@" ;;
	esac
}

pacman_has() { pacman -Si "$1" >/dev/null 2>&1; }

# --------------------------------------------------------------------------
# Bootstrap when the script is started as root on a bare system
# --------------------------------------------------------------------------
bootstrap_root_minimum() {
	case "$OS_FAMILY" in
		debian) apt_install sudo ca-certificates curl git ;;
		arch) pacman_install sudo ca-certificates curl git ;;
	esac
}

# create_bench_user <username>: create a sudo-capable user to own the bench.
create_bench_user() {
	local user=$1 group=sudo pw
	[[ "$OS_FAMILY" == arch ]] && group=wheel
	if id "$user" >/dev/null 2>&1; then
		info "User '$user' already exists."
	else
		run useradd -m -s /bin/bash "$user"
		ask_secret pw "Password for new user '$user'" yes FRAPPE_USER_PASSWORD
		printf '%s:%s\n' "$user" "$pw" | chpasswd
		success "Created user '$user'."
	fi
	getent group "$group" >/dev/null || groupadd "$group"
	run usermod -aG "$group" "$user"
	if [[ "$OS_FAMILY" == arch ]]; then
		# Arch ships wheel commented out in sudoers.
		echo '%wheel ALL=(ALL:ALL) ALL' >/etc/sudoers.d/10-wheel
		chmod 440 /etc/sudoers.d/10-wheel
	fi
}

# --------------------------------------------------------------------------
# System packages
# --------------------------------------------------------------------------
install_base_packages() {
	local mode=$1
	header "Installing system packages"
	case "$OS_FAMILY" in
		debian)
			local -a pkgs=(
				sudo git curl wget ca-certificates gnupg lsb-release locales tzdata cron file xz-utils procps
				build-essential pkg-config libffi-dev libssl-dev zlib1g-dev libbz2-dev libreadline-dev
				libsqlite3-dev liblzma-dev libjpeg-dev libpng-dev
				libmariadb-dev mariadb-client
				redis-server
				fontconfig libfreetype6 libx11-6 libxext6 libxrender1 libxcb1 xfonts-75dpi xfonts-base fonts-dejavu-core
				python3 python3-venv python3-pip
			)
			[[ "$mode" == production ]] && pkgs+=(nginx supervisor certbot)
			apt_install "${pkgs[@]}"
			# Make sure a UTF-8 locale exists.
			if ! locale -a 2>/dev/null | grep -qiE '^(c|en_us)\.utf-?8$'; then
				as_root sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen 2>/dev/null || true
				run as_root locale-gen || true
			fi
			;;
		arch)
			local redis_pkg=redis
			pacman_has valkey && redis_pkg=valkey
			local -a pkgs=(
				sudo git curl wget ca-certificates base-devel pkgconf openssl libffi zlib libjpeg-turbo libpng
				libarchive cronie which procps-ng inetutils
				mariadb mariadb-libs mariadb-clients
				"$redis_pkg"
				fontconfig freetype2 libx11 libxext libxrender libxcb xorg-fonts-75dpi xorg-fonts-misc ttf-dejavu
				python python-pip
			)
			pacman_has libjpeg6-turbo && pkgs+=(libjpeg6-turbo)
			[[ "$mode" == production ]] && pkgs+=(nginx supervisor certbot)
			pacman_install "${pkgs[@]}"
			# Valkey is a drop-in Redis replacement; bench looks for redis-server.
			if ! command -v redis-server >/dev/null 2>&1 && command -v valkey-server >/dev/null 2>&1; then
				run as_root ln -sf "$(command -v valkey-server)" /usr/local/bin/redis-server
				command -v valkey-cli >/dev/null 2>&1 && run as_root ln -sf "$(command -v valkey-cli)" /usr/local/bin/redis-cli
			fi
			;;
	esac
	command -v redis-server >/dev/null 2>&1 || die "redis-server was not installed."
	success "System packages installed."
}

# --------------------------------------------------------------------------
# MariaDB
# --------------------------------------------------------------------------
mariadb_conf_path() {
	case "$OS_FAMILY" in
		debian) echo /etc/mysql/mariadb.conf.d/99-frappe.cnf ;;
		arch) echo /etc/my.cnf.d/99-frappe.cnf ;;
	esac
}

install_mariadb_server() {
	header "Installing MariaDB"
	case "$OS_FAMILY" in
		debian) apt_install mariadb-server mariadb-client ;;
		arch)
			pacman_install mariadb
			if [[ ! -d /var/lib/mysql/mysql ]]; then
				run as_root mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql
			fi
			;;
	esac

	local conf
	conf=$(mariadb_conf_path)
	run as_root mkdir -p "$(dirname "$conf")"
	as_root tee "$conf" >/dev/null <<'EOF'
# Added by Frappe-Setup-Scripts: settings required by the Frappe framework.
[mysqld]
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
loose-character-set-client-handshake = FALSE
innodb-file-per-table = 1
innodb-buffer-pool-size = 256M
innodb-log-buffer-size = 16M
max_allowed_packet = 256M

[mysql]
default-character-set = utf8mb4

[client]
default-character-set = utf8mb4
EOF
	info "Wrote MariaDB config to $conf"

	start_mariadb
	success "MariaDB is running ($(mariadb_version))."
}

start_mariadb() {
	if service_is_active mariadb; then
		if has_systemd; then run as_root systemctl restart mariadb; else as_root service mariadb restart >/dev/null 2>&1 || true; fi
	else
		service_enable_start mariadb bash -c 'nohup mysqld_safe --user=mysql >/dev/null 2>&1 &' || true
	fi
	local _
	for _ in $(seq 1 30); do
		as_root mariadb-admin ping >/dev/null 2>&1 && return 0
		as_root mysqladmin ping >/dev/null 2>&1 && return 0
		sleep 1
	done
	die "MariaDB did not start. Check: sudo journalctl -u mariadb (or /var/log/mysql)."
}

mariadb_version() {
	(mariadb --version 2>/dev/null || mysql --version 2>/dev/null) | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true
}

_mysql_cli() { command -v mariadb >/dev/null 2>&1 && echo mariadb || echo mysql; }

# mariadb_password_works <password>
mariadb_password_works() {
	MYSQL_PWD="$1" "$(_mysql_cli)" -uroot -h127.0.0.1 -e 'SELECT 1' >/dev/null 2>&1 ||
		MYSQL_PWD="$1" "$(_mysql_cli)" -uroot -e 'SELECT 1' >/dev/null 2>&1
}

# configure_mariadb_root <varname>: make sure root has a password; store it in <varname>.
configure_mariadb_root() {
	local __var=$1 __pw=''
	if [[ -n "${DB_ROOT_PASSWORD:-}" ]] && mariadb_password_works "$DB_ROOT_PASSWORD"; then
		printf -v "$__var" '%s' "$DB_ROOT_PASSWORD"; success "MariaDB root password verified."; return 0
	fi
	if as_root "$(_mysql_cli)" -uroot -e 'SELECT 1' >/dev/null 2>&1; then
		# Socket (passwordless) root access: set a password while keeping socket login for sudo.
		local current_ok=0
		if as_root "$(_mysql_cli)" -uroot -N -e "SELECT COUNT(*) FROM mysql.global_priv WHERE User='root' AND Host='localhost' AND IFNULL(JSON_VALUE(Priv,'\$.authentication_string'),'') NOT IN ('','invalid')" 2>/dev/null | grep -q '^[1-9]'; then
			current_ok=1
		fi
		if ((current_ok)) && ask_yes_no "MariaDB root already has a password. Do you know it (No = reset it)?" y; then
			while true; do
				ask_secret __pw "Current MariaDB root password" no DB_ROOT_PASSWORD
				mariadb_password_works "$__pw" && break
				warn "That password did not work."; DB_ROOT_PASSWORD=''
			done
		else
			ask_secret __pw "New MariaDB root password" yes DB_ROOT_PASSWORD
			local esc=${__pw//\\/\\\\}; esc=${esc//\'/\\\'}
			as_root "$(_mysql_cli)" -uroot <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${esc}') OR unix_socket;
DELETE FROM mysql.global_priv WHERE User='';
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
SQL
		fi
	else
		while true; do
			ask_secret __pw "MariaDB root password" no DB_ROOT_PASSWORD
			mariadb_password_works "$__pw" && break
			warn "That password did not work."; DB_ROOT_PASSWORD=''
		done
	fi
	mariadb_password_works "$__pw" || die "Could not log in to MariaDB as root with the given password."
	success "MariaDB root password is set and verified."
	printf -v "$__var" '%s' "$__pw"
}

# --------------------------------------------------------------------------
# wkhtmltopdf (patched Qt build, required for PDF printing)
# --------------------------------------------------------------------------
wkhtmltopdf_ok() { wkhtmltopdf --version 2>/dev/null | grep -qi 'patched qt'; }

install_wkhtmltopdf() {
	header "Installing wkhtmltopdf (patched Qt)"
	if wkhtmltopdf_ok; then success "wkhtmltopdf already installed: $(wkhtmltopdf --version)"; return 0; fi
	local dist tmp url file
	case "$OS_FAMILY:$OS_ID:$OS_CODENAME" in
		debian:debian:bullseye) dist=bullseye ;;
		debian:debian:*) dist=bookworm ;;
		debian:*) dist=jammy
			# Debian derivatives that are not Ubuntu-based use the bookworm build.
			[[ " $OS_LIKE " == *" ubuntu "* || "$OS_ID" == ubuntu ]] || dist=bookworm ;;
		arch:*) dist=bookworm ;;
	esac
	file="wkhtmltox_${WKHTMLTOX_RELEASE}.${dist}_${ARCH}.deb"
	url="https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOX_RELEASE}/${file}"
	tmp=$(mktemp -d)
	run curl -fL --retry 3 -o "$tmp/$file" "$url"
	case "$OS_FAMILY" in
		debian)
			apt_install "$tmp/$file"
			;;
		arch)
			# No official Arch build: unpack the Debian package into /usr/local.
			( cd "$tmp" && bsdtar -xf "$file" && run as_root bsdtar -xf data.tar.* -C / )
			as_root ldconfig || true
			;;
	esac
	rm -rf "$tmp"
	if wkhtmltopdf_ok; then
		success "wkhtmltopdf installed: $(wkhtmltopdf --version)"
	else
		warn "wkhtmltopdf did not install cleanly. PDFs will not render until it is fixed."
		[[ "$OS_FAMILY" == arch ]] && warn "On Arch you can try the AUR package 'wkhtmltopdf-static'."
	fi
}

# --------------------------------------------------------------------------
# Python via uv, Node via nvm, yarn, bench
# --------------------------------------------------------------------------
install_uv() {
	load_runtime_env
	if command -v uv >/dev/null 2>&1; then
		info "uv already installed ($(uv --version))."
		uv self update >/dev/null 2>&1 || true
		return 0
	fi
	header "Installing uv (Python manager)"
	if ! curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh; then
		warn "astral.sh installer failed; downloading uv from GitHub releases."
		local triple tmp
		[[ "$ARCH" == amd64 ]] && triple=x86_64-unknown-linux-gnu || triple=aarch64-unknown-linux-gnu
		tmp=$(mktemp -d)
		run curl -fL --retry 3 -o "$tmp/uv.tgz" "https://github.com/astral-sh/uv/releases/latest/download/uv-${triple}.tar.gz"
		tar -xzf "$tmp/uv.tgz" -C "$tmp"
		mkdir -p "$HOME/.local/bin"
		install -m 755 "$tmp"/uv-*/uv "$tmp"/uv-*/uvx "$HOME/.local/bin/"
		rm -rf "$tmp"
	fi
	load_runtime_env
	command -v uv >/dev/null 2>&1 || die "uv installation failed."
	success "uv installed ($(uv --version))."
}

# install_python <version>: prints the interpreter path on stdout.
install_python() {
	local ver=$1 py
	info "Installing Python $ver with uv..."
	run uv python install "$ver" >&2
	py=$(uv python find "$ver") || die "Python $ver not found after install."
	success "Python $ver: $py"
	printf '%s\n' "$py"
}

install_node() {
	local major=$1
	load_runtime_env
	if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
		header "Installing nvm $NVM_VERSION"
		curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | PROFILE=/dev/null bash
	fi
	load_runtime_env
	command -v nvm >/dev/null 2>&1 || die "nvm installation failed."
	header "Installing Node.js $major"
	run nvm install "$major"
	nvm use --silent "$major" >/dev/null
	# Make the newest installed major the default for new shells.
	nvm alias default "$major" >/dev/null
	info "Installing yarn (classic)"
	run npm install -g yarn
	success "Node $(node --version), npm $(npm --version), yarn $(yarn --version)"
}

install_bench_cli() {
	load_runtime_env
	header "Installing the bench CLI"
	if command -v bench >/dev/null 2>&1 && uv tool list 2>/dev/null | grep -q '^frappe-bench'; then
		run uv tool upgrade frappe-bench || true
	else
		run uv tool install --python 3.12 frappe-bench
	fi
	load_runtime_env
	command -v bench >/dev/null 2>&1 || die "bench was not installed."
	success "bench $(bench --version 2>/dev/null)"
}

# persist_shell_env: make PATH/nvm available in future interactive shells.
persist_shell_env() {
	local rc="$HOME/.bashrc" marker='# >>> frappe-setup-scripts >>>'
	[[ -f "$rc" ]] && grep -qF "$marker" "$rc" && return 0
	cat >>"$rc" <<'EOF'

# >>> frappe-setup-scripts >>>
export PATH="$HOME/.local/bin:$PATH"
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
# Auto-switch Node when entering a bench that has an .nvmrc
_fss_nvm_auto() { [ -f .nvmrc ] && command -v nvm >/dev/null 2>&1 && nvm use --silent >/dev/null 2>&1; }
case ";${PROMPT_COMMAND:-};" in *"_fss_nvm_auto"*) ;; *) PROMPT_COMMAND="_fss_nvm_auto${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;; esac
# <<< frappe-setup-scripts <<<
EOF
	info "Added uv/nvm setup to $rc"
}

# --------------------------------------------------------------------------
# Production: nginx + supervisor
# --------------------------------------------------------------------------
nginx_user() { [[ "$OS_FAMILY" == arch ]] && echo http || echo www-data; }

start_production_services() {
	if [[ "$OS_FAMILY" == arch ]]; then
		service_enable_start supervisord bash -c 'supervisord -c /etc/supervisord.conf' || true
	else
		service_enable_start supervisor bash -c 'supervisord -c /etc/supervisor/supervisord.conf' || true
	fi
	service_enable_start nginx nginx || true
}

# bench_setup_nginx <bench>: generate the bench's nginx config, adapted to this host.
bench_setup_nginx() {
	local bench=$1
	( cd "$bench" && run bench setup nginx --yes )
	# bench always adds "listen [::]:80"; nginx refuses to start where IPv6 is disabled.
	if [[ ! -s /proc/net/if_inet6 ]] && grep -q 'listen \[::\]' "$bench/config/nginx.conf"; then
		info "IPv6 is disabled on this machine; removing IPv6 listen lines from the nginx config."
		sed -i '/listen \[::\]/d' "$bench/config/nginx.conf"
	fi
}

# nginx_apply: validate the config, then reload nginx (or start it if it is not running).
nginx_apply() {
	run as_root nginx -t
	if pgrep -x nginx >/dev/null 2>&1; then
		service_reload nginx || run as_root nginx -s reload
	else
		service_enable_start nginx nginx
	fi
}

# bench_setup_supervisor <bench>: generate the supervisor config and give the socketio
# process a PATH that contains this bench's Node (nvm installs Node outside the system PATH).
bench_setup_supervisor() {
	local bench=$1 node_dir
	( cd "$bench" && run bench setup supervisor --yes --skip-supervisord --user "$(id -un)" )
	node_dir=$(dirname "$(command -v node)")
	if [[ -n "$node_dir" ]] && ! grep -q '^environment=PATH=' "$bench/config/supervisor.conf"; then
		sed -i "/^\[program:.*-node-socketio\]/a environment=PATH=\"$node_dir:/usr/local/bin:/usr/bin:/bin\"" "$bench/config/supervisor.conf"
	fi
}

supervisor_conf_link() {
	local name=$1
	if [[ "$OS_FAMILY" == arch ]]; then echo "/etc/supervisor.d/$name.ini"; else echo "/etc/supervisor/conf.d/$name.conf"; fi
}

# setup_production <bench-path>
# Equivalent of `bench setup production`, done by hand so it works on Debian, Ubuntu and Arch
# without bench trying to pull in ansible.
setup_production() {
	local bench=$1 name user link
	name=$(basename "$bench")
	user=$(id -un)
	header "Configuring production (nginx + supervisor)"
	# Supervisor runs the bench's Redis from now on; stop any copy this script started.
	stop_bench_redis
	start_production_services

	# nginx must be able to traverse the home directory to serve static assets.
	run chmod o+x "$HOME"

	bench_setup_supervisor "$bench"
	bench_setup_nginx "$bench"

	link=$(supervisor_conf_link "$name")
	run as_root mkdir -p "$(dirname "$link")" /etc/nginx/conf.d
	run as_root ln -sfn "$bench/config/supervisor.conf" "$link"
	run as_root ln -sfn "$bench/config/nginx.conf" "/etc/nginx/conf.d/$name.conf"

	if ! grep -qE '^[[:space:]]*include[[:space:]]+/etc/nginx/conf\.d/\*\.conf' /etc/nginx/nginx.conf; then
		info "Adding conf.d include to /etc/nginx/nginx.conf"
		run as_root sed -i '0,/^[[:space:]]*http[[:space:]]*{/s//http {\n    include \/etc\/nginx\/conf.d\/*.conf;/' /etc/nginx/nginx.conf
	fi

	# bench's nginx config logs with a format named "main", which only bench's ansible role defines.
	if ! grep -rqsE '^[[:space:]]*log_format[[:space:]]+main[[:space:]]' /etc/nginx/nginx.conf /etc/nginx/conf.d/; then
		info "Defining nginx log format 'main' in /etc/nginx/conf.d/00-frappe-log-format.conf"
		as_root tee /etc/nginx/conf.d/00-frappe-log-format.conf >/dev/null <<'NGINX'
# Added by Frappe-Setup-Scripts: log format used by bench's nginx config.
log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                '$status $body_bytes_sent "$http_referer" '
                '"$http_user_agent" "$http_x_forwarded_for"';
NGINX
	fi

	# Default sites grab port 80 before Frappe does.
	local f
	for f in /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf; do
		if [[ -e "$f" ]] && ask_yes_no "Disable nginx default site $f so Frappe answers on port 80?" y; then
			run as_root rm -f "$f"
		fi
	done

	if ask_yes_no "Allow '$user' to restart nginx/supervisor without a sudo password (bench setup sudoers)?" y; then
		( cd "$bench" && run as_root env "PATH=$PATH" "$(command -v bench)" setup sudoers "$user" ) || warn "bench setup sudoers failed; bench restart will ask for sudo."
	fi

	nginx_apply
	run as_root supervisorctl reread || true
	run as_root supervisorctl update || true
	sleep 3
	as_root supervisorctl status || true
	success "Production services configured."
}

reload_production() {
	local bench=$1
	bench_setup_supervisor "$bench"
	bench_setup_nginx "$bench"
	nginx_apply
	as_root supervisorctl reread >/dev/null 2>&1 || true
	as_root supervisorctl update >/dev/null 2>&1 || true
	( cd "$bench" && run bench restart ) || as_root supervisorctl restart all || true
}

# WSL: offer to enable systemd so services start automatically.
wsl_offer_systemd() {
	((IS_WSL)) || return 0
	has_systemd && return 0
	warn "This WSL distro is running without systemd. Services can still be started manually,"
	warn "but enabling systemd makes MariaDB/nginx/supervisor start automatically."
	if ask_yes_no "Enable systemd in /etc/wsl.conf (takes effect after 'wsl --shutdown')?" y; then
		if [[ -f /etc/wsl.conf ]] && grep -q '^\[boot\]' /etc/wsl.conf; then
			if grep -q '^systemd=' /etc/wsl.conf; then
				as_root sed -i 's/^systemd=.*/systemd=true/' /etc/wsl.conf
			else
				as_root sed -i '/^\[boot\]/a systemd=true' /etc/wsl.conf
			fi
		else
			printf '\n[boot]\nsystemd=true\n' | as_root tee -a /etc/wsl.conf >/dev/null
		fi
		success "systemd enabled. After this script finishes, run 'wsl --shutdown' from Windows and reopen the distro."
	fi
}
