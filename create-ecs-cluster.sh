#!/bin/bash

# Set variables
CLUSTER_NAME="nginx-cluster"
SERVICE_NAME="nginx-service"
TASK_FAMILY="nginx-task"
CONTAINER_NAME="nginx-container"
IMAGE_URI="nginx:latest"  # NGINX official image
PORT=80
REGION="us-east-1"
VPC_CIDR="10.0.0.0/16"
SUBNET_CIDR1="10.0.1.0/24"
SUBNET_CIDR2="10.0.2.0/24"
ALB_NAME="nginx-alb"
TG_NAME="nginx-tg"
SG_NAME="nginx-sg"
EXECUTION_ROLE_NAME="ecsTaskExecutionRole"
TASK_ROLE_NAME="ecsTaskRole"

# Function to check for errors
check_error() {
  if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: $1"
    exit 1
  fi
}

# Retrieve available AZs dynamically
AVAILABLE_AZS=($(aws ec2 describe-availability-zones --region $REGION --query 'AvailabilityZones[*].ZoneName' --output text))
AZ1=${AVAILABLE_AZS[0]}
AZ2=${AVAILABLE_AZS[1]}

# Create ECS Cluster
echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating ECS Cluster..."
aws ecs create-cluster --cluster-name $CLUSTER_NAME
check_error "Failed to create ECS Cluster"

# Create VPC
echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating VPC..."
VPC_ID=$(aws ec2 create-vpc --cidr-block $VPC_CIDR --query 'Vpc.VpcId' --output text)
check_error "Failed to create VPC"

# Enable public DNS hostname for VPC
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames '{"Value":true}'

# Create and attach Internet Gateway
IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
check_error "Failed to create Internet Gateway"
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
check_error "Failed to attach Internet Gateway"

# Create Route Table and associate with subnets
ROUTE_TABLE_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text)
check_error "Failed to create Route Table"
aws ec2 create-route --route-table-id $ROUTE_TABLE_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
check_error "Failed to create route to Internet Gateway"

# Create Subnets in Different AZs
echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Subnet 1 in $AZ1..."
SUBNET_ID1=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_CIDR1 --availability-zone $AZ1 --query 'Subnet.SubnetId' --output text)
check_error "Failed to create Subnet 1"
aws ec2 associate-route-table --subnet-id $SUBNET_ID1 --route-table-id $ROUTE_TABLE_ID
aws ec2 modify-subnet-attribute --subnet-id $SUBNET_ID1 --map-public-ip-on-launch

echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Subnet 2 in $AZ2..."
SUBNET_ID2=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_CIDR2 --availability-zone $AZ2 --query 'Subnet.SubnetId' --output text)
check_error "Failed to create Subnet 2"
aws ec2 associate-route-table --subnet-id $SUBNET_ID2 --route-table-id $ROUTE_TABLE_ID
aws ec2 modify-subnet-attribute --subnet-id $SUBNET_ID2 --map-public-ip-on-launch

# Create Security Group
echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Security Group..."
SG_ID=$(aws ec2 create-security-group --group-name $SG_NAME --description "Security group for NGINX ALB" --vpc-id $VPC_ID --query 'GroupId' --output text)
check_error "Failed to create Security Group"
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port $PORT --cidr 0.0.0.0/0
check_error "Failed to set security group ingress rules"
aws ec2 authorize-security-group-egress --group-id $SG_ID --protocol -1 --cidr 0.0.0.0/0
check_error "Failed to set security group egress rules"

# Create Load Balancer
echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Load Balancer..."
ALB_ARN=$(aws elbv2 create-load-balancer --name $ALB_NAME --subnets $SUBNET_ID1 $SUBNET_ID2 --security-groups $SG_ID --query 'LoadBalancers[0].LoadBalancerArn' --output text)
check_error "Failed to create Load Balancer"
sleep 30  # Allow time for ALB to become available

# Create Target Group
echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Target Group..."
TG_ARN=$(aws elbv2 create-target-group --name $TG_NAME --protocol HTTP --port $PORT --vpc-id $VPC_ID --query 'TargetGroups[0].TargetGroupArn' --output text)
check_error "Failed to create Target Group"

# Create Listener
echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating Listener..."
aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port $PORT --default-actions Type=forward,TargetGroupArn=$TG_ARN
check_error "Failed to create Listener"

# Create ECS Task Execution Role
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
aws iam create-role --role-name $EXECUTION_ROLE_NAME --assume-role-policy-document "$TRUST_POLICY"
check_error "Failed to create ECS Task Execution Role"

# Attach AmazonECSTaskExecutionRolePolicy to the execution role
aws iam attach-role-policy --role-name $EXECUTION_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
check_error "Failed to attach policy to ECS Task Execution Role"

# Register ECS Task Definition
echo "$(date '+%Y-%m-%d %H:%M:%S') - Registering ECS Task Definition..."
aws ecs register-task-definition --family $TASK_FAMILY \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu "256" --memory "512" \
  --execution-role-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/$EXECUTION_ROLE_NAME \
  --container-definitions '[{"name":"'$CONTAINER_NAME'","image":"'$IMAGE_URI'","portMappings":[{"containerPort":'$PORT'}]}]'
check_error "Failed to register ECS Task Definition"

# Create ECS Service
echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating ECS Service..."
aws ecs create-service --cluster $CLUSTER_NAME --service-name $SERVICE_NAME \
  --task-definition $TASK_FAMILY --desired-count 1 \
  --launch-type FARGATE --network-configuration "awsvpcConfiguration={subnets=[\"$SUBNET_ID1\",\"$SUBNET_ID2\"],securityGroups=[\"$SG_ID\"],assignPublicIp=ENABLED}" \
  --load-balancers "targetGroupArn=$TG_ARN,containerName=$CONTAINER_NAME,containerPort=$PORT"
check_error "Failed to create ECS Service"

# Output Load Balancer DNS
ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN --query 'LoadBalancers[0].DNSName' --output text)
echo "$(date '+%Y-%m-%d %H:%M:%S') - Deployment successful! Access your application at http://$ALB_DNS"
