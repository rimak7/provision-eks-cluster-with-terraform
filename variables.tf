variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}
variable "efs_volume_name" {
  description = "efs volume name to be created "
  type = string
  default = "dev-efs-storage"
}