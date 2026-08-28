#!/bin/sh
# Bootstrap installer for the AWS Workload Credentials Provider on Linux.
#
#   sudo AWCP_VERSION=3.1.1 /bin/bash -c "$(curl --proto '=https' --tlsv1.2 -fsSL \
#     https://raw.githubusercontent.com/aws/aws-workload-credentials-provider/HEAD/install.sh)" \
#     -- --config /path/to/config.toml
#
# PLANNED CHANGE: the service units and install script are fetched from GitHub
# today. They will move to the artifact host alongside the binary, so that a
# version is published as one versioned unit and the glue can never be a
# different version from the binary it installs. Only fetch_glue changes;
# nothing else here does.
#
# Downloads the release binary from the artifact host, takes the service units
# and install script from the matching release tag on GitHub, then runs that
# install script. Options other than --dry-run are passed through to it.
#
# Neither download is checked against a digest: no release publishes one for the
# binary, and the glue comes from a source archive GitHub generates on demand,
# which has no stable checksum to compare against. Both rest on TLS to their
# host. Once the release workflow publishes digests, the binary's should be
# fetched and enforced here as a hard failure.
#
# The archive is extracted with its repository layout intact rather than being
# flattened, because every released tag hardcodes
#
#     PROVIDER_SOURCE_DIR=../../target/release
#
# in configuration/common.sh, and sourcing that file overwrites anything this
# script exports. configuration/install cd's to its own directory first, so the
# binary is placed where that relative path already resolves: <root>/target/
# release, inside the private temp directory. Tags that later gain a
# ${PROVIDER_SOURCE_DIR:-...} default resolve to the same place, so this needs
# no change when they do.
#
# Environment:
#   AWCP_VERSION   Version to install, in the pattern x.y.z. Required.
#   AWCP_BASE_URL  Artifact host for the binary.
#   AWCP_REPO_URL  GitHub repository the glue is fetched from.
#
# Everything runs from main, called on the last line, so a download truncated
# mid-transfer can't execute a partial install.

set -eu

BASE_URL="${AWCP_BASE_URL:-https://artifacts.awcp.global.on.aws}"
REPO_URL="${AWCP_REPO_URL:-https://github.com/aws/aws-workload-credentials-provider}"
REPO=aws-workload-credentials-provider
BIN=aws-workload-credentials-provider
# Release binaries are built against this glibc; older hosts can't load them.
# Read by the release workflow's floor check, so this is the single definition.
GLIBC_FLOOR=2.34

die() {
    echo "install.sh: $*" >&2
    exit 1
}

# The pass-through list mirrors configuration/install's own usage. Kept here
# because a customer running the one-liner has no copy of that script to consult
# until this one has already downloaded it.
usage() {
    cat <<'EOF'
Usage: install.sh [--dry-run] [-h|--help] [-- <install options>]

Downloads the AWS Workload Credentials Provider release for this architecture
and runs the release's own install script.

Options handled here:
    --dry-run          Download everything, then stop without installing
    -h, --help         Show this message

Options passed through to the release's install script:
    --config <file>    Config to install to /etc/aws-workload-credentials-provider
    --no-start         Install and enable services, but don't start them
    --no-privileges    Skip Linux capabilities on the ACM service
    --no-sudoers       Skip sudoers generation

Environment:
    AWCP_VERSION       Version to install, e.g. 3.1.1. Required.
    AWCP_BASE_URL      Artifact host the binary is downloaded from.
    AWCP_REPO_URL      Repository the service units are fetched from.

Options must come after --, or the shell consuming this script assigns the
first one to $0 and drops it.

Example:
    sudo AWCP_VERSION=3.1.1 /bin/bash -c "$(curl --proto '=https' --tlsv1.2 \
      -fsSL https://raw.githubusercontent.com/aws/aws-workload-credentials-provider/HEAD/install.sh)" \
      -- --config /path/to/config.toml
EOF
    exit 0
}

fetch() {
    curl --proto '=https' --tlsv1.2 -fsSL --retry 3 -o "$2" -- "$1" ||
        die "download failed: $1"
}

