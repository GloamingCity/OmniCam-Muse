#!/system/bin/sh
# NoMount verification + non-NoMount / Hybrid Mount fallback.
MODDIR=${0%/*}
LOG=$MODDIR/bind.log
NM_BIN="/data/adb/modules/nomount/bin/nm"
set -u

log() {
    echo "$1" >> "$LOG"
}

is_nomount_running() {
    [ ! -f "$MODDIR/skip_mount" ] || return 1
    [ -x "$NM_BIN" ] || return 1
    [ ! -f /data/adb/modules/nomount/disable ] || return 1
    [ ! -f /data/adb/modules/nomount/remove ] || return 1
    [ ! -f /data/adb/nomount/disable ] || return 1
    if [ -L /data/adb/metamodule ] || [ -e /data/adb/metamodule ]; then
        [ "$(readlink -f /data/adb/metamodule 2>/dev/null)" = "/data/adb/modules/nomount" ] || return 1
    fi
    "$NM_BIN" version >/dev/null 2>&1 || return 1
    "$NM_BIN" rule list 2>/dev/null | grep -qF "ricoh_pop_x9u"
}

bind_library() {
    NAME=$1
    SOURCE="$MODDIR/system/odm/lib64/$NAME"
    TARGET="/odm/lib64/$NAME"
    if [ ! -f "$SOURCE" ] || [ ! -f "$TARGET" ]; then
        log "lib bind skip $TARGET"
        return 0
    fi
    chown root:root "$SOURCE"
    chmod 0644 "$SOURCE"
    chcon u:object_r:same_process_hal_file:s0 "$SOURCE" 2>>"$LOG" || true
    if mount --bind "$SOURCE" "$TARGET" >> "$LOG" 2>&1; then
        log "lib bind ok $TARGET"
    else
        log "lib bind FAIL $TARGET"
    fi
}

bind_file() {
    SOURCE="$1"
    TARGET="$2"
    if [ ! -f "$SOURCE" ]; then
        log "file bind missing $SOURCE"
        return 0
    fi
    chown root:root "$SOURCE"
    chmod 0644 "$SOURCE"
    chcon u:object_r:vendor_configs_file:s0 "$SOURCE" 2>>"$LOG" || true
    if mount --bind "$SOURCE" "$TARGET" >> "$LOG" 2>&1; then
        log "file bind ok $TARGET"
    else
        log "file bind FAIL $TARGET"
    fi
}

label_tree() {
    DIR=$1
    chown -R root:root "$DIR"
    find "$DIR" -type d -exec chmod 0755 {} +
    find "$DIR" -type f -exec chmod 0644 {} +
    find "$DIR" -exec chcon u:object_r:vendor_configs_file:s0 {} + 2>>"$LOG" || true
}

bind_merged_dir() {
    LIVE=$1
    EXTRA=$2
    DEST=$3
    TARGET=$4
    log "merge $TARGET from $LIVE"
    if [ ! -d "$LIVE" ]; then
        log "missing live $LIVE"
        return 0
    fi
    rm -rf "$DEST"
    mkdir -p "$DEST"
    cp -a "$LIVE"/. "$DEST"/
    if [ -d "$EXTRA" ]; then
        cp -a "$EXTRA"/. "$DEST"/
    fi
    label_tree "$DEST"
    log "live_count=$(ls "$LIVE" | wc -l) merged_count=$(ls "$DEST" | wc -l)"
    if mount --bind "$DEST" "$TARGET" >> "$LOG" 2>&1; then
        log "dir bind ok $TARGET"
    else
        log "dir bind FAIL $TARGET"
    fi
}

HWCFG=/odm/etc/camera/CameraHWConfiguration.config
HWOUT="$MODDIR/system/odm/etc/camera/CameraHWConfiguration.config"

if is_nomount_running; then
    # Safety net in case CameraHWConfiguration.config was written after nm module load.
    if [ -f "$HWOUT" ] && ! "$NM_BIN" rule list 2>/dev/null | grep -qF "$HWCFG"; then
        "$NM_BIN" rule add "$HWCFG" "$HWOUT" >> "$LOG" 2>&1 || true
    fi
    log "polaroid=$(ls -l /odm/etc/camera/meishe_lut/polaroid_sdr.mslut 2>&1)"
    log "host_film=$(ls -l /odm/etc/camera/meishe_lut/fuji-nc.bin 2>&1)"
    log "retro_ini=$(ls -l /odm/etc/camera/basictone/setting_Retro/SimTool_Master.ini 2>&1)"
    log "lib_x10=$(ls -l /odm/lib64/libBasicTonePhotoX10.so 2>&1)"
    log "lib_algo=$(ls -l /odm/lib64/libAlgoInterface.so 2>&1)"
    log "post-mount nomount ok"
    exit 0
fi

# Non-NoMount / Hybrid Mount compatibility for the 4 core libraries.
bind_library libBasicTonePhotoX9.so
bind_library libBasicTonePhotoX10.so
bind_library libBasicTonePhoto.so
bind_library libAlgoInterface.so

# Fallback when no metamodule mounted system/odm/etc.
if [ ! -f /odm/etc/camera/meishe_lut/polaroid_sdr.mslut ]; then
    for NAME in camera_unit_config camera_unit_feature_config.protobuf oplus_camera_config oplus_camera_algo_switch_config oplus_camera_aps_config oplus_camera_preview_decision_config.json; do
        bind_file "$MODDIR/system/odm/etc/camera/config/$NAME" "/odm/etc/camera/config/$NAME"
    done
    bind_file "$MODDIR/system/odm/etc/audio/audio_policy_volumes.xml" /odm/etc/audio/audio_policy_volumes.xml
    bind_merged_dir /odm/etc/camera/meishe_lut "$MODDIR/system/odm/etc/camera/meishe_lut" "$MODDIR/merged/meishe_lut" /odm/etc/camera/meishe_lut
    bind_merged_dir /odm/etc/camera/basictone "$MODDIR/system/odm/etc/camera/basictone" "$MODDIR/merged/basictone" /odm/etc/camera/basictone
    for LENS in main wide tele ultratele; do
        NAME="com.qti.tuned.lighthouse${LENS}.bin"
        SOURCE="$MODDIR/system/odm/lib64/camera/$NAME"
        TARGET="/odm/lib64/camera/$NAME"
        chown root:root "$SOURCE"
        chmod 0644 "$SOURCE"
        chcon u:object_r:vendor_file:s0 "$SOURCE" 2>>"$LOG" || true
        if mount --bind "$SOURCE" "$TARGET" >>"$LOG" 2>&1; then
            log "isp bind ok $TARGET"
        else
            log "isp bind FAIL $TARGET"
        fi
    done
    for NAME in gamma_preview_sdr_conf.json gamma_quick_sdr_conf.json gamma_preview_hdr_conf.json; do
        bind_file "$MODDIR/system/odm/etc/camera/$NAME" "/odm/etc/camera/$NAME"
    done
    if [ -f "$HWOUT" ]; then
        bind_file "$HWOUT" "$HWCFG"
    fi
fi

log "post-mount fallback end"
