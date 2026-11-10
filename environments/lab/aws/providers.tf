provider "aws" {
  region = var.aws_region
}

provider "aws" {
  alias  = "dr"
  region = var.aws_dr_region
}
