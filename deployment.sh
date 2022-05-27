# debug
# set -o xtrace

KEY_NAME="cloud-course-`date +'%N'`"
ELB_NAME="elb-`date +'%N'`"
KEY_PEM="$KEY_NAME.pem"
TARGET_GRP="target-group-`date +'%N'`"
ELB_ROLE_NAME=$"elb-rule-`date +'%N'`"
ELB_POLICY_NAME=$"ELBFullAccessPolicy-`date +'%N'`"
INSTANCE_PROFILE_NAME=$"InstanceProfileNameF"

echo "create key pair $KEY_PEM to connect to instances and save locally"
aws ec2 create-key-pair --key-name $KEY_NAME \
    | jq -r ".KeyMaterial" > $KEY_PEM

# secure the key pair
chmod 400 $KEY_PEM

SEC_GRP="my-sg-`date +'%N'`"

echo "setup firewall $SEC_GRP"
SEC_GRP_ID=$(aws ec2 create-security-group   \
    --group-name $SEC_GRP       \
    --description "Access my instances" |
	jq -r '.GroupId')
	

# figure out my ip
MY_IP=$(curl ipinfo.io/ip)
echo "My IP: $MY_IP"


echo "setup rule allowing SSH access"
aws ec2 authorize-security-group-ingress        \
    --group-name $SEC_GRP --port 22 --protocol tcp \
    --cidr 0.0.0.0/0

echo "setup rule allowing HTTP (port 80)"
aws ec2 authorize-security-group-ingress        \
    --group-name $SEC_GRP --port 80 --protocol tcp \
    --cidr 0.0.0.0/0


VPC=$(aws ec2 describe-security-groups \
    --group-ids $SEC_GRP_ID |
	jq -r '.SecurityGroups[0].VpcId'
)

echo "VPC: $VPC"


TARGET_GRP_ARN=$(aws elbv2 create-target-group \
    --name $TARGET_GRP \
    --protocol HTTP \
    --port 80 \
    --target-type instance \
	--health-check-path "/healthcheck" \
	--health-check-protocol HTTP \
	--health-check-interval-seconds 5 \
	--health-check-timeout-seconds 3 \
	--healthy-threshold-count 2 \
	--unhealthy-threshold-count 2 \
	--vpc-id $VPC |
	jq -r '.TargetGroups[0].TargetGroupArn'
)	

echo "Target group ARN: $TARGET_GRP_ARN"

FIRST_SUBNET=$(aws ec2 describe-subnets | 
	jq -r '.Subnets[0].SubnetId'
)

SECOND_SUBNET=$(aws ec2 describe-subnets | 
	jq -r '.Subnets[1].SubnetId'
)	

echo "creating load balancer"
ELB_ARN=$(aws elbv2 create-load-balancer --name $ELB_NAME \
	--subnets $FIRST_SUBNET $SECOND_SUBNET \
	--security-groups $SEC_GRP_ID |
	jq -r '.LoadBalancers[0].LoadBalancerArn'
)

echo "Load Balancer ARN: $ELB_ARN"

echo "create http listener"

aws elbv2 create-listener \
    --load-balancer-arn $ELB_ARN \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=forward,TargetGroupArn=$TARGET_GRP_ARN
	
	
echo "create iam rule for elb access"	
aws iam create-role --role-name $ELB_ROLE_NAME --assume-role-policy-document file://ec2-role-trust-policy.json

aws iam put-role-policy --role-name $ELB_ROLE_NAME --policy-name $ELB_POLICY_NAME --policy-document file://elbPolicy.json

aws iam create-instance-profile --instance-profile-name $INSTANCE_PROFILE_NAME

aws iam add-role-to-instance-profile --instance-profile-name $INSTANCE_PROFILE_NAME --role-name $ELB_ROLE_NAME

sleep 10

UBUNTU_20_04_AMI=$(aws ec2 describe-images --owners 099720109477 \
	--filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-????????" \
	"Name=state,Values=available" --query \
	"reverse(sort_by(Images, &Name))[:1].ImageId" --output text)

for i in 1 2
do
	echo "Creating instance number $i"
	
	echo "Creating Ubuntu 20.04 instance... Ubuntu AMI: $UBUNTU_20_04_AMI"
	RUN_INSTANCES=$(aws ec2 run-instances   \
		--image-id $UBUNTU_20_04_AMI        \
		--iam-instance-profile Name=$INSTANCE_PROFILE_NAME \
		--instance-type t3.micro            \
		--key-name $KEY_NAME                \
		--security-group-ids $SEC_GRP_ID			\
		--subnet-id $SECOND_SUBNET)

	INSTANCE_ID=$(echo $RUN_INSTANCES | jq -r '.Instances[0].InstanceId')

	echo "Waiting for instance creation..."
	aws ec2 wait instance-running --instance-ids $INSTANCE_ID
	
	PUBLIC_IP=$(aws ec2 describe-instances  --instance-ids $INSTANCE_ID | 
		jq -r '.Reservations[0].Instances[0].PublicIpAddress'
	)

	sleep 5 
	
	echo "New instance $INSTANCE_ID @ $PUBLIC_IP"
	
	echo "Register instance to target group"
	aws elbv2 register-targets \
		--target-group-arn $TARGET_GRP_ARN \
		--targets Id=$INSTANCE_ID
	
	sleep 5
	
	echo "deploying code to production"
	scp -i $KEY_PEM -o "StrictHostKeyChecking=no" -o "ConnectionAttempts=60" app.py ubuntu@$PUBLIC_IP:/home/ubuntu/

	sleep 5
	
	echo "setup production environment"
	
	ssh -i $KEY_PEM -o "StrictHostKeyChecking=no" -o "ConnectionAttempts=10" ubuntu@$PUBLIC_IP <<EOF
		sudo echo OK > healthcheck
		sudo apt-get update
		sudo apt-get install python3-pip -y
		sudo apt-get install python3-flask -y
		sudo python3 -m pip install ec2-metadata
		sudo pip install boto3
		sudo python3 -m pip install uhashring
		# run app
		sudo nohup sudo flask run --host 0.0.0.0 --port 80 &>/dev/null &
		exit
EOF

	sleep 5

done 