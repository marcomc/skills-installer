PREFIX ?= $(HOME)/.local
CONFIG_HOME ?= $(HOME)/.config
INSTALL ?= install
MARKDOWNLINT_CONFIG ?= .markdownlint.json

BINDIR := $(PREFIX)/bin
CONFIG_DIR := $(CONFIG_HOME)/skills-installer
CONFIG_FILE := $(CONFIG_DIR)/external-skills.conf

SCRIPT := install_external_agent_skills.sh
SHELL_FILES := $(SCRIPT) tests/smoke.sh
MARKDOWN_FILES := README.md CHANGELOG.md TODO.md LICENSE.md

.DEFAULT_GOAL := help

.PHONY: all help install uninstall lint lint-shell lint-md test validate

all: help

help:
	@printf 'Available targets:\n'
	@printf '  make help        Show this help.\n'
	@printf '  make install     Install $(SCRIPT) and default config if missing.\n'
	@printf '  make uninstall   Remove installed $(SCRIPT).\n'
	@printf '  make lint        Run shell and Markdown lint checks.\n'
	@printf '  make lint-shell  Run shellcheck on $(SCRIPT).\n'
	@printf '  make lint-md     Run markdownlint on project Markdown files.\n'
	@printf '  make test        Run smoke tests.\n'
	@printf '  make validate    Run all validation checks.\n'

install:
	mkdir -p "$(BINDIR)" "$(CONFIG_DIR)"
	$(INSTALL) -m 0755 "$(SCRIPT)" "$(BINDIR)/$(SCRIPT)"
	if [ ! -f "$(CONFIG_FILE)" ]; then \
		$(INSTALL) -m 0644 config/external-skills.example.conf "$(CONFIG_FILE)"; \
	fi

uninstall:
	rm -f "$(BINDIR)/$(SCRIPT)"

lint: lint-shell lint-md

lint-shell:
	shellcheck --enable=all $(SHELL_FILES)

lint-md:
	markdownlint --config "$(MARKDOWNLINT_CONFIG)" $(MARKDOWN_FILES)

test:
	tests/smoke.sh

validate: lint test
