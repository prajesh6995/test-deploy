#!/bin/bash

# Set variables
CLUSTER_NAME="me-npm-cluster"
SERVICE_NAME_ME="mongo-express-service"
SERVICE_NAME_NPM="nginx-proxy-manager-service"
TASK_FAMILY_NPM="nginx-proxy-manager-task"
TASK_FAMILY_ME="mongo-express-task"
CONTAINER_NAME_NPM="nginx-proxy-manager-container"
CONTAINER_NAME_ME="mongo-express-container"
IMAGE_URI_NPM="jc21/nginx-proxy-manager:latest"  # NPM official image
IMAGE_URI_ME="mongo-express"  # Mongo Express image
PORT_NPM=80
PORT_ME=8081
REGION="us-east-1"
VPC_CIDR="10.0.0.0/16"
SUBNET_CIDR1="10.0.1.0/24"
SUBNET_CIDR2="10.0.2.0/24"
SG_NAME="ME-NPM-sg"
EXECUTION_ROLE_NAME="ecsTaskExecutionRole"
TASK_ROLE_NAME="ecsTaskRole"
NAMESPACE_NAME="ecs-services.local"  # Custom namespace for Service Discovery

# Track created resources for rollback
declare -A CREATED_RESOURCES
CREATED_RESOURCES=(
  ["ECS_CLUSTER"]=""
  ["VPC"]=""
  ["IGW"]=""
  ["SUBNET1"]=""
  ["SUBNET2"]=""
  ["SG"]=""
  ["ECS_SERVICE_ME"]=""
  ["ECS_SERVICE_NPM"]=""
  ["NAMESPACE"]=""
  ["SERVICE_DISCOVERY_ME"]=""
  ["SERVICE_DISCOVERY_NPM"]=""
)

# Function to check for errors
check_error() {
  if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: $1"
    #rollback
    exit 1
  fi
}

# Function to rollback resources
rollback() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Rolling back resources..."
  for resource in "${!CREATED_RESOURCES[@]}"; do
    if [ -n "${CREATED_RESOURCES[$resource]}" ]; then
      case $resource in
        "ECS_CLUSTER")
          echo "$(date '+%Y-%m-%d %H:%M:%S') - Deleting ECS Cluster..."
          aws ecs delete-cluster --cluster $CLUSTER_NAME
          ;;
        "VPC")
          echo "$(date '+%Y-%m-%d %H:%M:%S') - Deleting VPC..."
          aws ec2 delete-vpc --vpc-id ${CREATED_RESOURCES[$resource]}
          ;;
        "IGW")
          echo "$(date '+%Y-%m-%d %H:%M:%S') - Detaching and deleting Internet Gateway..."
          aws ec2 detach-internet-gateway --internet-gateway-id ${CREATED_RESOURCES[$resource]} --vpc-id ${CREATED_RESOURCES["VPC"]}
          aws ec2 delete-internet-gateway --internet-gateway-id ${CREATED_RESOURCES[$resource]}
          ;;
        "SUBNET1"|"SUBNET2")
          echo "$(date '+%Y-%m-%d %H:%M:%S') - Deleting Subnet ${CREATED_RESOURCES[$resource]}..."
          aws ec2 delete-subnet --subnet-id ${CREATED_RESOURCES[$resource]}
          ;;
        "SG")
          echo "$(date '+%Y-%m-%d %H:%M:%S') - Deleting Security Group..."
          aws ec2 delete-security-group --group-id ${CREATED_RESOURCES[$resource]}
          ;;
        "ECS_SERVICE_NPM"|"ECS_SERVICE_ME")
          echo "$(date '+%Y-%m-%d %H:%M:%S') - Deleting ECS Service ${CREATED_RESOURCES[$resource]}..."
          aws ecs delete-service --cluster $CLUSTER_NAME --service ${CREATED_RESOURCES[$resource]} --force
          ;;
        "NAMESPACE")
          echo "$(date '+%Y-%m-%d %H:%M:%S') - Deleting Service Discovery Namespace..."
          aws servicediscovery delete-namespace --id ${CREATED_RESOURCES[$resource]}
          ;;
        "SERVICE_DISCOVERY_ME"|"SERVICE_DISCOVERY_NPM")
          echo "$(date '+%Y-%m-%d %H:%M:%S') - Deleting Service Discovery Service ${CREATED_RESOURCES[$resource]}..."
          aws servicediscovery delete-service --id ${CREATED_RESOURCES[$resource]}
          ;;
      esac
    fi
  done
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Rollback complete."
}

