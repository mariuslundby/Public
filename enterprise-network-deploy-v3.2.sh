#!/bin/bash

# Force execution with bash if not already running in bash
if [ -z "$BASH_VERSION" ]; then
    exec /bin/bash "$0" "$@"
fi

set -o pipefail

SCRIPT_VERSION="3.0.0"
TEST_MODE=false

if [[ "$1" == "--test" ]]; then
    TEST_MODE=true
    echo "=== TEST MODE ENABLED ==="
    echo "No changes will be made to the system"
    echo ""
fi

# ─────────────────────────────────────────────
# AWK-deteksjon – kompatibel med Fedora 40/42+
# ─────────────────────────────────────────────

AWK=""
if command -v awk &>/dev/null; then
    AWK="awk"
elif command -v gawk &>/dev/null; then
    AWK="gawk"
elif command -v mawk &>/dev/null; then
    AWK="mawk"
elif command -v nawk &>/dev/null; then
    AWK="nawk"
else
    echo "[ERROR] Ingen awk-implementasjon funnet (awk/gawk/mawk/nawk)"
    echo "        Installer med: sudo dnf install -y gawk"
    exit 1
fi


SCEP_URL="https://ndesscep-indranavia.msappproxy.net/certsrv/mscep/mscep.dll"
CA_NAME="NDES"
DOMAIN_SUFFIX="ad.indra.no"

CERT_BASE_PATH="/etc/pki/802.1x"
MACHINE_CERT="${CERT_BASE_PATH}/machine.crt"
MACHINE_KEY="${CERT_BASE_PATH}/machine.key"
CA_CERT="${CERT_BASE_PATH}/ca-chain.pem"

WIRED_CONNECTION_NAME="Wired-802.1x"
WIRED_INTERFACES=""  # initialiseres i [7/9]
ACTIVE_WIRED_CONNECTION=""  # initialiseres i [1/9]
ACTIVE_WIFI_CONNECTION=""   # initialiseres i [1/9]
WIRED_PRIORITY=100

WIFI_CONNECTION_NAME="IndraNavia"
WIFI_SSID="IndraNavia"
WIFI_PRIORITY=50

EAP_METHOD="tls"

EXISTING_FALLBACK_PRIORITY=5
OLD_INDRA_PRIORITY=1

LOG_FILE="/var/log/enterprise-network-deployment.log"
STATE_FILE="/tmp/enterprise-deployment-state.$$"
ROLLBACK_LOG="/var/log/enterprise-network-rollback.log"

# Temp cert paths
TMP_BUNDLE="/tmp/ndes-ca-bundle.crt"
TMP_RA="/tmp/ndes-ra.crt"
TMP_CA_CHAIN="/tmp/ndes-ca-chain.crt"

# ─────────────────────────────────────────────
# Logging helpers
# ─────────────────────────────────────────────

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    echo "[LOG] $1"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >> "$LOG_FILE"
    echo "[ERROR] $1" >&2
}

log_section() {
    echo "" >> "$LOG_FILE"
    echo "==========================================" >> "$LOG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    echo "==========================================" >> "$LOG_FILE"
    echo ""
    echo "=== $1 ==="
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $1" >> "$LOG_FILE"
    echo "[WARN] $1"
}

log_success() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ $1" >> "$LOG_FILE"
    echo "[✓] $1"
}

log_debug() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: $1" >> "$LOG_FILE"
}

record_state() {
    echo "$1" >> "$STATE_FILE"
    log_debug "Rollback point: $1"
}

# ─────────────────────────────────────────────
# Rollback
# ─────────────────────────────────────────────

rollback() {
    if [ ! -f "$STATE_FILE" ]; then
        return
    fi

    log_error "Deployment failed - initiating rollback..."
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] === ROLLBACK STARTED ===" >> "$ROLLBACK_LOG"

    local ROLLBACK_SUCCESS=true

    while IFS= read -r action; do
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Processing: $action" >> "$ROLLBACK_LOG"

        case "$action" in
            CERT_REQUESTED:*)
                REQ_ID="${action#CERT_REQUESTED:}"
                log "Rolling back certificate request: $REQ_ID"
                if getcert stop-tracking -i "$REQ_ID" 2>/dev/null; then
                    echo "  ✓ Removed certificate tracking: $REQ_ID" >> "$ROLLBACK_LOG"
                else
                    echo "  ✗ Failed to remove certificate tracking: $REQ_ID" >> "$ROLLBACK_LOG"
                    ROLLBACK_SUCCESS=false
                fi
                ;;
            CONNECTION_CREATED:*)
                CONN_NAME="${action#CONNECTION_CREATED:}"
                log "Rolling back connection: $CONN_NAME"
                if nmcli connection delete "$CONN_NAME" 2>/dev/null; then
                    echo "  ✓ Deleted connection: $CONN_NAME" >> "$ROLLBACK_LOG"
                else
                    echo "  ✗ Failed to delete connection: $CONN_NAME" >> "$ROLLBACK_LOG"
                    ROLLBACK_SUCCESS=false
                fi
                ;;
            FILE_MODIFIED:*)
                FILE_PATH="${action#FILE_MODIFIED:}"
                if [ -f "${FILE_PATH}.backup-rollback" ]; then
                    log "Restoring file: $FILE_PATH"
                    if mv "${FILE_PATH}.backup-rollback" "$FILE_PATH"; then
                        echo "  ✓ Restored file: $FILE_PATH" >> "$ROLLBACK_LOG"
                    else
                        echo "  ✗ Failed to restore file: $FILE_PATH" >> "$ROLLBACK_LOG"
                        ROLLBACK_SUCCESS=false
                    fi
                fi
                ;;
            CA_ADDED:*)
                CA_TO_REMOVE="${action#CA_ADDED:}"
                log "Rolling back CA: $CA_TO_REMOVE"
                if getcert remove-ca -c "$CA_TO_REMOVE" 2>/dev/null; then
                    echo "  ✓ Removed CA: $CA_TO_REMOVE" >> "$ROLLBACK_LOG"
                else
                    echo "  ✗ Failed to remove CA: $CA_TO_REMOVE" >> "$ROLLBACK_LOG"
                    ROLLBACK_SUCCESS=false
                fi
                ;;
        esac
    done < "$STATE_FILE"

    rm -f "$STATE_FILE"

    if [ "$ROLLBACK_SUCCESS" = true ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] === ROLLBACK COMPLETED SUCCESSFULLY ===" >> "$ROLLBACK_LOG"
        log_error "Rollback complete. Check logs: $LOG_FILE and $ROLLBACK_LOG"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] === ROLLBACK COMPLETED WITH ERRORS ===" >> "$ROLLBACK_LOG"
        log_error "Rollback completed with errors. Manual cleanup may be required. Check: $ROLLBACK_LOG"
    fi
}

