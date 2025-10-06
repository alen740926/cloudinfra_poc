module "api_gateway" {
  source = "../../infra/Api-gateway"   # adjust path as needed

  # Required inputs (these map directly to your variables.tf)
  backend_lambda_arn     = ""
  tenant_id              = ""
  audience               = ""
  create_lambda_permission = true
}