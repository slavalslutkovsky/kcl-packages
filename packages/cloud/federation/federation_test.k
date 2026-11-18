# `kcl test ./...` — expand() against the long form it replaces, and the
# errors a binding that would admit the wrong tokens must raise.
import runtime

_err = lambda bindings: [any] -> str {
  _r = runtime.catch(lambda {
    expand(bindings)
  })
  assert _r, "expected expand(${bindings}) to fail"
  _r
}

# projects/dev/terraform.tfvars config.projects["infra"].workload_identity_pools, as the example XR spells it.
_infra_long = {
  "github-actions-pool" = {
    displayName = "GitHub Actions Pool"
    description = "Identity pool for GitHub Actions integrations"
    providers = {
      "github-actions-provider" = {
        displayName = "GitHub Actions Provider"
        attributeMapping = {
          "attribute.actor" = "assertion.actor"
          "attribute.repository" = "assertion.repository"
          "attribute.repository_owner" = "assertion.repository_owner"
          "google.subject" = "assertion.sub"
        }
        attributeCondition = "assertion.repository_owner == 'dbank-infrastructure-dc-dglz'"
        identityProvider = {
          oidc = {issuerUri = "https://token.actions.githubusercontent.com"}
        }
      }
    }
  }
}

test_github_owner_is_the_terraform_pool = lambda {
  assert expand([{client = "github", owner = "dbank-infrastructure-dc-dglz"}]) == _infra_long
}

test_github_repositories_and_pool_id = lambda {
  _p = expand([{client = "github", pool = "github-actions-agent-deploy", repositories = ["o/a", "o/b"]}])
  assert [_k for _k in _p] == ["github-actions-agent-deploy"]
  assert _p["github-actions-agent-deploy"].providers["github-actions-provider"].attributeCondition == "attribute.repository in ['o/a', 'o/b']"
}

test_jira_via_github_is_a_separate_pool_narrowed_to_dispatches = lambda {
  _p = expand([
    {client = "github", owner = "o"}
    {client = "github", ticket = "jira", repositories = ["o/deployer"]}
  ])
  assert [_k for _k in _p] == ["github-actions-pool", "jira-github"]
  assert _p["jira-github"].displayName == "Jira via GitHub Actions"
  assert _p["jira-github"].providers["github-actions-provider"].attributeCondition == "attribute.repository in ['o/deployer'] && assertion.event_name in ['repository_dispatch', 'workflow_dispatch']"
}

test_jira_via_gitlab_uses_pipeline_source = lambda {
  _pv = expand([{client = "gitlab", ticket = "jira", owner = "grp"}])["jira-gitlab"].providers["gitlab-ci-provider"]
  assert _pv.attributeCondition == "assertion.namespace_path == 'grp' && assertion.pipeline_source in ['trigger', 'api']"
  assert _pv.identityProvider.oidc == {issuerUri = "https://gitlab.com"}
}

test_github_issues_native_events = lambda {
  _pv = expand([{client = "github", ticket = "github-issues", owner = "o"}])["github-issues-github"].providers["github-actions-provider"]
  assert _pv.attributeCondition.endswith("assertion.event_name in ['issues', 'issue_comment']")
}

# Jira, ClickUp and monday.com on one repository: separate pools only because
# each is pinned to its own workflow.
test_ticket_managers_pinned_to_their_workflows = lambda {
  _wf = lambda name: str -> str {
    "acme/ops/.github/workflows/${name}.yml"
  }
  _p = expand([{client = "github", ticket = _t, workflows = [_wf(_t)]} for _t in ["jira", "clickup", "monday"]])
  assert [_k for _k in _p] == ["jira-github", "clickup-github", "monday-github"]
  assert [_p[_k].displayName for _k in _p] == ["Jira via GitHub Actions", "ClickUp via GitHub Actions", "monday.com via GitHub Actions"]
  assert _p["clickup-github"].providers["github-actions-provider"].attributeCondition == "assertion.event_name in ['repository_dispatch', 'workflow_dispatch'] && assertion.workflow_ref.startsWith('acme/ops/.github/workflows/clickup.yml@')"
  _two = expand([{client = "github", ticket = "monday", workflows = [_wf("monday") + "@refs/heads/main", _wf("board")]}])["monday-github"].providers["github-actions-provider"]
  assert _two.attributeCondition.endswith("(assertion.workflow_ref == 'acme/ops/.github/workflows/monday.yml@refs/heads/main' || assertion.workflow_ref.startsWith('acme/ops/.github/workflows/board.yml@'))")
}

