terraform {

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.2"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}
