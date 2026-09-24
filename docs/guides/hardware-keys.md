# Hardware Keys (FIDO2 / YubiKey)

**Provisioning FIDO2-backed SSH keys with explicit hardware-presence requirements.**

GitSetu supports resident `ed25519-sk` keys. The hardware token performs the private-key operation and OpenSSH requests user presence, but users must still protect the host, token, and recovery paths; no client-side tool can guarantee protection from a compromised system.

---

## Technical Prerequisites

To execute hardware-backed setup paths successfully, verify your local system environments meet standard cryptographic support targets:
- **OpenSSH Version:** Core OpenSSH binary `v8.2` or higher (introduced natively in early 2020).
- **Physical Token:** A dedicated FIDO2/WebAuthn compliant hardware security device.
- **Host Drivers:** Client integration libraries (`libfido2`) active on your operational OS layer.

---

## Provisioning Workflow

When initializing a new workspace configuration profile via the interactive setup wizard (`gitsetu setup`), the system scans your local compilation environment to verify hardware crypto capability.

If validated successfully, the interface presents native hardware key generation pathways inline:

```text
What type of SSH key do you want to generate?
1) ED25519    (Standard Software Keypair, Optimized Curve)
2) ED25519-SK (FIDO2 / YubiKey Hardware Security Token)
```

### The Generation Intercept

1. Select option **`2`**.
2. Connect your physical token directly into an available host USB interface.
3. The terminal halts execution mid-flight. **Physically tap the capacitive contact** on your hardware key to confirm user presence.
4. GitSetu compiles an isolated host pointer layout (`~/.ssh/id_ed25519_sk_<profile>`) containing reference hooks linking directly to your physical token.
5. The generated public key payload streams directly out for integration, while configuration blocks automatically pivot to leverage your OpenSSH zero-trust bounds.

---

## Runtime Verification Mechanics

When executing code pushes or fetching protected upstream branches over SSH, OpenSSH reads the localized key hook pointer and streams an evaluation request to the attached physical device.

```text
$ git push origin main
Confirm user presence for key ED25519-SK...
```

Your terminal session pauses while OpenSSH waits for the hardware token. A stolen laptop alone is not sufficient to use the resident key, but an attacker with the token, user presence, or a compromised host may still succeed. If hardware enrollment fails, GitSetu never silently substitutes a software key; any fallback requires an explicit user choice.

---

## Recovery & Redundancy Guard Rails

> [!WARNING]
> **Hardware Loss Risk:** Because the cryptographic private key resides strictly inside the secure element of your physical device, losing the physical token permanently destroys access to the SSH keypair. Always register redundant access paths (such as secondary hardware keys or restricted Personal Access Tokens) within your upstream provider configuration settings.
