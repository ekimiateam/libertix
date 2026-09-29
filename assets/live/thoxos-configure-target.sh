#!/bin/bash
# =============================================================================
# assets/live/thoxos-configure-target.sh
#
# ThoxOS brand + desktop layer for a Libertix-installed ThoxOS 26.10
# Workstation. Sourced by configure-target-main.sh from a chroot of the newly
# extracted target root filesystem. There are no positional arguments: every
# input arrives through the environment, exactly like configure-target-main.sh.
#
# Contract
# --------
#   * ThoxOS is a branded Ubuntu 26.10 base, so /etc/os-release keeps
#     ID=ubuntu (Libertix's assert_target_distribution_identity and
#     assert_distribution_rootfs_compatible_or_die both require it). ThoxOS
#     identity is published separately through /etc/thoxos-release plus the
#     PRETTY_NAME/NAME/VERSION branding keys layered on top of os-release.
#   * Nothing here may change the package payload: the distribution rootfs was
#     hash-verified before extraction.
#   * Every step is idempotent so the layer can be re-applied.
#
# Environment (set by configure-target-main.sh / Libertix):
#   THOXOS_LAYER_DIR   staged brand + desktop payload (default /tmp/thoxos-layer)
#   USERNAME           desktop account created by configure_user()
# =============================================================================
set -Eeuo pipefail

THOXOS_LAYER_DIR="${THOXOS_LAYER_DIR:-/tmp/thoxos-layer}"

thoxos_log() {
    printf '[thoxos] %s\n' "$*"
}

THOXOS_REQUIRED_PAYLOAD=(
    "tokens/thoxos-tokens.json"
    "fonts/Xolonium-Regular.otf"
    "fonts/Xolonium-Bold.otf"
    "fonts/OFL.txt"
    "logo/thox-icon.svg"
    "logo/thox-horizontal.svg"
    "logo/thox-wordmark.svg"
    "logo/thox-app-icon-256.png"
    "logo/on-light/thox-horizontal.svg"
    "wallpaper/thoxos-desk-wallpaper.jpg"
)

thoxos_require_layer() {
    local relative
    for relative in "${THOXOS_REQUIRED_PAYLOAD[@]}"; do
        [ -e "$THOXOS_LAYER_DIR/$relative" ] || {
            echo "ThoxOS layer payload is incomplete: $relative" >&2
            return 1
        }
    done
}

# -----------------------------------------------------------------------------
# 1. Product identity: /etc/thoxos-release + os-release branding keys
#
# Branding is derived from the target's own /usr/lib/os-release instead of a
# static file, so the edition always reports the base build it was actually
# extracted from. Only presentation keys are overridden; ID and ID_LIKE stay
# verbatim because Libertix's distribution identity assertions require
# ID=ubuntu for this base. The untouched upstream copy is kept so the branding
# can be re-derived.
# -----------------------------------------------------------------------------
thoxos_branded_os_release() {
    local upstream="/usr/lib/os-release.upstream"

    if [ ! -f "$upstream" ]; then
        cp -f /usr/lib/os-release "$upstream"
        chmod 0644 "$upstream"
    fi

    awk '
        BEGIN {
            override["PRETTY_NAME"] = "\"ThoxOS 26.10 Workstation\""
            override["NAME"]        = "\"ThoxOS\""
            override["HOME_URL"]    = "\"https://thox.ai/\""
            override["SUPPORT_URL"] = "\"https://thox.ai/support\""
            override["BUG_REPORT_URL"] = "\"https://github.com/ttracx/thoxos-ubuntu-26-10/issues\""
            override["PRIVACY_POLICY_URL"] = "\"https://thox.ai/legal/privacy\""
            override["LOGO"]        = "thoxos-logo"
        }
        {
            split($0, parts, "=")
            key = parts[1]
            if (key in override) {
                if (!seen[key]++) print key "=" override[key]
                next
            }
            print
        }
        END {
            print "THOX_EDITION=\"ThoxOS 26.10 Workstation\""
            print "THOX_VARIANT_ID=thoxos-workstation"
            print "THOX_DESKTOP=\"KDE Plasma 6.7\""
            print "THOX_BRAND_GREEN=\"#05a451\""
            print "THOX_UI_FONT=\"Xolonium\""
        }
    ' "$upstream" > /usr/lib/os-release
    chmod 0644 /usr/lib/os-release
}

