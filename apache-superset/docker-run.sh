#!/bin/bash

_operation="some"
_container="superset"
_build_image="superset:3.1.1"
_build_latest="superset:latest"
_version="3.1.1"
_volume=data
_port=" -p 8088:8088"

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
    	echo ">docker run -d --name $_container $_port $_build_image"
      docker run -d --name $_container $_port $_build_image
      echo "Container Created"
	    echo "Container: $_container"
	    echo "Host: localhost:$_port"
		echo "Login: admin"
		echo "Password: admin"

        echo ""
        echo "Use host http://host.docker.internal to connect from container to host machine"
        echo ""
        
        echo "to create admin"
        echo "docker exec -it superset superset fab create-admin --username admin --firstname Superset --lastname Admin --email admin@superset.com --password admin"
		
		echo "to migrate local DB to latest"              
        echo "$ docker exec -it superset superset db upgrade"
        
        echo "to load examples"
        echo "docker exec -it superset superset load_examples"
        
        echo "to setup roles"
        echo "docker exec -it superset superset init"
        
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
        docker rmi -f $_build_image
        docker image prune -f
    ;;
    'log')
	    docker logs -f $_container
    ;;
    'status')
        docker ps | grep ldap
    ;;
   'tag')
      	echo "tag/exporting container to image with tag $_build_image"
      	echo ">docker commit $_container $_build_image"
      	docker commit $_container $_build_image
      	echo ">docker tag $_build_image guilhermefacanha/$_build_image"
        docker tag $_build_image guilhermefacanha/$_build_image
      	echo ">docker push guilhermefacanha/$_build_image"
        docker push guilhermefacanha/$_build_image
    ;;
  'tag-latest')
        	echo "tag/exporting container to image with tag $_build_latest"
        	echo ">docker commit $_container $_build_latest"
        	docker commit $_container $_build_latest
        	echo ">docker tag $_build_latest guilhermefacanha/$_build_latest"
          docker tag $_build_latest guilhermefacanha/$_build_latest
        	echo ">docker push guilhermefacanha/$_build_latest"
          docker push guilhermefacanha/$_build_latest
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