test_ticket_pools_that_admit_the_same_tokens_fail = lambda {
  _wf = "acme/ops/.github/workflows/tickets.yml"
  assert "Jira (jira-github) and ClickUp (clickup-github)" in _err([{client = "github", ticket = "jira", owner = "acme"}, {client = "github", ticket = "clickup", owner = "acme"}])
  assert "admit the same tokens" in _err([{client = "github", ticket = "jira", workflows = [_wf]}, {client = "github", ticket = "monday", workflows = [_wf + "@refs/heads/main"]}]), "same workflow, one pinned to a ref"
  assert "admit the same tokens" in _err([{client = "gitlab", ticket = "asana", repositories = ["g/a", "g/b"]}, {client = "gitlab", ticket = "trello", repositories = ["g/b"]}])
  # Told apart: disjoint repositories, native vs external triggers, a hand-written condition.
  assert len(expand([{client = "gitlab", ticket = "asana", repositories = ["g/a"]}, {client = "gitlab", ticket = "trello", repositories = ["g/b"]}])) == 2
  assert len(expand([{client = "github", ticket = "github-issues", owner = "acme"}, {client = "github", ticket = "jira", owner = "acme"}])) == 2
  assert len(expand([{client = "github", ticket = "jira", owner = "acme", condition = "assertion.ref == 'refs/heads/jira'"}, {client = "github", ticket = "clickup", owner = "acme"}])) == 2
  assert "no workflow claim" in _err([{client = "gitlab", ticket = "jira", owner = "g", workflows = ["g/p/.gitlab-ci.yml"]}])
  assert "workflows are <owner>/<repo>/<path>" in _err([{client = "github", owner = "o", workflows = ["jira.yml"]}])
}

test_self_managed_hosts = lambda {
  _gl = expand([{client = "gitlab", host = "git.corp.example"}])["gitlab-ci-pool"].providers["gitlab-ci-provider"]
  assert _gl.identityProvider.oidc.issuerUri == "https://git.corp.example"
  assert "attributeCondition" not in _gl, "a self-managed GitLab is single-tenant: no condition required"
  _ghes = expand([{client = "github-enterprise", host = "ghe.corp.example", owner = "o"}])["github-enterprise-pool"].providers["github-enterprise-provider"]
  assert _ghes.identityProvider.oidc.issuerUri == "https://ghe.corp.example/_services/token"
  assert _ghes.displayName == "GitHub Enterprise Provider"
}

test_bitbucket_workspace_issuer_and_audience = lambda {
  _pv = expand([{client = "bitbucket", owner = "acme", repositories = ["{1b2c}"], audiences = ["ari:cloud:bitbucket::workspace/{9f8e}"]}])["bitbucket-pipelines-pool"].providers["bitbucket-pipelines-provider"]
  assert _pv.identityProvider.oidc == {issuerUri = "https://api.bitbucket.org/2.0/workspaces/acme/pipelines-config/identity/oidc", allowedAudiences = ["ari:cloud:bitbucket::workspace/{9f8e}"]}
  assert _pv.attributeCondition == "attribute.repository_uuid in ['{1b2c}']", "the workspace is the issuer, not a condition"
}

test_azure_devops_subjects_and_default_audience = lambda {
  _pv = expand([{client = "azure-devops", owner = "0000-org-guid", subjects = ["sc://org/proj/gcp"]}])["azure-pipelines-pool"].providers["azure-pipelines-provider"]
  assert _pv.identityProvider.oidc == {issuerUri = "https://vstoken.dev.azure.com/0000-org-guid", allowedAudiences = ["api://AzureADTokenExchange"]}
  assert _pv.attributeCondition == "assertion.sub in ['sc://org/proj/gcp']"
}

test_custom_client_and_ticket = lambda {
  _p = expand([{
    customClient = {id = "forgejo", label = "Forgejo Actions", issuer = "https://{host}/api/actions", ownerKey = "assertion.repository_owner", triggerClaim = "event_name"}
    customTicket = {id = "youtrack", label = "YouTrack", triggers = {event_name = ["repository_dispatch"]}}
    host = "code.example"
    owner = "o"
    condition = "assertion.ref == 'refs/heads/main' || assertion.ref == 'refs/heads/release'"
  }])
  _pv = _p["youtrack-forgejo"].providers["forgejo-provider"]
  assert _pv.identityProvider.oidc.issuerUri == "https://code.example/api/actions"
  assert _pv.attributeCondition == "assertion.repository_owner == 'o' && assertion.event_name in ['repository_dispatch'] && (assertion.ref == 'refs/heads/main' || assertion.ref == 'refs/heads/release')"
}

test_merge_keeps_long_form_and_rejects_overlap = lambda {
  assert [_k for _k in merge(_infra_long, [{client = "gitlab", owner = "g"}])] == ["github-actions-pool", "gitlab-ci-pool"]
  assert merge({}, []) == {}
  _r = runtime.catch(lambda {
    merge(_infra_long, [{client = "github", owner = "o"}])
  })
  assert "both in workloadIdentityPools and workloadIdentity" in _r
}

