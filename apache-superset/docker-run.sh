#!/bin/bash

_operation="some"
_container="superset"
_image="tylerfowler/superset"
_build_image="superset:1.0"
_volume=/Users/guilhermefacanha/workspace/docker/postgresql12/data

_port="8088"

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
    	echo "=>creating $_container container: "
        docker run -d --name $_container -e ADMIN_USERNAME=admin -e ADMIN_FIRST_NAME=Adminitrator -e ADMIN_LAST_NAME=LastName -e ADMIN_EMAIL=email@email.com -e ADMIN_PWD=admin -p $_port:$_port $_image
		
		
        echo "Container Created"
	    echo "Container: $_container"
	    echo "Host: localhost:$_port"
		echo "Login: admin"
		echo "Password: admin"

        echo ""
        echo "Use host http://host.docker.internal to connect from container to host machine"
        echo ""

        echo ""
        echo "To install mysql client use commands:"
        echo ">apt-get update"
        echo ">apt-get install python3-dev default-libmysqlclient-dev build-essential"
        echo ">pip install --upgrade pip"
        echo ">pip install mysqlclient"
        echo ""
	    
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
        docker ps | grep ldap
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
