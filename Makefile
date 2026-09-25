.PHONY: help check metadata docs lint test dist dist-check test-bundle package-check install local-install uninstall hooks windows-launcher clean

help:
	@echo "GitSetu Developer Commands:"
	@echo ""
	@echo "  make check           Run metadata, lint, tests, and bundle gates"
	@echo "  make metadata        Validate canonical release/development metadata"
	@echo "  make docs            Validate documentation state and provenance wording"
	@echo "  make lint            Lint shell, Node, JSON, and release templates"
	@echo "  make test            Run the regression suite"
	@echo "  make dist            Build dist/gitsetu and its integrity manifest"
	@echo "  make dist-check      Build and execute/verify the standalone bundle"
	@echo "  make test-bundle     Run the regression suite against dist/gitsetu"
	@echo "  make package-check   Validate npm metadata and package policy"
	@echo "  make local-install   Install a clean reviewed development checkout"
	@echo "  make install         Install a pinned public release"
	@echo "  make uninstall       Remove only a marker-verified installation"
	@echo "  make hooks           Install a pre-push hook only when no hook exists"
	@echo "  make windows-launcher Build the trusted native Windows launcher"
	@echo ""

check: metadata docs lint test dist-check package-check

metadata:
	@node packaging/release.js validate-source
	@test "$$(node -p "require('./package.json').gitsetuRelease.state")" = "$$(node -p "require('./packaging/release.json').release.state")"

docs:
	@node scripts/check-docs.mjs

lint:
	@shellcheck gitsetu install.sh uninstall.sh scripts/*.sh packaging/gh-extension/gh-gitsetu packaging/gh-extension/gh-setu tests/*.sh
	@node --check bin/gitsetu.js
	@node --check packaging/release.js
	@node --check scripts/check-docs.mjs
	@node -e "for (const f of ['package.json','package-lock.json','packaging/release.json','packaging/scoop/gitsetu.json.in']) { const s=require('fs').readFileSync(f,'utf8').replace(/\{\{[A-Z0-9_]+\}\}/g,'null'); if (f.endsWith('.json')) JSON.parse(s); }"
	@if command -v powershell.exe >/dev/null 2>&1; then powershell.exe -NoLogo -NoProfile -Command '$$errors=$$null; foreach($$f in @("install.ps1","uninstall.ps1","packaging/windows/build_launcher.ps1","packaging/windows/build_release_zip.ps1")){[Management.Automation.Language.Parser]::ParseFile((Resolve-Path $$f),[ref]$$null,[ref]$$errors)|Out-Null}; if($$errors.Count){$$errors|ForEach-Object{Write-Error $$_};exit 1}' ; fi

test:
	@bash tests/run_all.sh

dist:
	@bash scripts/bundle.sh

dist-check: dist
	@bash -n dist/gitsetu
	@./dist/gitsetu --version | grep -F 'gitsetu v1.1.0'
	@grep -F "Release state: $$(node -p "require('./packaging/release.json').release.state")" dist/gitsetu >/dev/null
	@node packaging/release.js verify-bundle dist/gitsetu dist/gitsetu.manifest.json

test-bundle: dist
	@bash tests/run_all.sh --bundle "$(CURDIR)/dist/gitsetu"

package-check:
	@node packaging/release.js validate-source
	@bash packaging/gh-extension/gh-gitsetu --version >/dev/null
	@bash packaging/gh-extension/gh-setu --version >/dev/null

install:
	@bash install.sh

local-install:
	@bash install.sh --local-development

uninstall:
	@bash uninstall.sh

hooks:
	@hook="$(git rev-parse --git-path hooks)/pre-push"; \
	if [ -e "$$hook" ] || [ -L "$$hook" ]; then \
		echo "Refusing to overwrite existing hook: $$hook" >&2; \
		exit 1; \
	fi; \
	printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'make check' > "$$hook"; \
	chmod 700 "$$hook"; \
	echo "Installed pre-push hook: $$hook"

windows-launcher:
	@powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File packaging/windows/build_launcher.ps1

clean:
	@rm -f dist/gitsetu dist/gitsetu.manifest.json dist/gitsetu.exe dist/gitsetu.exe.sha256 dist/gitsetu-windows-x64.zip dist/gitsetu-windows-x64.zip.sha256
