############################
# Outputs
############################
output "random_url" {
  description = "GET with Authorization: Bearer <AAD access_token>"
  value       = "https://${aws_api_gateway_rest_api.api.id}.execute-api.${data.aws_region.current.name}.amazonaws.com/${aws_api_gateway_stage.prod.stage_name}/random"
}