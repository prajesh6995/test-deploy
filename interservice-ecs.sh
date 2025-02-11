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
aws servicediscovery get-operation --operation-id $NAMESPACE_ID --query 'Operation.Status' --output text
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