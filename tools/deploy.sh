#!/usr/bin/env sh
# Build a package from HEAD and install it on a rooted phone over adb.
#
# usage: tools/deploy.sh [adb-serial]
#
# 1. refuses to run with uncommitted changes (the package is `git archive HEAD`)
# 2. on the phone: backs up the installed module and its data to /data/local/tmp/bk-acc-<time>.tgz
#    (not "acc-*" or "acc_*": the project's uninstaller deletes those)
# 3. runs the project's own install.sh, which also keeps a copy for `acc -b` (rollback)
#
# rollback: acc -b   (or restore the bk-acc-*.tgz: tar -xf it into /data/adb, then acc -D restart)

set -eu

cd "$(dirname "$0")/.."

serial=${1-}

adb_() {
  if [ -n "$serial" ]; then adb -s "$serial" "$@"; else adb "$@"; fi
}

[ -z "$(git status --porcelain --untracked-files=no)" ] || {
  echo "uncommitted changes; commit first, the package is built from HEAD" >&2
  exit 1
}

rev=$(git rev-parse --short HEAD)
pkg=fork-pkg-$rev
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

git archive --format=tar --prefix="$pkg/" HEAD | gzip -9 > "$tmp/$pkg.tgz"

cat > "$tmp/device.sh" << 'EOF'
#!/system/bin/sh
# runs as root on the phone
set -eu
tgz=$1
pkg=$2
bk=/data/local/tmp/bk-acc-$(date +%Y%m%d-%H%M%S).tgz

echo "backup: $bk"
tar -cf - -C /data/adb modules/acc vr25/acc-data | gzip -1 > "$bk"
ls -l "$bk"

cd /data/local/tmp
rm -rf "$pkg"
tar -xf "$tgz"

export installDir=
/system/bin/sh "$pkg/install.sh"

echo
echo "installed: $(sed -n 's/^version=//p' /data/adb/modules/acc/module.prop) ($(sed -n 's/^versionCode=//p' /data/adb/modules/acc/module.prop))"
rm -rf "$pkg"
EOF

adb_ push "$tmp/$pkg.tgz" /data/local/tmp/ > /dev/null
adb_ push "$tmp/device.sh" /data/local/tmp/fork-deploy.sh > /dev/null
adb_ shell "su -c 'sh /data/local/tmp/fork-deploy.sh /data/local/tmp/$pkg.tgz $pkg'"
adb_ shell "rm -f /data/local/tmp/fork-deploy.sh /data/local/tmp/$pkg.tgz"
