if [ -z "$HAMMER_ROOT" ]; then
    echo "Error: HAMMER_ROOT is not defined." >&2
    exit 1
fi

IFR="$HAMMER_ROOT/backup.ifr"

# ----------------------------------------------------------------------------
# Guard: backup.ifr embeds the board serial of the GPU it was captured from.
# Flashing it onto a different board would overwrite that board's InfoROM
# identity and corrupt it. Read the live board serial (driver still loaded)
# and, if a backup.ifr is already present, refuse to flash unless it belongs
# to this GPU. If no backup.ifr exists, we capture this board's own InfoROM
# below, so the flash is a safe restore of what was already there.
# ----------------------------------------------------------------------------
SERIAL="$(nvidia-smi --query-gpu=serial --format=csv,noheader,nounits 2>/dev/null | tr -d '[:space:]')"

if [ -f "$IFR" ]; then
    if [ -z "$SERIAL" ] || [ "$SERIAL" = "N/A" ]; then
        echo "Error: could not read this GPU's serial; refusing to flash $IFR." >&2
        echo "       $IFR is board-specific and flashing the wrong board corrupts its InfoROM." >&2
        exit 1
    fi
    if ! strings "$IFR" | grep -qF "$SERIAL"; then
        echo "Error: $IFR does not belong to this GPU (serial $SERIAL)." >&2
        echo "       This InfoROM image was captured from a different board; flashing it" >&2
        echo "       here would corrupt this GPU's InfoROM. Remove backup.ifr to capture" >&2
        echo "       this board's own InfoROM instead." >&2
        exit 1
    fi
fi

cd nvflash/x64
sudo rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia

# If no backup.ifr is present (e.g. the board-specific image was not shipped),
# offer to capture this board's own InfoROM before doing anything else, rather
# than backing up automatically. Either way we exit without flashing, since
# there is no board-specific image to restore.
if [ ! -f "$IFR" ]; then
    echo "No backup.ifr found for this GPU (serial ${SERIAL:-unknown})."
    echo "This board's own InfoROM can be captured now, both to $IFR and to the"
    echo "embedded InfoROM backup (IB), so it can be restored later."
    read -r -p "Back up this GPU's InfoROM now? [y/N] " reply
    case "$reply" in
        [Yy]|[Yy][Ee][Ss])
            sudo ./nvflash --auto -i0 --save "$IFR"
            sudo ./nvflash --auto -i0 --backupinforom
            echo "Backup complete: $IFR (and embedded IB). Exiting without flashing."
            ;;
        *)
            echo "Skipped backup. Exiting without flashing."
            ;;
    esac
    exit 1
fi

sudo ./nvflash --auto -i0 --flashinforom "$IFR"

sleep 1s
bash $HAMMER_ROOT/util/init_cuda.sh 1800 8000
