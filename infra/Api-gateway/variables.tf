variable "backend_lambda_arn" {
  type        = string
  description = "Existing backend Lambda ARN (Lambda proxy integration target)"
  default     = "arn:aws:lambda:us-east-1:179072210594:function:nodejs_backend"
}

variable "tenant_id" {
  type        = string
  description = "Azure AD (Entra ID) tenant ID (GUID)"
  default     = "d1df0ad0-35ed-4c7d-ab1c-e2d152e12025"
}

variable "audience" {
  type        = string
  description = "Expected audience for tokens (e.g., api://<app-id> or the API app's client ID). For multiple, comma-separate."
  default     = "10f78839-7a21-41c7-92f2-a9d8a546f58e"
}

variable "create_lambda_permission" {
  type        = bool
  default     = true
  description = "If true, grant API Gateway permission to invoke the existing backend Lambda"
}