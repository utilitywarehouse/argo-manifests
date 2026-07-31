# conventions.mk
#
# Included by every package Makefile under argo-workflows. A "package" is a
# directory kustomize can build: a template package (workflows/templates/<team>),
# a product package (workflows/<product>) or an environment (environments/<env>).
#
# Standard targets, identical in every package and identical locally and in CI:
#
#   build            render with kustomize -> $(BUILD_DIR)/$(PKG).yaml
#   lint             argo lint the rendered output
#   check            conftest policy over the rendered output
#   fmt / fmt-check  prettier
#   validate         build + lint + check
#   clean            remove $(BUILD_DIR)
#
# Only environments render a complete, namespaced graph — that is where kustomize
# applies the `namespace:` transformer, without which templateRefs cannot resolve.
# Every other package sets LINTABLE=no and gets a no-op lint/check.

include $(dir $(lastword $(MAKEFILE_LIST)))vars.mk

PKG ?= $(notdir $(CURDIR))
RENDERED = $(BUILD_DIR)/$(PKG).yaml

KUSTOMIZE_DIR ?= .

LINTABLE ?= yes

.PHONY: build lint check fmt fmt-check validate clean

build:
	@mkdir -p $(BUILD_DIR)
	@$(KUSTOMIZE) build $(KUSTOMIZE_DIR) > $(RENDERED)
	@echo "✅ build $(PKG)"

lint: build
	@if [ "$(LINTABLE)" = "yes" ]; then \
		$(ARGO) lint --offline $(RENDERED); \
	else \
		echo "⏭  lint $(PKG) (templateRefs only resolve in an environment build)"; \
	fi

check: build
	@if [ "$(LINTABLE)" = "yes" ]; then \
		$(CONFTEST) test --policy $(POLICY) --combine $(RENDERED); \
	else \
		echo "⏭  check $(PKG) (policy runs against the environment build)"; \
	fi

fmt:
	@$(PRETTIER) --write "**/*.yaml" >/dev/null
	@echo "✅ fmt $(PKG)"

fmt-check:
	@$(PRETTIER) --check "**/*.yaml"

validate: build lint check

clean:
	@rm -rf $(BUILD_DIR)
