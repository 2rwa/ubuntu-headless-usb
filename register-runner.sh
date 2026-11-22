#!/usr/bin/env bash
# Register one GitHub Actions self-hosted runner after firstboot-complete.
# Deliberately uses the official release asset with SHA-256 verification.
set -Eeuo pipefail
umask 077
URL='' VERSION='' SHA256=''
usage() { echo 'Usage: sudo usb-register-runner --url https://github.com/OWNER/REPO [--version X.Y.Z --sha256 HASH]'; }
die() { echo "ERROR: $*" >&2; exit 1; }
while (($#)); do
  case "$1" in
    --url|--version|--sha256)
      (($# >= 2)) || die "missing value for $1"
      case "$1" in --url) URL=$2;; --version) VERSION=$2;; --sha256) SHA256=$2;; esac
      shift 2;;
    -h|--help) usage; exit 0;;
    *) die "unknown option: $1";;
  esac
done
[[ $EUID == 0 ]] || die 'must run with sudo'
[[ -f /var/lib/ubuntu-usb/network-enabled ]] || die 'run usb-firstboot-complete first'
[[ -f /var/lib/ubuntu-usb/identity ]] || die 'missing installation identity'
RUNNER_USER=$(sed -n 's/^runner_user=//p' /var/lib/ubuntu-usb/identity)
[[ $RUNNER_USER =~ ^[a-z_][a-z0-9_-]{0,30}$ && $RUNNER_USER != root ]] || die 'invalid runner identity'
[[ $URL =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/?$ ]] || die 'requires a repository URL'
[[ $(dpkg --print-architecture) == amd64 ]] || die 'only amd64 supported'
[[ -z $VERSION || $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'invalid version'
[[ -z $SHA256 || $SHA256 =~ ^[a-fA-F0-9]{64}$ ]] || die 'invalid SHA256'
ROOT=/opt/actions-runner
[[ ! -e $ROOT/.runner ]] || die 'runner already registered; do not overwrite its identity'
[[ ! -e $ROOT/config.sh ]] || die 'existing runner installation; inspect it manually'
# GitHub API tag and asset digest are checked against the fetched release.
if [[ -z $VERSION ]]; then
  release_url=https://api.github.com/repos/actions/runner/releases/latest
else
  release_url="https://api.github.com/repos/actions/runner/releases/tags/v$VERSION"
fi
json=$(mktemp)
tarball=$(mktemp)
trap 'rm -f "$json" "$tarball"' EXIT
curl -fsSL --retry 3 -H 'Accept: application/vnd.github+json' "$release_url" -o "$json"
tag=$(jq -r '.tag_name // empty' "$json")
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'bad GitHub release tag'
VERSION=${tag#v}
name="actions-runner-linux-x64-$VERSION.tar.gz"
asset_url=$(jq -r --arg n "$name" '.assets[] | select(.name==$n) | .browser_download_url // empty' "$json")
digest=$(jq -r --arg n "$name" '.assets[] | select(.name==$n) | .digest // empty' "$json")
[[ $asset_url == "https://github.com/actions/runner/releases/download/v$VERSION/$name" ]] || die 'runner asset URL mismatch'
if [[ -z $SHA256 ]]; then
  [[ $digest =~ ^sha256:[a-f0-9]{64}$ ]] || die 'GitHub asset lacks SHA256 digest; supply --sha256 from trusted GitHub documentation'
  SHA256=${digest#sha256:}
else
  if [[ -n $digest && $digest != "sha256:$SHA256" ]]; then die 'supplied hash conflicts with GitHub digest'; fi
fi
echo "Downloading verified GitHub Actions runner v$VERSION..."
curl -fL --retry 3 "$asset_url" -o "$tarball"
printf '%s  %s\n' "$SHA256" "$tarball" | sha256sum -c -
install -d -o "$RUNNER_USER" -g "$RUNNER_USER" -m 755 "$ROOT"
tar -xzf "$tarball" -C "$ROOT" --no-same-owner
chown -R "$RUNNER_USER:$RUNNER_USER" "$ROOT"
# Read short-lived GitHub registration token without writing it to a file/history.
[[ -r /dev/tty ]] || die 'registration requires a local terminal'
printf 'Paste short-lived registration token from GitHub Settings > Actions > Runners: '
IFS= read -rs token </dev/tty
echo
[[ -n $token ]] || die 'empty token'
label=$(hostname -s)
# GitHub config.sh requires --token as an argument; it is never echoed or persisted by this script.
runuser -u "$RUNNER_USER" -- "$ROOT/config.sh" --unattended --url "$URL" --token "$token" \
  --name "$label" --labels "usb-dev,$label" --work _work
unset token
cd "$ROOT"
./svc.sh install "$RUNNER_USER"
./svc.sh start
./svc.sh status
echo 'Runner registered and enabled as systemd service.'