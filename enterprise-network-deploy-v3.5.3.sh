#!/bin/bash

# Force execution with bash if not already running in bash
if [ -z "$BASH_VERSION" ]; then
    exec /bin/bash "$0" "$@"
fi

set -o pipefail

SCRIPT_VERSION="3.5.3"
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
STATE_FILE="/tmp/enterprise-deployment-state"
ROLLBACK_LOG="/var/log/enterprise-network-rollback.log"

# Temp cert paths (for download/splitting)
TMP_BUNDLE="/tmp/ndes-ca-bundle.crt"
TMP_RA="/tmp/ndes-ra.crt"
TMP_CA_CHAIN="/tmp/ndes-ca-chain.crt"
TMP_RA_ENC="/tmp/ndes-ra-enc.crt"
TMP_RA_COMBINED="/tmp/ndes-ra-combined.crt"

# Persistent cert paths (SELinux-safe, certmonger_var_lib_t)
CERTMONGER_CERT_DIR="/var/lib/certmonger"
PERM_RA_ENC="${CERTMONGER_CERT_DIR}/scep-ra-enc.crt"
PERM_RA_SIGN="${CERTMONGER_CERT_DIR}/scep-ra-sign.crt"
PERM_CA_CHAIN="${CERTMONGER_CERT_DIR}/scep-ca-chain.crt"
PERM_ENTERPRISE_CA="${CERTMONGER_CERT_DIR}/scep-enterprise-ca.crt"
PERM_ALL_CERTS="${CERTMONGER_CERT_DIR}/scep-all-certs.crt"

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
# SHA-1 crypto policy fix for Fedora 42+
# NDES/SCEP signerer med SHA-1 som Fedora 42 blokkerer
# ─────────────────────────────────────────────

ensure_sha1_policy() {
    if command -v update-crypto-policies &>/dev/null; then
        CURRENT_POLICY=$(update-crypto-policies --show 2>/dev/null || echo "DEFAULT")
        if [[ "$CURRENT_POLICY" != *"SHA1"* ]]; then
            # Rocky 9, Fedora 42+ og RHEL 9+ blokkerer SHA-1 PKCS7 signaturer
            # NDES/SCEP bruker SHA-1 → må aktivere SHA1 subpolicy
            log "Crypto policy ($CURRENT_POLICY) mangler SHA1 – aktiverer for SCEP kompatibilitet"
            update-crypto-policies --set "${CURRENT_POLICY}:SHA1" 2>&1 | head -3
            record_state "CRYPTO_POLICY_CHANGED:${CURRENT_POLICY}"
            log_success "Crypto policy endret til ${CURRENT_POLICY}:SHA1"
        else
            log "SHA-1 allerede tillatt i crypto policy"
        fi
    fi
}

# ─────────────────────────────────────────────
# SCEP CA konfigurasjon – v3.4 RA splitting + certmonger intern config
# ─────────────────────────────────────────────

