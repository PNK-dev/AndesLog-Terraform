mock_provider "aws" {}

run "ephemeral_password_supports_private_encrypted_rds" {
  command = apply
  variables {
    master_password = "fixture-password-do-not-use"
  }
  assert {
    condition     = aws_db_instance.candidate.storage_encrypted && !aws_db_instance.candidate.publicly_accessible
    error_message = "La base de prueba debe ser privada y cifrada."
  }
}
