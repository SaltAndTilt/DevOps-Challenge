terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 2.65"
    }
  }

  required_version = ">= 1.1.0"
}

provider "azurerm" {
  features {}
}

#Resource-Gruppe auswählen:
data "azurerm_resource_group" "rg" {
    name = "jakob"
}
data "azurerm_subscription" "sub" {
}

#Virtuelles Netzwerk bereit gestellt
resource "azurerm_virtual_network" "nginx_network"{
    name                = "nginx_network"
    resource_group_name = data.azurerm_resource_group.rg.name
    location            = data.azurerm_resource_group.rg.location
    address_space       = ["10.0.0.0/16"]
}

#Subnet für die ScaleSets bereit gestellt
resource "azurerm_subnet" "subnet" {
    name                    = "subnet"
    resource_group_name     = data.azurerm_resource_group.rg.name
    virtual_network_name    = azurerm_virtual_network.nginx_network.name
    address_prefixes        = ["10.0.2.0/24"]
}

#Subnet-NSG
resource "azurerm_network_security_group" "nsg" {
  name                = "nginx-nsg"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  security_rule {
    name                       = "SSH and HTTPS"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}
resource "azurerm_subnet_network_security_group_association" "example" {
  subnet_id                 = azurerm_subnet.subnet.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

#Public IP wird generiert
resource "azurerm_public_ip" "public_nginx" {
    name                = "nginx-publicIP"
    resource_group_name = data.azurerm_resource_group.rg.name
    location            = data.azurerm_resource_group.rg.location
    allocation_method   = "Static"

    domain_name_label   = "devopsjakobcgi"
}

#LB für Scaleset aufbauen
resource "azurerm_lb" "nginxlb" {
  name                = "nginx_loadbalancer"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  frontend_ip_configuration {
    name                 = "PublicIPAddress"
    public_ip_address_id = azurerm_public_ip.public_nginx.id
  }
}

resource "azurerm_lb_nat_pool" "lbnatpool" {
  resource_group_name            = data.azurerm_resource_group.rg.name
  name                           = "ssh"
  loadbalancer_id                = azurerm_lb.nginxlb.id
  protocol                       = "Tcp"
  frontend_port_start            = 50000
  frontend_port_end              = 50119
  backend_port                   = 22
  frontend_ip_configuration_name = "PublicIPAddress"
}
resource "azurerm_lb_nat_pool" "lbnatpool2" {
  resource_group_name            = data.azurerm_resource_group.rg.name
  name                           = "http"
  loadbalancer_id                = azurerm_lb.nginxlb.id
  protocol                       = "Tcp"
  frontend_port_start            = 80 
  frontend_port_end              = 89
  backend_port                   = 80
  frontend_ip_configuration_name = "PublicIPAddress"
}



resource "azurerm_lb_backend_address_pool" "backendpool" {
  loadbalancer_id     = azurerm_lb.nginxlb.id
  name                = "BackEndAddressPool"
}

resource "azurerm_lb_probe" "probe" {
    resource_group_name = data.azurerm_resource_group.rg.name
    loadbalancer_id     = azurerm_lb.nginxlb.id
    name                = "ssh-probe"
    port                = 80
}

#Portfreigabe für HTTP SSH
resource "azurerm_network_security_group" "secgroup" {
  name                = "nginx_access_sec"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
}
resource "azurerm_network_security_rule" "http" {
  name                        = "http"
  priority                    = 100
  direction                   = "InBound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "8080"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = data.azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.secgroup.name
}
resource "azurerm_network_security_rule" "ssh" {
  name                        = "ssh"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = data.azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.secgroup.name
}

resource "azurerm_network_security_rule" "testing"{
  name                        = "testing"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "50000-50119"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = data.azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.secgroup.name  
}

#Bereitstellung Scaleset mit 2 Instanzen
resource "azurerm_linux_virtual_machine_scale_set" "nginx" {
    name                  = "nginx-vm-scaleset"
    resource_group_name   = data.azurerm_resource_group.rg.name
    location              = data.azurerm_resource_group.rg.location
    sku                   = "Standard_B1s"
    instances             = 2
    admin_username        = "scalesetadmin"
    admin_password        = "scalesetPassword1"
    disable_password_authentication = false

    overprovision         = true

    source_image_reference {
        publisher         = "Canonical"
        offer             = "UbuntuServer"
        sku               = "18.04-LTS"
        version           = "latest"
    }

    os_disk {
        storage_account_type    = "Standard_LRS"
        caching                 = "ReadWrite"
    }

    network_interface {
        name    = "nginx_cluster"
        primary = true

        ip_configuration {
            name = "IPConfig"
            primary = true
            subnet_id = azurerm_subnet.subnet.id
            load_balancer_backend_address_pool_ids = [azurerm_lb_backend_address_pool.backendpool.id]
            load_balancer_inbound_nat_rules_ids    = [azurerm_lb_nat_pool.lbnatpool.id,azurerm_lb_nat_pool.lbnatpool2.id]
        }
    }
    #Installing NGINX via Base64 Encoded "sudo apt-get update && apt get install -y nginx"
    custom_data = "IyEgL2Jpbi9iYXNoCnN1ZG8gYXB0LWdldCB1cGRhdGUgJiYgc3VkbyBhcHQgaW5zdGFsbCBuZ2lueCAteQ=="
  
}
#Loging-Agents
resource "azurerm_virtual_machine_scale_set_extension" "vmss_loging" {

  virtual_machine_scale_set_id = azurerm_linux_virtual_machine_scale_set.nginx.id
  name                         = "OmsAgentForLinux"
  publisher                    = "Microsoft.EnterpriseCloud.Monitoring"
  type                         = "OmsAgentForLinux"
  type_handler_version         = "1.12"

  protected_settings = jsonencode({
    "workspaceKey" = "${azurerm_log_analytics_workspace.law.primary_shared_key}"
  })

  settings = jsonencode({
    "workspaceId"               = "${azurerm_log_analytics_workspace.law.workspace_id}",
    "stopOnMultipleConnections" = true
  })
}

#Einrichtung Logging:

resource "azurerm_log_analytics_workspace" "law" {
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  name                = "law-vmss-nginx"
}

resource "azurerm_log_analytics_solution" "vminsights" {
  resource_group_name   = data.azurerm_resource_group.rg.name
  location              = data.azurerm_resource_group.rg.location
  solution_name         = "VMInsights"

  workspace_resource_id = azurerm_log_analytics_workspace.law.id
  workspace_name        = azurerm_log_analytics_workspace.law.name

  plan {
    publisher = "Microsoft"
    product = "OMSGallery/VMInsights"

  }
}

#Einrichtung Monitor+Alert

resource "azurerm_monitor_action_group" "ag" {
  name = "monitoringgroup"
  resource_group_name = data.azurerm_resource_group.rg.name
  short_name  = "monitoring"

  email_receiver {
    name = "sendtoadmin"
    email_address = "jakobaugustin@maximumsalt.de"
    use_common_alert_schema = true
  }
}

resource "azurerm_monitor_metric_alert" "cpualert"{
  name = "nginx-cpu-load-alert"
  resource_group_name = data.azurerm_resource_group.rg.name
  scopes = [azurerm_linux_virtual_machine_scale_set.nginx.id]
  description = "Warnung wird ausgelöst wenn CPU-Load über 40% liegt"

  criteria {
    metric_namespace  = "Microsoft.Compute/virtualmachineScaleSets"
    metric_name       = "Percentage CPU"
    aggregation       = "Average"
    operator          = "GreaterThan"
    threshold         = 40
  }
}

#dashboard

resource "azurerm_dashboard" "dash" {
  name                = "Nginx-CPU-Load-Dashboard"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location

  dashboard_properties = <<DASH
  {
    "lenses": {
      "0": {
        "order": 0,
        "parts": {
          "0": {
            "position": {
              "x": 0,
              "y": 0,
              "colSpan": 6,
              "rowSpan": 4
            },
            "metadata": {
              "inputs": [
                {
                  "name": "options",
                  "value": {
                    "chart": {
                      "metrics": [
                        {
                          "resourceMetadata": {
                            "id": "/subscriptions/${data.azurerm_subscription.sub.subscription_id}/resourceGroups/jakob/providers/Microsoft.Compute/virtualMachineScaleSets/nginx-vm-scaleset"
                          },
                          "name": "Percentage CPU",
                          "aggregationType": 4,
                          "namespace": "microsoft.compute/virtualmachinescalesets",
                          "metricVisualization": {
                            "displayName": "Percentage CPU",
                            "resourceDisplayName": "nginx-vm-scaleset"
                          }
                        }
                      ],
                      "title": "Avg Percentage CPU for nginx-vm-scaleset",
                      "titleKind": 1,
                      "visualization": {
                        "chartType": 2,
                        "legendVisualization": {
                          "isVisible": true,
                          "position": 2,
                          "hideSubtitle": false
                        },
                        "axisVisualization": {
                          "x": {
                            "isVisible": true,
                            "axisType": 2
                          },
                          "y": {
                            "isVisible": true,
                            "axisType": 1
                          }
                        }
                      },
                      "timespan": {
                        "relative": {
                          "duration": 86400000
                        },
                        "showUTCTime": false,
                        "grain": 1
                      }
                    }
                  },
                  "isOptional": true
                },
                {
                  "name": "sharedTimeRange",
                  "isOptional": true
                }
              ],
              "type": "Extension/HubsExtension/PartType/MonitorChartPart"
            }
          }
        }
      }
    }
}
DASH
}