configure_scep_ca() {
    log "Configuring SCEP CA: $CA_NAME (v3.5 – dynamisk RA-cert, system TLS)"

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
    rm -f "$TMP_BUNDLE" "$TMP_RA" "$TMP_RA_ENC" "$TMP_RA_COMBINED" "$TMP_CA_CHAIN" /tmp/ndes-cert-* 2>/dev/null

    log "Forsøker scep-submit -C ..."
    # scep-submit -C skriver PEM-certs til stdout, ikke til fil-argument
    timeout 30 "$SCEP_HELPER" -u "$SCEP_URL" -C > "$TMP_BUNDLE" 2>"$LOG_FILE.scep-err"
    SCEP_SUBMIT_EXIT=$?
    cat "$LOG_FILE.scep-err" >> "$LOG_FILE" 2>/dev/null; rm -f "$LOG_FILE.scep-err"
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
        if [ -s "$f" ] && grep -q "BEGIN CERTIFICATE" "$f"; then
            VALID_CERTS+=("$f")
        fi
    done

    log "Fant ${#VALID_CERTS[@]} gyldige sertifikater etter splitting"

    if [ ${#VALID_CERTS[@]} -lt 2 ]; then
        log_warn "Faerre enn 2 sertifikater – bruker hele bundle som -R og -r"
        cp "$TMP_BUNDLE" "$TMP_RA_COMBINED"
        cp "$TMP_BUNDLE" "$TMP_CA_CHAIN"
        cp "$TMP_BUNDLE" "$TMP_RA"
    else
        # v3.4: Innholdsbasert splitting med separat RA signing/encryption
        # Rekkefølgen i bundle varierer mellom scep-submit og GetCACert.
        #
        # Identifisering:
        #   Basic Constraints CA:TRUE eller "Subject Type=CA" → CA-sertifikat → -R
        #   Key Usage "Digital Signature" (uten Key Encipherment) → RA signing → -r
        #   Key Usage "Key Encipherment" (uten Digital Signature) → RA encryption → -e
        #   Begge Key Usages → RA combined (legges i begge)

        > "$TMP_CA_CHAIN"
        > "$TMP_RA_COMBINED"
        > "$TMP_RA"
        > "$TMP_RA_ENC"
        RA_SIGN_COUNT=0
        RA_ENC_COUNT=0
        CA_COUNT=0

        for cert_file in "${VALID_CERTS[@]}"; do
            CERT_TEXT=$(openssl x509 -in "$cert_file" -noout -text 2>/dev/null)
            SUBJECT=$(echo "$CERT_TEXT" | grep "Subject:" | head -1 | sed 's/.*Subject://' | xargs)

            # Sjekk CA via Basic Constraints (standard: CA:TRUE, MS: Subject Type=CA)
            IS_CA=false
            if echo "$CERT_TEXT" | grep -q "CA:TRUE"; then
                IS_CA=true
            elif echo "$CERT_TEXT" | grep -q "Subject Type=CA"; then
                IS_CA=true
            fi

            if [ "$IS_CA" = true ]; then
                cat "$cert_file" >> "$TMP_CA_CHAIN"
                CA_COUNT=$((CA_COUNT + 1))
                log "  CA-cert  -> CA-chain: $SUBJECT"
            else
                # RA-sertifikat – klassifiser via Key Usage
                KEY_USAGE_LINE=$(echo "$CERT_TEXT" | grep -A1 "X509v3 Key Usage:" | tail -1 | xargs)
                HAS_SIGN=false
                HAS_ENCIPHER=false
                echo "$KEY_USAGE_LINE" | grep -qi "Digital Signature" && HAS_SIGN=true
                echo "$KEY_USAGE_LINE" | grep -qi "Key Encipherment" && HAS_ENCIPHER=true

                # Alltid legges i combined
                cat "$cert_file" >> "$TMP_RA_COMBINED"

                if [ "$HAS_ENCIPHER" = true ]; then
                    # Encryption-cert → dette er det scep-submit trenger for -r
                    cat "$cert_file" >> "$TMP_RA_ENC"
                    RA_ENC_COUNT=$((RA_ENC_COUNT + 1))
                    log "  RA-enc   -> encryption (-r for scep-submit): $SUBJECT [${KEY_USAGE_LINE}]"
                fi

                if [ "$HAS_SIGN" = true ]; then
                    # Signing-cert → -N (signingca) i scep-submit
                    cat "$cert_file" >> "$TMP_RA"
                    RA_SIGN_COUNT=$((RA_SIGN_COUNT + 1))
                    log "  RA-sign  -> signing: $SUBJECT [${KEY_USAGE_LINE}]"
                fi

                if [ "$HAS_SIGN" = false ] && [ "$HAS_ENCIPHER" = false ]; then
                    # Ukjent – legg i begge
                    cat "$cert_file" >> "$TMP_RA"
                    cat "$cert_file" >> "$TMP_RA_ENC"
                    RA_SIGN_COUNT=$((RA_SIGN_COUNT + 1))
                    RA_ENC_COUNT=$((RA_ENC_COUNT + 1))
                    log "  RA-unknown -> begge: $SUBJECT [${KEY_USAGE_LINE}]"
                fi
            fi
        done

        log_success "Splitting ferdig: $CA_COUNT CA, $RA_SIGN_COUNT RA-sign, $RA_ENC_COUNT RA-enc"

        if [ $RA_ENC_COUNT -eq 0 ]; then
            log_warn "Ingen RA encryption-cert funnet – bruker combined som fallback"
            cp "$TMP_RA_COMBINED" "$TMP_RA_ENC"
        fi

        if [ $RA_SIGN_COUNT -eq 0 ]; then
            log_warn "Ingen RA signing-cert funnet – bruker combined som fallback"
            cp "$TMP_RA_COMBINED" "$TMP_RA"
        fi

        if [ $CA_COUNT -eq 0 ]; then
            log_warn "Ingen CA-sertifikater funnet – bruker hele bundle som -R fallback"
            cp "$TMP_BUNDLE" "$TMP_CA_CHAIN"
        fi

        CA_CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" "$TMP_CA_CHAIN" 2>/dev/null || true); CA_CERT_COUNT=${CA_CERT_COUNT:-0}
        RA_CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" "$TMP_RA_COMBINED" 2>/dev/null || true); RA_CERT_COUNT=${RA_CERT_COUNT:-0}
        log_success "CA-chain: $CA_CERT_COUNT sertifikat(er), RA totalt: $RA_CERT_COUNT sertifikat(er)"
    fi

    # ── Steg 3: Installer i system trust store + kopier til persistent sti ─────

    log "--- Steg 3: Installer i trust store + persistent paths ---"

    if [ -d /etc/pki/ca-trust/source/anchors ]; then
        cp "$TMP_CA_CHAIN" /etc/pki/ca-trust/source/anchors/ndes-ca-chain.crt
        [ -s "$TMP_RA_COMBINED" ] && cp "$TMP_RA_COMBINED" /etc/pki/ca-trust/source/anchors/ndes-ra.crt
        update-ca-trust extract 2>&1 | head -5
        log_success "Installert i trust store (Fedora/RHEL/Rocky)"
    elif [ -d /usr/local/share/ca-certificates ]; then
        cp "$TMP_CA_CHAIN" /usr/local/share/ca-certificates/ndes-ca-chain.crt
        [ -s "$TMP_RA_COMBINED" ] && cp "$TMP_RA_COMBINED" /usr/local/share/ca-certificates/ndes-ra.crt
        update-ca-certificates 2>&1 | head -5
        log_success "Installert i trust store (Debian/Ubuntu)"
    fi

    # Kopier til persistent sti for certmonger (SELinux-safe)
    [ -s "$TMP_RA_ENC" ] && cp "$TMP_RA_ENC" "$PERM_RA_ENC"
    [ -s "$TMP_RA" ] && cp "$TMP_RA" "$PERM_RA_SIGN"
    cp "$TMP_CA_CHAIN" "$PERM_CA_CHAIN"

    # Ekstraher Enterprise CA (issuer av RA-certene) for -N flagget
    > "$PERM_ENTERPRISE_CA"
    csplit -s -f /tmp/ca-perm-split- "$TMP_CA_CHAIN" '/-----BEGIN CERTIFICATE-----/' '{*}' 2>/dev/null
    for f in /tmp/ca-perm-split-*; do
        [ -s "$f" ] && grep -q "BEGIN CERTIFICATE" "$f" || continue
        if openssl x509 -in "$f" -noout -subject 2>/dev/null | grep -qi "Enterprise"; then
            cp "$f" "$PERM_ENTERPRISE_CA"
            log "Enterprise CA cert lagret: $(openssl x509 -in "$f" -noout -subject 2>/dev/null)"
        fi
    done
    rm -f /tmp/ca-perm-split-* 2>/dev/null

    # Lag combined fil med alle sertifikater for -I flagget
    cat "$TMP_RA" "$TMP_RA_ENC" "$TMP_CA_CHAIN" > "$PERM_ALL_CERTS" 2>/dev/null

    # Sett SELinux-kontekst
    if command -v chcon &>/dev/null; then
        chcon -t certmonger_var_lib_t "$PERM_RA_ENC" "$PERM_RA_SIGN" "$PERM_CA_CHAIN" "$PERM_ENTERPRISE_CA" "$PERM_ALL_CERTS" 2>/dev/null || true
    fi

    log_success "Persistente cert-filer lagret i $CERTMONGER_CERT_DIR"

    sleep 5

    # ── Steg 4: Legg til SCEP CA i certmonger ────────────────────────────────

    log "--- Steg 4: Legg til SCEP CA i certmonger ---"

    # scep-submit flagg-semantikk (certmonger 0.79.x):
    #   -u = SCEP URL
    #   -N = CA cert that signed the RA cert (signingca) for PKCS7 verification
    #   -I = additional certs for PKCS7 signature verification
    #
    # VIKTIG: IKKE bruk -R (CA cert for TLS) når NDES bruker offentlig TLS-sert
    # (f.eks. msappproxy.net). scep-submit bruker da system CA bundle automatisk.
    # Feil -R fører til SSL error 60 og "encryption_certs server unreachable".
    #
    # VIKTIG: IKKE sett ca_encryption_cert i intern config. certmonger 0.79.x
    # henter RA encryption cert dynamisk via GetCACert (scep-submit -C).
    # Manuell ca_encryption_cert fører til "Error decrypting PKCS#7" og NEED_GUIDANCE.

    CERTMONGER_VER=$(rpm -q certmonger 2>/dev/null || dpkg -l certmonger 2>/dev/null | grep -m1 "^ii" | $AWK '{print $3}' || echo "unknown")
    log "certmonger versjon: $CERTMONGER_VER"

    # Detekter scep-submit capabilities via versjonsnummer
    # CentOS 7 / certmonger 0.78.x støtter kun: -u -c -C -g -p -v
    # Nyere (0.79.x+) støtter også: -R -N -I
    local SCEP_SUPPORTS_R=false
    local CM_MAJOR CM_MINOR
    CM_MAJOR=$(echo "$CERTMONGER_VER" | grep -oP 'certmonger-\K[0-9]+' | head -1)
    CM_MINOR=$(echo "$CERTMONGER_VER" | grep -oP 'certmonger-[0-9]+\.\K[0-9]+' | head -1)
    if [ -n "$CM_MAJOR" ] && [ -n "$CM_MINOR" ]; then
        if [ "$CM_MAJOR" -gt 0 ] || [ "$CM_MINOR" -ge 79 ]; then
            SCEP_SUPPORTS_R=true
        fi
    else
        # Kan ikke parse versjon – test med faktisk kall
        if "$SCEP_HELPER" -u "https://test" -R /dev/null 2>&1 | grep -q "Usage:"; then
            SCEP_SUPPORTS_R=false
        else
            SCEP_SUPPORTS_R=true
        fi
    fi
    log "scep-submit støtter -R flag: $SCEP_SUPPORTS_R"

    # Bygg scep-submit kommandolinje
    local SYSTEM_CA_BUNDLE="/etc/pki/tls/certs/ca-bundle.crt"
    [ ! -f "$SYSTEM_CA_BUNDLE" ] && SYSTEM_CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"

    if [ "$SCEP_SUPPORTS_R" = true ]; then
        # Nyere certmonger: -R for TLS verification via system CA bundle
        SCEP_HELPER_ARGS="-u $SCEP_URL -R $SYSTEM_CA_BUNDLE"
        [ -s "$PERM_ENTERPRISE_CA" ] && SCEP_HELPER_ARGS="$SCEP_HELPER_ARGS -N $PERM_ENTERPRISE_CA"
        [ -s "$PERM_ALL_CERTS" ] && SCEP_HELPER_ARGS="$SCEP_HELPER_ARGS -I $PERM_ALL_CERTS"
    else
        # Gammel certmonger (CentOS 7 etc): kun -u støttet
        SCEP_HELPER_ARGS="-u $SCEP_URL"
    fi

    log "scep-submit args: $SCEP_HELPER_ARGS"

    # Registrer CA via getcert
    # getcert add-scep-ca krever ALLTID -R for HTTPS (også på CentOS 7)
    log "Registrerer SCEP CA (TLS via system CA bundle: $SYSTEM_CA_BUNDLE)..."
    SCEP_OUT=$(getcert add-scep-ca \
        -c "$CA_NAME" \
        -u "$SCEP_URL" \
        -R "$SYSTEM_CA_BUNDLE" 2>&1)
    echo "$SCEP_OUT" | tee -a "$LOG_FILE"

    sleep 5

    if ! getcert list-cas 2>/dev/null | grep -q "^CA '$CA_NAME'"; then
        log_error "getcert add-scep-ca feilet"
        return 1
    fi

    log_success "CA '$CA_NAME' registrert via getcert"

    # Oppdater certmonger intern config med -N og -I for PKCS7 verification
    local CA_CONFIG_FILE=""
    CA_CONFIG_FILE=$(grep -l "id=$CA_NAME" /var/lib/certmonger/cas/* 2>/dev/null | head -1)

    if [ -z "$CA_CONFIG_FILE" ]; then
        log_error "Fant ikke certmonger CA config-fil for $CA_NAME"
        return 1
    fi

    log "Oppdaterer certmonger intern config: $CA_CONFIG_FILE"

    # Stopp certmonger, oppdater config, start
    systemctl stop certmonger 2>/dev/null
    sleep 2

    # Skriv config UTEN ca_encryption_cert (hentes dynamisk)
    cat > "$CA_CONFIG_FILE" << CAEOF
id=$CA_NAME
ca_aka=SCEP (certmonger $CERTMONGER_VER)
ca_is_default=0
ca_type=EXTERNAL
ca_external_helper=$SCEP_HELPER $SCEP_HELPER_ARGS
CAEOF

    # Sett SELinux-kontekst
    if command -v chcon &>/dev/null; then
        chcon -t certmonger_var_lib_t "$CA_CONFIG_FILE" 2>/dev/null || true
    fi

    systemctl start certmonger
    sleep 5

    if ! getcert list-cas 2>/dev/null | grep -q "^CA '$CA_NAME'"; then
        log_error "Certmonger mistet CA config etter restart"
        return 1
    fi

    getcert list-cas -c "$CA_NAME" 2>&1 | tee -a "$LOG_FILE"
    record_state "CA_ADDED:$CA_NAME"

    log_success "SCEP CA konfigurert (dynamisk RA-cert, system TLS)"
    sleep 5
    return 0
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
    if [ -f "$MACHINE_CERT" ] && [ -s "$MACHINE_CERT" ] && [ -f "$MACHINE_KEY" ]; then
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
        TRACK_STATUS=$(getcert list -i "enterprise-8021x-${HOSTNAME}" 2>/dev/null | grep "status:" | $AWK '{print $2}' || true)
        if [ "$TRACK_STATUS" = "NEED_GUIDANCE" ] || [ "$TRACK_STATUS" = "SUBMITTING" ]; then
            log_warn "Certificate not yet issued – NDES enrollment pending"
        else
            log_error "Certificate files missing"
            VERIFY_PASSED=false
        fi
    fi

    log "Verifying certmonger tracking..."
    REQUEST_ID="enterprise-8021x-${HOSTNAME}"
    TRACK_STATUS=$(getcert list -i "$REQUEST_ID" 2>/dev/null | grep "status:" | $AWK '{print $2}' || true)
    if [ "$TRACK_STATUS" = "MONITORING" ]; then
        log_success "Certmonger tracking active: $REQUEST_ID (MONITORING)"
    elif [ "$TRACK_STATUS" = "NEED_GUIDANCE" ] || [ "$TRACK_STATUS" = "SUBMITTING" ]; then
        log_warn "Certmonger tracking active men venter på NDES: $TRACK_STATUS"
        log_warn "Sertifikatet vil komme automatisk når NDES utsteder det"
    else
        log_error "Certmonger not tracking certificate (status: $TRACK_STATUS)"
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

if [ "$TEST_MODE" = false ]; then
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
fi

log_section "Enterprise Network Deployment Starting"
log "Version: $SCRIPT_VERSION"
log "Test Mode: $TEST_MODE"

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

# ── [2A/9] SHA-1 crypto policy (Fedora 42+) ─────────────────────────────────

if [ "$TEST_MODE" = true ]; then
    log "[TEST] Would check/fix SHA-1 crypto policy for SCEP compatibility"
else
    ensure_sha1_policy
fi

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

    # Idempotent: sjekk om CA allerede er konfigurert OG fungerer
    NEED_SCEP_RECONFIG=false
    if getcert list-cas 2>/dev/null | grep -q "^CA '$CA_NAME'"; then
        # CA finnes – men sjekk om det er en gammel config som mangler encryption cert
        # ved å se om en eksisterende request har NEED_SCEP_ENCRYPTION_CERT
        EXISTING_STATUS=$(getcert list -i "enterprise-8021x-${HOSTNAME}" 2>/dev/null | grep "status:" | $AWK '{print $2}' || true)
        if [ "$EXISTING_STATUS" = "NEED_SCEP_ENCRYPTION_CERT" ]; then
            log_warn "Eksisterende CA mangler encryption-cert – rekonfigurerer"
            getcert stop-tracking -i "enterprise-8021x-${HOSTNAME}" 2>/dev/null || true
            getcert remove-ca -c "$CA_NAME" 2>/dev/null || true
            sleep 3
            NEED_SCEP_RECONFIG=true
        else
            log "SCEP CA already configured"
        fi
    else
        NEED_SCEP_RECONFIG=true
    fi

    if [ "$NEED_SCEP_RECONFIG" = true ]; then
        if ! configure_scep_ca; then
            log_error "Failed to configure SCEP CA"
            exit 1
        fi
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
                NEED_SCEP_ENCRYPTION_CERT)
                    log_error "NEED_SCEP_ENCRYPTION_CERT – certmonger krever separat encryption-cert (-e)"
                    log_error "RA encryption-cert mangler eller ble ikke akseptert av certmonger"
                    getcert list -i "$REQUEST_ID" | tee -a "$LOG_FILE"
                    exit 1
                    ;;
                NEED_GUIDANCE)
                    if [ $((ELAPSED % 30)) -eq 0 ]; then
                        log "Status: NEED_GUIDANCE – NDES venter (pending approval/retry)"
                        getcert resubmit -i "$REQUEST_ID" 2>/dev/null || true
                    fi
                    ;;
                SUBMITTING|WAITING_FOR_CA)
                    ;;
                *)
                    if [ $((ELAPSED % 15)) -eq 0 ]; then
                        log "Status: $STATUS (venter...)"
                    fi
                    ;;
            esac
        done

        if [ "$STATUS" = "NEED_GUIDANCE" ] || [ "$STATUS" = "SUBMITTING" ]; then
            log_warn "Certificate enrollment pending (status: $STATUS)"
            log_warn "NDES har mottatt forespørselen – venter på godkjenning/utstedelse"
            log_warn "Certmonger fortsetter å polle automatisk i bakgrunnen"
            getcert list -i "$REQUEST_ID" | tee -a "$LOG_FILE"
            # IKKE exit – la scriptet fortsette med NM-oppsett
            # Sertifikatet vil komme når NDES utsteder det
        elif [ "$STATUS" != "MONITORING" ]; then
            log_error "Certificate enrollment failed. Final status: $STATUS"
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
    echo "  - Splitte bundle: innholdsbasert (Basic Constraints) – CA → -R, RA → -r kombinert"
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
