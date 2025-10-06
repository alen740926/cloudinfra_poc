terraform {
  backend "s3" {
    bucket         = "my-tf-state"
    key            = "envs/dev/api-gateway/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tf-state-locks"
    encrypt        = true
  }
}