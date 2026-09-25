mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }
}

variables {
  github_owner = "test-owner"
}

run "baseline_roles_trust_only_the_expected_subjects" {
  command = apply

  assert {
    condition     = jsondecode(module.baseline_plan.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:test-owner/aws-account-baseline:pull_request"]
    error_message = "baseline-plan must only trust pull requests of this repo."
  }

  assert {
    condition     = jsondecode(module.baseline_apply.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:test-owner/aws-account-baseline:environment:production"]
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

  assert {
    condition = alltrue([
      for s in jsondecode(module.baseline_plan.policy).Statement :
      !anytrue([for a in flatten([s.Action]) : contains(["s3:PutObject", "s3:DeleteObject"], a)]) ||
      alltrue([for r in flatten([s.Resource]) : endswith(r, ".tflock")])
    ])
    error_message = "baseline-plan may only write/delete the state lock file."
  }

  assert {
    condition = alltrue([
      for a in flatten([for s in jsondecode(module.baseline_plan.policy).Statement : s.Action]) :
      can(regex("^[a-z0-9-]+:(Get|List|Describe|View)", a)) || contains(["s3:PutObject", "s3:DeleteObject"], a)
    ])
    error_message = "baseline-plan must otherwise be read-only."
  }

  assert {
    condition     = contains(one([for s in jsondecode(module.baseline_plan.policy).Statement : s if s.Sid == "StateLock"]).Resource, "arn:aws:s3:::gf-tfstate-123456789012/aws-account-baseline/terraform.tfstate.tflock")
    error_message = "Lock file permissions must target the state key's .tflock object."
  }

  # Fail-closed guard: no plan Allow action may be a bare "*" or have a wildcard in its service
  # prefix. None of the guards above look at an action outside the s3:PutObject/DeleteObject and
  # Get/List/Describe/View patterns, so a bare {Effect=Allow, Action="*", Resource="*"} statement
  # would otherwise slip through untested.
  assert {
    condition = alltrue([
      for a in flatten([for s in jsondecode(module.baseline_plan.policy).Statement : s.Action if s.Effect == "Allow"]) :
      !can(regex("^[^:]*\\*", a))
    ])
    error_message = "No plan Allow action may be a bare wildcard or have a wildcard service prefix."
  }

  # Allow-list (not a pattern): every action granted must be one of the exact actions the plan
  # policy is meant to carry. Catches an unlisted action that still happens to match the
  # Get/List/Describe/View prefix pattern above (e.g. a broader read permission on a service the
  # plan role has no business reading).
  assert {
    condition = alltrue([
      for a in flatten([for s in jsondecode(module.baseline_plan.policy).Statement : s.Action if s.Effect == "Allow"]) :
      contains([
        "s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
        "iam:Get*", "iam:List*",
        "cloudtrail:Describe*", "cloudtrail:Get*", "cloudtrail:List*",
        "budgets:ViewBudget", "budgets:ListTagsForResource",
        "s3:GetBucket*", "s3:GetEncryptionConfiguration", "s3:GetLifecycleConfiguration",
        "s3:GetAccelerateConfiguration", "s3:GetReplicationConfiguration",
      ], a)
    ])
    error_message = "baseline-plan must only grant the explicit action allow-list."
  }

  assert {
    condition = (
      one([for s in jsondecode(module.baseline_plan.policy).Statement : s if s.Sid == "StateRead"]).Action == ["s3:GetObject"] &&
      one([for s in jsondecode(module.baseline_plan.policy).Statement : s if s.Sid == "StateRead"]).Resource == "arn:aws:s3:::gf-tfstate-123456789012/aws-account-baseline/terraform.tfstate"
    )
    error_message = "StateRead must be exactly s3:GetObject on the state key, nothing broader."
  }
}

run "baseline_apply_is_scoped_to_baseline_resources" {
  command = apply

  assert {
    condition = one([for s in jsondecode(module.baseline_apply.policy).Statement : s if s.Sid == "ManagedIam"]).Resource == [
      "arn:aws:iam::123456789012:role/cv-site-*",
      "arn:aws:iam::123456789012:role/baseline-*",
      "arn:aws:iam::123456789012:policy/cv-site-*",
    ]
    error_message = "baseline-apply may only manage cv-site-* and baseline-* IAM resources."
  }

  assert {
    condition     = one([for s in jsondecode(module.baseline_apply.policy).Statement : s if s.Sid == "CloudTrailManage"]).Resource == "arn:aws:cloudtrail:eu-west-1:123456789012:trail/baseline-management-events"
    error_message = "baseline-apply may only manage the baseline trail."
  }

  # Fail-closed guard: no apply Allow action may be a bare "*" or have a wildcard in its service
  # prefix (this does not flag legitimate action-level wildcards like "iam:*" or "s3:*", since
  # their "*" falls after the colon, not in the service prefix).
  assert {
    condition = alltrue([
      for a in flatten([for s in jsondecode(module.baseline_apply.policy).Statement : s.Action if s.Effect == "Allow"]) :
      !can(regex("^[^:]*\\*", a))
    ])
    error_message = "No apply Allow action may be a bare wildcard or have a wildcard service prefix."
  }

  # iam:* is uniquely powerful (it can touch every IAM resource type, not just roles/policies);
  # it must only ever appear on the ManagedIam statement, whose Resource list is asserted above.
  assert {
    condition = alltrue([
      for s in jsondecode(module.baseline_apply.policy).Statement :
      !(s.Effect == "Allow" && contains(flatten([s.Action]), "iam:*")) || s.Sid == "ManagedIam"
    ])
    error_message = "iam:* may only appear in the ManagedIam statement."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(module.baseline_apply.policy).Statement :
      !(s.Effect == "Allow" && contains(flatten([s.Action]), "cloudtrail:*")) || s.Sid == "CloudTrailManage"
    ])
    error_message = "cloudtrail:* may only appear in the CloudTrailManage statement."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(module.baseline_apply.policy).Statement :
      !(s.Effect == "Allow" && contains(flatten([s.Action]), "s3:*")) || s.Sid == "TrailBucket"
    ])
    error_message = "s3:* may only appear in the TrailBucket statement."
  }

  assert {
    condition = one([for s in jsondecode(module.baseline_apply.policy).Statement : s if s.Sid == "TrailBucket"]).Resource == [
      "arn:aws:s3:::gf-cloudtrail-123456789012",
      "arn:aws:s3:::gf-cloudtrail-123456789012/*",
    ]
    error_message = "TrailBucket must be scoped to exactly the trail bucket and its objects."
  }

  # State access (list/read-write/lock) must stay confined to the state key and its lock object,
  # never a bucket-wide "*" resource.
  assert {
    condition = (
      one([for s in jsondecode(module.baseline_apply.policy).Statement : s if s.Sid == "StateList"]).Resource == "arn:aws:s3:::gf-tfstate-123456789012" &&
      one([for s in jsondecode(module.baseline_apply.policy).Statement : s if s.Sid == "StateReadWrite"]).Resource == "arn:aws:s3:::gf-tfstate-123456789012/aws-account-baseline/terraform.tfstate" &&
      contains(one([for s in jsondecode(module.baseline_apply.policy).Statement : s if s.Sid == "StateLock"]).Resource, "arn:aws:s3:::gf-tfstate-123456789012/aws-account-baseline/terraform.tfstate.tflock")
    )
    error_message = "State access must be confined to the state bucket listing, the state key and its lock object."
  }

  assert {
    condition     = one([for s in jsondecode(module.baseline_apply.policy).Statement : s if s.Sid == "Budgets"]).Resource == "arn:aws:budgets::123456789012:budget/*"
    error_message = "Budgets access must be scoped to budget/*."
  }
}