safe_execute() {
    local description="$1"
    local command="$2"
    local critical="${3:-true}"

    log_debug "Executing: $description"

    if [ "$TEST_MODE" = true ]; then
        log "[TEST] Would execute: $description"
        return 0
    fi

    if eval "$command" >> "$LOG_FILE" 2>&1; then
        log_success "$description"
        return 0
    else
        local exit_code=$?
        log_error "$description failed (exit code: $exit_code)"

        if [ "$critical" = true ]; then
            log_error "Critical failure - aborting"
            return 1
        else
            log_warn "Non-critical failure - continuing"
            return 0
        fi
    fi
}

cleanup_on_exit() {
    EXIT_CODE=$?

    if [ $EXIT_CODE -ne 0 ] && [ "$TEST_MODE" = false ]; then
        log_error "Script exited with code: $EXIT_CODE"
        rollback
        echo "FAILED: Deployment failed on $(hostname). Check log: $LOG_FILE" >&2
    else
        rm -f "$STATE_FILE"
        if [ "$TEST_MODE" = true ]; then
            echo ""
            echo "=== TEST MODE COMPLETED ==="
            echo "No actual changes were made"
        fi
    fi
}

trap cleanup_on_exit EXIT

# ─────────────────────────────────────────────
# SCEP CA konfigurasjon – v3.0 korrekt RA/CA-splitting
# ─────────────────────────────────────────────

