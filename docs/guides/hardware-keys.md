# Hardware Keys (FIDO2 / YubiKey)

**Bootstrapping highly secure, tamper-resistant SSH authentication keys backed directly by hardware tokens.**

GitSetu natively supports provisioning FIDO2-backed resident SSH keys (`ed25519-sk`). This operational paradigm ensures that private cryptographic signatures are generated and held strictly inside external physical security keys (e.g., YubiKey 5 Series), completely protecting key material from extraction even if your local host filesystem is compromised.

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

Your terminal session pauses automatically. You must **physically touch the hardware key** to complete the handshake negotiation. If an adversarial actor steals your laptop or intercepts remote terminal environments, they remain structurally incapable of pushing commits because the cryptographic operation requires explicit physical proximity verification.

---

## Recovery & Redundancy Guard Rails

> [!WARNING]
> **Hardware Loss Risk:** Because the cryptographic private key resides strictly inside the secure element of your physical device, losing the physical token permanently destroys access to the SSH keypair. Always register redundant access paths (such as secondary hardware keys or restricted Personal Access Tokens) within your upstream provider configuration settings.
