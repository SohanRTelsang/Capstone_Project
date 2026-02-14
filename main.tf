# --- PROVIDERS ---
provider "aws" {
  region = "us-east-1"
}

provider "azurerm" {
  features {}
}

# --- AWS NETWORKING ---
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "Main-VPC" }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "Main-IGW" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
}

resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.rt.id
}

# SSH Key Registration for AWS
resource "aws_key_pair" "deployer" {
  key_name   = "sony-key"
  public_key = file("/Users/sony/.ssh/id_rsa.pub") 
}

# Security Group for AWS
resource "aws_security_group" "allow_web_ssh" {
  name   = "allow_web_ssh"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- AWS COMPUTE ---
resource "aws_instance" "app_server" {
  ami                    = "ami-04b70fa74e45c3917"
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.public.id
  key_name               = aws_key_pair.deployer.key_name
  vpc_security_group_ids = [aws_security_group.allow_web_ssh.id]
  tags                   = { Name = "App-Machine-AWS" }
}

resource "aws_instance" "tools_machine" {
  ami                    = "ami-04b70fa74e45c3917"
  instance_type          = "t2.medium"
  subnet_id              = aws_subnet.public.id
  key_name               = aws_key_pair.deployer.key_name
  vpc_security_group_ids = [aws_security_group.allow_web_ssh.id]
  tags                   = { Name = "Tools-Machine" }
}

# --- AZURE INFRASTRUCTURE ---
resource "azurerm_resource_group" "rg" {
  name     = "DR-Project"
  location = "East US"
}

resource "azurerm_virtual_network" "vnet" {
  name                = "dr-network"
  address_space       = ["10.1.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "azure_subnet" {
  name                 = "internal"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.1.2.0/24"]
}

resource "azurerm_public_ip" "pip" {
  name                = "azure-app-pip"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "ni" {
  name                = "azure-app-nic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.azure_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.pip.id
  }
}

resource "azurerm_linux_virtual_machine" "azure_vm" {
  name                  = "App-Machine-Azure"
  resource_group_name   = azurerm_resource_group.rg.name
  location              = azurerm_resource_group.rg.location
  size                  = "Standard_B2ms"
  admin_username        = "ubuntu"
  network_interface_ids = [azurerm_network_interface.ni.id]

  admin_ssh_key {
    username   = "ubuntu"
    public_key = file("/Users/sony/.ssh/id_rsa.pub")
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
}

# 1. Create the Azure Security Group (NSG)
resource "azurerm_network_security_group" "azure_nsg" {
  name                = "azure-web-ssh-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "HTTP"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# 2. Link the NSG to the Network Interface
resource "azurerm_network_interface_security_group_association" "nsg_assoc" {
  network_interface_id      = azurerm_network_interface.ni.id
  network_security_group_id = azurerm_network_security_group.azure_nsg.id
}
# --- TASK 5: ROUTE 53 ---
resource "aws_route53_zone" "primary" {
  name = "upgrad-project.com" 
}

resource "aws_route53_health_check" "aws_health" {
  ip_address        = aws_instance.app_server.public_ip
  port              = 80
  type              = "HTTP"
  resource_path     = "/"
  failure_threshold = "3"
  request_interval  = "30"
}

resource "aws_route53_record" "www" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = "app.upgrad-project.com"
  type    = "A"
  failover_routing_policy { type = "PRIMARY" }
  set_identifier  = "primary"
  health_check_id = aws_route53_health_check.aws_health.id
  records         = [aws_instance.app_server.public_ip]
  ttl             = 60
}

resource "aws_route53_record" "www_secondary" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = "app.upgrad-project.com"
  type    = "A"
  failover_routing_policy { type = "SECONDARY" }
  set_identifier = "secondary"
  records        = [azurerm_public_ip.pip.ip_address]
  ttl            = 60
}

# --- OUTPUTS ---
output "aws_app_ip" { value = aws_instance.app_server.public_ip }
output "aws_tools_ip" { value = aws_instance.tools_machine.public_ip }
output "azure_app_ip" { value = azurerm_public_ip.pip.ip_address }
