# Parse the Job manifests exec-kube builds from `job-template`.
#
# `job-template` is a *string* inside the WorkflowTemplate, so kustomize, argo lint
# and every other policy treat it as opaque text — the YAML in it is not parsed by
# anything until the controller has substituted the {{...}} tags and exec-kube hands
# the result to the API server. Substitution is raw text with no YAML escaping, so a
# value carrying its own quotes (expr predicates like `{.name == "x"}`, GraphQL
# payloads) closes a quoted scalar early and breaks the manifest. That surfaces in a
# remote cluster, mid-run, as
#
#   invalid job template: failed to parse job manifest: error converting YAML to
#   JSON: yaml: line N: did not find expected ',' or '}'
#
# So: substitute the way Argo does and parse the result. Values come from the
# rendered manifest itself — every literal any caller passes to a parameter of that
# name — preferring one that carries quotes or a `#`, so the check exercises real
# values and a new caller passing a nastier one is covered with no edit here.
#
# Fix a failure by putting the interpolation in a `|-` block scalar, which survives
# arbitrary single-line text:
#
#   - name: SUCCESS_EXPR
#     value: |-
#       {{inputs.parameters.success-expr}}
#
# Run with --combine: the values a parameter is given live in other documents.
# Shares `templates`, `calls_of` and `param` with job_names.rego (same package).

package main

# Every literal value any parameter of this name is given anywhere in the render.
# Multi-line values are kept: a `>-` scalar whose continuation lines are indented
# further keeps its newlines, and injecting those into a block scalar breaks its
# indentation just as surely as a quote breaks a quoted one. Only job-template
# itself is excluded — it is the thing being rendered, never interpolated into one.
param_values[name] contains value if {
	some doc in input
	walk(doc.contents, [_, node])
	is_object(node)
	name := node.name
	is_string(name)
	name != "job-template"
	value := node.value
	is_string(value)
}

# The value worth rendering is the nastiest any caller passes. A newline beats a
# quote: it breaks the block scalar that quotes are escaped into, so a parameter
# carrying both is only proven safe by the newline. sort() makes the pick
# deterministic, nothing more.
worst(name) := sort(multiline)[0] if {
	multiline := {v | some v in param_values[name]; contains(v, "\n")}
	count(multiline) > 0
} else := sort(quoted)[0] if {
	quoted := {v | some v in param_values[name]; regex.match(`["#]`, v)}
	count(quoted) > 0
} else := sort(param_values[name])[0]

# Both tag spellings; hyphenated params must use the bracket form.
substitutions[key] := value if {
	some name, _ in param_values
	key := sprintf("{{inputs.parameters.%s}}", [name])
	value := worst(name)
}

substitutions[key] := value if {
	some name, _ in param_values
	key := sprintf("{{inputs.parameters['%s']}}", [name])
	value := worst(name)
}

# What the controller hands exec-kube.
#
# An expr tag alone on a line emits a whole YAML fragment, chosen at runtime — the
# DSN switch emits `value: "…"` or `valueFrom: {…}`, or a list item, or nothing.
# There is no stand-in that is valid in every one of those positions, so drop the
# line and check the rest of the manifest. Inline expr tags are computed ints
# (deadlines, ttls) -> 1; anything left over ({{workflow.*}}, {{steps.*}}) -> a
# benign token. Substitution runs twice: caller values carry tags of their own.
render(manifest, subs) := out if {
	fragments := regex.replace(manifest, `(?m)^[ \t]*\{\{=.*$`, "")
	exprs := regex.replace(fragments, `\{\{=.*?\}\}`, "1")
	once := strings.replace_n(subs, exprs)
	twice := strings.replace_n(subs, once)
	out := regex.replace(twice, `\{\{[^}]*\}\}`, "x")
}

dispatched_manifests contains {"owner": owner, "manifest": manifest} if {
	some entry in templates
	some call in calls_of(entry.template)
	call.templateRef.name == executor
	call.templateRef.template == "execute-job"
	owner := sprintf("%s/%s", [entry.wt.metadata.name, entry.template.name])
	manifest := param(call, "job-template")
}

broken contains d if {
	some d in dispatched_manifests
	not yaml.is_valid(render(d.manifest, substitutions))
}

# With every parameter tame, the manifest must parse; otherwise the structure itself
# is wrong and blaming a value would mislead.
structural(manifest) if not yaml.is_valid(render(manifest, {}))

# Isolate the parameter at fault: substitute it alone and see if that alone breaks
# the manifest.
culprits(d) := {name |
	some name, _ in param_values
	subs := {k: v |
		some k, v in substitutions
		k in {
			sprintf("{{inputs.parameters.%s}}", [name]),
			sprintf("{{inputs.parameters['%s']}}", [name]),
		}
	}
	not yaml.is_valid(render(d.manifest, subs))
}

deny contains msg if {
	some d in broken
	not structural(d.manifest)
	some name in culprits(d)
	msg := sprintf(
		"%s: job-template does not parse once %q is substituted (%q) — Argo substitutes raw text, so the value's own quotes close the scalar; use a |- block scalar",
		[d.owner, name, worst(name)],
	)
}

deny contains msg if {
	some d in broken
	not structural(d.manifest)
	count(culprits(d)) == 0
	msg := sprintf(
		"%s: job-template does not parse once its parameters are substituted; use |- block scalars for interpolated values",
		[d.owner],
	)
}

deny contains msg if {
	some d in dispatched_manifests
	structural(d.manifest)
	msg := sprintf(
		"%s: job-template is not valid YAML even before its parameters carry anything; exec-kube cannot create the Job",
		[d.owner],
	)
}
