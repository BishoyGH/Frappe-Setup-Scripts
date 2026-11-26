#!/usr/bin/env bash
# One-line installer for Frappe-Setup-Scripts:
#
#   curl -fsSL https://raw.githubusercontent.com/BishoyGH/Frappe-Setup-Scripts/main/get.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/BishoyGH/Frappe-Setup-Scripts/main/get.sh | bash -s -- install --quiet
#
# It installs git if needed, clones (or updates) the scripts into ~/Frappe-Setup-Scripts and starts
# frappe-setup.sh with the given arguments. Prompts read from the terminal, so piping into bash works.
#
# Environment: FSS_DIR (where to put the scripts), FSS_REF (branch or tag, default main),
#              FSS_REPO (git URL of the scripts).

# Everything is inside main so a partly downloaded script never runs.
main() {
	set -eo pipefail
	local repo=${FSS_REPO:-https://github.com/BishoyGH/Frappe-Setup-Scripts.git}
	local ref=${FSS_REF:-main}
	local dir=${FSS_DIR:-$HOME/Frappe-Setup-Scripts}
	local sudo=''

	say() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
	fail() { printf '\033[1;31m✖\033[0m  %s\n' "$*" >&2; exit 1; }

	[[ "$(uname -s)" == Linux ]] || fail "These scripts run on Linux (Ubuntu, Debian, Arch, or WSL 2)."
	if [[ "$(id -u)" -ne 0 ]]; then
		command -v sudo >/dev/null 2>&1 && sudo=sudo
	fi

	if ! command -v git >/dev/null 2>&1; then
		say "Installing git..."
		[[ -n "$sudo" || "$(id -u)" -eq 0 ]] || fail "git is missing and sudo is not available. Install git, then run this again."
		if command -v apt-get >/dev/null 2>&1; then
			$sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq
			$sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git ca-certificates
		elif command -v pacman >/dev/null 2>&1; then
			$sudo pacman -Sy --needed --noconfirm git
		else
			fail "Unsupported system: install git manually, then run this again."
		fi
	fi

	if [[ -d "$dir/.git" ]]; then
		say "Updating $dir"
		if ! { git -C "$dir" fetch --quiet --depth 1 origin "$ref" && git -C "$dir" checkout --quiet -B "$ref" FETCH_HEAD; }; then
			say "Could not update $dir; using the copy that is there."
		fi
	elif [[ -e "$dir" ]]; then
		fail "$dir exists and is not a git checkout. Move it away or set FSS_DIR."
	else
		say "Downloading Frappe-Setup-Scripts ($ref) to $dir"
		git clone --quiet --depth 1 --branch "$ref" "$repo" "$dir"
	fi

	if ! { : </dev/tty; } 2>/dev/null; then
		fail "No terminal available for the questions. Run: bash $dir/frappe-setup.sh"
	fi
	say "Starting the setup menu"
	exec bash "$dir/frappe-setup.sh" "$@" </dev/tty
}

main "$@"