# Create VPC
if ! aws ec2 describe-vpcs --filters "Name=cidr-block,Values=$VPC_CIDR" --query 'Vpcs[0].VpcId' --output text | grep -q 'vpc-'; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating VPC..."
  VPC_ID=$(aws ec2 create-vpc --cidr-block $VPC_CIDR --query 'Vpc.VpcId' --output text)
  check_error "Failed to create VPC"
  CREATED_RESOURCES["VPC"]=$VPC_ID
else
  VPC_ID=$(aws ec2 describe-vpcs --filters "Name=cidr-block,Values=$VPC_CIDR" --query 'Vpcs[0].VpcId' --output text)
  echo "$(date '+%Y-%m-%d %H:%M:%S') - VPC already exists with ID $VPC_ID."
fi

# Enable public DNS hostname for VPC
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames '{"Value":true}'

# Create and attach Internet Gateway
if ! aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'InternetGateways[0].InternetGatewayId' --output text | grep -q 'igw-'; then
  IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
  check_error "Failed to create Internet Gateway"
  aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
  check_error "Failed to attach Internet Gateway"
  CREATED_RESOURCES["IGW"]=$IGW_ID
else
  IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'InternetGateways[0].InternetGatewayId' --output text)
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Internet Gateway already attached with ID $IGW_ID."
fi

# Create Route Table and associate with subnets
ROUTE_TABLE_ID=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query 'RouteTables[0].RouteTableId' --output text)
if ! aws ec2 describe-route-tables --route-table-ids $ROUTE_TABLE_ID --query 'Routes[?DestinationCidrBlock==`0.0.0.0/0`]' --output text | grep -q '0.0.0.0/0'; then
  aws ec2 create-route --route-table-id $ROUTE_TABLE_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
  check_error "Failed to create route to Internet Gateway"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Route to Internet Gateway already exists."
fi

# Create Subnets in Different AZs
echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Subnet 1 in $AZ1..."
SUBNET_ID1=$(aws ec2 describe-subnets --filters "Name=cidr-block,Values=$SUBNET_CIDR1" --query 'Subnets[0].SubnetId' --output text)
if [ -z "$SUBNET_ID1" ]; then
  SUBNET_ID1=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_CIDR1 --availability-zone $AZ1 --query 'Subnet.SubnetId' --output text)
  check_error "Failed to create Subnet 1"
  aws ec2 associate-route-table --subnet-id $SUBNET_ID1 --route-table-id $ROUTE_TABLE_ID
  aws ec2 modify-subnet-attribute --subnet-id $SUBNET_ID1 --map-public-ip-on-launch
  CREATED_RESOURCES["SUBNET1"]=$SUBNET_ID1
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Subnet 1 already exists with ID $SUBNET_ID1."
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Subnet 2 in $AZ2..."
SUBNET_ID2=$(aws ec2 describe-subnets --filters "Name=cidr-block,Values=$SUBNET_CIDR2" --query 'Subnets[0].SubnetId' --output text)
if [ -z "$SUBNET_ID2" ]; then
  SUBNET_ID2=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_CIDR2 --availability-zone $AZ2 --query 'Subnet.SubnetId' --output text)
  check_error "Failed to create Subnet 2"
  aws ec2 associate-route-table --subnet-id $SUBNET_ID2 --route-table-id $ROUTE_TABLE_ID
  aws ec2 modify-subnet-attribute --subnet-id $SUBNET_ID2 --map-public-ip-on-launch
  CREATED_RESOURCES["SUBNET2"]=$SUBNET_ID2
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Subnet 2 already exists with ID $SUBNET_ID2."
fi

