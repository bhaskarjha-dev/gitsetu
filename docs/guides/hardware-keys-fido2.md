# Hardware Keys (FIDO2 / YubiKey)

GitSetu has native support for FIDO2-backed SSH keys. This means your private key material is stored directly on a hardware security token (like a YubiKey) and never touches your computer's filesystem.

## Prerequisites

To use hardware-backed SSH keys, you need:
- OpenSSH 8.2 or newer (released Feb 2020).
- A FIDO2-compliant security key (e.g., YubiKey 5 Series).

## Generating a Hardware Key

When you run `gitsetu setup` to create a new profile, the interactive wizard will ask you if you want to generate a new SSH keypair. 

If it detects that your system supports FIDO2 (via `ssh-keygen -t ed25519-sk`), it will offer it as an option:

```text
What type of SSH key do you want to generate?
1) ED25519 (Standard, Highly Secure)
2) ED25519-SK (FIDO2 / YubiKey Hardware Token)
```

1. Select option `2`.
2. Ensure your YubiKey is plugged into your USB port.
3. The terminal will pause. Touch the flashing gold contact on your YubiKey to confirm presence.

GitSetu will generate a stub file on your filesystem (`~/.ssh/id_ed25519_sk_profile`) that points to the hardware token, and instantly wire it into your Zero-Trust SSH configuration.

## Pushing Code

When you `git push` a repository associated with this profile, your terminal will pause again. You must physically touch your YubiKey to authorize the cryptographic operation. If someone steals your laptop, they cannot push code to your repositories because they do not have your physical token.

> [!NOTE]
> If you lose your YubiKey, you will lose access to the SSH key. Always ensure you have a backup authentication method (like a PAT) registered with your Git provider.
