mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }
}

variables {
  # Forced by the Repository tag regex (docs/tagging-policy.md), not "any owner". These runs can't
  # tell a threaded var.github_owner from a hardcoded default; github_oidc_role.tftest.hcl covers that.
  # The GitHub owner/repo IDs are left at their real defaults (99756598, 1394684072, 1386380543), which
  # the subject assertions expect; a wrong or swapped ID fails, a hardcoded copy of the same value would not.
  github_owner = "goncalofileno"
  alert_email  = "alerts@example.com"
}

run "baseline_roles_trust_only_the_expected_subjects" {
  command = apply

  assert {
    condition     = jsondecode(module.baseline_plan.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:goncalofileno@99756598/aws-account-baseline@1394684072:pull_request"]
    error_message = "baseline-plan must only trust pull requests of this repo."
  }

  assert {
    condition     = jsondecode(module.baseline_apply.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:goncalofileno@99756598/aws-account-baseline@1394684072:environment:production"]
    error_message = "baseline-apply must only trust the protected production environment."
  }

  assert {
    condition     = jsondecode(module.baseline_plan.assume_role_policy).Statement[0].Principal.Federated == aws_iam_openid_connect_provider.github.arn
    error_message = "baseline-plan must federate with the account's GitHub OIDC provider."
  }

  assert {
    condition     = jsondecode(module.baseline_apply.assume_role_policy).Statement[0].Principal.Federated == aws_iam_openid_connect_provider.github.arn
    error_message = "baseline-apply must federate with the account's GitHub OIDC provider."
  }
}

run "baseline_plan_only_writes_the_lock_file" {
  command = apply

  # Fail-closed guard, kept as a readable first line of defence even though the exact
  # comparison below subsumes it: no plan Allow action may be a bare "*" or have a wildcard
  # in its service prefix.
  assert {
    condition = alltrue([
      for a in flatten([for s in jsondecode(module.baseline_plan.policy).Statement : s.Action if s.Effect == "Allow"]) :
      !can(regex("^[^:]*\\*", a))
    ])
    error_message = "No plan Allow action may be a bare wildcard or have a wildcard service prefix."
  }

  # Exact, ordered statement list: catches any added, removed, renamed or reordered statement
  # (e.g. a new Sid smuggling in an extra grant).
  assert {
    condition = [for s in jsondecode(module.baseline_plan.policy).Statement : s.Sid] == [
      "StateList", "StateRead", "StateLock", "IamRead", "CloudTrailRead", "BudgetsRead", "TrailBucketConfigRead",
    ]
    error_message = "baseline-plan policy must declare exactly these statements, in this order."
  }

  # True allow-list: every statement's Effect/Action/Resource must match exactly. Action and
  # Resource are normalised with flatten([...]) so a single string and a one-element list
  # compare equal. None of these statements carry a Condition today; the comparison only
  # extracts Effect/Action/Resource, so a future statement gaining a Condition would need
  # this assert extended on both sides (add Condition = s.Condition to the actual-side for
  # expression below, and to the matching entry in the expected map) or its Condition would
  # go entirely unchecked here.
  assert {
    condition = {
      for s in jsondecode(module.baseline_plan.policy).Statement :
      s.Sid => { Effect = s.Effect, Action = flatten([s.Action]), Resource = flatten([s.Resource]) }
      } == {
      StateList      = { Effect = "Allow", Action = ["s3:ListBucket"], Resource = ["arn:aws:s3:::gf-tfstate-123456789012"] }
      StateRead      = { Effect = "Allow", Action = ["s3:GetObject"], Resource = ["arn:aws:s3:::gf-tfstate-123456789012/aws-account-baseline/terraform.tfstate"] }
      StateLock      = { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = ["arn:aws:s3:::gf-tfstate-123456789012/aws-account-baseline/terraform.tfstate.tflock"] }
      IamRead        = { Effect = "Allow", Action = ["iam:Get*", "iam:List*"], Resource = ["*"] }
      CloudTrailRead = { Effect = "Allow", Action = ["cloudtrail:Describe*", "cloudtrail:Get*", "cloudtrail:List*"], Resource = ["*"] }
      BudgetsRead    = { Effect = "Allow", Action = ["budgets:ViewBudget", "budgets:ListTagsForResource"], Resource = ["arn:aws:budgets::123456789012:budget/*"] }
      TrailBucketConfigRead = {
        Effect = "Allow"
        Action = [
          "s3:GetBucket*", "s3:GetEncryptionConfiguration", "s3:GetLifecycleConfiguration",
          "s3:GetAccelerateConfiguration", "s3:GetReplicationConfiguration", "s3:ListBucket",
        ]
        Resource = ["arn:aws:s3:::gf-cloudtrail-123456789012"]
      }
    }
    error_message = "baseline-plan policy statements must match exactly (Effect, Action, Resource) — no broadening, no extra actions or resources on any statement."
  }
}

run "baseline_apply_is_scoped_to_baseline_resources" {
  command = apply

  # Fail-closed guard, kept as a readable first line of defence even though the exact
  # comparison below subsumes it (this does not flag legitimate action-level wildcards like
  # "iam:*" or "s3:*", since their "*" falls after the colon, not in the service prefix).
  assert {
    condition = alltrue([
      for a in flatten([for s in jsondecode(module.baseline_apply.policy).Statement : s.Action if s.Effect == "Allow"]) :
      !can(regex("^[^:]*\\*", a))
    ])
    error_message = "No apply Allow action may be a bare wildcard or have a wildcard service prefix."
  }

  # Exact, ordered statement list: catches any added, removed, renamed or reordered statement
  # (e.g. a smuggled-in extra IAM-management statement).
  assert {
    condition = [for s in jsondecode(module.baseline_apply.policy).Statement : s.Sid] == [
      "StateList", "StateReadWrite", "StateLock", "IamRead", "GithubOidcProvider", "ManagedIam",
      "CloudTrailManage", "CloudTrailRead", "Budgets", "TrailBucket",
    ]
    error_message = "baseline-apply policy must declare exactly these statements, in this order."
  }

  # True allow-list: every statement's Effect/Action/Resource must match exactly. TrailBucket is
  # deliberately scoped to the bucket only (no "/*"): Terraform never reads or writes CloudTrail
  # log objects (no force_destroy), so apply has no legitimate reason to touch bucket objects.
  # None of these statements carry a Condition today; the comparison only extracts
  # Effect/Action/Resource, so a future statement gaining a Condition would need this assert
  # extended on both sides (add Condition = s.Condition to the actual-side for expression
  # below, and to the matching entry in the expected map) or its Condition would go entirely
  # unchecked here.
  assert {
    condition = {
      for s in jsondecode(module.baseline_apply.policy).Statement :
      s.Sid => { Effect = s.Effect, Action = flatten([s.Action]), Resource = flatten([s.Resource]) }
      } == {
      StateList      = { Effect = "Allow", Action = ["s3:ListBucket"], Resource = ["arn:aws:s3:::gf-tfstate-123456789012"] }
      StateReadWrite = { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject"], Resource = ["arn:aws:s3:::gf-tfstate-123456789012/aws-account-baseline/terraform.tfstate"] }
      StateLock      = { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = ["arn:aws:s3:::gf-tfstate-123456789012/aws-account-baseline/terraform.tfstate.tflock"] }
      IamRead        = { Effect = "Allow", Action = ["iam:Get*", "iam:List*"], Resource = ["*"] }
      GithubOidcProvider = {
        Effect   = "Allow"
        Action   = ["iam:*OpenIDConnectProvider*"]
        Resource = ["arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"]
      }
      ManagedIam = {
        Effect = "Allow"
        Action = ["iam:*"]
        Resource = [
          "arn:aws:iam::123456789012:role/cv-site-*",
          "arn:aws:iam::123456789012:role/baseline-*",
          "arn:aws:iam::123456789012:policy/cv-site-*",
        ]
      }
      CloudTrailManage = { Effect = "Allow", Action = ["cloudtrail:*"], Resource = ["arn:aws:cloudtrail:eu-north-1:123456789012:trail/baseline-management-events"] }
      CloudTrailRead   = { Effect = "Allow", Action = ["cloudtrail:Describe*", "cloudtrail:Get*", "cloudtrail:List*"], Resource = ["*"] }
      Budgets          = { Effect = "Allow", Action = ["budgets:ModifyBudget", "budgets:ViewBudget", "budgets:TagResource", "budgets:UntagResource", "budgets:ListTagsForResource"], Resource = ["arn:aws:budgets::123456789012:budget/*"] }
      TrailBucket      = { Effect = "Allow", Action = ["s3:*"], Resource = ["arn:aws:s3:::gf-cloudtrail-123456789012"] }
    }
    error_message = "baseline-apply policy statements must match exactly (Effect, Action, Resource) — no broadening, no extra actions or resources on any statement."
  }
}
