# Credential Broker

Corporate firewalls often block SSH Port 22 entirely, forcing developers to clone and push repositories using HTTPS and Personal Access Tokens (PATs). 

GitSetu includes a native Credential Broker to solve the chaos of managing multiple PATs for the same host.

## The Problem

If you have a personal GitHub account and a work GitHub account, both authenticate against `github.com`.

When you use Git over HTTPS, Git asks your operating system (macOS Keychain, Windows Credential Manager, or Linux Secret Service) for the password to `github.com`. 

Because the OS only keys off the hostname (`github.com`), it blindly returns the first token it finds. You end up authenticating to your work repository with your personal token, resulting in a confusing `HTTP 403 Forbidden` error.

## The GitSetu Solution

GitSetu intercepts this process by setting itself as the global Git credential helper.

Inside your managed `~/.gitconfig`, GitSetu injects:
```ini
[credential]
    helper = "/path/to/gitsetu credential"
```

### How It Works

1. You run `git push` over HTTPS.
2. Git needs authentication for `github.com`, so it streams a request to `gitsetu credential`.
3. GitSetu instantly detects which profile is currently active based on your directory.
4. Instead of asking the OS for `github.com`, GitSetu asks the OS for a heavily namespaced key: `gitsetu:work:github.com`.
5. The OS returns the exact PAT associated with your `work` profile.
6. GitSetu passes it back to Git. The push succeeds.

This completely isolates your tokens. You can have ten different GitHub tokens stored securely in your OS Keychain, and GitSetu will always route the correct one based on your current directory.

## Managing Credentials

To add or update a token for a profile, use the `auth` command:

```bash
gitsetu auth work
```

GitSetu will securely prompt you for the token and save it directly into your operating system's encrypted keychain. It never stores passwords in plain text.
