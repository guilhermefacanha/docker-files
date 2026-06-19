#!/bin/bash

_operation="some"
_container="mongodb"
_image="mongo:8.0.20"
_build_image="mongodb:1.0"
_volume=""  #"-v /my/host/path:/data/db"
_envVars=" --env MONGO_INITDB_ROOT_USERNAME=admin --env MONGO_INITDB_ROOT_PASSWORD=admin "

#port -p host:container_port
_port=" -p 27017:27017"

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
		docker run -it $_port $_volume $_envVars --name $_container  -d $_image
		
		echo "MongoDb Created"
	    echo "Host: localhost:$_port"
		echo "Login: admin"
		echo "Password: admin"
	    echo "You can use one of the following clients:"
	    echo "MongoDB Compass: https://www.mongodb.com/products/compass"
	    echo "mongosh --host localhost -u admin --authenticationDatabase admin admin"
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
