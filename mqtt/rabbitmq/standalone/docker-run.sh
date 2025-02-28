#!/bin/bash

_operation="some"
_container="rabbitmqtt"
_image="rabbitmqtt"
_build_image="rabbitmqtt"
_ports="-p 15672:15672 -p 5672:5672 -p 1883:1883"
_envs=""

echo 'params: '$#
echo "$@"
if (( $# <= 0 )); then
    echo 'you must provide one operation: [log, status, create, start, stop, remove, exec]: type _operation'
    read _operation
else
    _operation=$1
fi

echo ' ==== '
echo 'selected _operation: '$_operation
echo ' ==== '

case "$_operation" in
    'create')
    	echo "=>creating Active MQ Server containers: "
        docker run -it --privileged --restart unless-stopped $_ports $_envs --name $_container --detach $_image
        
        echo "RABBIT MQ Server"
        echo "Host: http://localhost:15672/"
        echo "username: admin"
        echo "password: admin"
    ;;
    'remove')
        docker rm -f $_container
    ;;
    'build')
        docker build -t $_build_image .
    ;;
    'clean')
        docker rm -f $_container
        docker rmi -f $_image
        docker image prune -f
    ;;
    'log')
	    docker logs $_container
    ;;
    'status')
        docker ps | grep $_container
    ;;
    'start')  
	    docker start $_container
    ;;
    'stop')  
	    docker stop $_container
    ;;
    'exec')  
        docker exec -it $_container bash
    ;;
    *)
        echo _operation $_operation not recognized
    ;;
esac


echo finished!
