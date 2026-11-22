# Tài nguyên mỗi root của `multi-account-networking` tạo trên account trống

Trang này đếm, cho mỗi root Terraform của lab, các tài nguyên mà lần `apply` đầu tiên tạo trên account chưa có gì của root đó, chia
theo phần và theo loại, kèm một sơ đồ. Đọc trước khi chạy một root để biết plan đúng ra bao nhiêu `to add` và chúng thuộc dịch vụ
nào; các bước của buổi ở [README của lab](../README.md). Trang và sơ đồ sinh bằng `make inventory` từ plan của `terraform test` trên
provider giả: offline, không credential, không phí. Không sửa tay: `make inventory-check` ở CI đỏ khi trang hay sơ đồ lệch code. Lý
do chọn cách này, và các phương án đã bỏ:
[ADR-0081](https://github.com/anhnvcoder/svp-backend/blob/main/docs/adr/0081-terraform-inventory.md).

## Cách đọc

- Dòng `Plan: …` là dòng tóm tắt `terraform plan` in ra trên account trống; `to import` là tài nguyên root nhận quản qua khối `import`
  thay vì tạo.
- **Phần**: lời gọi module cấp root (`module.<tên>`); tài nguyên khai báo thẳng trong root thì là file `.tf` khai báo nó.
- Bảng theo loại đếm mọi bản của `count`, `for_each`; cột dịch vụ là dịch vụ AWS của icon trên sơ đồ.
- Sơ đồ: mỗi khối một phần, tiêu đề ghi số tài nguyên của phần; mỗi icon một dịch vụ AWS kèm số tài nguyên của dịch vụ đó trong phần.
  Icon lấy từ bộ AWS Architecture Icons ([nguồn và bản](../../docs/diagrams/README.md#icon)).

## Giới hạn

- Số là của **account trống chạy lần đầu**. Chạy root trên account đã có một phần của nó: plan thật chỉ hiện phần còn thiếu cùng các
  thay đổi.
- Giá trị: biến theo mặc định của `variables.tf`, rồi theo `*.auto.tfvars.example` của root nếu có; account id giả dạng
  `000000000000`. Buổi đặt biến khác (file `*.auto.tfvars`) thì số đổi theo.
- Data source trả giá trị giả của `scripts/inventory/<slug>.tftest.hcl` (provider giả, không đọc account). Mỗi root dưới đây nêu giả
  định nào của giá trị giả quyết định số.

## `multi-account-networking/account`

- Tổ chức đã có, chưa có OU `Infrastructure` hay account `svp-network`. Số không phụ thuộc giá trị
  giả.

`Plan: 2 to add, 0 to change, 0 to destroy.`

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../../docs/diagrams/inventory/multi-account-networking-account-dark.svg">
  <img src="../../docs/diagrams/inventory/multi-account-networking-account.svg" alt="Tài nguyên của multi-account-networking-account">
</picture>

| Phần | Tài nguyên |
| --- | ---: |
| `main.tf` | 2 |

| Loại | Dịch vụ | Số |
| --- | --- | ---: |
| `aws_organizations_account` | Organizations | 1 |
| `aws_organizations_organizational_unit` | Organizations | 1 |

## `multi-account-networking/core`

- Bốn account (management, `svp-network`, `svp-stg`, `svp-prd`) chưa có gì của lab. Mỗi VPC một zone
  (`availability_zone_id` theo mặc định).

`Plan: 128 to add, 0 to change, 0 to destroy.`

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../../docs/diagrams/inventory/multi-account-networking-core-dark.svg">
  <img src="../../docs/diagrams/inventory/multi-account-networking-core.svg" alt="Tài nguyên của multi-account-networking-core">
</picture>

| Phần | Tài nguyên |
| --- | ---: |
| `main.tf` | 1 |
| `module.dns_hub` | 8 |
| `module.dns_prd` | 1 |
| `module.dns_share` | 4 |
| `module.dns_stg` | 2 |
| `module.egress` | 20 |
| `module.hub` | 19 |
| `module.prd_vpc` | 10 |
| `module.probe_egress` | 9 |
| `module.probe_prd` | 9 |
| `module.probe_shared` | 9 |
| `module.probe_stg` | 9 |
| `module.shared_vpc` | 10 |
| `module.stg_vpc` | 10 |
| `module.subnet_share` | 3 |
| `module.tgw_share` | 4 |

| Loại | Dịch vụ | Số |
| --- | --- | ---: |
| `aws_default_security_group` | VPC | 4 |
| `aws_ec2_transit_gateway` | Transit Gateway | 1 |
| `aws_ec2_transit_gateway_route` | Transit Gateway | 11 |
| `aws_ec2_transit_gateway_route_table` | Transit Gateway | 3 |
| `aws_ec2_transit_gateway_route_table_association` | Transit Gateway | 4 |
| `aws_ec2_transit_gateway_vpc_attachment` | Transit Gateway | 4 |
| `aws_eip` | VPC | 1 |
| `aws_iam_instance_profile` | IAM | 4 |
| `aws_iam_role` | IAM | 4 |
| `aws_iam_role_policy_attachment` | IAM | 4 |
| `aws_instance` | EC2 | 4 |
| `aws_internet_gateway` | VPC | 1 |
| `aws_nat_gateway` | VPC | 1 |
| `aws_ram_principal_association` | RAM | 5 |
| `aws_ram_resource_association` | RAM | 3 |
| `aws_ram_resource_share` | RAM | 3 |
| `aws_ram_sharing_with_organization` | RAM | 1 |
| `aws_route` | VPC | 8 |
| `aws_route53_record` | Route 53 | 3 |
| `aws_route53_vpc_association_authorization` | Route 53 | 1 |
| `aws_route53_zone` | Route 53 | 2 |
| `aws_route53_zone_association` | Route 53 | 1 |
| `aws_route53profiles_association` | Route 53 | 2 |
| `aws_route53profiles_profile` | Route 53 | 1 |
| `aws_route53profiles_resource_association` | Route 53 | 1 |
| `aws_route_table` | VPC | 9 |
| `aws_route_table_association` | VPC | 9 |
| `aws_security_group` | VPC | 4 |
| `aws_subnet` | VPC | 9 |
| `aws_vpc` | VPC | 4 |
| `aws_vpc_security_group_egress_rule` | VPC | 8 |
| `aws_vpc_security_group_ingress_rule` | VPC | 8 |

## `multi-account-networking/hybrid`

- Root `multi-account-networking/core` đã chạy: data source trả Transit Gateway, hai route table, các
  VPC, subnet, security group, instance probe và Route 53 Profile của nó, với id và CIDR giả có định dạng hợp lệ.

`Plan: 76 to add, 0 to change, 0 to destroy.`

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../../docs/diagrams/inventory/multi-account-networking-hybrid-dark.svg">
  <img src="../../docs/diagrams/inventory/multi-account-networking-hybrid.svg" alt="Tài nguyên của multi-account-networking-hybrid">
</picture>

| Phần | Tài nguyên |
| --- | ---: |
| `main.tf` | 3 |
| `module.resolver` | 14 |
| `module.service_prd` | 8 |
| `module.service_stg` | 3 |
| `module.site` | 42 |
| `module.vpn` | 6 |

| Loại | Dịch vụ | Số |
| --- | --- | ---: |
| `aws_customer_gateway` | Site-to-Site VPN | 1 |
| `aws_default_security_group` | VPC | 1 |
| `aws_ec2_transit_gateway_route` | Transit Gateway | 2 |
| `aws_ec2_transit_gateway_route_table_association` | Transit Gateway | 1 |
| `aws_eip` | VPC | 1 |
| `aws_eip_association` | VPC | 1 |
| `aws_iam_instance_profile` | IAM | 2 |
| `aws_iam_role` | IAM | 2 |
| `aws_iam_role_policy` | IAM | 1 |
| `aws_iam_role_policy_attachment` | IAM | 2 |
| `aws_instance` | EC2 | 2 |
| `aws_internet_gateway` | VPC | 1 |
| `aws_lb` | ELB | 1 |
| `aws_lb_listener` | ELB | 1 |
| `aws_lb_target_group` | ELB | 1 |
| `aws_lb_target_group_attachment` | ELB | 1 |
| `aws_network_interface` | EC2 | 1 |
| `aws_route` | VPC | 4 |
| `aws_route53_resolver_endpoint` | Route 53 | 2 |
| `aws_route53_resolver_rule` | Route 53 | 1 |
| `aws_route53profiles_resource_association` | Route 53 | 1 |
| `aws_route_table` | VPC | 3 |
| `aws_route_table_association` | VPC | 3 |
| `aws_security_group` | VPC | 5 |
| `aws_ssm_association` | Systems Manager | 1 |
| `aws_subnet` | VPC | 3 |
| `aws_vpc` | VPC | 1 |
| `aws_vpc_endpoint` | PrivateLink | 1 |
| `aws_vpc_endpoint_connection_accepter` | PrivateLink | 1 |
| `aws_vpc_endpoint_service` | PrivateLink | 1 |
| `aws_vpc_endpoint_service_allowed_principal` | PrivateLink | 1 |
| `aws_vpc_security_group_egress_rule` | VPC | 13 |
| `aws_vpc_security_group_ingress_rule` | VPC | 12 |
| `aws_vpn_connection` | Site-to-Site VPN | 1 |
