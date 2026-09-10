.PHONY: test lint dist install uninstall help

help:
	@echo "GitSetu Developer Commands:"
	@echo ""
	@echo "  make check     Run BOTH linting and tests (Simulates CI)"
	@echo "  make lint      Run ShellCheck against all scripts"
	@echo "  make test      Run all 32 regression test suites (requires bash 3.2+)"
	@echo "  make dist      Compile standalone monolithic single-file binary to dist/gitsetu"
	@echo "  make hooks     Install Git pre-push hook to prevent bad pushes"
	@echo "  make install   Install GitSetu to ~/.local/bin via git clone"
	@echo "  make uninstall Remove GitSetu from ~/.local/share and ~/.local/bin"
	@echo ""

check: lint test

test:
	@echo "Running 32 regression test suites..."
	@bash tests/run_all.sh

dist:
	@bash scripts/bundle.sh

lint:
	@echo "Running ShellCheck..."
	@shellcheck gitsetu lib/*.sh tests/*.sh install.sh uninstall.sh
	@echo "Linting complete!"

install:
	@bash install.sh

uninstall:
	@bash uninstall.sh

hooks:
	@echo "Installing pre-push hook..."
	@echo '#!/usr/bin/env bash' > .git/hooks/pre-push
	@echo 'set -e' >> .git/hooks/pre-push
	@echo 'echo "Running pre-push checks..."' >> .git/hooks/pre-push
	@echo 'make check' >> .git/hooks/pre-push
	@chmod +x .git/hooks/pre-push
	@echo "pre-push hook installed successfully!"
