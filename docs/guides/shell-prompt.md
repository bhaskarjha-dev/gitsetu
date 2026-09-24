# Shell Prompt Integration

**Low-overhead shell integration surfacing your active Git identity inside your terminal prompt.**

Committing code using the wrong author context often occurs because developers lack instant visual feedback regarding which identity profile owns their current terminal workspace directory.

GitSetu includes a specialized, high-speed **Prompt Engine** designed specifically to expose your active workspace context natively inside your command prompt (`$PS1`), Oh-My-Zsh themes, and cross-shell tools like Starship.

---

## The Performance Paradigm

Rendering logic inside terminal prompt structures executes every single time you hit `Enter`. If a prompt integration spawns external binary runtimes, executes multi-stage subprocesses, or queries network layers, shell interactivity grinds to a halt.

GitSetu's `prompt` subcommand avoids loading the full command modules and uses strict v2 registry parsing, but actual latency depends on the shell, filesystem, and path length. Measure it in the target environment rather than relying on a fixed latency claim.
- **Strict v2 parsing:** Rejects malformed registries instead of guessing.
- **Longest-prefix matching:** Resolves nested profile roots deterministically.
- **Cross-platform paths:** Handles platform-aware drive-letter and case semantics.
- **No network access:** Prompt evaluation is local and does not contact a provider.

---

## Integration Setup

### Standard Bash (`~/.bashrc`)
To prepend the active profile identifier directly to your terminal prompt line, append the following snippet to your shell configuration profile:

```bash
# GitSetu Native Shell Prompt Integration
gitsetu_ps1() {
    local profile
    # Rapidly extract current profile context silently
    profile=$(gitsetu prompt 2>/dev/null)
    if [ -n "$profile" ]; then
        echo "[$profile] "
    fi
}

# Update PS1 command rendering chain
PS1='$(gitsetu_ps1)'$PS1
```

### Zsh / Oh-My-Zsh (`~/.zshrc`)
Integrate context flags gracefully inside custom Zsh layout strings:

```zsh
# Enable command substitution within Zsh prompt evaluation
setopt PROMPT_SUBST

gitsetu_prompt_info() {
    local profile=$(gitsetu prompt 2>/dev/null)
    [[ -n "$profile" ]] && echo "%{$fg[cyan]%}[$profile]%{$reset_color%} "
}

# Inject cleanly ahead of standard prompt strings
PROMPT='$(gitsetu_prompt_info)'$PROMPT
```

### Starship Cross-Shell Prompt (`~/.config/starship.toml`)
For developers leveraging the popular high-speed Starship engine, provision a dedicated custom module block:

```toml
[custom.gitsetu]
command = "gitsetu prompt"
when = "gitsetu prompt >/dev/null 2>&1"
format = "via [$output]($style) "
style = "bold cyan"
```

---

## Output Behavior

When traversing across folders, visual updates render instantly:

```text
# Inside unmapped general directories
~ ❯ cd ~/work/api-gateway
# Context updates instantly mid-flight
[work] ~/work/api-gateway ❯ 
```
