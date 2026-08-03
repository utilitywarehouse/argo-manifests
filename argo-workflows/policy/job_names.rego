# Validate the `job-name` parameters that name exec-kube's remote Jobs.
#
# `argo lint` proves every execute-job call supplies a job-name. It cannot prove the
# values are usable: the Job name is assembled by exec-kube at runtime as
# `<job-name>-<workflow.uid[:8]>`. Two dispatches of one run sharing a job-name
# collide in Kubernetes; a job-name that is not DNS-1123 is rejected outright. Both
# fail in a remote cluster long after CI.
#
# Run with --combine so uniqueness can be checked across documents.
# See argo-workflows/docs/template-naming.md#naming-the-remote-job.

package main

executor := "step-executor-remote-namespace"

# Job name is <job-name>-<uid[:8]> and Kubernetes caps names at 63. exec-kube
# truncates rather than failing, which silently reintroduces collisions.
max_len := 54

dns_1123 := `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$`

templates contains {"wt": wt, "template": t} if {
	some doc in input
	wt := doc.contents
	wt.kind == "WorkflowTemplate"
	some t in wt.spec.templates
}

# Both shapes a template can invoke things in.
calls_of(t) := array.concat(
	[s | some group in object.get(t, "steps", []); some s in group],
	[s | some s in object.get(t, ["dag", "tasks"], [])],
)

param(call, name) := value if {
	some p in call.arguments.parameters
	p.name == name
	value := p.value
}

# Every execute-job dispatch, deduplicated: the same template rendered for two
# environments is one dispatch, not a collision.
dispatches contains {"owner": owner, "name": name} if {
	some entry in templates
	some call in calls_of(entry.template)
	call.templateRef.name == executor
	call.templateRef.template == "execute-job"
	owner := sprintf("%s/%s", [entry.wt.metadata.name, entry.template.name])
	name := param(call, "job-name")
}

literal(name) if not regex.match(`\{\{`, name)

# Parameters a job-name interpolates, e.g. op-name, system-key.
discriminators contains ref if {
	some d in dispatches
	some m in regex.find_n(`inputs\.parameters(?:\.[a-z0-9-]+|\['[a-z0-9-]+'\])`, d.name, -1)
	ref := regex.replace(m, `inputs\.parameters\.?\[?'?|'?\]?$`, "")
}

# A ref wrapped in sprig.replace is sanitised on the way in (system-key is
# snake_case), so its raw values are exempt from the DNS-1123 check.
sanitised contains ref if {
	some d in dispatches
	contains(d.name, "sprig.replace")
	some m in regex.find_n(`inputs\.parameters(?:\.[a-z0-9-]+|\['[a-z0-9-]+'\])`, d.name, -1)
	ref := regex.replace(m, `inputs\.parameters\.?\[?'?|'?\]?$`, "")
}

deny contains msg if {
	some d in dispatches
	literal(d.name)
	not regex.match(dns_1123, d.name)
	msg := sprintf(
		"%s: job-name %q is not DNS-1123 (lowercase, digits, '-'; no '_', no capitals)",
		[d.owner, d.name],
	)
}

deny contains msg if {
	some d in dispatches
	literal(d.name)
	count(d.name) > max_len
	msg := sprintf(
		"%s: job-name %q is %d chars, over the %d limit; exec-kube truncates silently",
		[d.owner, d.name, count(d.name), max_len],
	)
}

# The failure this convention exists to prevent.
deny contains msg if {
	some d in dispatches
	literal(d.name)
	owners := {o | some x in dispatches; x.name == d.name; o := x.owner}
	count(owners) > 1
	msg := sprintf(
		"job-name %q is used by %d dispatches (%s); one workflow composing both gets 'object is being deleted ... already exists'",
		[d.name, count(owners), concat(", ", sort(owners))],
	)
}

# What a call invokes. The discriminator only has to be unique per callee: the
# rest of the job-name is a literal the callee owns, so two DIFFERENT callees
# given the same value still produce different Job names
# (ledger-snapshot-before vs transaction-log-before).
callee_of(call) := c if {
	c := sprintf("%s/%s", [call.templateRef.name, call.templateRef.template])
}

callee_of(call) := c if {
	not call.templateRef
	c := sprintf("(local)/%s", [call.template])
}

# A templated job-name is only unique if its discriminator varies per call to the
# same callee.
deny contains msg if {
	some entry in templates
	some param_name in discriminators
	some callee in {callee_of(c) | some c in calls_of(entry.template)}
	values := [v |
		some call in calls_of(entry.template)
		callee_of(call) == callee
		v := param(call, param_name)
		literal(v)
	]
	some v in values
	count([x | some x in values; x == v]) > 1
	msg := sprintf(
		"%s/%s: passes %s=%q to more than one %s step; it names their Jobs, so they must differ",
		[entry.wt.metadata.name, entry.template.name, param_name, v, callee],
	)
}

deny contains msg if {
	some entry in templates
	some call in calls_of(entry.template)
	some p in call.arguments.parameters
	p.name in discriminators
	not p.name in sanitised
	literal(p.value)
	not regex.match(dns_1123, p.value)
	msg := sprintf(
		"%s/%s: passes %s=%q, which names a Job but is not DNS-1123",
		[entry.wt.metadata.name, entry.template.name, p.name, p.value],
	)
}
