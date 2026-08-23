.PHONY: check dry-run

check:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck install.sh; \
	else \
		echo "shellcheck not installed; skipping"; \
	fi

dry-run:
	bash install.sh --dry-run