configure_scep_ca() {
    log "Configuring SCEP CA: $CA_NAME (v3.0 – korrekt RA/CA-splitting)"

    # Fjern gammel CA hvis den finnes
    if getcert list-cas 2>/dev/null | grep -q "^CA '$CA_NAME'"; then
        log "Removing existing CA configuration..."
        getcert remove-ca -c "$CA_NAME" 2>/dev/null || true
        sleep 3
    fi

    # Finn SCEP-helper
    local SCEP_HELPER=""
    if [ -f /usr/libexec/certmonger/scep-submit ]; then
        SCEP_HELPER="/usr/libexec/certmonger/scep-submit"
    elif [ -f /usr/lib/certmonger/scep-submit ]; then
        SCEP_HELPER="/usr/lib/certmonger/scep-submit"
    else
        log_error "SCEP helper (scep-submit) not found"
        return 1
    fi

    log "SCEP helper: $SCEP_HELPER"

    # ── Steg 1: Last ned CA-bundle fra NDES ──────────────────────────────────

    log "--- Steg 1: Last ned CA-bundle ---"
    rm -f "$TMP_BUNDLE" "$TMP_RA" "$TMP_CA_CHAIN" /tmp/ndes-cert-* 2>/dev/null

    log "Forsøker scep-submit -C ..."
    SCEP_SUBMIT_OUT=$(timeout 30 "$SCEP_HELPER" -u "$SCEP_URL" -C "$TMP_BUNDLE" 2>&1)
    SCEP_SUBMIT_EXIT=$?
    echo "$SCEP_SUBMIT_OUT" | tee -a "$LOG_FILE"
    if [ $SCEP_SUBMIT_EXIT -eq 0 ] && [ -s "$TMP_BUNDLE" ]; then
        CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" "$TMP_BUNDLE" 2>/dev/null || true); CERT_COUNT=${CERT_COUNT:-0}
        log_success "Lastet ned CA-bundle via scep-submit: $CERT_COUNT sertifikater"
    else
        log_warn "scep-submit feilet eller returnerte tom fil (exit: $SCEP_SUBMIT_EXIT)"
        rm -f "$TMP_BUNDLE"
    fi

    # Fallback: GetCACert via curl
    if [ ! -s "$TMP_BUNDLE" ]; then
        log "Fallback: GetCACert via curl..."
        local GETCACERT_URL="${SCEP_URL}?operation=GetCACert&message=CA"

        if timeout 30 curl -k -s "$GETCACERT_URL" -o /tmp/ndes-ca.p7b 2>/dev/null && [ -s /tmp/ndes-ca.p7b ]; then
            openssl pkcs7 -in /tmp/ndes-ca.p7b -inform DER -print_certs -out "$TMP_BUNDLE" 2>/dev/null
            if [ -s "$TMP_BUNDLE" ]; then
                CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" "$TMP_BUNDLE" 2>/dev/null || true); CERT_COUNT=${CERT_COUNT:-0}
                log_success "Lastet ned CA-bundle via GetCACert: $CERT_COUNT sertifikater"
            fi
        fi
    fi

    if [ ! -s "$TMP_BUNDLE" ]; then
        log_error "Klarte ikke laste ned CA-bundle fra NDES"
        return 1
    fi

    # ── Steg 2: Split bundle i RA-cert og CA-chain ───────────────────────────
    #
    # NDES-bundle struktur (bekreftet fra logg):
    #   Cert 1: RA-sertifikat (INADC01-MSCEP-RA)   → -r flagg
    #   Cert 2: Root CA (Indra Root CA)              → -R flagg (CA-chain)
    #   Cert 3: Andre RA-cert (EnrollmentAgentOffline) → -R flagg
    #   Cert 4: Enterprise CA                        → -R flagg (CA-chain)

    log "--- Steg 2: Split RA-cert og CA-chain ---"

    # Bruk csplit til å dele på hver BEGIN CERTIFICATE
    csplit -s -f /tmp/ndes-cert- "$TMP_BUNDLE" \
        '/-----BEGIN CERTIFICATE-----/' '{*}' 2>/dev/null

    # Tell antall genererte filer
    SPLIT_FILES=(/tmp/ndes-cert-*)
    VALID_CERTS=()

    for f in "${SPLIT_FILES[@]}"; do
        # csplit lager en tom fil som første output (før første match)
        # Vi filtrerer ut filer uten sertifikatinnhold
        if [ -s "$f" ] && grep -q "BEGIN CERTIFICATE" "$f"; then
            VALID_CERTS+=("$f")
        fi
    done

    log "Fant ${#VALID_CERTS[@]} gyldige sertifikater etter splitting"

    if [ ${#VALID_CERTS[@]} -lt 2 ]; then
        log_warn "Færre enn 2 sertifikater – bruker hele bundle som både -R og -r"
        cp "$TMP_BUNDLE" "$TMP_RA"
        cp "$TMP_BUNDLE" "$TMP_CA_CHAIN"
    else
        # Første cert = RA-sertifikat
        cp "${VALID_CERTS[0]}" "$TMP_RA"

        # Resten = CA-chain
        > "$TMP_CA_CHAIN"
        for i in "${!VALID_CERTS[@]}"; do
            if [ $i -gt 0 ]; then
                cat "${VALID_CERTS[$i]}" >> "$TMP_CA_CHAIN"
            fi
        done

        # Valider RA-cert
        RA_SUBJECT=$(openssl x509 -in "$TMP_RA" -noout -subject 2>/dev/null | sed 's/subject=//')
        RA_EXPIRES=$(openssl x509 -in "$TMP_RA" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
        log_success "RA-sertifikat: $RA_SUBJECT"
        log "  Utløper: $RA_EXPIRES"

        CA_CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" "$TMP_CA_CHAIN" 2>/dev/null || true); CA_CERT_COUNT=${CA_CERT_COUNT:-0}
        log_success "CA-chain: $CA_CERT_COUNT sertifikater"
    fi

    # ── Steg 3: Installer i system trust store ───────────────────────────────

    log "--- Steg 3: Installer i system trust store ---"

    if [ -d /etc/pki/ca-trust/source/anchors ]; then
        cp "$TMP_CA_CHAIN" /etc/pki/ca-trust/source/anchors/ndes-ca-chain.crt
        cp "$TMP_RA"       /etc/pki/ca-trust/source/anchors/ndes-ra.crt
        update-ca-trust extract 2>&1 | head -5
        log_success "Installert i trust store (Fedora/RHEL/Rocky)"
    elif [ -d /usr/local/share/ca-certificates ]; then
        cp "$TMP_CA_CHAIN" /usr/local/share/ca-certificates/ndes-ca-chain.crt
        cp "$TMP_RA"       /usr/local/share/ca-certificates/ndes-ra.crt
        update-ca-certificates 2>&1 | head -5
        log_success "Installert i trust store (Debian/Ubuntu)"
    fi

    sleep 5

    # ── Steg 4: Legg til SCEP CA i certmonger ────────────────────────────────

    log "--- Steg 4: Legg til SCEP CA i certmonger ---"

    # Metode 1: Med korrekte -R (CA-chain) og -r (RA) flagg
    log "Metode 1: getcert add-scep-ca med -R og -r flagg..."
    SCEP_OUT=$(getcert add-scep-ca \
        -c "$CA_NAME" \
        -u "$SCEP_URL" \
        -R "$TMP_CA_CHAIN" \
        -r "$TMP_RA" 2>&1)
    echo "$SCEP_OUT" | tee -a "$LOG_FILE"

    sleep 10

    if getcert list-cas 2>/dev/null | grep -q "^CA '$CA_NAME'"; then
        log_success "CA '$CA_NAME' lagt til (metode 1)"
        getcert list-cas -c "$CA_NAME" 2>&1 | tee -a "$LOG_FILE"
        record_state "CA_ADDED:$CA_NAME"
        sleep 5
        return 0
    fi

    # Metode 2: Hele bundle som -R, første cert som -r
    log_warn "Metode 1 feilet – prøver metode 2 (bundle som -R)..."
    getcert remove-ca -c "$CA_NAME" 2>/dev/null || true
    sleep 3

    SCEP_OUT=$(getcert add-scep-ca \
        -c "$CA_NAME" \
        -u "$SCEP_URL" \
        -R "$TMP_BUNDLE" \
        -r "$TMP_RA" 2>&1)
    echo "$SCEP_OUT" | tee -a "$LOG_FILE"

    sleep 10

    if getcert list-cas 2>/dev/null | grep -q "^CA '$CA_NAME'"; then
        log_success "CA '$CA_NAME' lagt til (metode 2)"
        getcert list-cas -c "$CA_NAME" 2>&1 | tee -a "$LOG_FILE"
        record_state "CA_ADDED:$CA_NAME"
        sleep 5
        return 0
    fi

    # Metode 3: Kun -R (hele bundle), ingen -r
    log_warn "Metode 2 feilet – prøver metode 3 (kun -R)..."
    getcert remove-ca -c "$CA_NAME" 2>/dev/null || true
    sleep 3

    SCEP_OUT=$(getcert add-scep-ca \
        -c "$CA_NAME" \
        -u "$SCEP_URL" \
        -R "$TMP_BUNDLE" 2>&1)
    echo "$SCEP_OUT" | tee -a "$LOG_FILE"

    sleep 10

    if getcert list-cas 2>/dev/null | grep -q "^CA '$CA_NAME'"; then
        log_success "CA '$CA_NAME' lagt til (metode 3)"
        getcert list-cas -c "$CA_NAME" 2>&1 | tee -a "$LOG_FILE"
        record_state "CA_ADDED:$CA_NAME"
        sleep 5
        return 0
    fi

    log_error "Alle metoder for add-scep-ca feilet"
    log_error "CA-liste:"
    getcert list-cas 2>&1 | tee -a "$LOG_FILE"
    return 1
}

# ─────────────────────────────────────────────
# Pre-flight checks
# ─────────────────────────────────────────────

preflight_checks() {
    log_section "Pre-flight Checks"

    local CHECKS_PASSED=true

    log "Testing SCEP URL connectivity..."
    if [ "$TEST_MODE" = true ]; then
        log "[TEST] Would test: $SCEP_URL"
    else
        if timeout 15 curl -k -I --connect-timeout 10 "$SCEP_URL" &>/dev/null; then
            log_success "SCEP URL reachable: $SCEP_URL"
        else
            log_error "Cannot reach SCEP URL: $SCEP_URL"
            CHECKS_PASSED=false
        fi
    fi

    log "Checking disk space..."
    AVAILABLE_KB=$(df /etc 2>/dev/null | $AWK 'NR==2 {print $4}' || echo "0")
    if [ "$AVAILABLE_KB" -gt 10240 ]; then
        log_success "Sufficient disk space: ${AVAILABLE_KB}KB available"
    else
        log_error "Insufficient disk space: ${AVAILABLE_KB}KB (need 10MB+)"
        CHECKS_PASSED=false
    fi

    log "Testing DNS resolution..."
    NDES_HOST=$(echo "$SCEP_URL" | sed 's|https://||;s|/.*||')
    if [ "$TEST_MODE" = true ]; then
        log "[TEST] Would test DNS for: $NDES_HOST"
    else
        if timeout 5 host "$NDES_HOST" &>/dev/null; then
            log_success "DNS resolution works for: $NDES_HOST"
        else
            log_warn "DNS resolution failed for: $NDES_HOST (may be expected)"
        fi
    fi

    if [ "$EUID" -eq 0 ]; then
        log_success "Running as root"
    else
        log_error "Must run as root"
        CHECKS_PASSED=false
    fi

    if command -v nmcli &>/dev/null; then
        log_success "NetworkManager available"
    else
        log "NetworkManager not installed (will be installed)"
    fi

    log_success "AWK implementasjon: $AWK"

    if [ "$CHECKS_PASSED" = false ] && [ "$TEST_MODE" = false ]; then
        log_error "Pre-flight checks FAILED"
        exit 1
    else
        log_success "All pre-flight checks PASSED"
    fi
}

# ─────────────────────────────────────────────
# Post-deployment verification
# ─────────────────────────────────────────────

verify_deployment() {
    log_section "Post-Deployment Verification"

    local VERIFY_PASSED=true

    if [ "$TEST_MODE" = true ]; then
        log "[TEST] Would verify certificate, certmonger tracking, and NM connections"
        log_success "Test mode verification complete"
        return 0
    fi

    log "Verifying certificate..."
    if [ -f "$MACHINE_CERT" ] && [ -f "$MACHINE_KEY" ]; then
        if timeout 5 openssl x509 -in "$MACHINE_CERT" -noout -checkend 86400 &>/dev/null; then
            log_success "Certificate valid and not expiring within 24h"
            CERT_SUBJECT=$(openssl x509 -in "$MACHINE_CERT" -noout -subject | sed 's/subject=//')
            CERT_EXPIRES=$(openssl x509 -in "$MACHINE_CERT" -noout -enddate | sed 's/notAfter=//')
            log "  Subject: $CERT_SUBJECT"
            log "  Expires: $CERT_EXPIRES"
        else
            log_error "Certificate invalid or expiring soon"
            VERIFY_PASSED=false
        fi
    else
        log_error "Certificate files missing"
        VERIFY_PASSED=false
    fi

    log "Verifying certmonger tracking..."
    REQUEST_ID="enterprise-8021x-${HOSTNAME}"
    if getcert list -i "$REQUEST_ID" 2>/dev/null | grep -q "status: MONITORING"; then
        log_success "Certmonger tracking active: $REQUEST_ID"
    else
        log_error "Certmonger not tracking certificate"
        getcert list -i "$REQUEST_ID" 2>/dev/null | tee -a "$LOG_FILE"
        VERIFY_PASSED=false
    fi

    log "Verifying NetworkManager connections..."
    if nmcli connection show "$WIRED_CONNECTION_NAME" &>/dev/null 2>&1; then
        log_success "Wired 802.1x connection exists"
    else
        log_warn "Wired 802.1x connection not created"
    fi

    log "Testing network connectivity..."
    if timeout 3 ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        log_success "Network connectivity OK"
    else
        log_warn "No network connectivity (may be expected if offline)"
    fi

    if [ "$VERIFY_PASSED" = false ]; then
        log_error "Deployment verification FAILED"
        return 1
    else
        log_success "All deployment verifications PASSED"
        return 0
    fi
}

# ─────────────────────────────────────────────
# HOVEDFLYT
# ─────────────────────────────────────────────

log_section "Enterprise Network Deployment Starting"
log "Version: $SCRIPT_VERSION"
log "Test Mode: $TEST_MODE"

if [ "$TEST_MODE" = false ]; then
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
fi

preflight_checks

HOSTNAME=$(hostname -s)
FQDN="${HOSTNAME}.${DOMAIN_SUFFIX}"
log "Hostname: $HOSTNAME"
log "FQDN: $FQDN"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    log "OS: $NAME $VERSION_ID"
else
    log_error "Cannot detect OS"
    exit 1
fi

# ── NetworkManager ────────────────────────────────────────────────────────────

if ! command -v nmcli &>/dev/null; then
    log "NetworkManager not found - installing..."
    if [ "$TEST_MODE" = true ]; then
        log "[TEST] Would install NetworkManager for OS: $OS"
    else
        case "$OS" in
            fedora|rhel|centos|rocky|almalinux)
                safe_execute "Installing NetworkManager" \
                    "dnf install -y NetworkManager NetworkManager-wifi"
                ;;
            debian|ubuntu)
                export DEBIAN_FRONTEND=noninteractive
                safe_execute "Installing NetworkManager" \
                    "apt-get update -qq && apt-get install -y network-manager"
                ;;
            *)
                log_error "Unsupported OS: $OS"
                exit 1
                ;;
        esac
    fi
    log_success "NetworkManager installed"
