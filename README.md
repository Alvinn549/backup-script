# Project Backup & Restore Guide

This guide explains how to back up and restore project archives, with or without GPG encryption, and whether the backup files are single archives or split into parts.

> **Note:** Make sure the `zstd` package is installed on both backup and restore machines.

---

## Part 1: Backup Guide

By default, backups are compressed with `zstd`.  
You can enable **GPG encryption** for additional security.

### 1. Backup without encryption

- Configure `.env`:
  ```env
  ENABLE_GPG="no"
  ```

- Run the backup script normally:
  ```sh
  ./backup.sh
  ```

- Result:
  - `project-file.tar.zst` (with the `.sha256`)
  - `db-file.sql` (with the `db.sha256`)

---

### 2. Backup with encryption

- First generate or import a GPG key (see [Part 3: GPG Setup](#part-3-gpg-setup-for-encryptiondecryption)).
- Update `.env` with:
  ```env
  ENABLE_GPG="yes"
  GPG_RECIPIENT="<FPR>"
  ```

- Run the backup script:
  ```sh
  ./backup.sh
  ```

- Result:
  - `project-file.tar.zst.gpg` (with the `.sha256`)
  - `db-file.sql` (with the `db.sha256`)

---

## Part 2: Restore Guide

> **Tip:** Make sure to install `zstd` first.

### Case A: Single file, no encryption

1. **Verify checksum**
   ```sh
   sha256sum -c project-file.tar.zst.sha256
   ```
2. **Extract**
   ```sh
   tar --use-compress-program="zstd --long=31" -xvf project-file.tar.zst -C /restore/path
   ```

---

### Case B: Split into parts, no encryption

1. **Reassemble parts**
   ```sh
   cat project-file.tar.zst.part* > project-file.tar.zst
   ```
2. **Verify checksum**
   ```sh
   sha256sum -c project-file.tar.zst.sha256
   ```
3. **Extract**
   ```sh
   tar --use-compress-program="zstd --long=31" -xvf project-file.tar.zst -C /restore/path
   ```

---

### Case C: Single file, WITH encryption

1. **Verify checksum**
   ```sh
   sha256sum -c project-file.tar.zst.gpg.sha256
   ```
2. **Decrypt & extract**
   ```sh
   gpg -d project-file.tar.zst.gpg | tar --use-compress-program="zstd --long=31" -xvf - -C /restore/path
   ```

---

### Case D: Split into parts, WITH encryption

1. **Reassemble parts**
   ```sh
   cat project-file.tar.zst.gpg.part* > project-file.tar.zst.gpg
   ```
2. **Verify checksum**
   ```sh
   sha256sum -c project-file.tar.zst.gpg.sha256
   ```
3. **Decrypt & extract**
   ```sh
   gpg -d project-file.tar.zst.gpg | tar --use-compress-program="zstd --long=31" -xvf - -C /restore/path
   ```

---

## Part 3: GPG Setup (for encryption/decryption)

### 1. Key Concepts

- **Public key** → used to ENCRYPT backups (kept on backup server).
- **Private key** → used to DECRYPT backups (kept on restore machine).
- Public key is safe to share, private key must remain secure.

---

### 2. Generate a key (local machine)

```sh
gpg --full-generate-key
```
Choose:
- RSA and RSA
- Key size: 4096
- Email: your email
- Expiry: never (recommended)

Check:
```sh
gpg --list-keys --with-fingerprint
```

---

### 3. Export keys

**Public key (safe to share):**
```sh
gpg --export -a "<FPR>" > publickey.asc
```

**Private key (keep secure):**
```sh
gpg --export-secret-keys -a "<FPR>" > privatekey.asc
```

---

### 4. Import keys

On restore machine (needs private key to decrypt):
```sh
gpg --import privatekey.asc
```

---

### 5. Set trust

Get the fingerprint:
```sh
gpg --list-keys --with-fingerprint
```

Mark key as trusted:
```sh
echo "<FPR>:6:" | gpg --import-ownertrust
```

---

### 6. Update `.env`

Set encryption enabled and recipient fingerprint:
```env
ENABLE_GPG="yes"
GPG_RECIPIENT="<FPR>"
```