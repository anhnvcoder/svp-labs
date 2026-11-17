variable "name" {
  description = "Name of the VPC and prefix of everything in it (<name>-edge, <name>-lan, <name>-router, <name>-host), e.g. svp-lab-net-onprem. Unique per account: IAM names are global to the account."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3 to 32 lowercase letters, digits or dashes, starting with a letter."
  }
}

variable "cidr" {
  description = "IPv4 range of the site, a /20 outside the lab's range, e.g. 192.168.0.0/20: the router's subnet is its first /24, the host's the second, and the tunnels carry exactly this range."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.cidr)) && endswith(var.cidr, "/20")
    error_message = "cidr must be an IPv4 /20, e.g. 192.168.0.0/20."
  }
}

variable "lab_cidr" {
  description = "IPv4 range of every VPC of the lab, e.g. 10.64.0.0/16: what the router sends through the tunnels and the only source of ping and TCP 80 to the host."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.lab_cidr)) && var.lab_cidr != "0.0.0.0/0"
    error_message = "lab_cidr must be an IPv4 range other than 0.0.0.0/0, e.g. 10.64.0.0/16."
  }
}

variable "availability_zone_id" {
  description = "Zone of both subnets, by zone ID, e.g. apse1-az1."
  type        = string

  validation {
    condition     = can(regex("^[a-z]+[0-9]-az[0-9]+$", var.availability_zone_id))
    error_message = "availability_zone_id must be a zone ID such as apse1-az1."
  }
}

variable "public_ip" {
  description = "Elastic IP of the customer gateway, which the router takes as its public address and IKE identity."
  type        = string

  validation {
    condition     = can(cidrhost("${var.public_ip}/32", 0))
    error_message = "public_ip must be an IPv4 address."
  }
}

variable "eip_allocation_id" {
  description = "Allocation ID of that Elastic IP, associated with the router's interface."
  type        = string

  validation {
    condition     = can(regex("^eipalloc-[0-9a-f]+$", var.eip_allocation_id))
    error_message = "eip_allocation_id must be an Elastic IP allocation ID, e.g. eipalloc-0123456789abcdef0."
  }
}

variable "tunnels" {
  description = "The two tunnels of the VPN connection, in order: the AWS outside address and the router's inside address (the customer gateway side of the tunnel's /30)."
  type = list(object({
    outside_ip    = string
    cgw_inside_ip = string
  }))

  validation {
    condition     = length(var.tunnels) == 2
    error_message = "tunnels must hold the two tunnels of the VPN connection."
  }

  validation {
    condition = alltrue([for t in var.tunnels :
    can(cidrhost("${t.outside_ip}/32", 0)) && can(regex("^169\\.254\\.", t.cgw_inside_ip)) && can(cidrhost("${t.cgw_inside_ip}/32", 0))])
    error_message = "Each tunnel needs an IPv4 outside address and an inside address in 169.254.0.0/16."
  }
}

variable "preshared_key_arn" {
  description = "ARN of the Secrets Manager secret in which the VPN connection keeps its pre-shared keys (preshared_key_arn of aws_vpn_connection). The router reads it at boot with its role; the keys never pass through Terraform."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:.+$", var.preshared_key_arn))
    error_message = "preshared_key_arn must be the ARN of a Secrets Manager secret."
  }
}

variable "zone_name" {
  description = "DNS zone the site's server holds, e.g. onprem.svp.example, with the records router and host."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9-]+\\.)+[a-z]+$", var.zone_name))
    error_message = "zone_name must be a domain name in lowercase, e.g. onprem.svp.example."
  }
}

variable "forward_zones" {
  description = "Private zones of the lab the site's server forwards to the inbound Resolver endpoint, e.g. [\"net.svp.example\"]."
  type        = list(string)

  validation {
    condition     = length(var.forward_zones) > 0 && alltrue([for z in var.forward_zones : can(regex("^([a-z0-9-]+\\.)+[a-z]+$", z))])
    error_message = "forward_zones must hold at least one domain name in lowercase."
  }
}

variable "inbound_resolver_ips" {
  description = "Addresses of the inbound Resolver endpoint of the lab, the forwarders of forward_zones."
  type        = list(string)

  validation {
    condition     = length(var.inbound_resolver_ips) >= 2 && alltrue([for ip in var.inbound_resolver_ips : can(cidrhost("${ip}/32", 0))])
    error_message = "inbound_resolver_ips must hold at least two IPv4 addresses, as an inbound endpoint has."
  }
}