# The service units and install script for the given version, extracted into
# $tmp with the repository layout intact. This is the only part that changes
# when the glue moves to the artifact host.
fetch_glue() {
    fetch "$REPO_URL/archive/refs/tags/v$1.tar.gz" "$tmp/glue.tar.gz"
    # --no-same-owner: running as root, tar would otherwise restore whatever
    # uid the archive records.
    tar --no-same-owner -xzf "$tmp/glue.tar.gz" -C "$tmp" ||
        die "cannot extract the v$1 source archive"
}

main() {
    # Help comes before the $0 guard and the root check: reading the options
    # shouldn't require sudo, or knowing about the -- convention first. $0 is
    # checked too, since that's where --help lands without the --.
    case "$0" in
        -h | --help) usage ;;
    esac
    for arg in "$@"; do
        case "$arg" in
            -h | --help) usage ;;
        esac
    done

    # `bash -c <script> [name [args...]]` assigns the first word after the
    # script to $0, so an operator who omits the `--` loses their first option
    # silently. Refuse rather than install something they didn't ask for.
    case "$0" in
        --) ;;
        -*) die "unexpected \$0 '$0': put -- before the options, as in 'sh -s -- --dry-run'" ;;
    esac

    [ "$(id -u)" -eq 0 ] || die "must run as root"
    [ "$(uname -s)" = Linux ] || die "unsupported OS: $(uname -s). On Windows, use install.ps1"

    case "$(uname -m)" in
        x86_64 | amd64) target=x86_64-unknown-linux-gnu ;;
        aarch64 | arm64) target=aarch64-unknown-linux-gnu ;;
        *) die "unsupported architecture: $(uname -m)" ;;
    esac

    for cmd in awk chmod curl grep mktemp sort systemctl tar; do
        command -v "$cmd" >/dev/null || die "required command not found: $cmd"
    done

    # Fail here rather than after installing services that can't exec.
    glibc=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $NF}')
    if [ -z "$glibc" ] && command -v ldd >/dev/null; then
        ldd_version=$(ldd --version 2>&1 | head -1)
        case "$ldd_version" in
            *musl*) die "musl libc detected; release binaries are built against glibc" ;;
        esac
        glibc=$(printf '%s\n' "$ldd_version" | awk '{print $NF}')
    fi
    case "$glibc" in
        [0-9]*.[0-9]*) ;;
        *) glibc="" ;;
    esac
    if [ -z "$glibc" ]; then
        echo "install.sh: warning: cannot determine the glibc version" >&2
    elif [ "$(printf '%s\n%s\n' "$GLIBC_FLOOR" "$glibc" | sort -V | head -1)" != "$GLIBC_FLOOR" ]; then
        die "glibc $glibc is older than the $GLIBC_FLOOR the release binary requires"
    fi

    # Strip --dry-run and leave the rest in "$@" for the bundle's install
    # script. Rotating through "$@" keeps arguments containing spaces intact.
    dry_run=false
    remaining=$#
    while [ "$remaining" -gt 0 ]; do
        arg=$1
        shift
        if [ "$arg" = --dry-run ]; then
            dry_run=true
        else
            set -- "$@" "$arg"
        fi
        remaining=$((remaining - 1))
    done

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    # A signal handler returns to the next command, so these have to exit
    # themselves or the script would carry on with its work directory deleted.
    trap 'rm -rf "$tmp"; exit 130' HUP INT TERM

    # The version is always explicit. The artifact host publishes no pointer to
    # the newest release, and picking one here would install a version the
    # operator never named.
    version="${AWCP_VERSION:-}"
    [ -n "$version" ] ||
        die "set AWCP_VERSION to the version to install, as in 'sudo AWCP_VERSION=3.1.1 ...'"
    printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' ||
        die "not a valid version: $version"

    echo "Installing $BIN $version ($target)"

    # The glue comes first: its layout decides where the binary has to be put.
    fetch_glue "$version"

    root="$tmp/$REPO-$version"
    conf="$root/aws_workload_credentials_provider_common/configuration"
    [ -x "$conf/install" ] || die "release v$version has no configuration/install"

    mkdir -p "$root/target/release"
    fetch "$BASE_URL/$version/$target/$BIN" "$root/target/release/$BIN"
    chmod 755 "$root/target/release/$BIN"

    if [ "$dry_run" = true ]; then
        echo "Downloaded $BIN $version and the v$version service units. Install skipped (--dry-run)."
        return 0
    fi

    "$conf/install" "$@"
}

main "$@"