test_bindings_that_admit_too_much_fail = lambda {
  assert "shared by every GitHub Actions user" in _err([{client = "github"}])
  assert "shared by every GitHub Actions user" in _err([{client = "github", ticket = "jira"}]), "a dispatch filter alone admits every org"
  assert "cannot be told apart" in _err([{client = "bitbucket", ticket = "jira", owner = "w", audiences = ["a"]}])
  assert "set `audiences`" in _err([{client = "bitbucket", owner = "w"}])
  assert "needs `owner`" in _err([{client = "azure-devops", subjects = ["sc://o/p/c"]}])
  assert "needs `host`" in _err([{client = "github-enterprise", owner = "o"}])
  assert "has no owner claim" in _err([{client = "bitbucket", owner = "w", issuerUri = "https://x.example", audiences = ["a"]}])
  assert "quotes or backslashes" in _err([{client = "github", owner = "o' || true || '"}])
  assert "unknown git client" in _err([{client = "gitea"}])
  assert "unknown ticket system" in _err([{client = "github", owner = "o", ticket = "bugzilla"}])
  assert "exactly one of client or customClient" in _err([{owner = "o"}])
  assert "bound twice" in _err([{client = "github", owner = "o"}, {client = "github", owner = "p"}])
  assert "4-32 of [a-z0-9-]" in _err([{client = "github", owner = "o", pool = "gcp-pool"}])
  assert "only the first binding" in _err([{client = "github", owner = "o"}, {client = "github", owner = "o", provider = "second", displayName = "X"}])
}

# ---- access: the same entries on GCP, AWS and Azure ---------------------------------
test_access_roles_and_names = lambda {
  _as = access_list([{client = "github", owner = "acme", role = "write"}, {client = "gitlab", ticket = "jira", repositories = ["g/a"], provider = "jira-trigger"}])
  assert [_a.role for _a in _as] == ["write", "read"], "role defaults to read"
  assert [access_name(_a) for _a in _as] == ["github-actions-pool", "jira-gitlab-jira-trigger"]
  assert "admit the same tokens" in runtime.catch(lambda {
    access_list([{client = "github", ticket = "jira", owner = "acme"}, {client = "github", ticket = "clickup", owner = "acme", role = "admin"}])
  }), "access entries get the same overlap check as pools"
}

test_gcp_members = lambda {
  _p = "iam.googleapis.com/projects/42/locations/global/workloadIdentityPools"
  assert gcp_members(Binding {client = "github", owner = "acme"}, "42") == ["principalSet://${_p}/github-actions-pool/*"], "owner: the pool's provider condition narrows, the grant names the pool"
  assert gcp_members(Binding {client = "gitlab", repositories = ["g/a", "g/b"]}, "42") == ["principalSet://${_p}/gitlab-ci-pool/attribute.project_path/g/a", "principalSet://${_p}/gitlab-ci-pool/attribute.project_path/g/b"]
  assert gcp_members(Binding {client = "github", ticket = "jira", subjects = ["repo:a/b:ref:refs/heads/main"]}, "42") == ["principal://${_p}/jira-github/subject/repo:a/b:ref:refs/heads/main"]
}

test_aws_trust = lambda {
  _t = aws_trust(Binding {client = "github", repositories = ["acme/app"]}, "111122223333")
  _s = _t.Statement[0]
  assert _s.Principal.Federated == "arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com"
  assert _s.Condition == {StringEquals = {"token.actions.githubusercontent.com:aud" = ["sts.amazonaws.com"]}, StringLike = {"token.actions.githubusercontent.com:sub" = ["repo:acme/app:*"]}}
  _bb = aws_trust(Binding {client = "bitbucket", owner = "acme", audiences = ["ari:cloud:bitbucket::workspace/{w}"]}, "1")
  assert _bb.Statement[0].Condition.StringLike == {"api.bitbucket.org/2.0/workspaces/acme/pipelines-config/identity/oidc:sub" = ["*"]}, "the workspace is the issuer"
  assert aws_subjects(Binding {client = "gitlab", owner = "grp"}) == ["project_path:grp/*"]
}

test_aws_and_azure_refuse_what_sub_cannot_carry = lambda {
  _e = lambda b: {str:} -> str {
    runtime.catch(lambda {
      aws_trust(Binding {**b}, "1")
    })
  }
  assert "ticket cannot be expressed in an AWS trust" in _e({client = "github", ticket = "jira", owner = "acme"})
  assert "workflows cannot be expressed" in _e({client = "github", workflows = ["a/b/.github/workflows/x.yml"]})
  assert "set `audiences`" in _e({client = "gitlab", owner = "g"}), "GitLab's aud is whatever the pipeline asks for"
  assert "needs `subjects`" in _e({client = "azure-devops", owner = "org-guid"})
  assert "match the token's sub exactly" in runtime.catch(lambda {
    azure_subjects(Binding {client = "github", owner = "acme"})
  })
  assert azure_subjects(Binding {client = "github", owner = "acme", subjects = ["repo:acme/app:environment:prod"]}) == ["repo:acme/app:environment:prod"]
  assert audiences_for(Binding {client = "github", owner = "acme"}, "azure") == ["api://AzureADTokenExchange"]
}