thoxos_configure_identity() {
    install -d -m 0755 /etc

    thoxos_branded_os_release
    ln -sfn ../usr/lib/os-release /etc/os-release

    # Product identity that is explicitly NOT the distribution identity.
    {
        printf '# ThoxOS edition metadata. The distribution identity remains Ubuntu.\n'
        grep -E '^(PRETTY_NAME|NAME|VERSION|VERSION_ID|VERSION_CODENAME|UBUNTU_CODENAME|THOX_)=' \
            /usr/lib/os-release
    } > /etc/thoxos-release
    chmod 0644 /etc/thoxos-release

    cat > /etc/thoxos-variant <<'EOF'
variant_id=thoxos-workstation
variant_name=ThoxOS 26.10 Workstation
base_distribution=Ubuntu 26.10 (Stonking Stingray)
desktop_environment=KDE Plasma 6.7
brand_green=#05a451
ui_font=Xolonium
EOF
    chmod 0644 /etc/thoxos-variant

    # The branded value must never leak into the identity the installer and the
    # first-boot verifier check.
    [ "$(sed -n 's/^ID=//p' /usr/lib/os-release | head -n1)" = "$DISTRIBUTION_OS_RELEASE_ID" ] || {
        echo "ThoxOS branding changed the os-release identity" >&2
        return 1
    }

    thoxos_log "identity: /etc/thoxos-release written ($(grep -m1 '^PRETTY_NAME' /etc/thoxos-release))"
}

# -----------------------------------------------------------------------------
# 2. Brand typography and marks
#
# The brand faces are installed system-wide for the desktop, the greeter and
# the shell. Fontconfig is refreshed and the family is verified to resolve, so
# a missing or unreadable font fails the installation instead of silently
# falling back at first login.
# -----------------------------------------------------------------------------
thoxos_configure_brand_assets() {
    install -d -m 0755 /usr/local/share/fonts/thoxos
    install -m 0644 "$THOXOS_LAYER_DIR/fonts/Xolonium-Regular.otf" \
        /usr/local/share/fonts/thoxos/Xolonium-Regular.otf
    install -m 0644 "$THOXOS_LAYER_DIR/fonts/Xolonium-Bold.otf" \
        /usr/local/share/fonts/thoxos/Xolonium-Bold.otf
    install -d -m 0755 /usr/share/doc/thoxos-brand/fonts
    install -m 0644 "$THOXOS_LAYER_DIR/fonts/OFL.txt" \
        /usr/share/doc/thoxos-brand/fonts/OFL.txt

    install -d -m 0755 /usr/local/share/thoxos/branding
    install -m 0644 "$THOXOS_LAYER_DIR/logo/thox-icon.svg" \
        /usr/local/share/thoxos/branding/thox-icon.svg
    install -m 0644 "$THOXOS_LAYER_DIR/logo/thox-horizontal.svg" \
        /usr/local/share/thoxos/branding/thox-horizontal.svg
    install -m 0644 "$THOXOS_LAYER_DIR/logo/thox-horizontal.svg" \
        /usr/local/share/thoxos/branding/thox-horizontal-on-dark.svg
    install -m 0644 "$THOXOS_LAYER_DIR/logo/thox-wordmark.svg" \
        /usr/local/share/thoxos/branding/thox-wordmark.svg
    install -m 0644 "$THOXOS_LAYER_DIR/logo/thox-stacked.svg" \
        /usr/local/share/thoxos/branding/thox-stacked.svg
    install -m 0644 "$THOXOS_LAYER_DIR/logo/thox-app-icon.svg" \
        /usr/local/share/thoxos/branding/thox-app-icon.svg
    install -m 0644 "$THOXOS_LAYER_DIR/logo/on-light/thox-horizontal.svg" \
        /usr/local/share/thoxos/branding/thox-horizontal-on-light.svg
    install -m 0644 "$THOXOS_LAYER_DIR/logo/on-light/thox-wordmark.svg" \
        /usr/local/share/thoxos/branding/thox-wordmark-on-light.svg
    install -m 0644 "$THOXOS_LAYER_DIR/logo/thox-app-icon-256.png" \
        /usr/local/share/thoxos/branding/thox-app-icon-256.png

    install -d -m 0755 /usr/share/pixmaps
    install -m 0644 "$THOXOS_LAYER_DIR/logo/thox-app-icon-256.png" /usr/share/pixmaps/thoxos-logo.png
    install -m 0644 "$THOXOS_LAYER_DIR/logo/thox-app-icon-256.png" /usr/share/pixmaps/thoxos.png

    install -d -m 0755 /usr/share/icons/hicolor/128x128/apps
    install -d -m 0755 /usr/share/icons/hicolor/256x256/apps
    install -d -m 0755 /usr/share/icons/hicolor/512x512/apps
    install -m 0644 "$THOXOS_LAYER_DIR/logo/thox-app-icon-128.png" \
        /usr/share/icons/hicolor/128x128/apps/thoxos.png
    install -m 0644 "$THOXOS_LAYER_DIR/logo/thox-app-icon-256.png" \
        /usr/share/icons/hicolor/256x256/apps/thoxos.png
    install -m 0644 "$THOXOS_LAYER_DIR/logo/thox-app-icon-512.png" \
        /usr/share/icons/hicolor/512x512/apps/thoxos.png

    command -v fc-cache >/dev/null 2>&1 || {
        echo "Target distribution does not provide fc-cache" >&2
        return 1
    }
    fc-cache -f >/dev/null

    if command -v fc-match >/dev/null 2>&1; then
        if ! fc-match -f '%{family}\n' Xolonium 2>/dev/null | grep -qi 'xolonium'; then
            echo "ThoxOS brand font Xolonium does not resolve after installation" >&2
            return 1
        fi
    fi
    thoxos_log "brand assets: Xolonium + THOX marks installed and fontconfig verified"
}