fi

log "Checking for network management conflicts..."
if [ "$TEST_MODE" = false ]; then
    if systemctl is-active --quiet systemd-networkd; then
        log_warn "systemd-networkd is active - disabling"
        systemctl stop systemd-networkd &>/dev/null || true
        systemctl disable systemd-networkd &>/dev/null || true
        log_success "systemd-networkd disabled"
    fi

    if [ -d /etc/netplan ] && ls /etc/netplan/*.yaml &>/dev/null 2>&1; then
        log_warn "Netplan configuration detected - switching to NetworkManager"
        BACKUP_DIR="/etc/netplan.backup-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        cp /etc/netplan/*.yaml "$BACKUP_DIR/" 2>/dev/null || true
        cat > /etc/netplan/01-network-manager-all.yaml <<'EOF'
network:
  version: 2
  renderer: NetworkManager
EOF
        record_state "FILE_MODIFIED:/etc/netplan/01-network-manager-all.yaml"
        command -v netplan &>/dev/null && netplan apply &>/dev/null || true
        log_success "Netplan configured for NetworkManager"
    fi

    if ! systemctl is-active --quiet NetworkManager; then
        systemctl enable NetworkManager &>/dev/null
        systemctl start NetworkManager
        for i in $(seq 1 30); do
            systemctl is-active --quiet NetworkManager && break
            sleep 1
        done
    fi

    if ! systemctl is-active --quiet NetworkManager; then
        log_error "NetworkManager failed to start"
        exit 1
    fi

    nmcli general status &>/dev/null || { log_error "nmcli not responding"; exit 1; }
    log_success "NetworkManager ready"
fi

# ── [1/9] Detect current network status ──────────────────────────────────────

log_section "[1/9] Detecting Current Network Status"

if [ "$TEST_MODE" = true ]; then
    ACTIVE_CONNECTIONS=""
    ACTIVE_WIRED_CONNECTION=""
    ACTIVE_WIFI_CONNECTION=""
    log "[TEST] Would detect active wired and WiFi connections"
else
    ACTIVE_CONNECTIONS=$(nmcli -t -f NAME,TYPE,DEVICE connection show --active 2>/dev/null || true)

    if [ -n "$ACTIVE_CONNECTIONS" ]; then
        log "Currently active connections:"
        echo "$ACTIVE_CONNECTIONS" | while IFS=: read -r name type device; do
            log "  - $name ($type on $device)"
        done
    else
        log "No active connections"
    fi

    ACTIVE_WIRED_CONNECTION=""
    ACTIVE_WIFI_CONNECTION=""

    ACTIVE_WIRED=$(echo "$ACTIVE_CONNECTIONS" | grep ":ethernet:" | head -1 || true)
    if [ -n "$ACTIVE_WIRED" ]; then
        ACTIVE_WIRED_CONNECTION=$(echo "$ACTIVE_WIRED" | cut -d: -f1)
        log "Active wired: $ACTIVE_WIRED_CONNECTION"
    fi

    ACTIVE_WIFI=$(echo "$ACTIVE_CONNECTIONS" | grep ":wifi:" | head -1 || true)
    if [ -n "$ACTIVE_WIFI" ]; then
        ACTIVE_WIFI_CONNECTION=$(echo "$ACTIVE_WIFI" | cut -d: -f1)
        log "Active WiFi: $ACTIVE_WIFI_CONNECTION"
    fi
fi

# ── [2/9] Install packages ────────────────────────────────────────────────────

log_section "[2/9] Installing Required Packages"

if [ "$TEST_MODE" = true ]; then
    log "[TEST] Would install: certmonger, wpa_supplicant, openssl, curl"
else
    case "$OS" in
        fedora|rhel|centos|rocky|almalinux)
            dnf install -y certmonger NetworkManager wpa_supplicant openssl curl &>/dev/null
            dnf install -y NetworkManager-wifi &>/dev/null || log_warn "WiFi support not available"
            ;;
        debian|ubuntu)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y certmonger network-manager wpasupplicant openssl curl &>/dev/null
            ;;
        *)
            log_error "Unsupported OS: $OS"
            exit 1
            ;;
    esac

    systemctl enable --now certmonger &>/dev/null
    sleep 5
    systemctl restart certmonger
    sleep 5

    if ! getcert list &>/dev/null; then
        log_error "Certmonger not responding"
        exit 1
    fi

    if ! systemctl is-active --quiet certmonger; then
        log_error "Certmonger failed to start"
        exit 1
    fi

    log_success "Certmonger ready"
fi

log_success "Packages installed"

# ── [3/9] SCEP Certificate Enrollment ────────────────────────────────────────

log_section "[3/9] SCEP Certificate Enrollment"

if [ "$TEST_MODE" = true ]; then
    log "[TEST] Would create directory: $CERT_BASE_PATH"
    log "[TEST] Would configure SCEP CA: $CA_NAME (med korrekt RA/CA-splitting)"
    log "[TEST] Would request certificate for: $FQDN"
    log "[TEST] Would wait for certificate enrollment (max 180 sec)"
else
    mkdir -p "$CERT_BASE_PATH"
    chmod 700 "$CERT_BASE_PATH"

    if ! getcert list-cas 2>/dev/null | grep -q "^CA '$CA_NAME'"; then
        if ! configure_scep_ca; then
            log_error "Failed to configure SCEP CA"
            exit 1
        fi
    else
        log "SCEP CA already configured"
    fi

    # Rydd opp gamle forespørsler
    log "Checking for old certificate requests..."
    ALL_REQUESTS=$(getcert list 2>/dev/null | grep "Request ID" | $AWK '{print $3}' | tr -d "'" || true)

    if [ -n "$ALL_REQUESTS" ]; then
        CLEANED_COUNT=0
        while IFS= read -r REQ_ID; do
            [ -z "$REQ_ID" ] && continue
            REQ_CA=$(getcert list -i "$REQ_ID" 2>/dev/null | grep "^[[:space:]]*CA:" | $AWK '{print $2}' || true)
            REQ_SUBJECT=$(getcert list -i "$REQ_ID" 2>/dev/null | grep "^[[:space:]]*subject:" | cut -d: -f2- || true)

            if [[ "$REQ_CA" == "$CA_NAME" ]] && \
               [[ "$REQ_SUBJECT" == *"$HOSTNAME"* || "$REQ_SUBJECT" == *"$FQDN"* ]]; then
                if [[ "$REQ_ID" == "enterprise-8021x-${HOSTNAME}" ]]; then
                    log "  Keeping: $REQ_ID (canonical certificate)"
                    continue
                fi
                log_warn "  Removing old request: $REQ_ID"
                getcert stop-tracking -i "$REQ_ID" 2>/dev/null || true
                CLEANED_COUNT=$((CLEANED_COUNT + 1))
            fi
        done <<< "$ALL_REQUESTS"
        [ "${CLEANED_COUNT:-0}" -gt 0 ] && log_success "Cleaned up $CLEANED_COUNT old request(s)"
    fi

    REQUEST_ID="enterprise-8021x-${HOSTNAME}"
    CERT_ENROLLED=false

    if getcert list -i "$REQUEST_ID" 2>/dev/null | grep -q "status: MONITORING"; then
        if [ -f "$MACHINE_CERT" ] && [ -f "$MACHINE_KEY" ]; then
            log "Certificate already enrolled and valid"
            CERT_ENROLLED=true
        else
            log "Certificate tracking exists but files missing – removing"
            getcert stop-tracking -i "$REQUEST_ID" 2>/dev/null || true
        fi
    fi

    if [ "$CERT_ENROLLED" = false ]; then
        getcert stop-tracking -i "$REQUEST_ID" 2>/dev/null || true
        rm -f "$MACHINE_CERT" "$MACHINE_KEY"

        log "Requesting certificate for: $FQDN"

        getcert request \
            -c "$CA_NAME" \
            -I "$REQUEST_ID" \
            -k "$MACHINE_KEY" \
            -f "$MACHINE_CERT" \
            -N "CN=$FQDN" \
            -D "$FQDN" \
            -r

        record_state "CERT_REQUESTED:$REQUEST_ID"

        log "Waiting for certificate (max 180 sec)..."
        TIMEOUT=180
        ELAPSED=0

        while [ $ELAPSED -lt $TIMEOUT ]; do
            sleep 3
            ELAPSED=$((ELAPSED + 3))

            STATUS=$(getcert list -i "$REQUEST_ID" 2>/dev/null | grep "status:" | $AWK '{print $2}')

            case "$STATUS" in
                MONITORING)
                    log_success "Certificate enrolled successfully!"
                    break
                    ;;
                CA_REJECTED)
                    log_error "Certificate REJECTED by NDES"
                    getcert list -i "$REQUEST_ID" | tee -a "$LOG_FILE"
                    log_error "Sjekk NDES-logger og enrollment-tillatelser"
                    exit 1
                    ;;
                CA_UNREACHABLE)
                    log_error "CA UNREACHABLE"
                    getcert list -i "$REQUEST_ID" | tee -a "$LOG_FILE"
                    exit 1
                    ;;
                CA_UNCONFIGURED)
                    log_error "CA_UNCONFIGURED – RA-sertifikat problem"
                    getcert list -i "$REQUEST_ID" | tee -a "$LOG_FILE"
                    exit 1
                    ;;
                NEED_GUIDANCE|SUBMITTING|WAITING_FOR_CA)
                    ;;
                *)
                    if [ $((ELAPSED % 15)) -eq 0 ]; then
                        log "Status: $STATUS (venter...)"
                    fi
                    ;;
            esac
        done

        if [ "$STATUS" != "MONITORING" ]; then
            log_error "Certificate enrollment timeout. Final status: $STATUS"
            getcert list -i "$REQUEST_ID" | tee -a "$LOG_FILE"
            exit 1
        fi
    fi

    chmod 644 "$MACHINE_CERT"
    chmod 600 "$MACHINE_KEY"

    log "Verifying private key has no passphrase..."
    if openssl rsa -in "$MACHINE_KEY" -check -noout &>/dev/null; then
        log_success "Private key verified (no passphrase)"
    else
        log_error "Private key is not readable or has passphrase"
        exit 1
    fi

    CERT_SUBJECT=$(openssl x509 -in "$MACHINE_CERT" -noout -subject | sed 's/subject=//')
    CERT_EXPIRES=$(openssl x509 -in "$MACHINE_CERT" -noout -enddate | sed 's/notAfter=//')
    log "Certificate: $MACHINE_CERT"
    log "  Subject: $CERT_SUBJECT"
    log "  Expires: $CERT_EXPIRES"
fi

# ── [4/9] Extract CA certificate chain ───────────────────────────────────────

log_section "[4/9] Extracting CA Certificate Chain"

if [ "$TEST_MODE" = true ]; then
    log "[TEST] Would extract CA certificate chain for 802.1x"
else
    if [ ! -f "$CA_CERT" ] || [ ! -s "$CA_CERT" ]; then
        log "Downloading CA certificate for 802.1x..."

        SCEP_GET_CA_URL="${SCEP_URL}?operation=GetCACert&message=0"

        if timeout 30 curl -k -s "$SCEP_GET_CA_URL" -o /tmp/ndes-ca.p7b 2>/dev/null && \
           [ -s /tmp/ndes-ca.p7b ]; then
            openssl pkcs7 -in /tmp/ndes-ca.p7b -inform DER -print_certs -out "$CA_CERT"
        fi

        # Fallback: bruk allerede nedlastet bundle
        if [ ! -s "$CA_CERT" ] && [ -s "$TMP_CA_CHAIN" ]; then
            log_warn "GetCACert feilet – bruker CA-chain fra SCEP-bundle"
            cp "$TMP_CA_CHAIN" "$CA_CERT"
        fi

        if [ ! -s "$CA_CERT" ]; then
            log_error "Failed to extract CA certificates"
            exit 1
        fi

        chmod 644 "$CA_CERT"
        log_success "CA certificate saved for 802.1x"
    else
        log "CA certificate already exists"
    fi
fi

# ── [5/9] Deprioritize old Indra WiFi profiles ───────────────────────────────

log_section "[5/9] Deprioritizing Old Indra WiFi Profiles"

if [ "$TEST_MODE" = true ]; then
    log "[TEST] Would deprioritize old Indra WiFi profiles (priority: $OLD_INDRA_PRIORITY)"
else
    ALL_WIFI_CONNECTIONS=$(nmcli -t -f NAME,TYPE connection show 2>/dev/null | grep ":wifi$" | cut -d: -f1 || true)

    if [ -n "$ALL_WIFI_CONNECTIONS" ]; then
        DEPRIORITIZED_COUNT=0
        while IFS= read -r WIFI_NAME; do
            [ -z "$WIFI_NAME" ] && continue
            WIFI_NAME_LOWER=$(echo "$WIFI_NAME" | tr '[:upper:]' '[:lower:]')

            if [[ "$WIFI_NAME_LOWER" == *"indra"* ]] && [[ "$WIFI_NAME" != "$WIFI_CONNECTION_NAME" ]]; then
                log "  Deprioritizing: $WIFI_NAME"
                nmcli connection modify "$WIFI_NAME" \
                    connection.autoconnect-priority "$OLD_INDRA_PRIORITY" \
                    connection.autoconnect yes 2>/dev/null \
                    && DEPRIORITIZED_COUNT=$((DEPRIORITIZED_COUNT + 1))
            fi
        done <<< "$ALL_WIFI_CONNECTIONS"
        [ "${DEPRIORITIZED_COUNT:-0}" -gt 0 ] && log_success "Deprioritized $DEPRIORITIZED_COUNT old profile(s)"
    fi
fi

# ── [6/9] Preserve existing connections ──────────────────────────────────────

log_section "[6/9] Preserving Existing Connections"

if [ "$TEST_MODE" = true ]; then
    log "[TEST] Would preserve existing connections (priority: $EXISTING_FALLBACK_PRIORITY)"
else
    if [ -n "$ACTIVE_WIRED_CONNECTION" ] && [[ "$ACTIVE_WIRED_CONNECTION" != "$WIRED_CONNECTION_NAME" ]]; then
        log "Preserving: $ACTIVE_WIRED_CONNECTION"
        nmcli connection modify "$ACTIVE_WIRED_CONNECTION" \
            connection.autoconnect-priority "$EXISTING_FALLBACK_PRIORITY" \
            connection.autoconnect true 2>/dev/null || true
    fi

    if [ -n "$ACTIVE_WIFI_CONNECTION" ] && [[ "$ACTIVE_WIFI_CONNECTION" != "$WIFI_CONNECTION_NAME" ]]; then
        log "Preserving: $ACTIVE_WIFI_CONNECTION"
        nmcli connection modify "$ACTIVE_WIFI_CONNECTION" \
            connection.autoconnect-priority "$EXISTING_FALLBACK_PRIORITY" \
            connection.autoconnect yes 2>/dev/null || true
    fi
fi

# ── [7/9] Configure wired 802.1x ─────────────────────────────────────────────

log_section "[7/9] Configuring Wired 802.1x"

if [ "$TEST_MODE" = true ]; then
    log "[TEST] Would create wired 802.1x profile (priority: $WIRED_PRIORITY)"
    log "[TEST] private-key-password-flags: not-required (4)"
else
    WIRED_INTERFACES=$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | grep ethernet | cut -d: -f1 || true)

    if [ -z "$WIRED_INTERFACES" ]; then
        log "No wired interfaces found"
    else
        WIRED_INTERFACE=$(echo "$WIRED_INTERFACES" | head -1)
        log "Using wired interface: $WIRED_INTERFACE"

        SKIP_WIRED_ACTIVATION=false
        if [ -n "$ACTIVE_WIRED_CONNECTION" ] && [[ "$ACTIVE_WIRED_CONNECTION" != "$WIRED_CONNECTION_NAME" ]]; then
            log_warn "Interface active with: $ACTIVE_WIRED_CONNECTION – will not disrupt"
            SKIP_WIRED_ACTIVATION=true
        fi

        if nmcli connection show "$WIRED_CONNECTION_NAME" &>/dev/null; then
            CURRENT_CERT=$(nmcli -t -f 802-1x.client-cert con show "$WIRED_CONNECTION_NAME" 2>/dev/null | cut -d: -f2- || true)
            if [[ "$CURRENT_CERT" == "file://$MACHINE_CERT" ]]; then
                log "Wired 802.1x already configured correctly"
            else
                log "Recreating with updated certificate..."
                nmcli connection delete "$WIRED_CONNECTION_NAME" >> "$LOG_FILE" 2>&1 || true
            fi
        fi

        if ! nmcli connection show "$WIRED_CONNECTION_NAME" &>/dev/null; then
            nmcli connection add \
                type ethernet \
                con-name "$WIRED_CONNECTION_NAME" \
                ifname "$WIRED_INTERFACE" \
                autoconnect yes \
                connection.autoconnect-priority "$WIRED_PRIORITY" \
                802-1x.eap "$EAP_METHOD" \
                802-1x.identity "host/$FQDN" \
                802-1x.client-cert "file://$MACHINE_CERT" \
                802-1x.private-key "file://$MACHINE_KEY" \
                802-1x.private-key-password "" \
                802-1x.private-key-password-flags 4 \
                802-1x.ca-cert "file://$CA_CERT" \
                ipv4.method auto \
                ipv6.method auto >> "$LOG_FILE" 2>&1

            record_state "CONNECTION_CREATED:$WIRED_CONNECTION_NAME"
            log_success "Wired 802.1x configured (private-key-password-flags: not-required)"
        fi

        if [ "$SKIP_WIRED_ACTIVATION" = false ]; then
            if nmcli connection up "$WIRED_CONNECTION_NAME" >> "$LOG_FILE" 2>&1; then
                log_success "Wired 802.1x activated"
            else
                log_warn "Could not activate now – will auto-activate on 802.1x switch"
            fi
        else
            log "Profile ready – will auto-activate on 802.1x network"
        fi
    fi
fi

# ── [7A/9] Ensure ethernet is managed ────────────────────────────────────────

log_section "[7A/9] Ensuring Ethernet is Managed"

if [ "$TEST_MODE" = false ]; then
    if [[ "$OS" == "debian" || "$OS" == "ubuntu" ]] && [ -f /etc/network/interfaces ]; then
        if grep -qE "^[[:space:]]*(auto|allow-hotplug|iface)[[:space:]]+e(ns|th|np)[0-9]" /etc/network/interfaces; then
            log_warn "Ethernet found in /etc/network/interfaces – disabling"
            BACKUP_FILE="/etc/network/interfaces.backup-$(date +%Y%m%d-%H%M%S)"
            cp /etc/network/interfaces "$BACKUP_FILE"
            cp /etc/network/interfaces /etc/network/interfaces.backup-rollback
            record_state "FILE_MODIFIED:/etc/network/interfaces"
            sed -i \
                -e '/^[[:space:]]*\(auto\|allow-hotplug\|iface\)[[:space:]]\+e\(ns\|th\|np\)[0-9]/s/^/# DISABLED: /' \
                /etc/network/interfaces
            systemctl stop networking 2>/dev/null || true
            systemctl restart NetworkManager
            sleep 5
            log_success "Disabled ethernet in /etc/network/interfaces"
        fi
    fi

    if [ -n "$WIRED_INTERFACES" ]; then
        while IFS= read -r WIRED_IF; do
            [ -z "$WIRED_IF" ] && continue
            IF_STATE=$(nmcli -t -f DEVICE,STATE device status 2>/dev/null | grep "^${WIRED_IF}:" | cut -d: -f2 || echo "unknown")
            if [[ "$IF_STATE" == "unmanaged" || "$IF_STATE" == "uhåndteret" ]]; then
                log_warn "Interface $WIRED_IF is unmanaged – fixing"
                nmcli device set "$WIRED_IF" managed yes 2>/dev/null || true
                sleep 3
            fi
        done <<< "$WIRED_INTERFACES"
    fi
fi

# ── [8/9] Configure WiFi ──────────────────────────────────────────────────────

log_section "[8/9] Configuring WiFi"

if [ "$TEST_MODE" = true ]; then
    log "[TEST] Would create IndraNavia 802.1x WiFi profile (priority: $WIFI_PRIORITY)"
    log "[TEST] private-key-password-flags: not-required (4)"
else
    WIFI_INTERFACES=$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | grep wifi | cut -d: -f1 || true)

    if [ -z "$WIFI_INTERFACES" ]; then
        log "No WiFi interfaces found"
    else
        WIFI_INTERFACE=$(echo "$WIFI_INTERFACES" | head -1)
        nmcli radio wifi on &>/dev/null
        sleep 2

        SKIP_WIFI_ACTIVATION=false
        if [ -n "$ACTIVE_WIFI_CONNECTION" ] && [[ "$ACTIVE_WIFI_CONNECTION" != "$WIFI_CONNECTION_NAME" ]]; then
            log_warn "WiFi active with: $ACTIVE_WIFI_CONNECTION – will not disrupt"
            SKIP_WIFI_ACTIVATION=true
        fi

        nmcli device wifi rescan ifname "$WIFI_INTERFACE" &>/dev/null || true
        sleep 3

        SSID_HIDDEN="yes"
        if nmcli device wifi list ifname "$WIFI_INTERFACE" 2>/dev/null | grep -qw "$WIFI_SSID"; then
            SSID_HIDDEN="no"
            log_success "$WIFI_SSID is visible"
        else
            log "$WIFI_SSID not visible (hidden or out of range)"
        fi

        if nmcli connection show "$WIFI_CONNECTION_NAME" &>/dev/null; then
            CURRENT_CERT=$(nmcli -t -f 802-1x.client-cert con show "$WIFI_CONNECTION_NAME" 2>/dev/null | cut -d: -f2- || true)
            if [[ "$CURRENT_CERT" != "file://$MACHINE_CERT" ]]; then
                nmcli connection delete "$WIFI_CONNECTION_NAME" >> "$LOG_FILE" 2>&1 || true
            fi
        fi

        if ! nmcli connection show "$WIFI_CONNECTION_NAME" &>/dev/null; then
            nmcli connection add \
                type wifi \
                con-name "$WIFI_CONNECTION_NAME" \
                ifname "$WIFI_INTERFACE" \
                ssid "$WIFI_SSID" \
                autoconnect yes \
                connection.autoconnect-priority "$WIFI_PRIORITY" \
                wifi.hidden "$SSID_HIDDEN" \
                wifi-sec.key-mgmt wpa-eap \
                802-1x.eap "$EAP_METHOD" \
                802-1x.identity "host/$FQDN" \
                802-1x.client-cert "file://$MACHINE_CERT" \
                802-1x.private-key "file://$MACHINE_KEY" \
                802-1x.private-key-password "" \
                802-1x.private-key-password-flags 4 \
                802-1x.ca-cert "file://$CA_CERT" \
                ipv4.method auto \
                ipv6.method auto >> "$LOG_FILE" 2>&1

            record_state "CONNECTION_CREATED:$WIFI_CONNECTION_NAME"
            log_success "WiFi 802.1x configured (private-key-password-flags: not-required)"
        fi

        if [ "$SKIP_WIFI_ACTIVATION" = false ]; then
            if nmcli connection up "$WIFI_CONNECTION_NAME" >> "$LOG_FILE" 2>&1; then
                log_success "WiFi activated"
            else
                log_warn "Could not activate now – will auto-activate when in range"
            fi
        else
            log "Profile ready – will auto-activate when in range"
        fi
    fi
fi

# ── [9/9] Final verification ──────────────────────────────────────────────────

log_section "[9/9] Final Verification"
verify_deployment

if [ "$TEST_MODE" = false ]; then
    echo ""
    echo "SUCCESS: Enterprise network deployed on $(hostname). Log: $LOG_FILE"
else
    echo ""
    echo "=== TEST MODE SUMMARY ==="
    echo "Script v$SCRIPT_VERSION ville:"
    echo "  - Laste ned NDES CA-bundle (scep-submit eller GetCACert)"
    echo "  - Splitte bundle korrekt: cert[0]=RA (-r), cert[1+]=CA-chain (-R)"
    echo "  - Installere i system trust store"
    echo "  - Kalle getcert add-scep-ca med -R og -r flagg (løser CA_UNCONFIGURED)"
    echo "  - Enrolle maskin-sertifikat for: $FQDN"
    echo "  - Opprette Wired-802.1x profil (prioritet: $WIRED_PRIORITY)"
    echo "  - Opprette IndraNavia WiFi profil (prioritet: $WIFI_PRIORITY)"
    echo "  - Deprioritere gamle Indra-profiler (prioritet: $OLD_INDRA_PRIORITY)"
    echo ""
    echo "  - AWK: $AWK"
    echo ""
    echo "Kjør uten --test for å deploye"
fi
