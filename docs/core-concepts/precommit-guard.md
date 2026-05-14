# Pre-Commit Identity Guard

GitSetu's routing is incredibly robust, but dual-state leaks are still possible. For example, if a developer manually runs `git config user.email "wrong@email.com"` inside a local repository, Git will prioritize that local config over GitSetu's managed global config.

To prevent these edge cases from poisoning your public commit history, GitSetu includes a failsafe: the Identity Guard.

## How it works

When you initialize GitSetu, it establishes a global `core.hooksPath`. This means every time you run `git commit` in any repository on your machine, GitSetu's pre-commit hook fires first.

1. You type `git commit -m "update"`.
2. The hook intercepts the commit.
3. It instantly calculates which GitSetu profile *should* be active based on your current directory.
4. It reads the actual active `git config user.email` that Git is about to use for the commit.
5. If the emails diverge, the hook throws a fatal error and **blocks the commit entirely**.

```text
$ git commit -m "wip"
[GitSetu Guard] BLOCKING COMMIT!
Expected email: dev@company.com (from profile 'work')
Actual email: me@gmail.com (from local .git/config)
```

## Zero Overhead

The Identity Guard is written in pure, highly-optimized Bash. It parses the configurations directly, avoiding subshell overhead. The entire check takes less than 2 milliseconds, meaning it is completely imperceptible during your daily workflow.

## Enabling the Guard

If you didn't enable the guard during the initial `gitsetu setup` wizard, you can install it at any time:

```bash
gitsetu install-guard
```

To remove it safely without touching your other hooks:

```bash
gitsetu remove-guard
```

> [!NOTE]
> If you rely on repository-specific pre-commit hooks (like `husky` or `pre-commit`), the GitSetu guard is designed to automatically execute them *after* the identity verification passes, ensuring your existing CI/linting pipelines are never disrupted.
