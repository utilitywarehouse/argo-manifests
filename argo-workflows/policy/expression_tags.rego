# Reject a `{{...}}` tag nested inside a `{{= ... }}` expression.
#
# Argo's tag scanner does not nest. It opens at `{{` and closes at the FIRST `}}`,
# so an inner tag's closing braces end the outer expression — expr is handed a
# string literal cut in half, fails to parse, and the controller emits the tag
# VERBATIM rather than failing the node. Scanning then resumes past that point, so
# the tags after it resolve normally and the value looks half-substituted:
#
#   {{=inputs.parameters['dry-run'] == 'true'
#      ? "... string_to_array('{{inputs.parameters.account-ids}}', ',') ..."   <- raw
#      : "... string_to_array('0569f60d-…', ',') ..."}}                        <- resolved
#
# Nothing in Argo goes red. The literal text ships to whatever consumes it and
# surfaces there — for a query executor, as `syntax error at or near "{"` against a
# remote database, mid-run.
#
# Reference parameters from INSIDE the expression instead, concatenating with `+`:
#
#   {{=inputs.parameters['x'] == 'a' ? "SELECT … '" + inputs.parameters['y'] + "' …" : "…"}}
#
# Keep each string literal on one line; `>-` folds the joins between them.
#
# A step that needs to CHOOSE a statement is usually a domain script rather than a
# template: see argo-workflows/docs/choosing-a-step.md.
# See argo-workflows/docs/data-flow.md#never-nest-a-tag-inside-an-expression.
#
# Shares its package with job_names.rego and job_templates.rego.

package main

# The tag as the scanner sees it: `{{=` to the first `}}`, newlines included.
expr_tag_pattern := `(?s)\{\{=.*?\}\}`

nested contains {"owner": owner, "tag": tag} if {
	some doc in input
	wt := doc.contents
	is_object(wt)
	owner := object.get(wt, ["metadata", "name"], "<unnamed>")
	walk(wt, [_, node])
	is_string(node)
	some tag in regex.find_n(expr_tag_pattern, node, -1)

	# Anything after the opening `{{=`. The trailing `}}` carries no `{{`.
	contains(substring(tag, 3, -1), "{{")
}

deny contains msg if {
	some n in nested
	msg := sprintf(
		"%s: a {{...}} tag is nested inside a {{= ... }} expression (%q) — the scanner closes the expression at the inner tag's }}, so it is never evaluated and ships as literal text; concatenate with + from inside the expression instead",
		[n.owner, trim_space(regex.replace(substring(n.tag, 0, 120), `\s+`, " "))],
	)
}
