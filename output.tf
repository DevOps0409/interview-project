output "elb_url" {
value = aws_alb.Loadbalancer.dns_name
}