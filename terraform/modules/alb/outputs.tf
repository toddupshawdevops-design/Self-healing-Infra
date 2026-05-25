output "dns_name" {
  value = aws_lb.alb.dns_name
}

output "security_group_id" {
  value = aws_security_group.alb.id
}

output "target_group_arn" {
  value = aws_lb_target_group.app.arn
}

output "arn_suffix" {
  value = replace(
    aws_lb.alb.arn,
    "arn:aws:elasticloadbalancing:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:loadbalancer/",
    ""
  )
}

output "target_group_arn_suffix" {
  value = replace(
    aws_lb_target_group.app.arn,
    "arn:aws:elasticloadbalancing:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:targetgroup/",
    ""
  )
}
