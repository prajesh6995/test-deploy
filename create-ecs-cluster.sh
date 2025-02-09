#!/bin/bash

# Set variables
CLUSTER_NAME="nginx-cluster"
SERVICE_NAME="nginx-service"
TASK_FAMILY="nginx-task"
CONTAINER_NAME="nginx-container"
IMAGE_URI="nginx:latest"  # NGINX official image
PORT=8733
REGION="us-east-1"
NAMESPACE="nginx-namespace"
VPC_CIDR="10.0.0.0/16"
SUBNET_CIDR1="10.0.1.0/24"
SUBNET_CIDR2="10.0.2.0/24"
ALB_NAME="nginx-alb"
TG_NAME="nginx-tg"
SG_NAME="nginx-sg"

# Function to check for errors
check_error() {
  if [ $? -ne 0 ]; then
    echo "Error: $1"
    exit 1
  fi
}

# Check and Create VPC
echo "Checking for existing VPC..."
VPC_ID=$(aws ec2 describe-vpcs --filters Name=cidr-block,Values=$VPC_CIDR --query 'Vpcs[0].VpcId' --output text)
if [ "$VPC_ID" == "None" ]; then
  echo "Creating VPC..."
  VPC_ID=$(aws ec2 create-vpc --cidr-block $VPC_CIDR --query 'Vpc.VpcId' --output text)
  check_error "Failed to create VPC"
fi
echo "VPC ID: $VPC_ID"

# Enable Container Insights for the ECS Cluster
echo "Checking ECS Cluster status before enabling Container Insights..."
CLUSTER_STATUS=$(aws ecs describe-clusters --clusters $CLUSTER_NAME --query "clusters[0].status" --output text 2>/dev/null)
if [ "$CLUSTER_STATUS" == "ACTIVE" ]; then
  echo "Enabling Container Insights..."
  aws ecs update-cluster-settings --cluster $CLUSTER_NAME --settings name=containerInsights,value=enabled
  check_error "Failed to enable Container Insights"
else
  echo "Cluster $CLUSTER_NAME is not in ACTIVE state. Skipping Container Insights configuration."
fi

# Check and Create Subnets
SUBNET_ID1=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID Name=cidr-block,Values=$SUBNET_CIDR1 --query 'Subnets[0].SubnetId' --output text)
if [ "$SUBNET_ID1" == "None" ]; then
  echo "Creating Subnet 1..."
  SUBNET_ID1=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_CIDR1 --availability-zone ${REGION}a --query 'Subnet.SubnetId' --output text)
  check_error "Failed to create Subnet 1"
fi
SUBNET_ID2=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID Name=cidr-block,Values=$SUBNET_CIDR2 --query 'Subnets[0].SubnetId' --output text)
if [ "$SUBNET_ID2" == "None" ]; then
  echo "Creating Subnet 2..."
  SUBNET_ID2=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_CIDR2 --availability-zone ${REGION}b --query 'Subnet.SubnetId' --output text)
  check_error "Failed to create Subnet 2"
fi
echo "Subnet IDs: $SUBNET_ID1, $SUBNET_ID2"

# Check and Create Internet Gateway
IGW_ID=$(aws ec2 describe-internet-gateways --filters Name=attachment.vpc-id,Values=$VPC_ID --query 'InternetGateways[0].InternetGatewayId' --output text)
if [ "$IGW_ID" == "None" ]; then
  echo "Creating and attaching Internet Gateway..."
  IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
  aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID
  check_error "Failed to create or attach Internet Gateway"
fi

# Check and Configure Route Table
ROUTE_TABLE_ID=$(aws ec2 describe-route-tables --filters Name=vpc-id,Values=$VPC_ID --query 'RouteTables[0].RouteTableId' --output text)
ROUTE_EXISTS=$(aws ec2 describe-route-tables --route-table-ids $ROUTE_TABLE_ID --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId' --output text)
if [ "$ROUTE_EXISTS" == "None" ]; then
  echo "Configuring Route Table..."
  aws ec2 create-route --route-table-id $ROUTE_TABLE_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
  check_error "Failed to configure Route Table"
fi

for SUBNET_ID in $SUBNET_ID1 $SUBNET_ID2; do
  ASSOCIATION_EXISTS=$(aws ec2 describe-route-tables --route-table-ids $ROUTE_TABLE_ID --query 'RouteTables[0].Associations[?SubnetId==`'$SUBNET_ID'`].RouteTableAssociationId' --output text)
  if [ "$ASSOCIATION_EXISTS" == "None" ]; then
    aws ec2 associate-route-table --subnet-id $SUBNET_ID --route-table-id $ROUTE_TABLE_ID
    check_error "Failed to associate Route Table with Subnet $SUBNET_ID"
  else
    echo "Subnet $SUBNET_ID already associated with the route table."
  fi
done

# Check and Create Security Group
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values=$SG_NAME Name=vpc-id,Values=$VPC_ID --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SECURITY_GROUP_ID" == "None" ]; then
  echo "Creating Security Group..."
  SECURITY_GROUP_ID=$(aws ec2 create-security-group --group-name $SG_NAME --description "Allow port $PORT and ALB traffic" --vpc-id $VPC_ID --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port $PORT --cidr 0.0.0.0/0
  aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 80 --cidr 0.0.0.0/0
  check_error "Failed to create or configure Security Group"
fi
echo "Security Group ID: $SECURITY_GROUP_ID"

# Check and Create ECS Cluster
echo "Checking for existing ECS Cluster..."
CLUSTER_EXISTS=$(aws ecs describe-clusters --clusters $CLUSTER_NAME --query "clusters[0].status" --output text 2>/dev/null)
if [ "$CLUSTER_EXISTS" != "ACTIVE" ]; then
  echo "Creating ECS Cluster..."
  aws ecs create-cluster --cluster-name $CLUSTER_NAME --region $REGION
  check_error "Failed to create ECS Cluster"
  echo "ECS Cluster '$CLUSTER_NAME' created successfully."
else
  echo "ECS Cluster '$CLUSTER_NAME' already exists."
fi

# Check and Create IAM Role for ECS Task Execution
ROLE_NAME="ecsTaskExecutionRole"
ROLE_EXISTS=$(aws iam get-role --role-name $ROLE_NAME --query 'Role.RoleName' --output text 2>/dev/null)
if [ "$ROLE_EXISTS" != "$ROLE_NAME" ]; then
  echo "Creating IAM Role for ECS Task Execution..."
  TRUST_POLICY='{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Service": "ecs-tasks.amazonaws.com"
        },
        "Action": "sts:AssumeRole"
      }
    ]
  }'
  aws iam create-role --role-name $ROLE_NAME --assume-role-policy-document "$TRUST_POLICY"
  aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
  check_error "Failed to create IAM Role"
  echo "IAM Role '$ROLE_NAME' created and policy attached."