# -----------------------------------------------------------------------------
# 3. Desktop branding and welcome content for the interactive account
# -----------------------------------------------------------------------------
thoxos_configure_desktop_defaults() {
    local skel="/etc/skel"
    local home="/home/$USERNAME"
    local target

    for target in "$skel" "$home"; do
        [ -d "$target" ] || continue
        install -d -m 0755 "$target/.config"
        install -d -m 0755 "$target/.local/share"
        install -d -m 0755 "$target/Pictures"
        install -m 0644 "$THOXOS_LAYER_DIR/wallpaper/thoxos-desk-wallpaper.jpg" \
            "$target/Pictures/thoxos-desk-wallpaper.jpg"
    done

    mkdir -p /usr/share/wallpapers/ThoxOS/contents/images
    install -m 0644 "$THOXOS_LAYER_DIR/wallpaper/thoxos-desk-wallpaper.jpg" \
        /usr/share/wallpapers/ThoxOS/contents/images/2560x1600.jpg
    cat > /usr/share/wallpapers/ThoxOS/metadata.json <<'EOF'
{
  "KPlugin": {
    "Id": "ThoxOS",
    "Name": "ThoxOS",
    "Description": "ThoxOS dark Scandinavian wallpaper",
    "Authors": [{ "Name": "THOX.ai", "Email": "tommy@thox.ai" }],
    "License": "Proprietary",
    "Version": "26.10"
  }
}
EOF
    cat > /usr/share/wallpapers/ThoxOS/contents/images/2560x1600.desktop <<'EOF'
[Wallpaper]
Image=2560x1600.jpg
EOF

    [ -d "$home" ] || return 0
    if id "$USERNAME" >/dev/null 2>&1; then
        chown "$USERNAME:$USERNAME" "$home/Pictures" \
            "$home/Pictures/thoxos-desk-wallpaper.jpg"
    fi
    thoxos_log "desktop defaults: wallpaper published to /etc/skel and $home"
}

# -----------------------------------------------------------------------------
# 4. ThoxOS workspace launcher and product documentation
# -----------------------------------------------------------------------------
thoxos_configure_workspace_launcher() {
    install -d -m 0755 /usr/local/bin /usr/local/share/applications

    cat > /usr/local/bin/thoxos-info <<'EOF'
#!/bin/bash
# ThoxOS workstation summary. Read-only: reports what the installation placed.
set -Eeuo pipefail

read_field() {
    local file="$1" key="$2"
    [ -r "$file" ] || return 0
    sed -n "s/^${key}=//p" "$file" | head -n1 | tr -d '"'
}

printf 'ThoxOS        : %s\n' "$(read_field /etc/thoxos-release PRETTY_NAME)"
printf 'Edition       : %s\n' "$(read_field /etc/thoxos-release THOX_EDITION)"
printf 'Base          : %s\n' "$(read_field /etc/thoxos-release THOX_BASE)"
printf 'Desktop       : %s\n' "$(read_field /etc/thoxos-release THOX_DESKTOP)"
printf 'Distribution  : %s / %s\n' \
    "$(read_field /usr/lib/os-release ID)" "$(read_field /usr/lib/os-release VERSION_ID)"
printf 'Brand green   : %s\n' "$(read_field /etc/thoxos-release THOX_BRAND_GREEN)"
printf 'UI font       : %s\n' "$(read_field /etc/thoxos-release THOX_UI_FONT)"
printf 'Telemetry     : none (local-first)\n'
EOF
    chmod 0755 /usr/local/bin/thoxos-info

    cat > /usr/local/share/applications/thoxos-info.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=About ThoxOS
Comment=Show the installed ThoxOS edition, base and brand details
Exec=/usr/local/bin/thoxos-info
Icon=thoxos
Terminal=true
Categories=System;Settings;
EOF

    install -d -m 0755 /usr/local/share/thoxos
    printf '%s\n' 'ThoxOS 26.10 Workstation' > /usr/local/share/thoxos/edition
    thoxos_log "workspace launcher: thoxos-info installed"
}

