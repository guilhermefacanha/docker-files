#!/bin/bash

_operation="some"
_container="grafana"
_image="grafana/grafana"
_build_image="grafana:1.0"
_volume=/Users/guilhermefacanha/workspace/docker/postgresql12/data

_port="3000"

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
        docker run -d --name $_container -p $_port:$_port $_image
		
		
        echo "Container Created"
	    echo "Container: $_container"
	    echo "Host: localhost:$_port"
		echo "Login: admin"
		echo "Password: admin"

        echo ""
        echo "Use host http://host.docker.internal to connect from container to host machine"
        echo ""

        echo ""
        echo "To install plugins run docker with -e \"GF_INSTALL_PLUGINS=http://plugin-domain.com/my-custom-plugin.zip;custom-plugin\" "
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
        docker exec -it -u 0 $_container bash
    ;;
    *)
        echo _operation $_operation not recognized
    ;;
esac


echo finished!
