# One-time state migration: azurerm_storage_table -> azapi_resource (D-015).
# The table is kept in Azure (destroy = false) and adopted by the azapi resource.
# Kept in the root module because import blocks in child modules need Terraform 1.16.
# DELETE THIS FILE in a follow-up PR once the apply that performs the migration is done.

removed {
  from = module.storage.azurerm_storage_table.images

  lifecycle {
    destroy = false
  }
}

import {
  to = module.storage.azapi_resource.images_table
  id = "${module.storage.account_id}/tableServices/default/tables/images"
}
