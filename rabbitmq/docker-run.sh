#!/bin/bash

_operation="some"
_container="rabbitmq"
_image="rabbitmq:3-management"
_build_image="jms/rabbitmq:1.0"

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
    	echo "=>creating ldap containers: "
	docker run -p 5672:5672 -p 15672:15672 -e RABBITMQ_DEFAULT_USER=admin -e RABBITMQ_DEFAULT_PASS=admin --name $_container --detach $_image
	
	echo "Rabbit MQ Server"
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
