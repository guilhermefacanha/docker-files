#!/bin/bash

_operation="some"
_container="activemq"
_image="vromero/activemq-artemis"
_build_image="jms/activemq:1.0"
_ports="-p 8161:8161 -p 61616:61616"
_envs="-e ARTEMIS_USERNAME=admin -e ARTEMIS_PASSWORD=admin"

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
        docker run $_ports $_envs --name $_container --detach $_image
        
        echo "Active MQ Server"
        echo "Host: http://localhost:8161/admin"
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
