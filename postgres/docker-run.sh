#!/bin/bash

_operation="some"
_container="postgres11"
_image="postgres:11"
_build_image="postgres:1.0"
_volume=/Users/guilhermefacanha/workspace/docker/postgresql11/data

_port="5432"

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
		docker run -p $_port:$_port --name $_container --restart unless-stopped -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=1234 -v $_volume:/var/lib/postgresql/data -d $_image
		
		echo "Postgres Created"
	    echo "Container: $_container"
	    echo "Host: localhost:$_port"
		echo "Login: postgres"
		echo "Password: 1234"
	    
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
