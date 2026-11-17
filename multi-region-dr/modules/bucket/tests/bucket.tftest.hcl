# Validation rule of the name, then what replication and the destroy of a session rely on: versioning, public access
# blocked, ACLs off, TLS only, and a bucket the destroy empties. The AWS provider is a mock.

mock_provider "aws" {}

variables {
  name = "svp-lab-dr-media-000000000000-ap-southeast-1"
}

run "bucket" {
  command = plan

  assert {
    condition     = aws_s3_bucket_versioning.this.versioning_configuration[0].status == "Enabled"
    error_message = "Replication needs versioning on."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.this.block_public_acls && aws_s3_bucket_public_access_block.this.block_public_policy && aws_s3_bucket_public_access_block.this.ignore_public_acls && aws_s3_bucket_public_access_block.this.restrict_public_buckets
    error_message = "Every public access setting is blocked."
  }

  assert {
    condition     = aws_s3_bucket_ownership_controls.this.rule[0].object_ownership == "BucketOwnerEnforced"
    error_message = "ACLs are off."
  }

  assert {
    condition     = aws_s3_bucket.this.force_destroy
    error_message = "The destroy of a session deletes every version of the probes."
  }
}

run "name_outside_the_lab" {
  command = plan

  variables {
    name = "svp-prd-media-000000000000-ap-southeast-1"
  }

  expect_failures = [var.name]
}

run "name_too_long" {
  command = plan

  variables {
    name = "svp-lab-dr-media-000000000000-ap-southeast-1-and-much-much-more-text"
  }

  expect_failures = [var.name]
}

run "name_with_uppercase" {
  command = plan

  variables {
    name = "svp-lab-dr-Media-000000000000-ap-southeast-1"
  }

  expect_failures = [var.name]
}
