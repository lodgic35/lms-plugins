#!/bin/sh
# lms_watchdog.sh - Monitors LMS and restarts/reboots if unresponsive
#
# INSTALLATION:
# 1. Copy to /usr/local/sbin/lms_watchdog.sh
# 2. Make executable: chmod +x /usr/local/sbin/lms_watchdog.sh
# 3. Add to /opt/bootlocal.sh:
#    /usr/local/sbin/lms_watchdog.sh &
# 4. Run: pcp bu  (backup so it survives reboot)

LMS_HOST="127.0.0.1"
LMS_PORT="9000"
CHECK_INTERVAL=30       # seconds between checks
FAIL_THRESHOLD=2        # consecutive failures before restart (~1 min)
REBOOT_THRESHOLD=2      # restart attempts before reboot
LOG_FILE="/mnt/mmcblk0p2/tce/lms_watchdog.log"
MAX_LOG_SIZE=102400     # 100KB max log before rotation
PID_FILE="/mnt/mmcblk0p2/tce/lms_watchdog.pid"
LMS_INIT="/usr/local/etc/init.d/slimserver"

echo $$ > "$PID_FILE"

fail_count=0
restart_count=0

log() {
    if [ -f "$LOG_FILE" ] && [ $(wc -c < "$LOG_FILE" 2>/dev/null || echo 0) -gt $MAX_LOG_SIZE ]; then
        mv "$LOG_FILE" "${LOG_FILE}.old"
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1"
}

is_lms_running() {
    wget -q --timeout=5 --tries=1 -O /dev/null "http://$LMS_HOST:$LMS_PORT/" 2>/dev/null
    return $?
}

restart_lms() {
    log "Stopping LMS..."
    $LMS_INIT stop 2>/dev/null
    sleep 5
    log "Starting LMS..."
    $LMS_INIT start 2>/dev/null
    log "LMS restart issued - waiting 45s for startup..."
    sleep 45
}

log "========================================"
log "LMS Watchdog started (PID: $$)"
log "Checking http://$LMS_HOST:$LMS_PORT every ${CHECK_INTERVAL}s"
log "Restart after $FAIL_THRESHOLD failures, reboot after $REBOOT_THRESHOLD restarts"
log "========================================"

# Wait on boot for LMS to start up
log "Waiting 90s for initial LMS startup..."
sleep 90

log "Monitoring started"

while true; do
    if is_lms_running; then
        if [ $fail_count -gt 0 ]; then
            log "LMS is responding again - resetting counters"
        fi
        fail_count=0
        restart_count=0
    else
        fail_count=$((fail_count + 1))
        log "LMS not responding (failure $fail_count of $FAIL_THRESHOLD)"

        if [ $fail_count -ge $FAIL_THRESHOLD ]; then
            restart_count=$((restart_count + 1))
            log "--- Restart attempt $restart_count of $REBOOT_THRESHOLD ---"

            if [ $restart_count -ge $REBOOT_THRESHOLD ]; then
                log "!!! REBOOT THRESHOLD REACHED - rebooting piCorePlayer !!!"
                sleep 2
                /sbin/reboot
                exit 0
            fi

            restart_lms
            fail_count=0

            if is_lms_running; then
                log "LMS restart successful - back online"
                restart_count=0
            else
                log "LMS still not responding after restart"
                fail_count=$FAIL_THRESHOLD
            fi
        fi
    fi

    sleep $CHECK_INTERVAL
done
