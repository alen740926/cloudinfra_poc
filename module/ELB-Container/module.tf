module "api_gateway" {
  source = "../../infra/NLB-ECS"   # adjust path as needed

  # Required inputs (these map directly to your variables.tf)

  vpc_id                 = ""    
  private_subnet_ids     = "" 
  public_subnet_ids      = ""       
  app_name               = "" 
  container_image        = ""
  container_port         = "" 
  desired_count          = ""
  enable_nlb_sg          = "" 

}