# azapi_resource.rg is the resource group that the virtual network will be created in
# the module will create as many as is required by the var.virtual_networks input variable
resource "azapi_resource" "rg" {
  for_each = { for i in local.resource_group_data : i.name => i }

  type      = "Microsoft.Resources/resourceGroups@2021-04-01"
  location  = each.value.location
  name      = each.key
  parent_id = local.subscription_resource_id
  tags      = each.value.tags
}

# azapi_resource.rg_lock is an optional resource group lock that can be used
# to prevent accidental deletion.
resource "azapi_resource" "rg_lock" {
  for_each = { for i in local.resource_group_data : i.name => i if i.lock }

  type = "Microsoft.Authorization/locks@2017-04-01"
  body = {
    properties = {
      level = "CanNotDelete"
    }
  }
  name      = coalesce(each.value.lock_name, substr("lock-${each.key}", 0, 90))
  parent_id = azapi_resource.rg[each.key].id

  depends_on = [
    module.virtual_networks,
    module.peering_hub_outbound,
    module.peering_hub_inbound,
    module.peering_mesh,
    azapi_resource.vhubconnection,
    azapi_resource.vhubconnection_routing_intent,
  ]
}

# module.virtual_networks uses the Azure Verified Module to create
# as many virtual networks as is required by the var.virtual_networks input variable
module "virtual_networks" {
  for_each        = var.virtual_networks
  source          = "Azure/avm-res-network-virtualnetwork/azurerm"
  version         = "0.8.1"
  subscription_id = var.subscription_id

  name                    = each.value.name
  address_space           = each.value.address_space
  resource_group_name     = each.value.resource_group_name
  location                = each.value.location
  flow_timeout_in_minutes = each.value.flow_timeout_in_minutes

  ddos_protection_plan = each.value.ddos_protection_plan_id == null ? null : {
    id     = each.value.ddos_protection_plan_id
    enable = true
  }
  dns_servers = length(each.value.dns_servers) == 0 ? null : {
    dns_servers = each.value.dns_servers
  }
  subnets = each.value.subnets

  tags             = each.value.tags
  enable_telemetry = var.enable_telemetry

  depends_on = [azapi_resource.rg]
}

# module.peering_hub_outbound uses the peering submodule from theAzure Verified Module
# to create the outboud peering from the spoke to the hub network when specified
module "peering_hub_outbound" {
  for_each        = { for k, v in local.hub_peering_map : k => v if v.peering_direction != local.peering_direction_fromhub }
  source          = "Azure/avm-res-network-virtualnetwork/azurerm//modules/peering"
  version         = "0.8.1"
  subscription_id = var.subscription_id

  virtual_network = {
    "resource_id" = each.value["outbound"].this_resource_id,
  }
  remote_virtual_network = {
    "resource_id" = each.value["outbound"].remote_resource_id,
  }
  name                         = each.value.outbound.name
  allow_forwarded_traffic      = each.value.outbound.options.allow_forwarded_traffic
  allow_gateway_transit        = each.value.outbound.options.allow_gateway_transit
  allow_virtual_network_access = each.value.outbound.options.allow_virtual_network_access
  use_remote_gateways          = each.value.outbound.options.use_remote_gateways
  create_reverse_peering       = false

  depends_on = [module.virtual_networks]
}

# module.peering_hub_inbound uses the peering submodule from theAzure Verified Module
# to create the inbound peering from the hub network to the spoke network when specified
module "peering_hub_inbound" {
  for_each        = { for k, v in local.hub_peering_map : k => v if v.peering_direction != local.peering_direction_tohub }
  source          = "Azure/avm-res-network-virtualnetwork/azurerm//modules/peering"
  version         = "0.8.1"
  subscription_id = var.subscription_id

  virtual_network = {
    "resource_id" = each.value["inbound"].this_resource_id,
  }
  remote_virtual_network = {
    "resource_id" = each.value["inbound"].remote_resource_id,
  }
  name                         = each.value.inbound.name
  allow_forwarded_traffic      = each.value.inbound.options.allow_forwarded_traffic
  allow_gateway_transit        = each.value.inbound.options.allow_gateway_transit
  allow_virtual_network_access = each.value.inbound.options.allow_virtual_network_access
  use_remote_gateways          = each.value.inbound.options.use_remote_gateways
  create_reverse_peering       = false

  depends_on = [module.virtual_networks]
}

# module.peering_mesh uses the peering submodule from theAzure Verified Module
# to create the peering from the local and remote virtual networks as specified
module "peering_mesh" {
  for_each        = { for i in local.virtual_networks_mesh_peering_list : "${i.source_key}-${i.destination_key}" => i }
  source          = "Azure/avm-res-network-virtualnetwork/azurerm//modules/peering"
  version         = "0.8.1"
  subscription_id = var.subscription_id

  virtual_network = {
    "resource_id" = each.value.this_resource_id,
  }
  remote_virtual_network = {
    "resource_id" = each.value.remote_resource_id,
  }
  name                         = each.value.name
  allow_forwarded_traffic      = each.value.allow_forwarded_traffic
  allow_gateway_transit        = false
  allow_virtual_network_access = true
  use_remote_gateways          = false
  create_reverse_peering       = false

  depends_on = [module.virtual_networks]
}

# azapi_resource.vhubconnection creates a virtual wan hub connection between the spoke and the supplied vwan hub.
resource "azapi_resource" "vhubconnection" {
  for_each = { for k, v in var.virtual_networks : k => v if v.vwan_connection_enabled && !v.vwan_security_configuration.routing_intent_enabled }

  type = "Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2022-07-01"
  body = {
    properties = local.vhubconnection_body_properties[each.key]
  }
  name      = coalesce(each.value.vwan_connection_name, "vhc-${uuidv5("url", module.virtual_networks[each.key].resource_id)}")
  parent_id = each.value.vwan_hub_resource_id

  depends_on = [module.virtual_networks]
}

# azapi_resource.vhubconnection creates a virtual wan hub connection between the spoke and the supplied vwan hub.
# This resource is used when routing intent is enabled on the vwan security configuration,
# as the routing configuration is then ignored.
resource "azapi_resource" "vhubconnection_routing_intent" {
  for_each = { for k, v in var.virtual_networks : k => v if v.vwan_connection_enabled && v.vwan_security_configuration.routing_intent_enabled }

  type = "Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2022-07-01"
  body = {
    properties = local.vhubconnection_body_properties[each.key]
  }
  name      = coalesce(each.value.vwan_connection_name, "vhc-${uuidv5("url", module.virtual_networks[each.key].resource_id)}")
  parent_id = each.value.vwan_hub_resource_id

  depends_on = [module.virtual_networks]

  lifecycle {
    ignore_changes = [
      body.properties.routingConfiguration,
    ]
  }
}
