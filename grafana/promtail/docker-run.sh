#!/bin/bash

_operation="some"
_container="promtail-alpine"
_image="alpine"
_build_image="promtail-alpine"
_volume="-v /Users/guilherme.facanha/workspace/sonar/logs:/opt/logs -v ./config:/opt/config"

_port="9081"

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
        docker run --platform=linux/amd64 -d -it --name $_container -p $_port:$_port $_volume $_build_image
		
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
        #docker build --no-cache -t $_build_image .
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
