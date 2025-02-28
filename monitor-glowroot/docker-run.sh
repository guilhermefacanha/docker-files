#!/bin/bash

_operation="some"
_container="glowroot"
_build_image="glowroot:1.0"
_image="glowroot/glowroot-central:latest"
_volume=data
_port="4000"

if (( $# <= 0 )); then
    echo "you must provide one operation: 
    [
    help - show data about connections and credentials, 
    build - build image $_build_image from Dockerfile, 
    create - create a new container $_container from built image, 
    status - show container $_container status, 
    log - show container $_container log, 
    start - start the container $_container, 
    stop - stop the container $_container, 
    remove - remove the container $_container, 
    clean - remove the container $_container and clean all image data from hard drive, 
    exec - open container $_container shell
    ]"
    read _operation
else
    _operation=$1
fi

echo ' ==== '
echo 'selected _operation: '$_operation
echo ' ==== '

showHelp(){
    
    echo ""
    echo "Glowroot Central Server Installed"
    echo ""
    echo "Execute docker-run.sh exec to enter in shell mode"
    echo "run command to install all necessary components"
    echo "> ./opt/install.sh"
    echo ""
    
    echo ""
    echo "After install enter Glowroot central at"
    echo "URL: http://localhost:4000"
    echo ""
}

case "$_operation" in
    'help')
        showHelp
    ;;
    'create')
    	echo "=>creating $_container container: "
		docker run --privileged -it -d -p 4000:4000 -p 3100:3100 --name $_container $_build_image
		
        echo "SonarFinder Docker Created"
		showHelp
	    
    ;;
    'remove')
        docker rm -f $_container
    ;;
    'build')
        #docker build --rm --no-cache -t $_build_image .
        docker build -t $_build_image .
    ;;
    'clean')
        docker rm -f $_container
        docker rmi -f $_build_image
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
        echo "operation '$_operation' not recognized"
    ;;
esac


echo finished!