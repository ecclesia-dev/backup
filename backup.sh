#!/bin/bash
# backup.sh — tar + checksum + encrypt (age identity file) + iCloud + offline HDD
# Requires: age, age-keygen (brew install age)
#
# Encryption: filippo.io/age — ChaCha20-Poly1305 AEAD, proper authenticated encryption.
# Key approach: age identity file (age-keygen). Public key is extracted from the identity
# file for encryption; secret key is used for decryption. Store the identity file in your
# password manager — do NOT store it in iCloud or alongside the backups.

set -euo pipefail
umask 077

# ── Config ────────────────────────────────────────────────────────────────────
SOURCES=("$HOME/Documents" "$HOME/Pictures")
BACKUP_NAME="backup-$(date +%Y-%m-%dT%H-%M-%S)"
STAGING="$(mktemp -d)"
ICLOUD="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Backups"
OFFLINE="/Volumes/BackupDrive"   # set to "" to skip
KEY_FILE="$HOME/.backup.age"     # age identity file (secret key)
LOG_FILE="$HOME/.backup.log"
# ─────────────────────────────────────────────────────────────────────────────

# ── Logging ───────────────────────────────────────────────────────────────────
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== Backup started: $(date) ==="

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in age age-keygen; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "✗ Required: $cmd — install with: brew install age"
        exit 1
    fi
done

# ── Cleanup ───────────────────────────────────────────────────────────────────
cleanup() {
    echo "→ Cleaning up staging..."
    if [ -d "$STAGING" ]; then
        # Note: shred is ineffective on APFS (copy-on-write) and SSDs (wear leveling).
        # rm -rf is sufficient here — FileVault encryption protects the underlying volume.
        rm -rf "$STAGING"
    fi
}
trap cleanup EXIT

# ── sha256 compat (macOS vs Linux) ────────────────────────────────────────────
if command -v sha256sum >/dev/null 2>&1; then
    SHA="sha256sum"
else
    SHA="shasum -a 256"
fi

# ── Key setup ─────────────────────────────────────────────────────────────────
if [ ! -f "$KEY_FILE" ]; then
    echo "→ No key found. Generating new age identity..."

    # age-keygen writes the identity file directly with correct format.
    # Create with restricted permissions before writing.
    touch "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    age-keygen -o "$KEY_FILE"

    # Extract the public key from the identity file comment for display.
    PUBKEY=$(grep "^# public key:" "$KEY_FILE" | sed 's/# public key: //')

    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║  NEW KEY GENERATED — ACTION REQUIRED                 ║"
    echo "║                                                      ║"
    echo "║  Identity file: $KEY_FILE"
    echo "║  Public key:    $PUBKEY"
    echo "║                                                      ║"
    echo "║  1. Add identity file to your password manager NOW   ║"
    echo "║  2. Note the public key above for reference          ║"
    echo "║  3. Never store the identity file in iCloud or with  ║"
    echo "║     your backups — keep it separate                  ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo ""
    echo "→ The identity file is an age keypair — too long for a QR code."
    echo "  Back it up to your password manager (e.g. 1Password, Bitwarden)."
    echo "  Without this file you CANNOT decrypt your backups."

    if [ -t 0 ]; then
        printf "Press ENTER once the identity file is secured, or Ctrl+C to abort: "
        read -r _
    else
        echo "⚠  Non-interactive mode: key generated. Secure $KEY_FILE before next run."
        exit 1
    fi
fi

# Sanity check key — age identity files contain the AGE-SECRET-KEY- prefix.
if ! grep -q "^AGE-SECRET-KEY-" "$KEY_FILE" 2>/dev/null; then
    echo "✗ Key file malformed or not a valid age identity. Aborting."
    exit 1
fi

# Extract public key for encryption (recipient).
PUBKEY=$(grep "^# public key:" "$KEY_FILE" | sed 's/# public key: //')
if [ -z "$PUBKEY" ]; then
    echo "✗ Could not extract public key from identity file. Aborting."
    exit 1
fi

# ── Archive ───────────────────────────────────────────────────────────────────
ARCHIVE="$STAGING/$BACKUP_NAME.tar.gz"
CHECKSUM="$STAGING/$BACKUP_NAME.sha256"
ENCRYPTED="$STAGING/$BACKUP_NAME.tar.gz.age"

echo "→ Creating archive..."
tar -czf "$ARCHIVE" "${SOURCES[@]}"
echo "  Size: $(du -sh "$ARCHIVE" | cut -f1)"

# ── Checksum ──────────────────────────────────────────────────────────────────
echo "→ Checksumming..."
$SHA "$ARCHIVE" > "$CHECKSUM"
cat "$CHECKSUM"

# ── Encrypt ───────────────────────────────────────────────────────────────────
# age: ChaCha20-Poly1305 AEAD — authenticated encryption, correct on macOS.
# Encrypt to recipient (public key extracted from identity file).
echo "→ Encrypting..."
age -r "$PUBKEY" -o "$ENCRYPTED" "$ARCHIVE"

# ── iCloud ────────────────────────────────────────────────────────────────────
mkdir -p "$ICLOUD"
echo "→ Copying to iCloud..."
cp "$ENCRYPTED" "$ICLOUD/$BACKUP_NAME.tar.gz.age"
cp "$CHECKSUM"  "$ICLOUD/$BACKUP_NAME.sha256"

# ── Offline drive ─────────────────────────────────────────────────────────────
if [ -n "$OFFLINE" ] && [ -d "$OFFLINE" ]; then
    echo "→ Copying to offline drive (encrypted)..."
    cp "$ENCRYPTED" "$OFFLINE/$BACKUP_NAME.tar.gz.age"
    cp "$CHECKSUM"  "$OFFLINE/$BACKUP_NAME.sha256"
else
    [ -n "$OFFLINE" ] && echo "⚠  Offline drive not mounted at $OFFLINE — skipping"
fi

# ── Verify iCloud copy ────────────────────────────────────────────────────────
echo "→ Verifying iCloud copy..."
EXPECTED=$(awk '{print $1}' "$CHECKSUM")
ACTUAL=$(age -d -i "$KEY_FILE" -o /dev/stdout "$ICLOUD/$BACKUP_NAME.tar.gz.age" \
    | $SHA | awk '{print $1}')

if [ "$EXPECTED" = "$ACTUAL" ]; then
    echo "  ✓ Checksum verified"
else
    echo "  ✗ CHECKSUM MISMATCH — iCloud copy may be corrupt"
    exit 1
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "✓ Done: $BACKUP_NAME"
echo "  iCloud:  $ICLOUD/$BACKUP_NAME.tar.gz.age"
[ -n "$OFFLINE" ] && [ -d "$OFFLINE" ] && \
    echo "  Offline: $OFFLINE/$BACKUP_NAME.tar.gz.age"
echo "  Key:     $KEY_FILE — never upload, never share"
echo "=== Backup finished: $(date) ==="
