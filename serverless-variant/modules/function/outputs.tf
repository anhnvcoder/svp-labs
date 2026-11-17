# Both wait for the role policy: Lambda checks the role's permissions when an event source mapping is created.
output "name" {
  description = "Name of the function, available once its role policy exists."
  value       = var.name
  depends_on  = [aws_iam_role_policy.this, aws_lambda_function.this]
}

output "arn" {
  description = "ARN of the function (unqualified), known at plan."
  value       = local.arn
  depends_on  = [aws_iam_role_policy.this, aws_lambda_function.this]
}

output "log_group_name" {
  description = "Log group of the function."
  value       = aws_cloudwatch_log_group.this.name
}
