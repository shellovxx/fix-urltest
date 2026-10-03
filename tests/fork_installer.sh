#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
awk '/^(parse_args|sing_box_is_present|select_sing_box_installation|installation_space_requirement|install_backend_package|pkg_install_files)\(\) \{/ {capture=1} capture {print} capture && /^\}/ {capture=0}' "$ROOT/install.sh" > "$WORK/functions.sh"
# shellcheck disable=SC1091
source "$WORK/functions.sh"
msg() { :; }
installer_text() { printf '%s' "$1"; }
fail() { printf '%s\n' "$1" >&2; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
pkg_is_installed() { [[ "${PACKAGE_INSTALLED:-0}" == 1 ]]; }
mkdir "$WORK/bin"
cat > "$WORK/bin/sing-box" <<'SH'
#!/bin/sh
printf '%s\n' "$MOCK_CORE_VERSION"
SH
chmod +x "$WORK/bin/sing-box"
export PATH="$WORK/bin:$PATH"
export MOCK_CORE_VERSION='sing-box version 1.14.2'
export SING_BOX_REQUESTED_VARIANT=''
SING_BOX_INSTALL_VARIANT=''
export REQUIRED_SPACE_KB=15360
select_sing_box_installation < /dev/null
[[ "$SING_BOX_INSTALL_VARIANT" == extended ]] || fail 'stock core must default to extended'
export MOCK_CORE_VERSION='sing-box version 1.14.1-extended-2.7.2'
select_sing_box_installation < /dev/null
[[ -z "$SING_BOX_INSTALL_VARIANT" ]] || fail 'installed extended core must be preserved'
PACKAGE_INSTALLED=1
[[ "$(installation_space_requirement)" == 4096 ]] || fail 'package-only update should fit existing extended installation'
parse_args --sing-box stable
select_sing_box_installation < /dev/null
[[ "$SING_BOX_INSTALL_VARIANT" == stable ]] || fail 'explicit stock override lost'
[[ "$(installation_space_requirement)" == 15360 ]] || fail 'core replacement must not receive package-only space allowance'
parse_args --sing-box extended-compressed
select_sing_box_installation < /dev/null
[[ "$SING_BOX_INSTALL_VARIANT" == extended-compressed ]] || fail 'compressed override lost'
parse_args --sing-box keep
select_sing_box_installation < /dev/null
[[ -z "$SING_BOX_INSTALL_VARIANT" ]] || fail 'keep override changed the core'
if (parse_args --sing-box unknown >/dev/null 2>&1); then fail 'unknown variant accepted'; fi
if (parse_args --sing-box >/dev/null 2>&1); then fail 'missing variant accepted'; fi
PACKAGE_INSTALLED=0
SING_BOX_REQUESTED_VARIANT=''
[[ "$(installation_space_requirement)" == 15360 ]] || fail 'fresh installation received update allowance'
[[ "$(ucode "$ROOT/forkop/files/usr/lib/core/constants.uc" get FORKOP_RELEASE_REPO)" == shellovxx/fix-urltest ]] || fail 'updates would return to upstream'
opkg() { printf '%s\n' "$@" > "$WORK/opkg-install.args"; }
PKG_IS_APK=0
pkg_install_files "$WORK/forkop_1.0.6.ipk"
grep -Fxq -- '--force-reinstall' "$WORK/opkg-install.args" || fail 'same-version corrected release must be reinstalled'
grep -Fxq -- '--force-downgrade' "$WORK/opkg-install.args" || fail 'installer must allow replacing 1.0.7 with corrected 1.0.6'
grep -Fxq "$WORK/forkop_1.0.6.ipk" "$WORK/opkg-install.args" || fail 'installer lost the selected package'
unset -f opkg
export FORKOP_UCI_STATE_FILE="$WORK/config.state"
printf 'forkop.settings=settings\nforkop.settings.dont_touch_dhcp=1\n' > "$FORKOP_UCI_STATE_FILE"
export FORKOP_INIT="$WORK/bin/no-service"
printf '#!/bin/sh\nexit 0\n' > "$FORKOP_INIT"
chmod +x "$FORKOP_INIT"
export FORKOP_PACKAGE_UPGRADE_STATE="$WORK/upgrade.state"
export FORKOP_RT_TABLES="$WORK/rt_tables"
export FORKOP_SING_BOX_INIT="$WORK/managed-init"
printf '#!/bin/sh\n# Forkop managed sing-box service for binary variants\nexit 0\n' > "$FORKOP_SING_BOX_INIT"
export FORKOP_SING_BOX_BIN="$WORK/core"
export FORKOP_SING_BOX_CRONET="$WORK/cronet"
touch "$FORKOP_SING_BOX_BIN" "$FORKOP_SING_BOX_CRONET"
export TMP_DIR="$WORK"
export FORKOP_BACKEND_FILE="$WORK/package.apk"
# The old upgrade hook behaves like removal; exercise that destructive action
# under the installer's compatibility guard, without touching system files.
pkg_install_files() { ucode -L "$ROOT/forkop/files/usr/lib" "$ROOT/forkop/files/usr/lib/service/package.uc" prerm remove; }
install_backend_package
[[ -f "$WORK/core" && -f "$WORK/managed-init" && -f "$WORK/cronet" ]] || fail 'installer did not protect a managed core from old upgrade hooks'
[[ "$FORKOP_SING_BOX_INIT" == "$WORK/managed-init" ]] || fail 'package-hook override leaked into runtime'
printf 'Fork installer default, overrides and core preservation checks passed\n'
