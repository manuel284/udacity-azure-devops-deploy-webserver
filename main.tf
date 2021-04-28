provider "azurerm" {
  features {}
}

# define tags for the resources
locals {
  tags = {
    Project = var.project
  }
}

# create resource group
resource "azurerm_resource_group" "main" {
  name     = var.rgname
  location = var.location
  tags = local.tags
}

# create virtual network
resource "azurerm_virtual_network" "main" {
  name                = "${var.prefix}-network"
  address_space       = ["10.0.0.0/22"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags = local.tags
}

# create subnet
resource "azurerm_subnet" "main" {
  name                 = "VMs"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.2.0/24"]
}

# create NSG
resource "azurerm_network_security_group" "main" {
  name                = "${var.prefix}-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  # allow access from inside the virtual network
  security_rule {
    name                       = "allow_subnet"
    source_address_prefix      = "VirtualNetwork"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    destination_address_prefix = "*"
  }

  # deny access from the internet
  security_rule {
    name                       = "deny_internet"
    source_address_prefix      = "Internet"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    destination_address_prefix = "*"
  }

  tags = local.tags
}

# associate subnet to NSG
resource "azurerm_subnet_network_security_group_association" "main" {
  subnet_id                 = azurerm_subnet.main.id
  network_security_group_id = azurerm_network_security_group.main.id
}

# create public ip address
resource "azurerm_public_ip" "publicip" {
  name                = "${var.prefix}-ip"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  tags = local.tags
}

# create load balancer
resource "azurerm_lb" "main" {
  name                = "${var.prefix}-lb"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  # associate public ip address to the lb
  frontend_ip_configuration {
      name                 = "PublicIPAddress"
      public_ip_address_id = azurerm_public_ip.publicip.id
  }
  tags = local.tags
}

# add backend pool to the lb
resource "azurerm_lb_backend_address_pool" "main" {
  loadbalancer_id     = azurerm_lb.main.id
  name                = "BackendPool"
}

# add probe to the lb
resource "azurerm_lb_probe" "main" {
  resource_group_name = azurerm_resource_group.main.name
  loadbalancer_id     = azurerm_lb.main.id
  name                = "${var.prefix}-probe"
  port                = 80
}

# add lb rule
resource "azurerm_lb_rule" "main" {
  resource_group_name            = azurerm_resource_group.main.name
  loadbalancer_id                = azurerm_lb.main.id
  name                           = "http"
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  backend_address_pool_id        = azurerm_lb_backend_address_pool.main.id
  frontend_ip_configuration_name = "PublicIPAddress"
  probe_id                       = azurerm_lb_probe.main.id
}

# create availability set
resource "azurerm_availability_set" "main" {
  name                = "${var.prefix}-aset"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  tags = local.tags
}

# define packer image rg
data "azurerm_resource_group" "image" {
  name = var.packer_rg
}

# define packer image name
data "azurerm_image" "image" {
  name                = var.packer_image_name
  resource_group_name = data.azurerm_resource_group.image.name
}

# create VMs
resource "azurerm_linux_virtual_machine" "main" {
  count                           = var.vm-count
  name                            = "${var.prefix}-${count.index}-vm"
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  availability_set_id             = azurerm_availability_set.main.id
  size                            = "Standard_A2"
  admin_username                  = "${var.username}"
  admin_password                  = "${var.password}"
  disable_password_authentication = false
  network_interface_ids = [element(azurerm_network_interface.main.*.id, count.index)]
  source_image_id=data.azurerm_image.image.id
  
  
  os_disk {
      name                 = "${var.prefix}-osdisk-${count.index}"
      storage_account_type = "Standard_LRS"
      caching              = "ReadWrite"
  }
  tags = local.tags
}

# create managed disks for the VMs
resource "azurerm_managed_disk" "main" {
  count                = var.vm-count
  name                 = "${var.prefix}-${count.index}-datadisk"
  resource_group_name  = azurerm_resource_group.main.name
  location             = azurerm_resource_group.main.location
  storage_account_type = "Standard_LRS"
  create_option        = "Empty"
  disk_size_gb         = 1
  tags                 = local.tags
}

# attach data disks to VMs
resource "azurerm_virtual_machine_data_disk_attachment" "main" {
  count              = var.vm-count
  managed_disk_id    = element(azurerm_managed_disk.main.*.id, count.index)
  virtual_machine_id = element(azurerm_linux_virtual_machine.main.*.id, count.index)
  lun                = "10"
  caching            = "ReadWrite"
}

# create NICs for the VMs
resource "azurerm_network_interface" "main" {
  count               = var.vm-count
  name                = "${var.prefix}-${count.index}-nic"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  ip_configuration {
      name                          = "${var.prefix}-ipconf"
      subnet_id                     = azurerm_subnet.main.id
      private_ip_address_allocation = "Dynamic"
  }
  tags = local.tags
}

# associate NICs to backend pool
resource "azurerm_network_interface_backend_address_pool_association" "main" {
  count                   = var.vm-count
  network_interface_id    = element(azurerm_network_interface.main.*.id, count.index)
  ip_configuration_name   = "${var.prefix}-ipconf"
  backend_address_pool_id = azurerm_lb_backend_address_pool.main.id
}

# associate NICs to NSG
resource "azurerm_network_interface_security_group_association" "main" {
  count                     = var.vm-count
  network_interface_id      = element(azurerm_network_interface.main.*.id, count.index)
  network_security_group_id = azurerm_network_security_group.main.id
}