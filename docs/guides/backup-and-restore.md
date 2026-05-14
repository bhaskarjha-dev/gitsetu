# Backup and Restore

Developers frequently switch laptops or wipe their operating systems. Reconfiguring Git identities and re-generating SSH keys from scratch can take hours. GitSetu provides a native `backup` and `restore` command to compress your entire identity state into a single, encrypted vault file.

## Backing up your State

To create a backup of your GitSetu configuration, run:

```bash
gitsetu backup
```

### What gets backed up?
- The GitSetu registry (`~/.config/gitsetu/profiles.conf`).
- All generated Git config fragments (`~/.config/gitsetu/profiles/*.gitconfig`).
- All Zero-Trust SSH aliases (`~/.config/gitsetu/ssh/*`).
- **Your SSH Private and Public Keys** associated with these profiles (`~/.ssh/id_*`).

### OpenSSL Encryption
Because this backup contains highly sensitive private SSH keys, GitSetu mandates encryption. It leverages the native `openssl` binary on your system to encrypt the tarball using **AES-256-CBC**.

During the backup process, you will be prompted to enter a strong password. **Do not lose this password.** The encryption is mathematically secure; if you forget the password, the backup is completely unrecoverable.

The output will be a file named `gitsetu_backup_YYYYMMDD_HHMMSS.tar.gz.enc`. Store this file safely in your password manager, cloud storage, or an offline hard drive.

## Restoring your State

On your new laptop, simply install GitSetu as usual. Then, run the restore command, passing the path to your encrypted vault file:

```bash
gitsetu restore /path/to/gitsetu_backup_YYYYMMDD_HHMMSS.tar.gz.enc
```

You will be prompted for the password you set during the backup. GitSetu will decrypt the vault, safely extract the SSH keys into `~/.ssh/` with the correct permissions, and rebuild the global `~/.gitconfig` and `~/.ssh/config` `include` blocks.

Within seconds, your entire multi-identity Git environment is completely restored.
