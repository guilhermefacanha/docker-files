#!/bin/bash

_operation="some"
_container="eap7.2"
_backup="_backup"
_image="daggerok/jboss-eap-7.2:7.2.5-centos"
_build_image="workflow/eap7.2:latest"

echo 'params: '$#
echo "$@"
if (( $# <= 0 )); then
    echo "you must provide one operation: [
        log - show log for container $_container, 
        status - show status for container $_container, 
        build - build image $_build_image with Dockerfile, 
        create - create container $_container for image $_build_image, 
        start - start container $_container, 
        stop - stop container $_container,
        remove - remove container $_container, 
        exec - enter execution mode for container $_container,
        clean - clean all container $_container files and images,
        save - image $_build_image into tar file
        backup - create backup commit for container $_container
        ] : type _operation"
    read _operation
else
    _operation=$1
fi

echo "selected _operation: [$_operation]"
echo ' ==== '

case "$_operation" in
    'create')
    	echo "Creating container $_container for image $_build_image ... "
	    docker run -i -d -p 8943:8443  -p 8580:8080 -p 10490:9990 --name $_container $_build_image

        echo "==================================
        ports
        management: 10490:9990
        web http: 8580:8080
        https: 8943:8443

        web administration
        username: admin
        password: Admin.123
        =================================="
    ;;
    'remove')
        docker rm -f $_container
    ;;
    'build')
        echo "Building $_build_image image ...."
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
    'save')
        echo "Saving image  $_build_image.tar ..."
        docker save $_build_image > $_build_image.tar
    ;;
    'backup')  
        echo "Creating backup for $_container with name $_container$_backup ..."
        docker commit $_container $_container$_backup
        echo "Saving backup for $_container$_backup with name $_container$_backup.tar ..."
        docker save $_container$_backup > $_container$_backup.tar
    ;;
    *)
        echo "Operation [$_operation] not recognized"
    ;;
esac


echo ""
echo finished!
echo " ============ "
