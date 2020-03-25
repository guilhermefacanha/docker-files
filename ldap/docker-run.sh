#!/bin/bash

_operation="some"
_container="openldap"
_image="osixia/openldap:1.3.0"
_build_image="ldap/openldap:1.0"

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
	docker run -p 389:389 -p 636:636 --hostname ldap.local.com --env LDAP_ADMIN_PASSWORD="admin" --name $_container --detach $_image
	
	echo "Open LDAP credentials"
    echo "Host: localhost:389"
    echo "Login DN: cn=admin,dc=example,dc=org"
	echo "Password: admin"
    echo "You can use one of the following clients:"
    echo "Apache Directory Studio: https://directory.apache.org/studio/"
    echo "JXplorer simple client: http://jxplorer.org/"
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
