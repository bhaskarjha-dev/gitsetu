# Credential Broker Engine

**Native OS keychain isolation preventing HTTPS Personal Access Token (PAT) cross-profile pollution.**

Corporate network firewalls frequently block outbound connections on SSH Port 22 entirely. This forces developers to clone, push, and pull repositories using HTTPS protocols backed by Personal Access Tokens (PATs).

However, operating system credential stores natively introduce a critical vulnerability when managing multiple tokens across overlapping environments. GitSetu includes a specialized **Credential Broker Engine** to resolve this challenge permanently.

---

## The Operational Vulnerability

When authenticating over HTTPS, Git streams a credential request directly to your underlying operating system (macOS Keychain, Windows Credential Manager, or Linux Secret Service).

```
[ git push https://github.com/org/repo.git ]
                     │
                     ▼
        [ Upstream Request: "github.com" ]
                     │
                     ▼
[ OS Keychain blindly returns first cached token ]
                     │
                     ▼
    [ Return payload: Personal Token ]
                     │
                     ▼
       [ HTTP 403 Forbidden Error ]
```

Because external keychains key authentication strictly off the base domain string (`github.com`), they blindly return the first matching token encountered. You end up attempting to authenticate against an enterprise repository using your personal access token, raising persistent, confusing access errors.

---

## The GitSetu Intercept Architecture

GitSetu intercepts this systemic failure by registering itself as a proxy credential helper within your dynamically mapped configuration layers.

Inside your target `.gitconfig` bounds, GitSetu statefully compiles:
```ini
[credential]
    helper = "gitsetu credential"
```

### The Isolated Resolution Flow

1. **Trigger Operation:** You execute `git push` over HTTPS inside a managed workspace folder.
2. **Helper Interception:** Git streams an authentication verification payload directly to the configured credential helper.
3. **Context Evaluation:** GitSetu leverages its optimized path-matching algorithm to identify the active profile context instantly.
4. **Namespaced Query:** Instead of requesting credentials for `github.com` from the OS, GitSetu constructs an isolated, unique namespace query: `gitsetu:work:github.com`.
5. **Target Delivery:** The OS keychain (macOS Keychain, Linux Secret Service, or Windows Git Credential Manager) returns the exact token explicitly mapped to your `work` profile context.
6. **Execution Success:** GitSetu passes the isolated token payload back to Git. Upstream communication succeeds flawlessly.

> [!NOTE]
> **Windows Credential Manager Integration:**
> On Windows (Git Bash), GitSetu automatically configures `credential.helper = manager`, natively delegating to Microsoft's **Git Credential Manager (GCM)** backed by Windows DPAPI and Windows Credential Manager.

---

## Token Lifecycle Management

To securely seed or update a Personal Access Token within an isolated profile scope, you can:
1. **Interactive Setup:** Enter your PAT when prompted during the interactive `gitsetu setup` wizard.
2. **Headless Profile Registration:** Provide credentials when invoking profile commands:
   ```bash
   gitsetu profile add work --email=dev@company.com --dir=~/work
   ```
3. **Standard Git Credential Helper Interface:** Store or retrieve credentials directly via standard Git credential protocol inputs:
   ```bash
   printf "protocol=https\nhost=github.com\nusername=dev-corp\npassword=PAT_TOKEN\n" | gitsetu credential store
   ```

### Encrypted Fallback Storage
In environments where native OS keychain facilities are absent (such as headless Linux or minimal WSL containers), GitSetu securely falls back to a restricted credential vault at `~/.config/gitsetu/.tokens`. This file is strictly enforced with `chmod 600` permissions (read/write only by the current user) immediately upon creation, preventing world-readable token exposure. Passwords and tokens are never stored in plain-text global configuration files.