# -----------------------------------------------------------------------------
# 5. Console identity, issue and message-of-the-day
# -----------------------------------------------------------------------------
thoxos_configure_console_identity() {
    local pretty
    pretty="$(sed -n 's/^PRETTY_NAME=//p' /etc/thoxos-release | head -n1 | tr -d '"')"
    [ -n "$pretty" ] || pretty="ThoxOS 26.10 Workstation"

    cat > /etc/issue <<EOF
$pretty \\n \\l
EOF
    chmod 0644 /etc/issue

    cat > /etc/motd <<EOF

$pretty
Ubuntu 26.10 base with KDE Plasma 6.7, installed alongside Windows by Libertix.

  thoxos-info        edition, base and brand summary
  neofetch           system summary (when installed)

Local-first: this image ships no telemetry and no preloaded cloud credentials.
EOF
    chmod 0644 /etc/motd

    install -d -m 0755 /etc/update-motd.d
    cat > /etc/update-motd.d/90-thoxos <<'EOF'
#!/bin/sh
printf '\n%s\n' "$(sed -n 's/^PRETTY_NAME=//p' /etc/thoxos-release | head -n1 | tr -d '"')"
printf '%s\n' 'Run thoxos-info for edition, base and brand details.'
EOF
    chmod 0755 /etc/update-motd.d/90-thoxos

    thoxos_log "console identity: /etc/issue, /etc/motd and 90-thoxos motd installed"
}

# -----------------------------------------------------------------------------
# 6. First-boot ThoxOS report
#
# The unit writes a result file under /var/lib/thoxos. It never blocks the
# graphical target, so a failure here degrades reporting only.
# -----------------------------------------------------------------------------
thoxos_configure_first_boot_report() {
    install -d -m 0755 /usr/local/sbin
    cat > /usr/local/sbin/thoxos-first-boot-report <<'EOF'
#!/bin/bash
# Record that the ThoxOS desktop layer survived first boot.
set -Eeuo pipefail

result_dir=/var/lib/thoxos
install -d -m 0755 "$result_dir"

{
    echo "status=ok"
    echo "reported_at=$(date -Is 2>/dev/null || date)"
    echo "product=$(sed -n 's/^PRETTY_NAME=//p' /etc/thoxos-release | head -n1 | tr -d '"')"
    echo "base=$(sed -n 's/^THOX_BASE=//p' /etc/thoxos-release | head -n1 | tr -d '"')"
    echo "desktop=$(sed -n 's/^THOX_DESKTOP=//p' /etc/thoxos-release | head -n1 | tr -d '"')"
    echo "os_release_id=$(sed -n 's/^ID=//p' /usr/lib/os-release | head -n1)"
    echo "brand_green=$(sed -n 's/^THOX_BRAND_GREEN=//p' /etc/thoxos-release | head -n1 | tr -d '"')"
    echo "xolonium=$(fc-match -f '%{family}' Xolonium 2>/dev/null || echo unknown)"
} > "$result_dir/first-boot-result.txt"
sync "$result_dir" 2>/dev/null || true
EOF
    chmod 0755 /usr/local/sbin/thoxos-first-boot-report

    install -d -m 0755 /etc/systemd/system
    cat > /etc/systemd/system/thoxos-first-boot-report.service <<'EOF'
[Unit]
Description=ThoxOS first-boot brand report
After=local-fs.target
ConditionPathExists=!/var/lib/thoxos/first-boot-result.txt

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/thoxos-first-boot-report
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable thoxos-first-boot-report.service >/dev/null 2>&1 || {
            echo "ThoxOS first-boot report service could not be enabled" >&2
            return 1
        }
    fi
    thoxos_log "first-boot report: thoxos-first-boot-report.service enabled"
}

thoxos_configure_target() {
    thoxos_require_layer
    thoxos_configure_identity
    thoxos_configure_brand_assets
    thoxos_configure_desktop_defaults
    thoxos_configure_workspace_launcher
    thoxos_configure_console_identity
    thoxos_configure_first_boot_report
    thoxos_log "brand layer complete"
}
