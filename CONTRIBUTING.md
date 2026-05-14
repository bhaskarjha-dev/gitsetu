# Contributing to gitsetu

Thank you for your interest in contributing!

## Development Setup

```bash
git clone https://github.com/bhaskarjha-com/gitsetu.git
cd gitsetu
```

No build step. No dependencies to install. See the [Architecture Guide](docs/ARCHITECTURE.md) for how the codebase is structured.

## Running Tests

We use a standard `Makefile` to orchestrate our test suite.

```bash
# Install the Git pre-push hook to automatically prevent bad pushes
make hooks

# Run the entire 168-test sandbox matrix
make test
```

Tests automatically run in an isolated `$HOME` in a temp directory — they never touch your real configuration.

## Linting

```bash
# Install ShellCheck if needed
# Ubuntu/Debian: sudo apt install shellcheck
# macOS: brew install shellcheck

# Lint all scripts
make lint
```

All scripts must pass ShellCheck with **zero warnings**.

### Running Everything (CI Simulation)

Before submitting a Pull Request, you can simulate the exact GitHub Actions CI pipeline by running:

```bash
make check
```

This command will run `make lint` followed by `make test`, ensuring your code is flawless before pushing.

## Code Style

### Bash 3.2 Compatibility

macOS ships bash 3.2. Do **NOT** use these bash 4+ features:

| ❌ Don't Use | ✅ Use Instead |
|-------------|---------------|
| `declare -A` (associative arrays) | Parallel indexed arrays |
| `mapfile` / `readarray` | `while IFS= read -r` loops |
| `${var,,}` (lowercase) | `printf '%s' "$var" \| tr '[:upper:]' '[:lower:]'` |
| `|&` (pipe stderr) | `2>&1 \|` |

> **Note:** `read -a` (read into array), `<<<` (here-strings), and `[[ ]]` (conditional expressions) **are** permitted — these are Bash 3.2 features, not Bash 4+ additions. The compatibility floor is Bash 3.2, not POSIX `sh`.

### Quoting

**Always** quote variables. No exceptions.

```bash
# ✅ Correct
local path="$HOME/.ssh"
if [[ -f "$path" ]]; then

# ❌ Wrong
local path=$HOME/.ssh
if [[ -f $path ]]; then
```

### Functions

- Use `snake_case` for function names
- Document with a header comment: purpose, usage, return value
- Use `local` for all variables inside functions

### Output

- All user-facing output goes to **stderr** (`>&2`), keeping stdout clean
- Use the `print_*` functions from `lib/ui.sh`, not raw `echo`
- Respect `NO_COLOR` — never hardcode escape sequences

### Managed Blocks

When adding content to user config files, always use managed block markers:

```bash
${GITSETU_MANAGED_START}
# your content here
${GITSETU_MANAGED_END}
```

## Pull Request Guidelines

1. All tests must pass
2. ShellCheck must report zero warnings
3. Include tests for new functionality
4. Update docs if adding features or changing behavior
5. Follow the existing code style

## Reporting Issues

When reporting a bug, please include:
- OS and version (`uname -a`)
- Bash version (`bash --version`)
- Git version (`git --version`)
- The full error output
