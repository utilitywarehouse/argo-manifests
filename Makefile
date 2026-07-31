# argo-manifests
#
# Delegates to each product. A product owns its own packages and conventions
# (argo-workflows/conventions.mk); this only exists so the repo root is a working
# entry point — `make validate` here or in argo-workflows does the same thing.
#
# Add a product by adding it to PRODUCTS; it needs to answer the same targets.

PRODUCTS := argo-workflows

.PHONY: validate build lint check fmt fmt-check tools clean

validate build lint check fmt fmt-check tools clean:
	@failed=0; \
	for p in $(PRODUCTS); do \
		$(MAKE) --no-print-directory -C $$p $@ || failed=1; \
	done; \
	exit $$failed
