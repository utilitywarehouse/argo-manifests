# argo-workflows
#
# Aggregates the per-package Makefiles (each includes conventions.mk). CI runs
# `make validate`, which is the same command to run locally before pushing.
#
#   make validate    build + lint + check, every package
#   make build       render every package
#   make lint        argo lint the environment builds
#   make check       conftest policy over the environment builds
#   make fmt         prettier --write
#   make tools       fail early listing anything not installed

include vars.mk

# Discovered, not listed: a new package with a Makefile joins automatically.
PACKAGES := $(patsubst %/Makefile,%,$(wildcard workflows/templates/*/Makefile \
	workflows/*/Makefile environments/*/Makefile))

.DEFAULT_GOAL := validate

# conventions.mk defines these for a single package; at the root they fan out.
.PHONY: build lint check fmt fmt-check validate clean packages

define for_each
	@failed=0; \
	for p in $(PACKAGES); do \
		echo "::group::$(1) $$p"; \
		$(MAKE) --no-print-directory -C $$p $(1) || failed=1; \
		echo "::endgroup::"; \
	done; \
	exit $$failed
endef

build:
	$(call for_each,build)

lint:
	$(call for_each,lint)

check:
	$(call for_each,check)

validate:
	$(call for_each,validate)

clean:
	$(call for_each,clean)

# Formatting is repo-wide rather than per-package: prettier reads .prettierignore
# and .prettierrc.yaml from the repo root, which is where vendored upstream is
# excluded and where markdown's proseWrap override lives.
fmt:
	@$(PRETTIER) --write "**/*.yaml" "**/*.md" >/dev/null
	@echo "✅ fmt"

fmt-check:
	@$(PRETTIER) --check "**/*.yaml" "**/*.md"

packages:
	@printf '%s\n' $(PACKAGES)
