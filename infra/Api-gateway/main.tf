terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.0" }
  }
  backend "s3" {
    bucket         = "my-tf-state-gha-poc"
    key            = "envs/poc/api-gw/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
  }
}

provider "aws" { region = "us-east-1" }

data "aws_region" "current" {}
data "aws_caller_identity" "me" {}


############################
# Authorizer Lambda (Node.js)
############################
resource "aws_iam_role" "auth_role" {
  name               = "rest-aad-authorizer-poc"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{ Effect="Allow", Principal={ Service="lambda.amazonaws.com" }, Action="sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "auth_logs" {
  role       = aws_iam_role.auth_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}


# Zip file you build locally: lambda_authorizer.zip (see JS & packaging below)
resource "aws_lambda_function" "authorizer" {
  function_name    = "rest-aad-token-authorizer-poc"
  role             = aws_iam_role.auth_role.arn
  runtime          = "nodejs20.x"
  handler          = "authorizer_handler.handler"

  # go up one level to reach build/
  filename         = "${path.module}/../build/lambda_authorizer.zip"
  source_code_hash = filebase64sha256("${path.module}/../build/lambda_authorizer.zip")

  environment {
    variables = {
      TENANT_ID = var.tenant_id
      AUDIENCE  = var.audience
    }
  }
}

resource "aws_cloudwatch_log_group" "auth_lg" {
  name              = "/aws/lambda/${aws_lambda_function.authorizer.function_name}"
  retention_in_days = 14
}

############################
# REST API (REGIONAL)
############################
resource "aws_api_gateway_rest_api" "api" {
  name        = "demo-rest"
  description = "REST API with Lambda proxy and Azure AD JWT Lambda authorizer"
  endpoint_configuration { types = ["REGIONAL"] }
}

# Resource: /random
resource "aws_api_gateway_resource" "random" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "random"
}

# Lambda TOKEN authorizer (Authorization header -> event.authorizationToken)
resource "aws_api_gateway_authorizer" "auth" {
  name                        = "aad-token-authorizer-poc"
  rest_api_id                 = aws_api_gateway_rest_api.api.id
  type                        = "TOKEN"
  authorizer_uri              = "arn:aws:apigateway:${data.aws_region.current.name}:lambda:path/2015-03-31/functions/${aws_lambda_function.authorizer.arn}/invocations"
  identity_source             = "method.request.header.Authorization"
  authorizer_result_ttl_in_seconds = 60
}

# Method protected by authorizer
resource "aws_api_gateway_method" "get_random" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.random.id
  http_method   = "GET"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.auth.id
}

# Lambda PROXY integration → your existing backend
resource "aws_api_gateway_integration" "proxy" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.random.id
  http_method             = aws_api_gateway_method.get_random.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = "arn:aws:apigateway:${data.aws_region.current.name}:lambda:path/2015-03-31/functions/${var.backend_lambda_arn}/invocations"
}

# Deploy & stage
resource "aws_api_gateway_deployment" "dep" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  triggers = {
    redeploy = sha1(jsonencode([
      aws_api_gateway_resource.random.id,
      aws_api_gateway_method.get_random.id,
      aws_api_gateway_integration.proxy.id,
      aws_lambda_function.authorizer.source_code_hash
    ]))
  }
  depends_on = [aws_api_gateway_integration.proxy]
}

resource "aws_api_gateway_stage" "prod" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  deployment_id = aws_api_gateway_deployment.dep.id
  stage_name    = "prod"
}

############################
# Permissions
############################
# Allow API Gateway to call the EXISTING backend Lambda
resource "aws_lambda_permission" "invoke_backend" {
  count         = var.create_lambda_permission ? 1 : 0
  action        = "lambda:InvokeFunction"
  function_name = var.backend_lambda_arn
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/GET/random"
}

# Allow API Gateway to call the authorizer
resource "aws_lambda_permission" "invoke_authorizer" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.authorizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "arn:aws:execute-api:${data.aws_region.current.name}:${data.aws_caller_identity.me.account_id}:${aws_api_gateway_rest_api.api.id}/authorizers/*"
}

