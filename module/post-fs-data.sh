#!/system/bin/sh
# Prepare /odm payload permissions, SELinux labels, and dynamic Pro-video ISZ config
# before the metamodule (NoMount / OverlayFS / MagicMount) injects system/odm.
MODDIR=${0%/*}
LOG=$MODDIR/bind.log
NM_BIN="/data/adb/modules/nomount/bin/nm"
set -u

log() {
    echo "$1" >> "$LOG"
}

: > "$LOG"
log "begin"

# Release any legacy/soft-reboot bind mounts from this module under /odm/etc/ or /odm/lib64/camera/.
for TARGET in $(awk -v root="${MODDIR#/data}/" 'index($4, root) == 1 && (index($5, "/odm/etc/") == 1 || index($5, "/odm/lib64/camera/") == 1) { print $1, $5 }' /proc/self/mountinfo | sort -rn | cut -d ' ' -f 2); do
    log "release $TARGET"
    umount -l "$TARGET" >> "$LOG" 2>&1 || exit 1
done

# Pro video ISZ (2x main, 6x tele; O-Log2 too): stock sets the ISO gate of rows 25-40 to 0/0,
# which DoIzoomStable() can never pass; -1 means "no ISO check", like the normal video rows.
# Patched from the live file on every boot. Touch $MODDIR/disable_pro_video_isz to skip.
HWCFG=/odm/etc/camera/CameraHWConfiguration.config
HWOUT="$MODDIR/system/odm/etc/camera/CameraHWConfiguration.config"
if [ -f "$MODDIR/disable_pro_video_isz" ]; then
    rm -f "$HWOUT" "$HWOUT.tmp"
    if [ -x "$NM_BIN" ] && "$NM_BIN" version >/dev/null 2>&1; then
        "$NM_BIN" rule del "$HWCFG" >> "$LOG" 2>&1 || true
    fi
    log "pro video isz disabled"
elif [ -f "$HWCFG" ]; then
    if [ -x "$NM_BIN" ] && "$NM_BIN" version >/dev/null 2>&1; then
        "$NM_BIN" rule del "$HWCFG" >> "$LOG" 2>&1 || true
    fi
    mkdir -p "$MODDIR/system/odm/etc/camera"
    awk -F';' -v OFS=';' '
        /^\[/ { section = $0 }
        section == "[InsensorZoom]" && match($0, /^[ \t]*iZoomSettins\[[0-9]+\]/) {
            row = $0; sub(/^[ \t]*iZoomSettins\[/, "", row); sub(/\].*/, "", row)
            if (row + 0 >= 25 && row + 0 <= 40 && NF == 14 && $12 + 0 == 0 && $13 + 0 == 0 && $12 ~ /^[ \t]*0[ \t]*$/ && $13 ~ /^[ \t]*0[ \t]*$/) {
                $12 = "     -1"; $13 = "     -1"; patched++
            }
        }
        { print }
        END { print patched + 0 > "/dev/stderr" }
    ' "$HWCFG" > "$HWOUT.tmp" 2> "$MODDIR/isz_count"
    COUNT=$(cat "$MODDIR/isz_count" 2>/dev/null || echo 0)
    rm -f "$MODDIR/isz_count"
    if [ "$COUNT" = "16" ]; then
        mv -f "$HWOUT.tmp" "$HWOUT"
        log "pro video isz patched (16 rows)"
    else
        rm -f "$HWOUT.tmp" "$HWOUT"
        log "pro video isz skipped, patched rows=$COUNT (expected 16)"
    fi
fi

# Label the entire system/odm tree before metamount.sh runs.
if [ -d "$MODDIR/system/odm" ]; then
    chown -R root:root "$MODDIR/system/odm"
    find "$MODDIR/system/odm" -type d -exec chmod 0755 {} +
    find "$MODDIR/system/odm" -type f -exec chmod 0644 {} +
    if [ -d "$MODDIR/system/odm/etc" ]; then
        find "$MODDIR/system/odm/etc" -exec chcon u:object_r:vendor_configs_file:s0 {} + 2>>"$LOG" || true
    fi
    if [ -d "$MODDIR/system/odm/lib64/camera" ]; then
        chcon u:object_r:vendor_file:s0 "$MODDIR/system/odm/lib64/camera" "$MODDIR/system/odm/lib64/camera/"*.bin 2>>"$LOG" || true
    fi
    if [ -d "$MODDIR/system/odm/lib64" ]; then
        chcon u:object_r:same_process_hal_file:s0 "$MODDIR/system/odm/lib64/"*.so 2>>"$LOG" || true
    fi
fi

log "post-fs-data end"
