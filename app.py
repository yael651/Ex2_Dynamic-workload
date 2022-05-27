import boto3
import requests
from datetime import datetime
from ec2_metadata import ec2_metadata
from flask import Flask, request
from uhashring import HashRing

data_dict = {}
expiration_dict = {}    
app = Flask(__name__)

complete_work = {}

def work(buffer, iterations):
    import hashlib
    output = hashlib.sha512(buffer).digest()
    for i in range(iterations - 1):
        output = hashlib.sha512(output).digest()
    return output

@app.route('/enqueue', methods=['PUT'])
def enqueue():
    num_iteration = int(request.args.get('iterations'))
    body = str(request.data)
    result = work(body.encode('utf-8'), num_iteration)
    import time
    key = int(time.time())
    if key == None:
        return"", 401

    complete_work[key] = [body, num_iteration,result]
    #pass data to other node
    healty_nodes = get_healty_instances_id()
    if (len(healty_nodes) > 1):
        for instance in healty_nodes:
            #send to everyone that is not you
            if str(instance)[:14] != str(ec2_metadata.instance_id)[:14]:
                next_dns = get_instance_public_dns(instance)
                end_point = "http://" + next_dns + "/putDenka?iterations=" + str(num_iteration) + "&data=" + body + "&result=" + str(result) + "&time=" + str(key)
                requests.post(url=end_point)

    return "", 201


@app.route('/pullCompleted', methods=['POST'])
def pullCompleted():
    top = int(request.args.get('top'))
    #get results from other ec2
    healty_nodes = get_healty_instances_id()
    if (len(healty_nodes) > 1):
        for instance in healty_nodes:
            if str(instance)[:14] != str(ec2_metadata.instance_id)[:14]:
                next_dns = get_instance_public_dns(instance)
                end_point = "http://" + next_dns + "/getDenka?top=" + str(top)
                ans = requests.post(url=end_point)
                try:
                    ans = ans.text
                    new_works = eval(ans)#make it dict
                    new_keys = list(new_works.keys())
                    for work_id in new_keys:
                        if int(work_id) not in list(complete_work.keys()):
                            complete_work[int(work_id)] = new_works[work_id]
                except:
                    print("Bad Parsing")
                    continue

    r = list(complete_work.keys())
    if len(r) ==0 :
        return "",201
    #print(r)
    r.sort()
    r.reverse()
    r = r[:top]
    result = ""
    #print resuls from current ec2
    for work_id in r:
        r_body, r_iteration,r_hash = complete_work[work_id]
        result += "work_id = " + str(work_id) + " r_hash = " + str(r_hash) + "\n"


    return result, 201
  



@app.route('/healthcheck', methods=['GET', 'POST'])
def health():
    return "bol", 200


@app.route('/putDenka', methods=['POST'])
def putDenka():
    num_iteration = request.args.get('iterations')
    data = request.args.get('data')
    result = request.args.get('result')
    time = int(request.args.get('time'))
    if time != None:
        if time not in list(complete_work.keys()):
           complete_work[time] = [data, num_iteration,result]

    return "",201

@app.route('/getDenka', methods=['POST'])
def getDenka():
    top = int(request.args.get('top'))
    return str(complete_work),201

def get_healty_instances_id():

    elb = boto3.client('elbv2', region_name=ec2_metadata.region)
    lbs = elb.describe_load_balancers()
    isFound = False

    for current_lb in lbs["LoadBalancers"]:
        lb_arn = current_lb["LoadBalancerArn"]
        response_tg = elb.describe_target_groups(
            LoadBalancerArn=lb_arn
        )

        num_of_tg = len(response_tg["TargetGroups"])
        for current_tg in response_tg["TargetGroups"]:
            target_group_arn = current_tg["TargetGroupArn"]

            response_health = elb.describe_target_health(
                TargetGroupArn=target_group_arn
            )

            healty_instances = []
            for instance in response_health['TargetHealthDescriptions']:
                if instance['TargetHealth']['State'] == 'healthy':
                    healty_instances.append(instance['Target']['Id'])
                    if (instance['Target']['Id'] == ec2_metadata.instance_id):
                        isFound = True

            if (isFound):
                return healty_instances
    return []

def get_instance_public_dns(instanc_id):
    client = boto3.client('ec2', region_name=ec2_metadata.region)
    response_in = client.describe_instances(
        InstanceIds=[
            str(instanc_id)
        ]
    )

    public_dns_name = response_in['Reservations'][0]['Instances'][0]['PublicDnsName']
    return public_dns_name

def get_key_node_id(key, nodes):
    hr = HashRing(nodes=nodes)
    target_node_id = hr.get_node(key)

    return target_node_id