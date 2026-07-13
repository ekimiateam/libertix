#!/bin/sh
set -eu

theme_dir=/usr/share/plymouth/themes/libertix
toram_script=/usr/lib/live/boot/9990-toram-todisk.sh

for required in \
    "$theme_dir/libertix.plymouth" \
    "$theme_dir/libertix.script" \
    "$theme_dir/logo.png" \
    "$toram_script"
do
    [ -f "$required" ] || {
        echo "Missing boot splash input: $required" >&2
        exit 1
    }
done

# Debian live-boot writes rsync's normal progress directly to /dev/console.
# Silence stdout only: rsync errors remain on stderr and therefore visible.
grep -Fq 'rsync -a --progress ${MODULETORAMFILE} ${copyto} 1>/dev/console' "$toram_script"
grep -Fq 'rsync -a --progress ${copyfrom}/* ${copyto} 1>/dev/console' "$toram_script"

sed -i \
    -e '/echo " \* Copying \$MODULETORAMFILE to RAM" 1>\/dev\/console/d' \
    -e '/echo " \* Copying whole medium to RAM" 1>\/dev\/console/d' \
    -e 's@rsync -a --progress ${MODULETORAMFILE} ${copyto} 1>/dev/console@rsync -a ${MODULETORAMFILE} ${copyto} 1>/dev/null@' \
    -e 's@rsync -a --progress ${copyfrom}/\* ${copyto} 1>/dev/console@rsync -a ${copyfrom}/* ${copyto} 1>/dev/null@' \
    "$toram_script"

if grep -Eq 'rsync -a --progress|Copying .* to RAM.*dev/console' "$toram_script"; then
    echo "live-boot toram console progress was not fully disabled" >&2
    exit 1
fi

grep -Fq 'rsync -a ${MODULETORAMFILE} ${copyto} 1>/dev/null' "$toram_script"
grep -Fq 'rsync -a ${copyfrom}/* ${copyto} 1>/dev/null' "$toram_script"

plymouth-set-default-theme libertix
