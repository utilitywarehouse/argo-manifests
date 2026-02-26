.DEFAULT_GOAL := get-upstream

# https://github.com/argoproj/argo-workflows/releases
VERSION=v4.0.1
NAMESPACE=sys-argo-workflows
GITHUB_TOKEN ?=
CURL_AUTH = $(if $(GITHUB_TOKEN),-H "Authorization: token $(GITHUB_TOKEN)")
PLUGINS = \
  slack:argoproj-labs/argo-workflows-slack-executor-plugin:main:slack-executor-plugin-configmap.yaml

.PHONY: get-upstream

get-upstream:
	rm -rf cluster/upstream/crds namespaced/server/upstream namespaced/controller/upstream
	mkdir -p cluster cluster/upstream/crds namespaced namespaced/server/upstream namespaced/controller/upstream
	curl -Ls https://github.com/argoproj/argo-workflows/releases/download/${VERSION}/namespace-install.yaml > /tmp/argo.yaml

	@for name in $$(yq e 'select(.kind == "CustomResourceDefinition") | .metadata.name' /tmp/argo.yaml | grep -v null | grep -v '^---'); do \
		yq e "select(.kind == \"CustomResourceDefinition\" and .metadata.name == \"$$name\")" /tmp/argo.yaml > cluster/upstream/crds/$$(echo "$$name" | tr '[:upper:]' '[:lower:]').yaml; \
	done

	yq e 'select(.kind != "CustomResourceDefinition" and .kind != "ClusterRole" and .kind != "ClusterRoleBinding")' /tmp/argo.yaml > /tmp/_namespaced-all.yaml

	@for kind in $$(yq e '.kind' /tmp/_namespaced-all.yaml | sort | uniq | grep -v null); do \
		yq e "select(.kind == \"$$kind\" and (.metadata.name // \"\" | contains(\"argo-server\")))" /tmp/_namespaced-all.yaml > namespaced/server/upstream/$$(echo "$$kind" | tr '[:upper:]' '[:lower:]').yaml; \
		if [ ! -s namespaced/server/upstream/$$(echo "$$kind" | tr '[:upper:]' '[:lower:]').yaml ]; then \
			rm namespaced/server/upstream/$$(echo "$$kind" | tr '[:upper:]' '[:lower:]').yaml; \
		fi; \
	done

	yq e 'select((.metadata.name // "" | contains("argo-server") | not))' /tmp/_namespaced-all.yaml > /tmp/_namespaced-nonserver.yaml

	@for kind in $$(yq e '.kind' /tmp/_namespaced-nonserver.yaml | sort | uniq | grep -v null); do \
		yq e "select(.kind == \"$$kind\")" /tmp/_namespaced-nonserver.yaml > namespaced/controller/upstream/$$(echo "$$kind" | tr '[:upper:]' '[:lower:]').yaml; \
		if [ ! -s namespaced/controller/upstream/$$(echo "$$kind" | tr '[:upper:]' '[:lower:]').yaml ]; then \
			rm namespaced/controller/upstream/$$(echo "$$kind" | tr '[:upper:]' '[:lower:]').yaml; \
		fi; \
	done



.PHONY: get-upstream-plugins

get-upstream-plugins:
	rm -rf namespaced/plugins/upstream
	mkdir -p namespaced/plugins/upstream
	@for entry in $(PLUGINS); do \
		name=$$(echo "$$entry" | cut -d':' -f1); \
		repo=$$(echo "$$entry" | cut -d':' -f2-3); \
		branch=$$(echo "$$entry" | cut -d':' -f4); \
		file=$$(echo "$$entry" | cut -d':' -f5); \
		echo "Fetching plugin: $$name ($$file from $$repo@$$branch)"; \
		curl -Ls $(CURL_AUTH) "https://raw.githubusercontent.com/$$repo/$$branch/$$file" \
			> namespaced/plugins/upstream/$$name-$$file; \
		if [ ! -s namespaced/plugins/upstream/$$name-$$file ]; then \
			echo "WARNING: $$name plugin download empty or failed"; \
			rm -f namespaced/plugins/upstream/$$name-$$file; \
		fi; \
	done