# Create Security Group
echo "SG_NAME: $SG_NAME"
echo "VPC_ID: $VPC_ID"

SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text)

if [ "$SG_ID" == "None" ] || [ -z "$SG_ID" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Security Group not found, creating..."
  SG_ID=$(aws ec2 create-security-group --group-name $SG_NAME --description "Security group for NGINX ALB" --vpc-id $VPC_ID --query 'GroupId' --output text)
  check_error "Failed to create Security Group"
  CREATED_RESOURCES["SG"]=$SG_ID
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Security Group already exists with ID $SG_ID."
fi
echo "SG_ID: $SG_ID"

aws ec2 describe-security-groups --query 'SecurityGroups[*].[GroupId, GroupName, Description, VpcId]' --output table

# Set Ingress Rule if not exists
if ! aws ec2 describe-security-groups --group-ids $SG_ID --query 'SecurityGroups[0].IpPermissions[?FromPort==`8000` && ToPort==`24000` && IpProtocol==`tcp`]' --output text | grep -q '0.0.0.0/0'; then
  aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port $PORT_NGINX --cidr 0.0.0.0/0
  #check_error "Failed to set security group ingress rules"
  aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port $PORT_NPM --cidr 0.0.0.0/0
  #check_error "Failed to set security group ingress rules"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Ingress rule already exists."
fi


# Set Egress Rule if not exists

aws ec2 describe-security-groups \
  --query 'SecurityGroups[*].{GroupId:GroupId, GroupName:GroupName, EgressRules:IpPermissionsEgress}' \
  --output table

# Check if the egress rule already exists for the specific Security Group
EXISTING_EGRESS=$(aws ec2 describe-security-groups --group-ids $SG_ID --query "SecurityGroups[0].IpPermissionsEgress[?IpProtocol=='-1'].[IpRanges]" --output text)

echo "EXISTING_EGRESS : $EXISTING_EGRESS "

# Check if the rule already exists by verifying if 0.0.0.0/0 is present
if echo "$EXISTING_EGRESS" | grep -q '0.0.0.0/0'; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Egress rule already exists."
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Adding egress rule to Security Group..."
  aws ec2 authorize-security-group-egress --group-id $SG_ID --protocol -1 --cidr 0.0.0.0/0

  check_error "Failed to set security group egress rules"
fi

# Create a Service Discovery Namespace
echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Service Discovery Namespace..."
NAMESPACE_ID=$(aws servicediscovery create-private-dns-namespace \
  --name $NAMESPACE_NAME \
  --vpc $VPC_ID \
  --query 'OperationId' \
  --output text)
check_error "Failed to create Service Discovery Namespace"

# Wait for the namespace to be created
echo "$(date '+%Y-%m-%d %H:%M:%S') - Waiting for Service Discovery Namespace to be created..."
while true; do
  NAMESPACE_STATUS=$(aws servicediscovery get-operation --operation-id $NAMESPACE_ID --query 'Operation.Status' --output text)
  if [ "$NAMESPACE_STATUS" == "SUCCESS" ]; then
    NAMESPACE_ARN=$(aws servicediscovery list-namespaces --query "Namespaces[?Name=='$NAMESPACE_NAME'].Arn" --output text)
    NAMESPACE_ID=$(aws servicediscovery list-namespaces --query "Namespaces[?Name=='$NAMESPACE_NAME'].Id" --output text)
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Namespace created successfully with ID: $NAMESPACE_ID"
    break
  elif [ "$NAMESPACE_STATUS" == "FAIL" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Namespace creation failed."
    exit 1
  else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Namespace creation in progress..."
    sleep 10
  fi
done
CREATED_RESOURCES["NAMESPACE"]=$NAMESPACE_ID

# Create Service Discovery Services
echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Service Discovery Service for NPM..."
SERVICE_DISCOVERY_NPM=$(aws servicediscovery create-service \
  --name $SERVICE_NAME_NPM \
  --dns-config "NamespaceId=$NAMESPACE_ID,RoutingPolicy=WEIGHTED,DnsRecords=[{Type=A,TTL=60}]" \
  --health-check-custom-config "FailureThreshold=1" \
  --query 'Service.Id' \
  --output text)
check_error "Failed to create Service Discovery Service for NPM"
CREATED_RESOURCES["SERVICE_DISCOVERY_NPM"]=$SERVICE_DISCOVERY_NPM

echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Service Discovery Service for Mongo Express..."
SERVICE_DISCOVERY_ME=$(aws servicediscovery create-service \
  --name $SERVICE_NAME_ME \
  --dns-config "NamespaceId=$NAMESPACE_ID,RoutingPolicy=WEIGHTED,DnsRecords=[{Type=A,TTL=60}]" \
  --health-check-custom-config "FailureThreshold=1" \
  --query 'Service.Id' \
  --output text)
check_error "Failed to create Service Discovery Service for Mongo Express"
CREATED_RESOURCES["SERVICE_DISCOVERY_ME"]=$SERVICE_DISCOVERY_ME

# Create ECS Service for NPM with Service Discovery
SERVICE_STATUS_NPM=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME_NPM --query 'services[0].status' --output text 2>&1)

if [ "$SERVICE_STATUS_NPM" != "ACTIVE" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating ECS Service for NPM with Service Discovery..."
  NPM_SERVICE_OUTPUT=$(aws ecs create-service --cluster $CLUSTER_NAME --service-name $SERVICE_NAME_NPM \
    --task-definition $TASK_FAMILY_NPM --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[\"$SUBNET_ID1\",\"$SUBNET_ID2\"],securityGroups=[\"$SG_ID\"],assignPublicIp=ENABLED}" \
    --service-registries "registryArn=arn:aws:servicediscovery:$REGION:$(aws sts get-caller-identity --query Account --output text):service/$SERVICE_DISCOVERY_NPM" \
    --query "service.serviceName" --output text 2>&1)

  if [ $? -ne 0 ]; then
    echo "Failed to create ECS Service for NPM. Error: $NPM_SERVICE_OUTPUT"
    exit 1
  else
    echo "ECS Service for NPM created successfully: $NPM_SERVICE_OUTPUT"
  fi
else
  echo "ECS Service for NPM already exists and is active."
fi
CREATED_RESOURCES["ECS_SERVICE_NPM"]=$SERVICE_NAME_NPM

# Create ECS Service for Mongo Express with Service Discovery
SERVICE_STATUS_ME=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME_ME --query 'services[0].status' --output text 2>&1)

if [ "$SERVICE_STATUS_ME" != "ACTIVE" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating ECS Service for Mongo Express with Service Discovery..."
  ME_SERVICE_OUTPUT=$(aws ecs create-service --cluster $CLUSTER_NAME --service-name $SERVICE_NAME_ME \
    --task-definition $TASK_FAMILY_ME --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[\"$SUBNET_ID1\",\"$SUBNET_ID2\"],securityGroups=[\"$SG_ID\"],assignPublicIp=ENABLED}" \
    --service-registries "registryArn=arn:aws:servicediscovery:$REGION:$(aws sts get-caller-identity --query Account --output text):service/$SERVICE_DISCOVERY_ME" \
    --query "service.serviceName" --output text 2>&1)

  if [ $? -ne 0 ]; then
    echo "Failed to create ECS Service for Mongo Express. Error: $ME_SERVICE_OUTPUT"
    exit 1
  else
    echo "ECS Service for Mongo Express created successfully: $ME_SERVICE_OUTPUT"
  fi
else
  echo "ECS Service for Mongo Express already exists and is active."
fi
CREATED_RESOURCES["ECS_SERVICE_ME"]=$SERVICE_NAME_ME

# Output Service Discovery DNS
echo "$(date '+%Y-%m-%d %H:%M:%S') - Deployment successful! Access your NPM application using Service Discovery DNS: $SERVICE_NAME_NPM.$NAMESPACE_NAME"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Deployment successful! Access your Mongo Express application using Service Discovery DNS: $SERVICE_NAME_ME.$NAMESPACE_NAME"