#!/bin/bash

set -e

export DIGITALOCEAN_IMAGE=debian-8-x64
export DIGITALOCEAN_PRIVATE_NETWORKING=true
export DIGITALOCEAN_REGION=sfo1
export NUM_WORKERS=3

case "$1" in 
        up)
                if [[ -z "$DIGITALOCEAN_ACCESS_TOKEN" ]]; then
                    echo "Must set DIGITALOCEAN_ACCESS_TOKEN for the script to work."
                    exit 1
                fi
                
                echo "=> Creating KV store for Consul."
                docker-machine create -d digitalocean kvstore
                
                echo "=> Creating Swarm master node."
                export KV_IP=$(docker-machine ssh kvstore 'ifconfig eth1 | grep "inet addr:" | cut -d: -f2 | cut -d" " -f1')
                docker $(docker-machine config kvstore) run -d \
                        -p ${KV_IP}:8500:8500 \
                        -h consul \
                        progrium/consul -server -bootstrap
                        
                docker-machine create \
                    -d digitalocean \
                    --swarm \
                    --swarm-master \
                    --swarm-discovery="consul://${KV_IP}:8500" \
                    --engine-opt="cluster-store=consul://${KV_IP}:8500" \
                    --engine-opt="cluster-advertise=eth1:2376" \
                    queenbee
                    
                echo "=> Creating Swarm worker nodes."
                for i in $(seq 1 $NUM_WORKERS); do
                    docker-machine create \
                        -d digitalocean \
                        --swarm \
                        --swarm-discovery="consul://${KV_IP}:8500" \
                        --engine-opt="cluster-store=consul://${KV_IP}:8500" \
                        --engine-opt="cluster-advertise=eth1:2376" \
                        workerbee-${i} &
                done;
                wait
        ;;
        provision)
                eval $(docker-machine env --swarm queenbee)
                for i in $(seq 0 ${NUM_WORKERS}); do 
                        docker-compose -f ansible-provision.yml run -d provision; 
                done

                while [[ $(docker ps -q | wc -l) -ne 0 ]]; do
                        sleep 1
                        echo "=> Waiting for Ansible provisioning to finish..."
                done

                echo "=> Cleaning up provisioning containers."
                docker rm $(docker ps -aq --filter label=com.docker.compose.service=provision)

                echo "=> Restarting nodes to enable memory accounting. This may take a few minutes."
                docker-machine restart queenbee workerbee-{1..3}
        ;;
        down)
                docker-machine rm kvstore queenbee workerbee-{1..3}
        ;;
        *)
                echo "Usage: ./ctl.sh [up|provision|down]"
                exit 1
        ;;
esac