else
  echo "IAM Role '$ROLE_NAME' already exists."
fi
ROLE_ARN=$(aws iam get-role --role-name $ROLE_NAME --query 'Role.Arn' --output text)

# Check and Register Task Definition
TASK_DEF_EXISTS=$(aws ecs list-task-definitions --family-prefix $TASK_FAMILY --query "taskDefinitionArns[-1]" --output text)
if [ "$TASK_DEF_EXISTS" == "None" ]; then
  echo "Registering Task Definition..."
  TASK_DEF_ARN=$(aws ecs register-task-definition \
    --family $TASK_FAMILY \
    --network-mode awsvpc \
    --requires-compatibilities FARGATE \
    --cpu "256" \
    --memory "512" \
    --execution-role-arn $ROLE_ARN \
    --container-definitions '[{
      "name": "'$CONTAINER_NAME'",
      "image": "'$IMAGE_URI'",
      "portMappings": [{
        "containerPort": '$PORT',
        "protocol": "tcp"
      }],
      "essential": true
    }]' \
    --query "taskDefinition.taskDefinitionArn" --output text)
  check_error "Failed to register Task Definition"
  echo "Task Definition registered: $TASK_DEF_ARN"
else
  echo "Task Definition already exists: $TASK_DEF_EXISTS"
  TASK_DEF_ARN=$TASK_DEF_EXISTS
fi

# Create Application Load Balancer
ALB_EXISTS=$(aws elbv2 describe-load-balancers --names $ALB_NAME --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)
if [ "$ALB_EXISTS" == "None" ]; then
  echo "Creating Application Load Balancer..."
  ALB_ARN=$(aws elbv2 create-load-balancer --name $ALB_NAME --subnets $SUBNET_ID1 $SUBNET_ID2 --security-groups $SECURITY_GROUP_ID --scheme internet-facing --type application --query 'LoadBalancers[0].LoadBalancerArn' --output text)
  check_error "Failed to create Load Balancer"
else
  echo "Load Balancer '$ALB_NAME' already exists."
  ALB_ARN=$ALB_EXISTS
fi

# Create Target Group
TG_EXISTS=$(aws elbv2 describe-target-groups --names $TG_NAME --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)
if [ "$TG_EXISTS" == "None" ]; then
  echo "Creating Target Group..."
  TG_ARN=$(aws elbv2 create-target-group --name $TG_NAME --protocol HTTP --port $PORT --vpc-id $VPC_ID --target-type ip --query 'TargetGroups[0].TargetGroupArn' --output text)
  check_error "Failed to create Target Group"
else
  echo "Target Group '$TG_NAME' already exists."
  TG_ARN=$TG_EXISTS
fi

# Ensure Target Group is associated with ALB
TG_ASSOCIATION=$(aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN --query 'Listeners[?DefaultActions[0].TargetGroupArn==`'$TG_ARN'`].ListenerArn' --output text 2>/dev/null)
if [ "$TG_ASSOCIATION" == "None" ]; then
  echo "Associating Target Group with Load Balancer..."
  aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn=$TG_ARN
  check_error "Failed to associate Target Group with Load Balancer"
else
  echo "Target Group '$TG_NAME' is already associated with Load Balancer '$ALB_NAME'."
fi

# Check and Create ECS Service
SERVICE_EXISTS=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --query "services[0].status" --output text 2>/dev/null)
if [ "$SERVICE_EXISTS" != "ACTIVE" ]; then
  echo "Creating ECS Service..."
  aws ecs create-service \
    --cluster $CLUSTER_NAME \
    --service-name $SERVICE_NAME \
    --task-definition $TASK_DEF_ARN \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID1,$SUBNET_ID2],securityGroups=[$SECURITY_GROUP_ID],assignPublicIp=ENABLED}" \
    --load-balancers "targetGroupArn=$TG_ARN,containerName=$CONTAINER_NAME,containerPort=$PORT" \
    --desired-count 1
  check_error "Failed to create ECS Service"
  echo "ECS Service '$SERVICE_NAME' created successfully."
else
  echo "ECS Service '$SERVICE_NAME' already exists."
fi

# Wait for the service to stabilize
aws ecs wait services-stable --cluster $CLUSTER_NAME --services $SERVICE_NAME
check_error "Service failed to stabilize"

# Retrieve ALB DNS Name
ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN --query 'LoadBalancers[0].DNSName' --output text)
echo "NGINX server is now accessible at http://$ALB_DNS"
